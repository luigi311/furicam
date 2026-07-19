// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Furi Labs
//
// PixelFilter — pixel-art ("Pixless"-style) post-processing for saved photos,
// mirroring the live GLSL preview filter in PreviewRenderer.  Parses lospec
// palette files (one #rrggbb color per line) and applies pixelate + palette
// quantize to a JPEG in place, so the saved photo matches the on-screen preview.

#ifndef PIXELFILTER_H
#define PIXELFILTER_H

#include <QString>
#include <QVector>
#include <QColor>

class PixelFilter
{
public:
    // Loads a bundled palette from qrc (":/palettes/<name>.txt").  Returns the
    // list of RGB colors, empty if the palette can't be read.  `name` is the
    // palette id without extension (e.g. "oil-6").
    static QVector<QColor> loadPalette(const QString &name);

    // Applies pixelation + palette quantize to the image file in place.
    // gridWidth: number of pixel blocks across the image width (blocky look).
    // palette: target colors; each block is snapped to the nearest palette color.
    //          If empty, the block is quantized to an RGB cube of `autoLevels`
    //          steps per channel (no-palette mode).
    // Does nothing (returns false) on unreadable image.
    static bool applyToFile(const QString &imagePath, int gridWidth,
                            const QVector<QColor> &palette, int autoLevels = 0);

    // Brightness/contrast pre-adjust, same formula as the GLSL filter.
    // brightness shifts, contrast scales around mid-grey.  1.0 = no change.
    static QColor adjust(const QColor &c, float brightness, float contrast);
};

#endif // PIXELFILTER_H
