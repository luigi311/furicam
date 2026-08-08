// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2023 Droidian Project
// Copyright (C) 2024 Furi Labs
//
// Authors:
// Bardia Moshiri <fakeshell@bardia.tech>
// Erik Inkinen <erik.inkinen@gmail.com>
// Alexander Rutz <alex@familyrutz.com>

#include "thumbnailgenerator.h"

#include <QUrl>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QDateTime>
#include <QDebug>
#include <QStandardPaths>
#include <QCryptographicHash>
#include <QTimer>

ThumbnailGenerator::ThumbnailGenerator(QObject *parent) : QObject(parent) {
    qRegisterMetaType<QImage>("QImage");
} 
void ThumbnailGenerator::setVideoSource(const QString &videoSource) {
    // The QML side passes a file:// URL; ffmpeg needs a plain filesystem path.
    QString path = videoSource;
    const QUrl u(videoSource);
    if (u.isLocalFile())
        path = u.toLocalFile();

    if (path.isEmpty() || !QFile::exists(path)) {
        qDebug() << "ThumbnailGenerator: video not found:" << path;
        return;
    }

    // Skip files written in the last couple of seconds: an MP4 still being
    // recorded has no moov atom yet, so ffmpeg exits 183 and the failure is
    // wasted work (and noisy).  Retry shortly instead of dropping: the gallery
    // refresh right after stopRecording() lands inside this window, and the
    // review button's thumbnail only ever updates via thumbnailGenerated.
    const QFileInfo fi(path);
    const qint64 ageMs = fi.lastModified().msecsTo(QDateTime::currentDateTime());
    if (ageMs < 2000) {
        qDebug() << "ThumbnailGenerator: deferring very recent (likely still recording) file:" << path;
        QTimer::singleShot(2000 - ageMs, this, [this, videoSource]() {
            setVideoSource(videoSource);
        });
        return;
    }

    // Only one extraction at a time; drop any in-flight job (e.g. when the user
    // swipes quickly between videos).
    if (m_proc) {
        m_proc->kill();
        m_proc->deleteLater();
        m_proc = nullptr;
    }

    m_outPath = QDir::tempPath() + QStringLiteral("/furicam_vidthumb.jpg");
    QFile::remove(m_outPath);

    m_proc = new QProcess(this);
    connect(m_proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int exitCode, QProcess::ExitStatus) {
        qDebug() << "ThumbnailGenerator: ffmpeg finished, exit:" << exitCode << "path:" << m_outPath;
        QImage img(m_outPath);
        if (!img.isNull()) {
            qDebug() << "ThumbnailGenerator: image loaded" << img.width() << "x" << img.height();
            emit thumbnailGenerated(img);
        } else {
            qDebug() << "ThumbnailGenerator: failed to load thumbnail from" << m_outPath;
        }
        if (m_proc) {
            m_proc->deleteLater();
            m_proc = nullptr;
        }
    });

    // Decode just the first frame, scaled down to a thumbnail.  Software decode
    // (the default) works regardless of the device's hardware codec path.
    QStringList args;
    args << QStringLiteral("-y")
         << QStringLiteral("-loglevel") << QStringLiteral("error")
         << QStringLiteral("-i") << path
         << QStringLiteral("-frames:v") << QStringLiteral("1")
         << QStringLiteral("-vf") << QStringLiteral("scale=320:-2")
         << m_outPath;
    qDebug() << "ThumbnailGenerator: starting" << "/usr/bin/ffmpeg" << args;
    m_proc->start(QStringLiteral("/usr/bin/ffmpeg"), args);
}

QString ThumbnailGenerator::toQmlImage(const QImage &image) {
    QByteArray byteArray;
    QBuffer buffer(&byteArray);
    image.save(&buffer, "PNG");
    return QString("data:image/png;base64,") + QString(byteArray.toBase64());
}

QString ThumbnailGenerator::cachePathFor(const QString &localPath) const {
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
                        + QStringLiteral("/vidthumbs");
    QDir().mkpath(dir);
    // Key on path + mtime so a replaced/re-encoded file gets a fresh thumbnail.
    QFileInfo fi(localPath);
    const QString key = localPath + QString::number(fi.lastModified().toSecsSinceEpoch());
    const QString hash = QString::fromLatin1(
        QCryptographicHash::hash(key.toUtf8(), QCryptographicHash::Md5).toHex());
    return dir + QLatin1Char('/') + hash + QStringLiteral(".jpg");
}

QString ThumbnailGenerator::cachedThumbnail(const QString &videoUrl) {
    QString path = videoUrl;
    const QUrl u(videoUrl);
    if (u.isLocalFile())
        path = u.toLocalFile();
    if (path.isEmpty() || !QFile::exists(path))
        return QString();

    const QString out = cachePathFor(path);
    if (QFile::exists(out))
        return QUrl::fromLocalFile(out).toString();

    // Not cached yet — enqueue (de-duplicated) and let the worker generate it.
    if (m_curReqUrl != videoUrl && !m_pending.contains(videoUrl))
        m_pending.enqueue(videoUrl);
    processQueue();
    return QString();
}

void ThumbnailGenerator::processQueue() {
    if (m_cacheProc || m_pending.isEmpty())
        return;

    m_curReqUrl = m_pending.dequeue();
    QString path = m_curReqUrl;
    const QUrl u(m_curReqUrl);
    if (u.isLocalFile())
        path = u.toLocalFile();
    m_curOutPath = cachePathFor(path);

    if (QFile::exists(m_curOutPath)) {
        emit thumbnailReady(m_curReqUrl, QUrl::fromLocalFile(m_curOutPath).toString());
        m_curReqUrl.clear();
        processQueue();
        return;
    }

    m_cacheProc = new QProcess(this);
    connect(m_cacheProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int, QProcess::ExitStatus) {
        if (QFile::exists(m_curOutPath))
            emit thumbnailReady(m_curReqUrl, QUrl::fromLocalFile(m_curOutPath).toString());
        m_cacheProc->deleteLater();
        m_cacheProc = nullptr;
        m_curReqUrl.clear();
        processQueue();
    });

    QStringList args;
    args << QStringLiteral("-y")
         << QStringLiteral("-loglevel") << QStringLiteral("error")
         << QStringLiteral("-i") << path
         << QStringLiteral("-frames:v") << QStringLiteral("1")
         << QStringLiteral("-vf") << QStringLiteral("scale=480:-2")
         << m_curOutPath;
    m_cacheProc->start(QStringLiteral("/usr/bin/ffmpeg"), args);
}
