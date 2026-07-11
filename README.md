# FuriCam
<img src="furicam.svg" width="100px">

An enhanced camera app for FuriPhone, built with Qt6/QML/C++.

Based on [furios-camera](https://github.com/FuriLabs/furios-camera) by FuriLabs.

I decided not to do an obvious fork and rename it since these changes will most likely never be upstreamed anyway. Not that I dont want that but since Im not a developer all I do is AI generated and I assume they wouldnt want that which is understandable.

Licensed under GPL-2.0.

# Enhancements so far

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

# To be improved

- Manual focus
- Tap to focus seems to ignore where the tap was
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

> **Note — Qt6 dev packages vs. the GLES Qt on FuriOS**
>
> On current FuriOS the GUI stack is the GLES Qt build (`libqt6gui6-gles`), which
> only `Provides: libqt6gui6 (= …dfsg-12)` and `Conflicts:` the plain
> `libqt6gui6`. But `qt6-base-dev` hard-depends on the exact matching
> `libqt6gui6 (= …dfsg-15)`, so a normal `apt install qt6-base-dev …` refuses.
>
> Work around it by downloading the dev packages and force-installing them (the
> real GLES libs serve at runtime — only the headers/CMake files are needed):
>
> ```
> mkdir -p /tmp/qt6debs && cd /tmp/qt6debs
> apt-get download qt6-base-dev qt6-declarative-dev qt6-multimedia-dev
> sudo dpkg -i --force-depends /tmp/qt6debs/*.deb
> ```
>
> This leaves apt with one "unmet dependency" for `qt6-base-dev` — harmless for
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

The `-d` flag skips build-dependency checks — required here both because
`qt6-base-dev`'s `libqt6gui6` dependency is unsatisfiable against the GLES Qt
(see the note above) and because `libhybris-common.so.1` is present at runtime
but lacks a proper dev package. `dpkg-shlibdeps` still resolves the runtime
`Depends` correctly (it picks `libqt6gui6-gles`), so the resulting `.deb`
installs and upgrades cleanly via apt.

# AI Disclosure 

This application was built with the assistance of AI (Mostly Claude and DeepSeek inside Copilot CLI).
