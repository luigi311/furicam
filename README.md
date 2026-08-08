# FuriCam
<img src="furicam.svg" width="100px">

An enhanced camera app for FuriPhone, built with Qt6/QML/C++.

Based on [furios-camera](https://github.com/FuriLabs/furios-camera) by FuriLabs.

I decided not to do an obvious fork and rename it since these changes will most likely never be upstreamed anyway. Not that I dont want that but since Im not a developer all I do is AI generated and I assume they wouldnt want that which is understandable.

Licensed under GPL-2.0.

## Enhancements so far

- HDR Photography (uses Mertens fusion with OpenCV)
- Added option to adjust resolution (megapixel)
- Added option to increase jpeg compression
- Added 3x3 grid
- Added level indicator
- Added zoom slider
- Added Pro Mode (allows for manual ISO and Shutter speed adjustment)
- Added RAW (DNG) output
- Video output is now of reasonable file size (MJPEG --> H.264)
- Video output has adjustable bitrate to further adjust quality or storage savings
- Added different video resolutions to choose
- Added post processing options (RGB channels and saturation) - red was slightly reduced by default due to the FLX1s but does not seem to be an issue anymore
- Switching between photo and video mode also switches aspect ratio now
- Major improvements to the built-in gallery: Double tap to zoom, smooth swiping between pictures, etc.
- Pixel-art filters (was requested)

## To be improved

- Manual focus (does not seem to be possible, on the FLX1s at least)
- Different media player backend in the built-in gallery because video playback is a little choppy even at 1080p
- Maybe different HDR approach as OpenCV is very memory intensive but results are pretty solid overall
- DRO (maybe, spollards fork already includes it but it made everything very washed out so i left it out)
- Feel free to request something if there is anything missing

## Building

Builds natively on the FuriPhone (Debian Forky arm64) - no distrobox needed.

### Build dependencies

```
sudo apt install cmake \
                 qt6-base-dev \
                 qt6-declarative-dev \
                 qt6-multimedia-dev \
                 qt6-tools-dev-tools \
                 qt6-shader-baker \
                 qml6-module-qt5compat-graphicaleffects \
                 qml6-module-qtsensors \
                 qt6-svg-plugins \
                 libegl-dev \
                 libz-dev \
                 libgstreamer1.0-dev \
                 libgstreamer-plugins-base1.0-dev \
                 pkgconf \
                 libzxing-dev \
                 libexiv2-dev \
                 libglib2.0-dev \
                 libopencv-core-dev \
                 libopencv-imgproc-dev \
                 libopencv-photo-dev
```

> **Note - Qt6 dev packages vs. the GLES Qt on FuriOS**
>
> On current FuriOS the GUI stack is the GLES Qt build (`libqt6gui6-gles`), which
> only `Provides: libqt6gui6 (= …dfsg-12)` and `Conflicts:` the plain
> `libqt6gui6`. But `qt6-base-dev` hard-depends on the exact matching
> `libqt6gui6 (= …dfsg-15)`, so a normal `apt install qt6-base-dev …` refuses.
>
> Work around it by downloading the dev packages and force-installing them (the
> real GLES libs serve at runtime - only the headers/CMake files are needed):
>
> ```
> mkdir -p /tmp/qt6debs && cd /tmp/qt6debs
> apt-get download qt6-base-dev qt6-declarative-dev qt6-multimedia-dev
> sudo dpkg -i --force-depends /tmp/qt6debs/*.deb
> ```
>
> This leaves apt with one "unmet dependency" for `qt6-base-dev` - harmless for
> building, but every later `apt` command will complain. To restore a clean apt
> state (e.g. before testing a package upgrade), remove them again:
>
> ```
> sudo dpkg --remove --force-depends qt6-base-dev qt6-declarative-dev qt6-multimedia-dev
> ```

### Build

```
mkdir build
cd build
cmake ..
make -j$(nproc)
```

### Runtime dependencies

```
sudo apt install qml6-module-qtmultimedia \
                 libqt6multimedia6 \
                 qml6-module-qtquick \
                 qml6-module-qtquick-controls \
                 qml6-module-qtquick-window \
                 qml6-module-qt-labs-platform \
                 qml6-module-qt-labs-folderlistmodel \
                 qml6-module-qt-labs-settings \
                 qml6-module-qtquick-layouts \
                 qml6-module-qt5compat-graphicaleffects \
                 qml6-module-qtquick-shapes \
                 qml6-module-qtsensors \
                 qt6-svg-plugins \
                 mkvtoolnix \
                 ffmpeg \
                 libqt6svg6 \
                 libgstreamer1.0-0 \
                 gstreamer1.0-droid \
                 gstreamer1.0-plugins-good \
                 gstreamer1.0-plugins-base \
                 libzxing3
```

### Building the .deb

With the Qt6 dev headers force-installed as above:

```
dpkg-buildpackage -d -us -uc -b
```

The `-d` flag skips build-dependency checks - required here both because
`qt6-base-dev`'s `libqt6gui6` dependency is unsatisfiable against the GLES Qt
(see the note above) and because `libhybris-common.so.1` is present at runtime
but lacks a proper dev package. `dpkg-shlibdeps` still resolves the runtime
`Depends` correctly (it picks `libqt6gui6-gles`), so the resulting `.deb`
installs and upgrades cleanly via apt.

## AI Disclosure 

This application was built with the assistance of AI (Mostly Claude, DeepSeek and Kimi inside Copilot CLI).

## Credits

- Obviously: https://github.com/FuriLabs/furios-camera
- Some inspiration regarding the flash and initial HDR logic (among others): https://sourceforge.net/p/opencamera/code/ci/master/tree
- Initial inspiration for the requested pixel-art filters: https://github.com/cnmoro/pixel-camera-simulator
- [Spollard](https://github.com/spollard): Did basically the whole camera2 implementation
- [Luigi311](https://github.com/luigi311): Made some significant improvements, most notably to the HDR mode

#### Palette credits

The color palettes in this directory were collected from the
[lospec palette list](https://lospec.com/palette-list) and are used here for the
pixel-art ("Pixless"-style) photo filter.  Each palette is credited to its
creator on lospec:

| File                  | Palette        | Author           | Source |
|-----------------------|----------------|------------------|--------|
| `oil-6.txt`           | Oil 6          | GrafxKid        | https://lospec.com/palette-list/oil-6 |
| `digital-paper.txt`   | Digital Paper  | Snurly           | https://lospec.com/palette-list/digital-paper |
| `rust-gold-8.txt`     | Rust Gold 8    | Trigo Mathmancer | https://lospec.com/palette-list/rust-gold-8 |
| `ice-cream-gb.txt`    | Ice Cream GB   | Kerrie Lake      | https://lospec.com/palette-list/ice-cream-gb |
| `twilight-5.txt`      | Twilight 5     | Star             | https://lospec.com/palette-list/twilight-5 |
| `midnight-ablaze.txt` | Midnight ablaze| Inkpendude       | https://lospec.com/palette-list/midnight-ablaze |

If you are one of these authors and would prefer your palette not be bundled
here, please open an issue and it will be removed.
