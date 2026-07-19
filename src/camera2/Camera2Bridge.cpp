// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Sean Pollard <spollard08@gmail.com>
//
// Camera2Bridge implementation — Milestone 3b: live preview on screen.
//
// startCamera() opens the camera and starts a PRIVATE-format preview through
// CameraSession (M3a).  The preview AImageReader is allocated with GPU-sampled
// usage so each frame's AHardwareBuffer can be imported straight into GL: the
// Renderer (on Qt's scene-graph thread) does
//   AImage -> AImage_getHardwareBuffer -> eglGetNativeClientBufferANDROID
//          -> eglCreateImageKHR(EGL_NATIVE_BUFFER_ANDROID)
//          -> glEGLImageTargetTexture2DOES(GL_TEXTURE_EXTERNAL_OES)
//          -> textured quad into the QQuickFramebufferObject.
// Zero copy, GPU does the YUV->RGB.  Extensions confirmed present on the FLX1s
// (Mali-G68, hybris EGL): EGL_ANDROID_image_native_buffer,
// EGL_ANDROID_get_native_client_buffer, GL_OES_EGL_image_external.
//
// M4-M7 entry points (recording, photo, manual controls) are present but stubbed
// — they are filled in by their milestones.

#include "Camera2Bridge.h"
#include "CameraSession.h"
#include "VideoEncoder.h"
#include "Camera2NDK.h"
#include "../hdrprocessor.h"
#include "../pixelfilter.h"

#include <QDateTime>
#include <QTimer>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <exiv2/exiv2.hpp>
#include <thread>

#include <ReadBarcode.h>
#include <BarcodeFormat.h>
#include <ImageView.h>

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QUuid>
#include <QVariant>
#include <QOpenGLFramebufferObject>
#include <QStandardPaths>
#include <QtDBus/QDBusConnection>
#include <QtDBus/QDBusInterface>
#include <QtDBus/QDBusReply>
#include <QtDBus/QDBusVariant>

#include <cmath>
#include <cstdio>

#include "PreviewRenderer.h"

namespace furicam {

namespace {

// Qt scene-graph renderer: a thin QQuickFramebufferObject::Renderer that hands
// the actual GL work to the shared (Qt-free) PreviewRenderer.
class Camera2PreviewRenderer : public QQuickFramebufferObject::Renderer {
public:
    ~Camera2PreviewRenderer() override { renderer_.cleanup(); }

    QOpenGLFramebufferObject* createFramebufferObject(const QSize& size) override
    {
        viewSize_ = size;
        QOpenGLFramebufferObjectFormat fmt;
        return new QOpenGLFramebufferObject(size, fmt);
    }

    void synchronize(QQuickFramebufferObject* item) override
    {
        auto* bridge = static_cast<Camera2Bridge*>(item);
        reader_   = bridge->previewReader();
        rotation_ = bridge->previewRotation();
        cropX_    = bridge->cropScaleX();
        cropY_    = bridge->cropScaleY();
        mirror_   = bridge->previewMirrored();
        // Pull the pixel-art filter for the next render() (GUI thread set it).
        renderer_.setPixelFilter(bridge->pixelGridWidth(), bridge->pixelPaletteRgb(),
                                 bridge->pixelAutoLevels());
    }

