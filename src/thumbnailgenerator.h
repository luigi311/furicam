// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2023 Droidian Project
// Copyright (C) 2024 Furi Labs
//
// Authors:
// Bardia Moshiri <fakeshell@bardia.tech>
// Erik Inkinen <erik.inkinen@gmail.com>
// Alexander Rutz <alex@familyrutz.com>

#ifndef THUMBNAILGENERATOR_H
#define THUMBNAILGENERATOR_H

#include <QObject>
#include <QImage>
#include <QBuffer>
#include <QProcess>
#include <QQueue>

class ThumbnailGenerator : public QObject
{
    Q_OBJECT
public:
    ThumbnailGenerator(QObject *parent = nullptr);
    Q_INVOKABLE void setVideoSource(const QString &videoSource);
    Q_INVOKABLE QString toQmlImage(const QImage &image);
    // Returns a cached thumbnail file:// URL for a video if one already exists,
    // otherwise "" and kicks off async generation — thumbnailReady() fires with
    // the same videoUrl when it's done.  Used by the gallery's video pager so
    // swiping shows a still instantly instead of spinning up a QMediaPlayer.
    Q_INVOKABLE QString cachedThumbnail(const QString &videoUrl);

signals:
    void thumbnailGenerated(const QImage &image);
    void thumbnailReady(const QString &videoUrl, const QString &thumbUrl);

private:
    void processQueue();
    QString cachePathFor(const QString &localPath) const;

    // Frames are extracted with ffmpeg (software decode) rather than
    // QMediaPlayer/QVideoProbe: the latter hands back native YUV frames that
    // QImage can't construct from, and on the libhybris hardware-codec path the
    // frames may not even be CPU-mappable — both produce a black thumbnail.
    QProcess *m_proc = nullptr;
    QString m_outPath;

    // Per-video disk-cached thumbnails, generated one ffmpeg at a time.
    QProcess *m_cacheProc = nullptr;
    QQueue<QString> m_pending;   // video urls awaiting a thumbnail
    QString m_curReqUrl;         // url of the in-flight request
    QString m_curOutPath;
};

#endif // THUMBNAILGENERATOR_H
