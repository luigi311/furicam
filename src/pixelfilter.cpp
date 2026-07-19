// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Furi Labs

#include "pixelfilter.h"

#include <QFile>
#include <QImage>
#include <QTextStream>

#include <exiv2/exiv2.hpp>

#include <cmath>

QVector<QColor> PixelFilter::loadPalette(const QString &name)
{
    QVector<QColor> out;
    QFile f(QStringLiteral(":/palettes/%1.txt").arg(name));
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return out;
    QTextStream in(&f);
    while (!in.atEnd()) {
        QString line = in.readLine().trimmed();
        if (line.startsWith(QLatin1Char('#')))
            line = line.mid(1);
        if (line.size() == 6) {
            bool ok = false;
            const QRgb rgb = line.toUInt(&ok, 16);
            if (ok)
                out.append(QColor::fromRgb(rgb));
        }
    }
    return out;
}

QColor PixelFilter::adjust(const QColor &c, float brightness, float contrast)
{
    auto ch = [&](int v) {
        float f = v / 255.0f;
        f = (f - 0.5f) * contrast + 0.5f + (brightness - 1.0f);
        return qBound(0, int(std::lround(f * 255.0f)), 255);
    };
    return QColor(ch(c.red()), ch(c.green()), ch(c.blue()));
}

// Snap a color to the nearest palette entry (perceptual-ish weighted RGB).
static const QColor &nearest(const QColor &c, const QVector<QColor> &palette)
{
    int best = 0;
    long bestD = LONG_MAX;
    for (int i = 0; i < palette.size(); ++i) {
        const QColor &p = palette[i];
        const long dr = c.red() - p.red();
        const long dg = c.green() - p.green();
        const long db = c.blue() - p.blue();
        // Weight green more (human eye sensitivity), red/blue less.
        const long d = 3 * dr * dr + 4 * dg * dg + 2 * db * db;
        if (d < bestD) { bestD = d; best = i; }
    }
    return palette[best];
}

bool PixelFilter::applyToFile(const QString &imagePath, int gridWidth,
                              const QVector<QColor> &palette, int autoLevels)
{
    if (gridWidth < 1 || (palette.isEmpty() && autoLevels < 2))
        return false;
    QImage img(imagePath);
    if (img.isNull())
        return false;
    img = img.convertToFormat(QImage::Format_RGB32);

    const int gridH = qMax(1, int(std::lround(gridWidth * double(img.height()) / img.width())));
    // Downscale to the pixel grid (fast, blocky) then back up with NEAREST so each
    // grid cell becomes a crisp block — the classic pixel-art look.
    QImage small = img.scaled(gridWidth, gridH, Qt::IgnoreAspectRatio, Qt::FastTransformation);

    for (int y = 0; y < small.height(); ++y) {
        QRgb *line = reinterpret_cast<QRgb*>(small.scanLine(y));
        for (int x = 0; x < small.width(); ++x) {
            const QColor c = QColor::fromRgb(line[x]);
            if (!palette.isEmpty()) {
                line[x] = nearest(c, palette).rgb();
            } else {
                // No-palette mode: snap each channel to a uniform RGB cube.
                const int step = 255 / (autoLevels - 1);
                auto q = [&](int v) { return qBound(0, (v + step / 2) / step * step, 255); };
                line[x] = qRgb(q(c.red()), q(c.green()), q(c.blue()));
            }
        }
    }

    QImage out = small.scaled(img.size(), Qt::IgnoreAspectRatio, Qt::FastTransformation);
    // QImage::save drops EXIF — read it off the original first and copy it back so
    // the filtered photo keeps camera model / exposure / date / orientation tags.
    Exiv2::ExifData exif;
    bool haveExif = false;
    try {
        auto orig = Exiv2::ImageFactory::open(imagePath.toStdString());
        if (orig) {
            orig->readMetadata();
            exif = orig->exifData();
            haveExif = !exif.empty();
        }
    } catch (const Exiv2::Error&) { haveExif = false; }

    if (!out.save(imagePath))
        return false;

    if (haveExif) {
        try {
            auto dest = Exiv2::ImageFactory::open(imagePath.toStdString());
            if (dest) {
                dest->readMetadata();
                // Orientation no longer applies (we baked the pixels) — drop it so
                // viewers don't double-rotate.  Set the real output dimensions so
                // the file doesn't report 0x0.
                exif.erase(exif.findKey(Exiv2::ExifKey("Exif.Image.Orientation")));
                exif["Exif.Photo.PixelXDimension"] = uint32_t(out.width());
                exif["Exif.Photo.PixelYDimension"] = uint32_t(out.height());
                exif["Exif.Image.ImageWidth"]      = uint32_t(out.width());
                exif["Exif.Image.ImageLength"]     = uint32_t(out.height());
                dest->setExifData(exif);
                dest->writeMetadata();
            }
        } catch (const Exiv2::Error&) { /* image still valid, just missing EXIF */ }
    }
    return true;
}