    void render() override
    {
        renderer_.render(reader_, viewSize_.width(), viewSize_.height(), rotation_,
                         cropX_, cropY_, mirror_);
    }

private:
    PreviewRenderer renderer_;
    QSize           viewSize_{1, 1};
    AImageReader*   reader_   = nullptr;
    int             rotation_ = 90;
    float           cropX_    = 1.0f;
    float           cropY_    = 1.0f;
    bool            mirror_   = false;
};

} // namespace

// ─────────────────────────────────────────────────────────────────────────────

Camera2Bridge::Camera2Bridge(QQuickItem* parent)
    : QQuickFramebufferObject(parent)
{
    // QQuickFramebufferObject renders bottom-up by default; mirror so our texture
    // coordinates match screen orientation.
    setMirrorVertically(true);
}

Camera2Bridge::~Camera2Bridge()
{
    stopCameraSession();
}

QQuickFramebufferObject::Renderer* Camera2Bridge::createRenderer() const
{
    return new Camera2PreviewRenderer();
}

void Camera2Bridge::startCamera(int newFacing)
{
    // Camera-selection facing: use the deferred flip from switchCamera() if
    // present, otherwise stick with the current lensFacingPref_.  MUST be a
    // local — lensFacingPref_ feeds previewMirrored() and if we update it
    // before the new previewReader_ is live, any render() in between draws
    // the old camera's held frame with the new mirror (the "flipped image"
    // glitch).  The real store happens after the reader is ready.
    const int wantFacing = (newFacing >= 0) ? newFacing : lensFacingPref_.load();
    if (!session_)
        session_ = std::make_unique<CameraSession>([](const std::string& s) {
            std::fprintf(stderr, "[camera] %s\n", s.c_str());
        });

    if (CameraSession::isHostStub()) {
        emit cameraError(QStringLiteral("Camera2 unavailable: host stub build"));
        return;
    }
    // ponytail: enumerate once; camera list doesn't change at runtime.
    if (session_->cameras().empty() && !session_->enumerate()) {
        emit cameraError(QString::fromStdString(session_->lastError()));
        return;
    }

    const auto& cams = session_->cameras();
    if (cams.empty()) {
        emit cameraError(QStringLiteral("no cameras"));
        return;
    }

    bool haveFront = false;
    for (const auto& c : cams)
        if (c.facing == ACAMERA_LENS_FACING_FRONT)
            haveFront = true;

    std::string chosen;
    int chosenOrientation;
    int chosenFacing = -1;
    int chosenIndex = 0;
    const int idx = selectedCameraIndex_.load();
    if (idx >= 0 && idx < (int)cams.size()) {
        // Explicit camera pick (e.g. the secondary back/macro camera).
        chosen = cams[idx].id;
        chosenOrientation = cams[idx].sensorOrientation;
        chosenFacing = cams[idx].facing;
        chosenIndex = idx;
    } else {
        // First camera with the wanted facing (camera 0 = main back, not the
        // secondary macro camera that also reports back-facing).
        chosen = cams.front().id;
        chosenOrientation = cams.front().sensorOrientation;
        bool chosenSet = false;
        for (int i = 0; i < (int)cams.size(); ++i) {
            const auto& c = cams[i];
            if (c.facing == wantFacing && !chosenSet) {
                chosen = c.id;
                chosenOrientation = c.sensorOrientation;
                chosenFacing = c.facing;
                chosenIndex = i;
                chosenSet = true;
            }
        }
    }
    currentCameraId_ = chosen;
    emit cameraIdChanged();

    // pony: pull sensor range for manual exposure sliders from the chosen camera
    for (const auto& c : cams) {
        if (c.id == chosen) {
            isoMin_.store(c.isoMin);
            isoMax_.store(c.isoMax);
            exposureMinMs_.store((int)(c.exposureMinNs / 1000000));
            exposureMaxMs_.store((int)(c.exposureMaxNs / 1000000));
            manualSensor_.store(c.manualSensor);
            minFocusDistance_.store(c.minFocusDistance);
            focusDistanceCalibration_.store(c.focusDistanceCalibration);
            break;
        }
    }
    emit manualRangeChanged();

    if (!session_->open(chosen)) {
        emit cameraError(QString::fromStdString(session_->lastError()));
        return;
    }

    // Render-pull mode: schedule a repaint per frame; the renderer acquires.
    session_->setFrameCallback([this] {
        frameCount_.fetch_add(1, std::memory_order_relaxed);
        QMetaObject::invokeMethod(this, [this] {
            update();
            emit frameCountChanged();
        }, Qt::QueuedConnection);
    });

    // Photo completion (fires on a camera thread) -> marshal to the GUI thread.
    session_->setPhotoCallback([this](const std::string& path, bool ok) {
        const QString p = QString::fromStdString(path);
        QMetaObject::invokeMethod(this, [this, p, ok] {
            onPhotoCaptured(p, ok);
        }, Qt::QueuedConnection);
    });

    // Propagate the user-chosen still resolution for this camera, clamped
    // inside startPreview() to the sensor's actual max.  No saved choice
    // means 0 → maxJpegSize() picks the per-sensor max.
    auto it = cameraResolutions_.find(chosen);
    if (it != cameraResolutions_.end() && it->second.first > 0) {
        session_->setJpegSize(it->second.first, it->second.second);
    } else {
        // No in-session choice yet: fall back to the size persisted across app
        // restarts (seeded by QML via setSavedResolution before startCamera).
        auto sv = savedResolutions_.find(chosenIndex);
        if (sv != savedResolutions_.end() && sv->second.first > 0) {
            session_->setJpegSize(sv->second.first, sv->second.second);
            // Promote into the live map so effectiveCaptureSize()/preview crop match.
            cameraResolutions_[chosen] = sv->second;
        }
    }
    pickPreviewStreamSize();   // match the preview aspect to the chosen still aspect
    if (!session_->startPreview(previewStreamW_, previewStreamH_, AIMAGE_FORMAT_PRIVATE,
                                AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, 30)) {
        // Fall back to a universally-supported 16:9 preview if the picked size fails.
        previewStreamW_ = 1280; previewStreamH_ = 720;
        if (!session_->startPreview(previewStreamW_, previewStreamH_, AIMAGE_FORMAT_PRIVATE,
                                    AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, 30)) {
            emit cameraError(QString::fromStdString(session_->lastError()));
            return;
        }
    }

    previewReader_ = session_->previewReader();
    // Apply any deferred orientation state now that the new reader is live —
    // all three (sensorOrientation_, lensFacingPref_, previewReader_) feed the
    // renderer and must change atomically so the old camera's held frame never
    // renders with the new camera's rotation or mirror.
    sensorOrientation_.store(chosenOrientation);
    if (chosenFacing >= 0)
        lensFacingPref_.store(chosenFacing);
    // Must run after sensorOrientation_ is updated.
    updateDisplayRotation();
    // Decode QR/barcodes from the analysis (YUV luma) stream — photo mode only.
    session_->setAnalysisCallback([this](const uint8_t* y, int w, int h, int stride) {
        qrDecode(y, w, h, stride);
    });
    if (hasFrontCamera_.exchange(haveFront) != haveFront)
        emit hasFrontCameraChanged();
    // Claim the accelerometer so orientation stays live; we read it on-demand
    // at capture time to tag photos/videos with the device tilt.  The preview
    // stays portrait-locked — updateDisplayRotation ignores device rotation.
    claimAccelerometer();
    // Re-apply a pending video-mode request now that preview is streaming (also
    // re-enters video mode after a camera switch, which reopens the session).
    applyVideoMode();
    // Sync deferred settings that may have been set via QML bindings before the
    // session was created (flash mode, etc.).  The QML property bindings fire during
    // component construction, but session_ doesn't exist until startCamera() runs.
    if (session_) {
        session_->setFlashMode(flashMode_);
    }
    ready_.store(true);
    emit readyChanged();
    update();
}

void Camera2Bridge::stopCamera()
{
    stopCameraSession();
    if (ready_.exchange(false))
        emit readyChanged();
}

void Camera2Bridge::stopCameraSession()
{
    if (session_) {
        session_->setFrameCallback({});
        session_->close();
    }
    previewReader_ = nullptr;
}

void Camera2Bridge::switchCamera()
{
    // Gesture flip reverts to facing-based pick (the main camera of each side).
    selectedCameraIndex_.store(-1);
    // Compute the new facing but DON'T apply it yet — the renderer still shows
    // an old frame during the close→open gap, and an eager flip would show it
    // with the wrong mirror flag (the brief "flipped image" glitch).  Defer to
    // startCamera(), which applies it atomically with the new sensor orientation
    // and preview reader.
    const int newFacing = lensFacingPref_.load() == ACAMERA_LENS_FACING_BACK
                              ? ACAMERA_LENS_FACING_FRONT
                              : ACAMERA_LENS_FACING_BACK;
    stopCameraSession();
    startCamera(newFacing);
}

QVariantList Camera2Bridge::availableCameras()
{
    QVariantList list;
    if (!session_)
        return list;
    if (session_->cameras().empty())
        session_->enumerate();
    int i = 0;
    for (const auto& c : session_->cameras()) {
        long best = 0;
        for (const auto& s : c.outputs)
            if (s.format == AIMAGE_FORMAT_JPEG)
                best = std::max(best, (long)s.width * s.height);
        QVariantMap m;
        m["index"]      = i++;
        m["facing"]     = (c.facing == ACAMERA_LENS_FACING_FRONT) ? 0 : 1;   // 0=front, 1=back
        m["megapixels"] = (int)((best + 500000) / 1000000);
        list.append(m);
    }
    return list;
}

void Camera2Bridge::selectCamera(int index)
{
    selectedCameraIndex_.store(index);
    if (ready_.load()) {
        stopCameraSession();
        startCamera();
    }
}

void Camera2Bridge::setDeviceRotation(int degrees)
{
    deviceRotation_.store(((degrees % 360) + 360) % 360);
    updateDisplayRotation();
    update();
}

void Camera2Bridge::claimAccelerometer()
{
    // Claim iio-sensor-proxy (the auto-rotate service) once so it keeps the
    // AccelerometerOrientation property live.  We do NOT poll/feed the preview —
    // the preview is portrait-locked — we just read it on demand at capture time
    // (queryDeviceRotation) to tag photos/videos with the device tilt.
    if (orientationMonitorStarted_)
        return;
    orientationMonitorStarted_ = true;

    QDBusInterface sensor(QStringLiteral("net.hadess.SensorProxy"),
                          QStringLiteral("/net/hadess/SensorProxy"),
                          QStringLiteral("net.hadess.SensorProxy"),
                          QDBusConnection::systemBus());
    if (sensor.isValid())
        sensor.call(QStringLiteral("ClaimAccelerometer"));
}

// Read the current device orientation from iio-sensor-proxy and map it to degrees
// clockwise from natural portrait (0/90/180/270).  Defaults to 0 (portrait) when
// the sensor is unavailable.
int Camera2Bridge::queryDeviceRotation()
{
    QDBusInterface props(QStringLiteral("net.hadess.SensorProxy"),
                         QStringLiteral("/net/hadess/SensorProxy"),
                         QStringLiteral("org.freedesktop.DBus.Properties"),
                         QDBusConnection::systemBus());
    QDBusReply<QDBusVariant> r = props.call(QStringLiteral("Get"),
                                            QStringLiteral("net.hadess.SensorProxy"),
                                            QStringLiteral("AccelerometerOrientation"));
    if (!r.isValid())
        return 0;
    const QString o = r.value().variant().toString();
    return (o == QLatin1String("left-up"))  ? 90
         : (o == QLatin1String("bottom-up")) ? 180
         : (o == QLatin1String("right-up"))  ? 270
         :                                     0;   // "normal" / unknown
}

void Camera2Bridge::updateDisplayRotation()
{
    // Preview is portrait-locked: rotation depends only on the sensor mount angle,
    // never device rotation (turning the phone must NOT counter-rotate the preview
    // because the UI is portrait-only for now).  The +180 corrects the texcoord-
    // rotation convention in the renderer (verified on-device: back camera, portrait).
    // deviceRotation_ is still tracked via setDeviceRotation() as the hook for a
    // future rotating UI; wire it back in here when the UI elements rotate.
    const int sensor = sensorOrientation_.load();
    displayRotation_.store(((sensor + 180) % 360 + 360) % 360);
    recomputePreviewAspect();
}

// The effective still size: the user-chosen one, else the sensor's largest size.
void Camera2Bridge::effectiveCaptureSize(int& cw, int& ch)
{
    auto it = cameraResolutions_.find(currentCameraId_);
    if (it != cameraResolutions_.end()) {
        cw = it->second.first;
        ch = it->second.second;
    }
    if ((cw <= 0 || ch <= 0) && session_) {
        long best = 0;
        for (const auto& s : session_->jpegSizes()) {
            const long area = (long)s.width * s.height;
            if (area > best) { best = area; cw = s.width; ch = s.height; }
        }
    }
    if (cw <= 0 || ch <= 0) { cw = 4; ch = 3; }
}

// The preview stream is always the sensor's full-FOV (4:3) aspect; the renderer
// crops it to the chosen still aspect (recomputePreviewAspect computes the crop),
// so ANY still ratio (1:1, 3:2, 16:9 …) maps corner-for-corner with the capture.
void Camera2Bridge::pickPreviewStreamSize()
{
    // Always a 4:3 stream matching the full sensor FOV; recomputePreviewAspect()
    // crops it to whatever aspect the current mode needs (4:3 still / 16:9 video).
    // Keeping the reader size constant lets video-mode toggles reconfigure just
    // the capture session (add/remove the encoder) instead of reopening the
    // camera device — the difference between a ~200ms switch and a 2-4s one.
    previewStreamW_ = 1280;
    previewStreamH_ = 960;
}

// previewAspectRatio_ = the on-screen (post-rotation) w/h of the *still* aspect;
// cropScale = the centred sub-rect of the 4:3 stream that equals that aspect.
void Camera2Bridge::recomputePreviewAspect()
{
    int cw, ch;
    if (videoModeDesired_) { cw = videoW_; ch = videoH_; }   // video mode: match the clip
    else                     effectiveCaptureSize(cw, ch);    // photo mode: match the still
    if (cw <= 0 || ch <= 0) { cw = 4; ch = 3; }
    const float ca = (float)cw / (float)ch;                                   // still aspect
    const float sa = (float)previewStreamW_ / (float)previewStreamH_;         // stream aspect (~4:3)

    // Crop the 4:3 stream down to the still aspect (it's always a centred crop of
    // the full sensor): wider-than-4:3 crops height, narrower crops width.
    float sx = 1.0f, sy = 1.0f;
    if (ca >= sa) sy = sa / ca;
    else          sx = ca / sa;
    cropScaleX_.store(sx);
    cropScaleY_.store(sy);

    // Use sensor-only rotation for preview aspect so the viewport doesn't flip
    // when device rotates — only the JPEG orientation uses displayRotation_.
    const int rot = previewRotation();
    const bool portrait = (rot == 90 || rot == 270);
    const float a = portrait ? (float)ch / (float)cw : (float)cw / (float)ch;
    if (previewAspectRatio_.exchange(a) != a)
        emit previewAspectRatioChanged();
    // The next preview frame (and the cam2 resize from previewAspectRatioChanged)
    // re-render and pick up the new crop via the renderer's synchronize().
}

void Camera2Bridge::setLastPhotoPath(const QString& path)
{
    {
        QMutexLocker lk(&lastPhotoMutex_);
        lastPhotoPath_ = path;
    }
    emit lastPhotoPathChanged();
}

// Captures go under <media-dir>/<binary name> (the app convention the built-in
// gallery scans, e.g. ~/Pictures/furicam and ~/Videos/furicam).
static QString mediaSubdir()
{
    return QFileInfo(QCoreApplication::applicationFilePath()).fileName();
}

QString Camera2Bridge::defaultVideoPath() const
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::MoviesLocation)
                        + "/" + mediaSubdir();
    return QDir(dir).filePath(
        QStringLiteral("VID_%1.mp4").arg(QDateTime::currentDateTime().toString("yyyyMMdd_hhmmss")));
}

QString Camera2Bridge::defaultPhotoPath() const
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::PicturesLocation)
                        + "/" + mediaSubdir();
    return QDir(dir).filePath(
        QStringLiteral("IMG_%1.jpg").arg(QDateTime::currentDateTime().toString("yyyyMMdd_hhmmss")));
}

void Camera2Bridge::initCamera()
{
    startCamera();
}

// ── M4–M7 entry points: stubbed until their milestones ───────────────────────

bool Camera2Bridge::startRecording(const QString& outputPath)
{
    if (!session_ || !session_->isOpen()) {
        emit cameraError(QStringLiteral("startRecording: camera not open"));
        return false;
    }
    if (recording_.load())
        return false;
    // Tag this clip with how the phone is held as recording starts (preview stays
    // portrait); the session applies it to the MP4 rotation hint per clip.
    session_->setDeviceRotation(queryDeviceRotation());
    recordingPath_ = outputPath.isEmpty() ? defaultVideoPath() : outputPath;
    QDir().mkpath(QFileInfo(recordingPath_).absolutePath());
    // Make sure the combined preview+record session is up at the current size so
    // we don't silently fall back to the legacy 1080p path.
    if (videoModeDesired_ && session_->isStreaming() && !session_->isVideoMode())
        enterVideoMode();
    // In video mode the preview keeps streaming during record (same reader), so
    // leave previewReader_ valid.  The legacy path records to a dedicated session
    // that displaces the preview, so its reader becomes stale.
    if (!session_->isVideoMode())
        previewReader_ = nullptr;
    if (!session_->startRecording(recordingPath_.toStdString(), videoW_, videoH_,
                                    30, videoBitrate_ * 1000, true,
                                    deviceRotation_.load())) {
        emit cameraError(QString::fromStdString(session_->lastError()));
        return false;
    }
    recording_.store(true);
    emit recordingChanged();
    return true;
}

void Camera2Bridge::stopRecording()
{
    if (!session_ || !recording_.load())
        return;
    const bool wasVideoMode = session_->isVideoMode();
    session_->stopRecording();
    recording_.store(false);
    emit recordingChanged();
    emit recordingSaved(recordingPath_);
    // In video mode the preview never stopped; only the legacy path needs the
    // displaced preview restarted.
    if (!wasVideoMode)
        startCamera();
}

// ── Bitrate floor by resolution (kbps) ──────────────────────────────────────
// ponytail: prevents 20 Mbps starving 4K; gives lower res a sensible default.
static int floorBitrateKbps(int videoWidth)
{
    if (videoWidth >= 3000) return 40000;   // 4K+
    if (videoWidth >= 1920) return 20000;   // 1080p
    return 10000;                           // 720p and below
}

int Camera2Bridge::videoBitrateKbps() const
{
    return std::max(videoBitrate_, floorBitrateKbps(videoW_));
}

void Camera2Bridge::enterVideoMode()
{
    if (!session_)
        return;
    const int bitrate = videoBitrateKbps() * 1000;
    session_->enterVideoMode(videoW_, videoH_, 30, bitrate);
}

void Camera2Bridge::exitVideoMode()
{
    if (session_)
        session_->exitVideoMode();
}

void Camera2Bridge::rebuildVideoIfActive()
{
    // If already in video mode (and not recording), rebuild the encoder at the
    // current size; otherwise the new size just takes effect on the next enter.
    if (session_ && session_->isVideoMode() && !recording_.load()) {
        session_->exitVideoMode();
        enterVideoMode();
    }
}

// Set the H.264 video bitrate (kbps).  Rebuilds the video session if it's up
// (and not recording) so the new bitrate takes effect immediately.
void Camera2Bridge::setVideoBitrate(int kbps)
{
    if (kbps <= 0 || kbps == videoBitrate_)
        return;
    videoBitrate_ = kbps;
    rebuildVideoIfActive();
}

void Camera2Bridge::setVideoStabilization(bool on)
{
    if (session_)
        session_->setVideoStabilization(on);
    // Restart preview so the FOV change takes effect immediately.
    // ponytail: full video-session teardown/rebuild; per-frame reconfiguration
    // would be nicer but the NDK doesn't expose it for EIS at session level.
    if (session_ && session_->isVideoMode() && !recording_.load()) {
        session_->exitVideoMode();
        enterVideoMode();
    }
}

void Camera2Bridge::setVideoWidth(int width)
{
    if (width <= 0 || width == videoW_)
        return;
    videoW_ = width;
    emit videoSizeChanged();
    rebuildVideoIfActive();
}

void Camera2Bridge::setVideoHeight(int height)
{
    if (height <= 0 || height == videoH_)
        return;
    videoH_ = height;
    emit videoSizeChanged();
    rebuildVideoIfActive();
}

void Camera2Bridge::setVideoResolution(int width, int height)
{
    const bool sizeChanged = (width > 0 && width != videoW_) || (height > 0 && height != videoH_);
    const int  oldKbps     = videoBitrateKbps();
    if (width  > 0) videoW_ = width;
    if (height > 0) videoH_ = height;
    if (sizeChanged) {
        // Snap the bitrate to the new resolution's floor so the slider reflects it.
        const int newFloor = floorBitrateKbps(videoW_);
        videoBitrate_ = newFloor;   // always reset to floor on resolution change
        emit videoSizeChanged();
        rebuildVideoIfActive();
        if (videoModeDesired_)
            recomputePreviewAspect();
    }
    if (videoBitrateKbps() != oldKbps)
        emit videoBitrateChanged();
}

void Camera2Bridge::setVideoMode(bool on)
{
    if (on == videoModeDesired_)
        return;
    videoModeDesired_ = on;
    // Reconfigure just the capture session (add/remove the encoder surface) via
    // enter/exitVideoMode — the camera device and preview reader stay open, so
    // this is a ~200ms switch instead of a 2-4s device reopen.  The preview reader
    // is a constant 4:3 and recomputePreviewAspect() crops it to 16:9 for video.
    // No-op on initial startup (session_ null); startCamera() applies the mode.
    if (ready_.load())
        applyVideoMode();
    recomputePreviewAspect();
    emit videoModeChanged();
}

void Camera2Bridge::applyVideoMode()
{
    // Reconcile the GUI's desired mode with the session.  No-op until preview is
    // streaming (re-applied from startCamera) and never reconfigures mid-record.
    if (!session_ || !session_->isStreaming() || recording_.load())
        return;
    if (videoModeDesired_ && !session_->isVideoMode())
        enterVideoMode();   // bridge's — applies videoW_/videoH_ (NOT session_->enterVideoMode(), which defaults to 1080p)
    else if (!videoModeDesired_ && session_->isVideoMode())
        session_->exitVideoMode();
}

void Camera2Bridge::prepareRecording()
{
    if (!session_)
        return;
    if (!session_->prepareRecording())
        qWarning("Camera2Bridge: mic pre-warm failed: %s", session_->lastError().c_str());
}

void Camera2Bridge::releaseRecording()
{
    if (session_)
        session_->releaseRecording();
}

bool Camera2Bridge::audioReady() const
{
    return session_ && session_->isAudioReady();
}

void Camera2Bridge::capturePhoto(const QString& outputPath, const QString& /*settingsJson*/)
{
    if (!session_ || !session_->isStreaming()) {
        emit cameraError(QStringLiteral("capturePhoto: camera not streaming"));
        return;
    }
    // HDR: submit all 3 bracketed frames as a single NDK burst call.  The HAL
    // queues them back-to-back at sensor frame rate (~100ms total).
    if (hdrEnabled_.load() && !hdrBurstActive_) {
        // EV stops for the 3-frame bracket (EV 0, -3, +3).  captureBurst()
        // converts these to manual sensor exposure times scaled from the live
        // preview AE result.
        const std::vector<int> evSteps = {0, -3, 3};

        std::vector<std::string> paths;
        hdrPaths_.clear();
        const QString burstId = QUuid::createUuid().toString(QUuid::WithoutBraces).left(8);
        for (int i = 0; i < kHdrFrames; ++i)
            paths.push_back((QDir::tempPath() + QStringLiteral("/furicam_hdr_%1_%2.jpg")
                             .arg(burstId).arg(i)).toStdString());

        hdrBurstActive_  = true;
        hdrBurstPending_ = kHdrFrames;
        hdrFinalPath_    = outputPath;
        emit hdrBusyChanged();
        emit hdrCapturingChanged();

        session_->setDeviceRotation(queryDeviceRotation());
        qDebug() << "[camera] HDR burst: EV steps" << evSteps[0] << evSteps[1] << evSteps[2];
        if (!session_->captureBurst(paths, deviceRotation_.load(), evSteps)) {
            hdrBurstActive_  = false;
            hdrBurstPending_ = 0;
            emit hdrBusyChanged();
            emit hdrCapturingChanged();
            emit cameraError(QString::fromStdString(session_->lastError()));
        }
        return;
    }
    // Auto flash: kick an AE precapture, then shoot the moment the HAL settles the
    // metering (FLASH_REQUIRED → fire, CONVERGED → don't).  On/Off need no precapture.
    if (flashMode_ == 2) {
        session_->triggerPrecapture();
        beginAutoFlashCapture(outputPath, 0);
        return;
    }
    // Torch mode: light is already on continuously — focus is aided by the
    // ongoing torch, so no AF assist is needed.  Just capture without extra flash.
    if (flashMode_ == 3) {
        doSingleCapture(outputPath);
        return;
    }
    // Flash ON: same AF-assist + timing as auto-flash's dark path (unified).
    // Torch lights, AF locks under the assist light, brief settle, then flash fires.
    if (flashMode_ == 1) {
        session_->triggerAfAssist();
        beginFlashAfCapture(outputPath, 0, -1, 800, 200, session_->afAssistGen());
        return;
    }
    doSingleCapture(outputPath);
}

// Poll the cached AE state until the metering settles, then shoot.  This HAL's
// ON_AUTO_FLASH still never fires even at FLASH_REQUIRED, but ON_ALWAYS_FLASH does
// — so we read the AE decision ourselves and force always-flash when it's dark.
// ACAMERA_CONTROL_AE_STATE: 2=CONVERGED 3=LOCKED 4=FLASH_REQUIRED.
void Camera2Bridge::beginAutoFlashCapture(const QString& outputPath, int attempt)
{
    if (!session_) return;
    const int s = session_->aeState();
    const int elapsedMs = attempt * 50;
    const bool settled = (s == 2 || s == 3 || s == 4);
    if ((settled && elapsedMs >= 200) || elapsedMs >= 1200) {
        if (s == 4) {                       // dark → force the flash to actually fire + AF assist
            session_->setFlashMode(1);      // ON_ALWAYS_FLASH for this shot
            session_->triggerAfAssist();    // torch on, AF trigger for low-light focus
            // Poll AF, then capture; restore flash AUTO after.  Same timing as the
            // flash-ON path so both feel identical.
            beginFlashAfCapture(outputPath, 0, 2, 800, 200, session_->afAssistGen());
            return;
        } else {                            // bright → no flash
            doSingleCapture(outputPath);
        }
        return;
    }
    QTimer::singleShot(50, this, [this, outputPath, attempt] {
        beginAutoFlashCapture(outputPath, attempt + 1);
    });
}

// Poll the cached AF state until focus settles, then turn off the torch, wait a
// short settle gap, and shoot.  AF_TRIGGER_START was already fired by
// triggerAfAssist() which also turned on the torch.  We wait for FOCUSED_LOCKED
// or NOT_FOCUSED_LOCKED (with minDwellMs keeping the torch up long enough to
// actually help focus, and a timeout backstop), then endAfAssist() drops the
// torch + restores AF, we pause settleMs so the flash doesn't fire on the same
// breath as the torch cutoff, then submit the still.
// ACAMERA_CONTROL_AF_STATE: 4=FOCUSED_LOCKED 5=NOT_FOCUSED_LOCKED.
// flashRestore: if >= 0, setFlashMode(flashRestore) after the shot (auto-flash path).
void Camera2Bridge::beginFlashAfCapture(const QString& outputPath, int attempt,
                                        int flashRestore, int minDwellMs, int settleMs, int gen)
{
    if (!session_) return;
    const int elapsedMs = attempt * 50;
    // Only accept an AF lock that arrived AFTER this trigger (a stale lock cached
    // before the trigger let flash-ON fire before the torch actually helped).
    const bool settled = session_->afSettledSince(gen);
    if ((settled && elapsedMs >= minDwellMs) || elapsedMs >= 1500) {
        // Drop the AF-assist torch AND restore the prior AF mode before the still
        // so ON_ALWAYS_FLASH fires on a clean request (lingering torch + AF_AUTO
        // on the repeating request suppressed the flash on this HAL).
        session_->endAfAssist();
        // Brief gap between torch-off and the flash firing so the HAL reconfigures
        // from torch to flash pulse cleanly.
        QTimer::singleShot(settleMs, this, [this, outputPath, flashRestore] {
            doSingleCapture(outputPath);
            if (flashRestore >= 0 && session_)
                session_->setFlashMode(flashRestore);
        });
        return;
    }
    QTimer::singleShot(50, this, [this, outputPath, attempt, flashRestore, minDwellMs, settleMs, gen] {
        beginFlashAfCapture(outputPath, attempt + 1, flashRestore, minDwellMs, settleMs, gen);
    });
}

void Camera2Bridge::doSingleCapture(const QString& outputPath)
{
    if (!session_)
        return;
    const QString path = outputPath.isEmpty() ? defaultPhotoPath() : outputPath;
    QDir().mkpath(QFileInfo(path).absolutePath());
    // Tag this shot with how the phone is currently held.
    session_->setDeviceRotation(queryDeviceRotation());
    if (!session_->capturePhoto(path.toStdString(), deviceRotation_.load()))
        emit cameraError(QString::fromStdString(session_->lastError()));
}

// Camera2 HAL writes EXIF DateTime in UTC; per EXIF spec it should be local time
// with no timezone field, so shift it by the system UTC offset.
void Camera2Bridge::fixExifDateTime(const QString& path)
{
    try {
        auto img = Exiv2::ImageFactory::open(path.toStdString());
        if (!img) return;
        img->readMetadata();
        auto& exif = img->exifData();
        if (exif.empty()) return;

        int offsetSec = QDateTime::currentDateTime().offsetFromUtc();
        if (offsetSec == 0) return; // already UTC — nothing to shift

        auto fixTag = [&](const std::string& key) {
            auto it = exif.findKey(Exiv2::ExifKey(key));
            if (it == exif.end() || it->count() < 20) return;
            std::string val = it->toString();
            // EXIF DateTime format: "2026:06:20 10:16:12" (19 chars)
            if (val.size() < 19) return;
            QDateTime dt = QDateTime::fromString(QString::fromStdString(val.substr(0, 19)), "yyyy:MM:dd HH:mm:ss");
            if (!dt.isValid()) return;
            dt.setTimeZone(QTimeZone::UTC);
            dt = dt.addSecs(offsetSec);
            // Write back local time in EXIF format
            it->setValue(dt.toString("yyyy:MM:dd HH:mm:ss").toStdString());
        };

        fixTag("Exif.Image.DateTime");
        fixTag("Exif.Photo.DateTimeOriginal");
        fixTag("Exif.Photo.DateTimeDigitized");

        img->writeMetadata();
    } catch (const Exiv2::Error&) {
        // non-fatal — the image is still valid
    }
}

// Photo completion on the GUI thread; routes HDR-burst frames vs single shots.
void Camera2Bridge::onPhotoCaptured(const QString& path, bool ok)
{
    if (hdrBurstActive_) {
        if (!ok) {
            hdrBurstActive_  = false;
            hdrBurstPending_ = 0;
            emit hdrBusyChanged();
            emit hdrCapturingChanged();
            for (const QString& p : hdrPaths_) QFile::remove(p);
            hdrPaths_.clear();
            emit cameraError(QStringLiteral("HDR capture failed"));
            return;
        }
        hdrPaths_ << path;
        if (--hdrBurstPending_ == 0)
            finishHdrBurst();
        return;
    }
    if (ok) {
        applyPixelFilterTo(path);
        fixExifDateTime(path);
        // DEBUG: log file size vs requested quality for calibration
        qDebug() << "[camera] JPEG quality:" << session_->jpegQuality()
                 << "size:" << (QFileInfo(path).size() / 1024) << "KB path:" << path;
        setLastPhotoPath(path);
        emit photoSaved(path);
    } else {
        emit cameraError(QStringLiteral("photo capture failed"));
    }
}

// Fuse the burst on a worker thread (OpenCV is heavy), then emit photoSaved.
// When hdrSaveEv0 is on, the EV 0 frame is also saved as a standard photo so
// the user has a clean baseline image even if the HDR fusion result is
// misaligned; it's off by default since HDR fusion is reliable enough that
// keeping the extra frame every shot is just wasteful.
void Camera2Bridge::finishHdrBurst()
{
    const QStringList paths = hdrPaths_;
    const QString outDir = QFileInfo(hdrFinalPath_.isEmpty() ? defaultPhotoPath()
                                                             : hdrFinalPath_).absolutePath();
    hdrBurstActive_ = false;
    hdrProcessing_  = true;
    emit hdrCapturingChanged();  // "Hold still" → "Processing…"
    qDebug() << "[camera] HDR merge: starting OpenCV fusion on worker thread";
    hdrPaths_.clear();
    QDir().mkpath(outDir);
    std::thread([this, paths, outDir] {
        // Copy EV 0 frame to a permanent file before processHdrBurst() deletes the temps.
        QString ev0Path;
        if (hdrSaveEv0_.load() && !paths.isEmpty()) {
            ev0Path = QDir(outDir).filePath(
                QStringLiteral("IMG_%1.jpg").arg(QDateTime::currentDateTime().toString("yyyyMMdd_hhmmss")));
            if (!QFile::copy(paths[0], ev0Path)) {
                qDebug() << "[camera] HDR: could not copy EV 0 frame to" << ev0Path;
                ev0Path.clear();
            }
        }

        HdrProcessor proc;
        const QString out = proc.processHdrBurst(paths, outDir);
        for (const QString& p : paths) QFile::remove(p);
        QMetaObject::invokeMethod(this, [this, ev0Path, out] {
            hdrProcessing_ = false;
            emit hdrBusyChanged();
            if (!ev0Path.isEmpty()) {
                fixExifDateTime(ev0Path);
                emit photoSaved(ev0Path);
            }
            if (!out.isEmpty()) {
                fixExifDateTime(out);
                setLastPhotoPath(out);
                emit photoSaved(out);
            } else {
                emit cameraError(QStringLiteral("HDR merge failed"));
            }
        }, Qt::QueuedConnection);
    }).detach();
}

void Camera2Bridge::setHdrEnabled(bool on)
{
    if (on == hdrEnabled_.exchange(on))
        return;
    emit hdrEnabledChanged();
}

void Camera2Bridge::setAutoExposure()
{
    if (session_)
        session_->setAutoExposure();
}

void Camera2Bridge::setManualExposure(int iso, int exposureMs)
{
    if (session_)
        session_->setManualExposure(iso, (int64_t)exposureMs * 1000000LL);
}

void Camera2Bridge::setExposureCompensation(float ev)
{
    if (!session_)
        return;
    // ev in [0,1] (0=most under, 0.5=neutral, 1=most over) → the open camera's AE
    // compensation index range, read from CONTROL_AE_COMPENSATION_RANGE (no
    // device-specific hardcode).  For a symmetric range 0.5 maps to 0 (neutral).
    const int mn = session_->evCompMin();
    const int mx = session_->evCompMax();
    int steps = mn + (int)std::lround(ev * (mx - mn));
    if (steps < mn) steps = mn;
    else if (steps > mx) steps = mx;
    session_->setExposureCompensation(steps);
}

void Camera2Bridge::setFocusDistance(float diopters)
{
    if (session_)
        session_->setFocusDistance(diopters);
}

void Camera2Bridge::setAELock(bool lock)  { if (session_) session_->setAeLock(lock); }
void Camera2Bridge::setAWBLock(bool lock) { if (session_) session_->setAwbLock(lock); }

void Camera2Bridge::setFocusLock(bool lock)
{
    if (session_)
        session_->setAfMode(lock ? ACAMERA_CONTROL_AF_MODE_OFF
                                 : ACAMERA_CONTROL_AF_MODE_CONTINUOUS_PICTURE);
}

void Camera2Bridge::setAutoFocus()
{
    if (session_)
        session_->setAfMode(ACAMERA_CONTROL_AF_MODE_CONTINUOUS_PICTURE);
}

void Camera2Bridge::setFocusPoint(float x, float y)
{
    if (!session_)
        return;
    session_->setFocusPoint(x, y);
    // If the tap lit the AF-assist torch (flash ON/AUTO), cut it once focus locks
    // (or after a timeout) — tap-to-focus isn't followed by a capture that would
    // otherwise drop it.
    if (session_->focusAssistLit())
        endFocusAssist(0);
}

// Poll AF after a tap-to-focus that lit the assist torch; cut the torch once
// focus locks or after ~1.5 s.
void Camera2Bridge::endFocusAssist(int attempt)
{
    if (!session_)
        return;
    const int s = session_->afState();
    const bool settled = (s == 4 || s == 5);
    if (settled || attempt * 50 >= 1500) {
        session_->setTorch(false);
        session_->clearFocusAssist();
        return;
    }
    QTimer::singleShot(50, this, [this, attempt] { endFocusAssist(attempt + 1); });
}

void Camera2Bridge::setTorch(bool on) { if (session_) session_->setTorch(on); }
void Camera2Bridge::setFlashMode(int mode)
{
    if (mode == flashMode_)
        return;
    // Turn off torch if leaving torch mode (3 → anything else)
    if (flashMode_ == 3 && session_)
        session_->setTorch(false);
    flashMode_ = mode;
    if (session_) {
        // Torch mode: keep the LED on continuously via the repeating request
        if (mode == 3)
            session_->setTorch(true);
        session_->setFlashMode(mode);
    }
    emit flashModeChanged();
}

// Set the pixel-art palette ("" = off).  Loads the palette colors, converts to
// 0..1 RGB floats for the GLSL uniform, turns the grid on/off, and repaints so
// the live preview reflects the change immediately.  The same palette is applied
// to the saved JPEG on capture (see onPhotoCaptured).
void Camera2Bridge::setPixelPalette(const QString &name)
{
    // "auto" = no-palette mode (uniform RGB-cube quantize); "" = off; otherwise a
    // bundled palette id loaded from qrc.
    const bool autoMode = (name == QLatin1String("auto"));
    QVector<QColor> colors;
    if (!name.isEmpty() && !autoMode)
        colors = PixelFilter::loadPalette(name);
    const bool active = autoMode || !colors.isEmpty();
    {
        QMutexLocker lk(&pixelMutex_);
        pixelPalette_ = active ? name : QString();
        pixelPaletteColors_ = colors;
        pixelPaletteRgb_.clear();
        for (const QColor &c : colors) {
            pixelPaletteRgb_.push_back(float(c.redF()));
            pixelPaletteRgb_.push_back(float(c.greenF()));
            pixelPaletteRgb_.push_back(float(c.blueF()));
        }
    }
    pixelGridWidth_.store(active ? float(kPixelGridWidth) : 0.0f);
    pixelAutoLevels_.store(autoMode ? kPixelAutoLevels : 0);
    emit pixelPaletteChanged();
    update();   // repaint the preview with the new filter
}

// Apply the active pixel-art filter to a freshly saved photo so it matches the
// live preview (WYSIWYG).  No-op when no palette is selected.  Uses the same
// grid width as the preview.
void Camera2Bridge::applyPixelFilterTo(const QString& path)
{
    QVector<QColor> colors;
    {
        QMutexLocker lk(&pixelMutex_);
        colors = pixelPaletteColors_;
    }
    const int grid = int(pixelGridWidth_.load());
    const int autoLevels = pixelAutoLevels_.load();
    if (grid < 1 || (colors.isEmpty() && autoLevels < 2))
        return;
    PixelFilter::applyToFile(path, grid, colors, autoLevels);
}

void Camera2Bridge::setWhiteBalanceMode(int appMode)
{
    if (!session_)
        return;
    // Existing app modes: 0=Auto, 1=Daylight, 2=Cloudy, 3=Fluorescent, 4=Incandescent.
    int c2;
    switch (appMode) {
        case 1:  c2 = ACAMERA_CONTROL_AWB_MODE_DAYLIGHT;        break;
        case 2:  c2 = ACAMERA_CONTROL_AWB_MODE_CLOUDY_DAYLIGHT; break;
        case 3:  c2 = ACAMERA_CONTROL_AWB_MODE_FLUORESCENT;     break;
        case 4:  c2 = ACAMERA_CONTROL_AWB_MODE_INCANDESCENT;    break;
        default: c2 = ACAMERA_CONTROL_AWB_MODE_AUTO;            break;
    }
    session_->setAwbMode(c2);
}

void Camera2Bridge::setZoom(float ratio)
{
    if (session_)
        session_->setZoomRatio(ratio);
}

float Camera2Bridge::minZoom() const
{
    return session_ ? session_->minZoomRatio() : 1.0f;
}

float Camera2Bridge::maxZoom() const
{
    return session_ ? session_->maxZoomRatio() : 4.0f;
}

QVariantList Camera2Bridge::availableResolutions()
{
    QVariantList list;
    if (!session_)
        return list;
    auto sizes = session_->jpegSizes();
    std::sort(sizes.begin(), sizes.end(),
              [](const CameraSession::StreamConfig& a, const CameraSession::StreamConfig& b) {
                  return (long)a.width * a.height > (long)b.width * b.height;
              });
    for (const auto& s : sizes) {
        QVariantMap m;
        m["width"]  = s.width;
        m["height"] = s.height;
        list.append(m);
    }
    return list;
}

void Camera2Bridge::setResolution(int width, int height)
{
    if (!session_)
        return;
    cameraResolutions_[currentCameraId_] = {width, height};
    recomputePreviewAspect();   // letterbox + crop follow the new still aspect at once
    session_->setJpegSize(width, height);
    // Recreate the still output (JPEG reader) at the new size by restarting the
    // camera (not while recording — that would interrupt the clip).
    if (ready_.load() && !recording_.load()) {
        stopCamera();
        startCamera();
    }
}

void Camera2Bridge::setSavedResolution(int cameraIndex, int width, int height)
{
    if (width > 0 && height > 0)
        savedResolutions_[cameraIndex] = {width, height};
}

void Camera2Bridge::setJpegQuality(int quality)
{
    if (session_)
        session_->setJpegQuality(quality);
}

void Camera2Bridge::setRawEnabled(bool on)
{
    if (session_)
        session_->setRawEnabled(on);
}

bool Camera2Bridge::rawSupported() const
{
    return session_ && session_->rawSupported();
}

bool Camera2Bridge::isRawEnabled() const
{
    return session_ && session_->isRawEnabled();
}

void Camera2Bridge::qrDecode(const uint8_t* y, int w, int h, int stride)
{
    if (!y || w <= 0 || h <= 0)
        return;
    // Decoding runs on a camera thread; throttle to ~6/sec.
    using namespace std::chrono;
    const int64_t now = duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
    if (now - lastQrMs_.load() < 160)
        return;
    lastQrMs_.store(now);

    ZXing::ImageView image(y, w, h, ZXing::ImageFormat::Lum, stride);
    ZXing::ReaderOptions opts;
    opts.setFormats(ZXing::BarcodeFormat::QRCode);
    opts.setTryHarder(true);
    const ZXing::Barcode bc = ZXing::ReadBarcode(image, opts);
    if (!bc.isValid())
        return;

    const QString text = QString::fromStdString(bc.text());
    // Map sensor-normalized corners to viewfinder-normalized: inverse of the
    // renderer's texcoord rotation (sensor-only, no device rotation), then the
    // FBO vertical mirror.  Emits {x,y} in [0,1] of the preview item.
    const double rad = -previewRotation() * 3.14159265358979 / 180.0;
    const double cc = std::cos(rad), ss = std::sin(rad);
    // The analysis stream is the full 4:3 FOV but the preview is cropped to the
    // still aspect; expand the sensor-normalized point by the inverse crop so the
    // box lands on the (cropped) preview, matching the renderer's uCrop.
    const double cx = cropScaleX_.load(), cy = cropScaleY_.load();
    QVariantList pts;
    const ZXing::Position& pos = bc.position();
    for (const auto& c : { pos.topLeft(), pos.topRight(), pos.bottomRight(), pos.bottomLeft() }) {
        const double nx = ((double)c.x / w - 0.5) / (cx > 0 ? cx : 1.0);
        const double ny = ((double)c.y / h - 0.5) / (cy > 0 ? cy : 1.0);
        QVariantMap m;
        m["x"] = (cc * nx - ss * ny) + 0.5;
        m["y"] = (ss * nx + cc * ny) + 0.5;
        pts.append(m);
    }
    // Marshal the result to the GUI thread.
    QMetaObject::invokeMethod(this, [this, text, pts] {
        emit qrDetected(text, pts);
    }, Qt::QueuedConnection);
}

} // namespace furicam
