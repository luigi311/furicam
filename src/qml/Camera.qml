// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2024 Furi Labs
// Copyright (C) 2026 Sean Pollard <spollard08@gmail.com>
//
// Camera.qml — the camera item.  Rewritten to drive the Camera2 engine
// (Camera2Bridge) instead of the QtMultimedia Camera + gst-droid pipeline,
// while keeping the EXACT contract main.qml depends on (the handle*/set*
// functions, the resolutionModel/currentRes*/maxZoom/currentZoom properties,
// and the photoSaved() signal).  main.qml is unchanged.
//
// QtMultimedia enums are now window-level readonly properties in main.qml
// (window.flashOff, window.frontFace, window.focusContinuous, …).

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Window 2.12
import Qt5Compat.GraphicalEffects
import QtQuick.Layouts 1.15
import Qt.labs.settings 1.0
import Qt.labs.platform 1.1
import FuriCam 1.0

Item {
    id: cameraItem
    width: 400
    height: 800

    property int lockedVideoRotation: 0
    // Frame count when a camera-switch became ready; the blur is held until a few
    // frames past this so it lifts on a live NEW-camera frame, not the stale held
    // frame of the old camera.  -1 = no switch blur pending.
    property int switchBlurBaseCount: -1

    property alias resolutionModel: resModel
    property int currentResWidth: 0
    property int currentResHeight: 0

    // Manual exposure — forwarded from Camera2Bridge for settings-drawer access
    readonly property bool manualSensor: cam2.manualSensor
    readonly property int isoMin: cam2.isoMin
    readonly property int isoMax: cam2.isoMax
    readonly property int exposureMinMs: cam2.exposureMinMs
    readonly property int exposureMaxMs: cam2.exposureMaxMs
    readonly property real minFocusDistance: cam2.minFocusDistance
    readonly property int focusDistanceCalibration: cam2.focusDistanceCalibration
    function setManualExposure(iso, exposureMs) { cam2.setManualExposure(iso, exposureMs) }
    function setAutoExposure() { cam2.setAutoExposure() }
    function setFocusDistance(diopters) { cam2.setFocusDistance(diopters) }
    function setJpegQuality(q) { cam2.setJpegQuality(q) }
    function handleSetRaw(on) { cam2.setRawEnabled(on) }
    function handleSetVideoResolution(w, h) { cam2.setVideoResolution(w, h) }
    function handleSetVideoStabilization(on) { cam2.setVideoStabilization(on) }

    // Zoom: currentZoom is the actual zoom ratio (minZoom..maxZoom). The slider
    // in main.qml directly sets currentZoom and calls cam2.setZoom().
    property real currentZoom: 1.0
    property real minZoom: cam2.ready ? cam2.minZoom() : 1.0
    property real maxZoom: cam2.ready ? cam2.maxZoom() : 1.0

    property int  colorTemperature: 0
    property bool frontActive: false
    property bool hdrBusy: cam2.hdrBusy
    property bool hdrCapturing: cam2.hdrCapturing

    // Emitted whenever a final photo has been saved and is ready for the gallery.
    signal photoSaved()
    // Emitted after a video recording is finalized and ready for the gallery.
    signal recordingSaved()

    ListModel { id: resModel }

    function setColorTemperature(temp) { colorTemperature = temp }

    function setWhiteBalanceMode(mode) { cam2.setWhiteBalanceMode(mode) }

    function gcd(a, b) { return b == 0 ? a : gcd(b, a % b) }

    // Populate the photo-resolution picker from the engine's JPEG output sizes.
    function fnAspectRatio() {
        resModel.clear()
        var res = cam2.availableResolutions()
        for (var i = 0; i < res.length; i++) {
            var w = res[i].width
            var h = res[i].height
            var g = gcd(w, h)
            var mp = Math.round((w * h) / 100000) / 10
            resModel.append({
                "resWidth": w, "resHeight": h,
                "aspectRatio": (w / g) + ":" + (h / g),
                "mp": mp, "label": mp + " MP (" + w + "×" + h + ")  " + (w / g) + ":" + (h / g)
            })
        }
        // Restore the current camera's saved resolution, else default to largest.
        // Always run (not only on first open) so the dropdown shows the right
        // value after switching cameras — per-camera resolution memory means
        // each camera may have a different saved size.
        if (res.length > 0) {
            var savedW = 0, savedH = 0
            var camId = cam2.currentCameraId
            if (settings.cameras && settings.cameras[camId]) {
                savedW = settings.cameras[camId].resWidth
                savedH = settings.cameras[camId].resHeight
            }
            // Check saved resolution is still in the available list
            var found = false
            for (var j = 0; j < res.length; j++) {
                if (savedW === res[j].width && savedH === res[j].height) {
                    found = true
                    break
                }
            }
            var targetW = found ? savedW : res[0].width
            var targetH = found ? savedH : res[0].height
            // Sync QML state to what startCamera() already applied.
            // ponytail: startCamera() sets the saved resolution via setJpegSize()
            // BEFORE startPreview(), so the camera is already at the right size.
            // Avoid calling setResolution() here — it restarts the camera,
            // doubling binder calls on every switch.
            if (targetW !== currentResWidth || targetH !== currentResHeight) {
                currentResWidth = targetW
                currentResHeight = targetH
                if (!found) {
                    if (settings.cameras && settings.cameras[camId]) {
                        var cams = settings.cameras
                        cams[camId].resWidth = targetW
                        cams[camId].resHeight = targetH
                        settings.cameras = cams
                    }
                }
            }
        }
    }

    function setResolution(width, height) {
        currentResWidth = width
        currentResHeight = height
        var camId = cam2.currentCameraId
        if (settings.cameras && settings.cameras[camId]) {
            var cams = settings.cameras
            cams[camId].resWidth = width
            cams[camId].resHeight = height
            settings.cameras = cams // pony: force serialization
        }
        cam2.setResolution(width, height)   // restarts the camera at the new still size
    }

    function handleSetFlashState(flashState) {
        // No-op: the flash mode is applied via the reactive `flashMode` binding on
        // cam2 (settings.flashMode → engine), which also covers startup.  Doing an
        // imperative cam2.setFlashMode here would break that binding.
    }

    // Torch toggle for video mode — called from main.qml (cam2 id is
    // scoped inside this component, not accessible from outside).
    function handleSetTorch(on) {
        cam2.setTorch(on)
    }

    function handleCameraTakeShot() {
        pinchArea.enabled = true
        if (settings.soundOn === 1)
            sound.play()
        if (mediaView.index < 0)
            mediaView.folder = StandardPaths.writableLocation(StandardPaths.PicturesLocation) + "/furicam"
        freezeCurrentPreview()         // hold ~what you shot while the still capture stalls preview
        window.triggerCaptureFlash()   // immediate shutter cue
        // Capture directly at the chosen quality (no on-disk re-encode afterward).
        cam2.setJpegQuality(toHalJpegQuality(settings.jpegQuality))
        // Single full-resolution capture; the engine writes the JPEG and emits
        // photoSaved(path), handled in onPhotoSaved below.
        cam2.capturePhoto("")
    }

    // Grab the current preview frame and hold it over the viewfinder during the
    // still-capture stall, so the user instantly sees ~what they captured.  It
    // fades out the moment fresh live frames resume (frozenFrame's Connections).
    function freezeCurrentPreview() {
        cam2.grabToImage(function(result) {
            if (!result)
                return
            frozenFrame.source = result.url
            frozenFrame.baseCount = cam2.frameCount
            frozenFrame.opacity = 1
            frozenHideTimer.restart()
        })
    }

    function handleCameraTakeVideo() { handleVideoRecording() }

    function handleCameraChangeResolution(resolution) {
        // 4:3 / 16:9 toggle — cosmetic until engine capture-size selection lands.
    }

    function handleStopCamera() {
        // Stop streaming but keep the bridge item alive: destroying the whole
        // camera+GL stack on every focus loss (and rebuilding it on return) is
        // the app's main startup/switch stability hazard.  cam2.stopCamera()
        // releases the HAL device; the item and renderer stay, so re-activation
        // is a cheap re-open instead of a full teardown+recreate.
        cam2.stopCamera()
    }

    // Returning from the gallery or re-activating the window: the item (and its
    // GL stack) was kept alive, so only start if the session actually isn't
    // live.  Restarting a live session pointlessly reopens the camera — and in
    // video mode also rebuilds it with the encoder surface.
    function handleStartCamera() { if (!cam2.ready) cam2.startCamera() }

    function handleSetFocusMode(focusMode) {
        // window.focusContinuous -> continuous AF; window.focusAuto (the app's
        // "locked" state) -> hold focus but leave AE unlocked.
        if (focusMode === window.focusContinuous) {
            cam2.setAutoFocus()
        } else {
            cam2.setFocusLock(true)
        }
    }

    function handleSetFocusPointMode(focusPointMode) {
        // The focus region is driven by the tap handler (cam2.setFocusPoint).
    }

    function handleSetCameraAspWide(aspWide) {
        // Aspect-ratio preference is cosmetic for the Camera2 capture path.
    }

    function handleSetDeviceID(deviceIdToSet) {
        var cams = cam2.availableCameras()
        var facing = (cams[deviceIdToSet] !== undefined) ? cams[deviceIdToSet].facing : 1  // 0=front,1=back
        // Keep the gesture/mirror state in sync first so the cameraPosition change
        // below doesn't trigger applyCameraPosition() into a redundant switch.
        frontActive = (facing === 0)
        settings.cameraPosition = (facing === 0) ? window.frontFace : window.backFace
        window.blurInstant = true   // snap on, no fade; cleared on first fresh frame
        window.blurView = 1         // hide the reopen glitch
        switchBlurSafety.restart()
        // Defer the blocking reopen a tick so the blur paints first (see timer).
        cameraFlipTimer.deviceId = deviceIdToSet
        cameraFlipTimer.start()
    }

    function handleSetZoom(zoomLevel) {
        var z = Math.max(minZoom, Math.min(zoomLevel, maxZoom))
        currentZoom = z
        cam2.setZoom(z)
    }

    // Populate the camera selector from the engine's full list (incl. the
    // secondary back/macro camera), keyed by camera index.
    function initializeCameraList() {
        allCamerasModel.clear()
        window.backCameras = 0
        window.frontCameras = 0
        var cams = cam2.availableCameras()
        for (var i = 0; i < cams.length; i++) {
            var c = cams[i]   // {index, facing(0=front,1=back), megapixels}
            allCamerasModel.append({
                "cameraId": c.index, "index": c.index,
                "position": (c.facing === 1) ? window.backFace : window.frontFace
            })
            if (settings.cameras[c.index])
                settings.cameras[c.index].resolution = c.megapixels
            if (c.facing === 1) window.backCameras += 1
            else window.frontCameras += 1
        }
    }

    // Deferred half of the camera switch: the actual (blocking) reopen. Split out
    // so the blur can paint one event-loop tick BEFORE switchCamera()/selectCamera()
    // freezes the UI thread — otherwise the blur is set and cleared (onReadyChanged)
    // within the same blocked call and never renders.  deviceId >= 0 picks a specific
    // camera (the selector); -1 is the gesture/button flip.
    Timer {
        id: cameraFlipTimer
        interval: 50
        property bool wantFront: false
        property int deviceId: -1
        onTriggered: {
            if (deviceId >= 0) {
                cam2.selectCamera(deviceId)
            } else {
                cam2.switchCamera()
                cameraItem.frontActive = wantFront
            }
        }
    }

    // Safety net: if the new camera never pushes the frames that would lift the
    // switch blur (onFrameCountChanged), force it off so we can't get stuck on a
    // frozen blurred screen.
    Timer {
        id: switchBlurSafety
        interval: 1500
        onTriggered: {
            cameraItem.switchBlurBaseCount = -1
            if (optionContainer.state === "closed")
                window.blurView = 0
            window.blurInstant = false
        }
    }

    function applyCameraPosition() {
        var wantFront = (settings.cameraPosition === window.frontFace)
        if (wantFront !== frontActive) {
            // Snap the blur fully on (no fade — the reopen would freeze it mid-fade)
            // to hide the last-frame glitch; cleared in onReadyChanged.
            window.blurInstant = true
            window.blurView = 1
            switchBlurSafety.restart()
            cameraFlipTimer.deviceId = -1
            cameraFlipTimer.wantFront = wantFront
            cameraFlipTimer.start()
        }
    }

    // Enter/leave video mode, setting the recording size atomically BEFORE video
    // mode so the encoder is built at the right resolution from the start.
    function applyVideoMode() {
        if (typeof cslate === "undefined" || !cam2.ready)
            return
        if (cslate.state === "VideoCapture") {
            cam2.setVideoResolution(settings.videoResWidth, settings.videoResHeight)
            cam2.videoMode = true
        } else {
            cam2.videoMode = false
        }
    }

    function handleVideoRecording() {
        if (!window.videoCaptured) {
            // Lock in the current size right before recording (also covers a
            // resolution change made while already in video mode).
            cam2.setVideoResolution(settings.videoResWidth, settings.videoResHeight)
            // Only show the stop-square when recording actually started — a failed
            // start (mic/encoder) would otherwise leave the button stuck.
            if (cam2.startRecording(""))
                window.videoCaptured = true
        } else {
            cam2.stopRecording()
            window.videoCaptured = false
        }
    }

    // One-line summary of app settings used for a shot, embedded in EXIF UserComment.
    function captureSettingsSummary() {
        var s = settings
        var wb = ["Auto", "Daylight", "Cloudy", "Tungsten", "Fluorescent"]
        var expo = s.manualExposureEnabled || s.proModeEnabled
              ? "ISO" + s.manualIso + " " + (s.manualExposureMs < 1000
                  ? "1/" + Math.round(1000 / s.manualExposureMs) + "s"
                  : (s.manualExposureMs / 1000).toFixed(2) + "s")
              : "AE"
        return "furicam"
             + " | JPEG:" + jpegQualityLabel(s.jpegQuality)
             + " | RAW:" + (s.rawEnabled ? "on" : "off")
             + " | WB:" + (wb[s.whiteBalanceMode] || "Auto")
             + " | Exp:" + expo
             + (s.colorCorrectionEnabled ? " | CC:on" : "")
             + (s.hdrEnabled ? " | HDR:on" : "")
             + " | Flash:" + (s.flashMode === 1 ? "on" : "off")
             + (s.gpsOn ? " | GPS:on" : "")
    }

    // Post-process + announce a saved photo (fires on the GUI thread).
    function onCam2PhotoSaved(path) {
        if (settings.colorCorrectionEnabled) {
            fileManager.applyColorCorrection(path,
                settings.colorCorrectionRed, settings.colorCorrectionGreen,
                settings.colorCorrectionBlue, settings.colorCorrectionSaturation)
        }
        // JPEG quality is set on the HAL before capture — no re-encode needed.
        if (window.locationAvailable === 1)
            fileManager.appendGPSMetadata(path)
        // Write app settings into EXIF UserComment — after re-encode so it survives.
        var summary = captureSettingsSummary()
        fileManager.writeCaptureSettings(path, summary)
        if (settings.rawEnabled)
            fileManager.writeCaptureSettings(path.replace(/\.jpe?g$/i, ".dng"), summary)
        photoSaved()
    }

    // React to camera-position changes (gestures set settings.cameraPosition).
    Connections {
        target: settings
        function onCameraPositionChanged() { cameraItem.applyCameraPosition() }
    }

    // Enter/leave video mode as the photo/video tab changes.
    Connections {
        target: cslate
        function onStateChanged() { cameraItem.applyVideoMode() }
    }

    // ── Live QR scanning ─────────────────────────────────────────────────────
    // The engine decodes QR codes from the analysis stream (photo mode) and the
    // bridge emits qrDetected(text, points).  Show a tappable result banner;
    // tapping it parses the code and offers the matching action (open/connect/copy).
    property string qrText: ""
    property var    qrPoints: []
    property bool   qrVisible: false

    Connections {
        target: cam2
        function onQrDetected(text, points) {
            cameraItem.qrText = text
            cameraItem.qrPoints = points
            cameraItem.qrVisible = true
            qrClearTimer.restart()
        }
    }
    Timer {
        id: qrClearTimer
        interval: 1500
        onTriggered: cameraItem.qrVisible = false
    }

    function handleQrTap() {
        if (!qrText.length)
            return
        var qrType = QRCodeHandler.parseQrString(qrText)
        if (qrType === "URL") {
            window.openPopup("Open URL?", qrText,
                [{text: "Cancel"}, {text: "Copy"}, {text: "Open", isPrimary: true}], qrText)
        } else if (qrType === "WIFI") {
            var wifiID = QRCodeHandler.getWifiId()
            window.openPopup("Connect to Network?", wifiID,
                [{text: "Cancel"}, {text: "Connect", isPrimary: true}], wifiID)
        } else {
            window.openPopup("QR Code Detected", "Content: " + qrText,
                [{text: "OK", isPrimary: true}, {text: "Copy"}], qrText)
        }
    }


    // ── The live preview: the Camera2 engine item ───────────────────────────
    // Dark backdrop behind the letterboxed preview (fills the aspect-ratio bars).
    Rectangle {
        anchors.fill: parent
        color: "black"
        z: -1
    }

    Camera2Bridge {
        id: cam2
        // Letterbox the preview to its capture-matched aspect (WYSIWYG).  The aspect
        // itself is decided in the bridge (mid layer); previewAspectRatio is the
        // on-screen width/height.  Children (grid/focus/zoom) ride along for free.
        property real dispAspect: previewAspectRatio > 0 ? previewAspectRatio : (9.0 / 16.0)
        width: Math.min(parent.width, parent.height * dispAspect)
        height: width / dispAspect
        anchors.horizontalCenter: parent.horizontalCenter
        // Centre vertically in the area above the bottom control bar
        y: Math.max(0, (parent.height - height) / 2 - window.controlBarReservedHeight / 2)
        hdrEnabled: settings.hdrEnabled   // HDR burst+fuse handled in the bridge
        hdrSaveEv0: settings.hdrSaveEv0   // also keep the un-fused EV0 baseline frame
        // Pixel-art filter palette ("" = off) — live in the GLSL preview and
        // applied to the saved photo (WYSIWYG).  Forced off while RAW or HDR is
        // enabled or in video mode: those outputs bypass the filter, so a filtered
        // preview would misrepresent what gets saved.
        pixelPalette: (settings.rawEnabled || settings.hdrEnabled || cam2.videoMode) ? "" : settings.pixelPalette
        // Flash mode tracks the GUI setting reactively (applied on startup + every
        // change), mapping to the engine's 0=off/1=on/2=auto/3=torch.
        flashMode: (settings.flashMode === window.flashOn) ? 1
                 : (settings.flashMode === window.flashAuto) ? 2
                 : (settings.flashMode === window.flashTorch) ? 3
                 : 0

        // Video mode + recording size are applied atomically at discrete moments
        // (entering video mode, starting a recording) via applyVideoMode() /
        // handleVideoRecording() — reactive split bindings churned and could
        // produce a mismatched (e.g. 1920x2160) size.
        Component.onCompleted: {
            // Seed the persisted per-camera still size BEFORE the first session is
            // built, so startup restores e.g. 12MP instead of defaulting to the
            // sensor max.  Keyed by camera index; the engine applies the one it opens.
            for (var i = 0; i < settings.cameras.length; i++) {
                var c = settings.cameras[i]
                if (c && c.resWidth > 0 && c.resHeight > 0)
                    cam2.setSavedResolution(i, c.resWidth, c.resHeight)
            }
            cam2.startCamera()
        }

        onReadyChanged: {
            if (ready) {
                focusState.state = "Default"
                cameraItem.fnAspectRatio()
                cam2.setRawEnabled(settings.rawEnabled)
                cam2.setVideoResolution(settings.videoResWidth, settings.videoResHeight)
                cam2.setVideoStabilization(settings.eisEnabled === 1)
                cameraItem.applyVideoMode()   // enter video mode if starting on the video tab
                // Sync GUI position state to the camera that actually opened (bridge
                // ground truth) — the flash button and other UI gate on
                // settings.cameraPosition, and reading frontActive here would race
                // with the switch that triggered this signal.
                frontActive = (cam2.currentFacing() === 0)   // 0=front
                settings.cameraPosition = frontActive ? window.frontFace : window.backFace
                // Device is ready but the preview may still hold the OLD camera's
                // last frame; keep the blur up and lift it on the first fresh frame
                // (onFrameCountChanged) so it never uncovers a stale frame.
                if (window.blurInstant)
                    cameraItem.switchBlurBaseCount = cam2.frameCount
            }
        }
        onCameraError: {
            cameraItem.errorBannerText = message
            cameraItem.errorBannerVisible = true
            errorBannerTimer.restart()
        }
        onPhotoSaved: function(path) { cameraItem.onCam2PhotoSaved(path) }
        onRecordingSaved: cameraItem.recordingSaved()

        // Live color correction shader — runs on GPU per frame (photo mode only).
        // Video encoding doesn't use the shader path, so disable it in video mode
        // to keep the preview WYSIWYG.
        layer.enabled: settings.colorCorrectionEnabled && !cam2.videoMode
        layer.effect: ShaderEffect {
            property real redScale:   settings.colorCorrectionRed
            property real greenScale: settings.colorCorrectionGreen
            property real blueScale:  settings.colorCorrectionBlue
            property real saturation: settings.colorCorrectionSaturation
            fragmentShader: "qrc:/colorCorrection.frag.qsb"
            vertexShader:   "qrc:/colorCorrection.vert.qsb"
        }

        PinchArea {
            id: pinchArea
            anchors.fill: parent
            pinch.target: camZoom
            pinch.maximumScale: (cameraItem.maxZoom > 0 ? cameraItem.maxZoom : 1) / camZoom.zoomFactor
            pinch.minimumScale: cameraItem.minZoom / camZoom.zoomFactor
            enabled: !mediaView.visible && !window.videoCaptured

            MouseArea {
                id: dragArea
                hoverEnabled: true
                anchors.fill: parent
                enabled: !mediaView.visible && !window.videoCaptured
                property real startX: 0
                property real startY: 0
                property int swipeThreshold: 80
                property var lastTapTime: 0
                property int doubleTapInterval: 300

                onPressed: function(mouse) {
                    startX = mouse.x
                    startY = mouse.y
                }

                onReleased: function(mouse) {
                    var deltaX = mouse.x - startX
                    var deltaY = mouse.y - startY

                    var currentTime = new Date().getTime();
                    if (currentTime - lastTapTime < doubleTapInterval) {
                        settings.cameraPosition = settings.cameraPosition === window.backFace ? window.frontFace : window.backFace;
                        settings.flashMode = settings.cameraPosition === window.frontFace ? window.flashOff : settings.flashMode;
                        lastTapTime = 0;
                    } else {
                        lastTapTime = currentTime;
                        if (Math.abs(deltaY) > Math.abs(deltaX) && Math.abs(deltaY) > swipeThreshold) {
                            if (deltaY > 0) { // Swipe down
                                configBarDrawer.open()
                            } else { // Swipe up
                                if (configBarDrawer.opened) {
                                    // Collapse the menu first; a second swipe-up
                                    // then flips the camera.
                                    configBarDrawer.close()
                                } else { // Flip camera
                                    settings.flashMode = window.flashOff
                                    settings.cameraPosition = settings.cameraPosition === window.backFace ? window.frontFace : window.backFace;
                                    settings.flashMode = settings.cameraPosition === window.frontFace ? window.flashOff : settings.flashMode;
                                }
                            }
                        } else if (Math.abs(deltaX) > swipeThreshold) {
                            if (deltaX > 0) { // Swipe right
                                window.blurView = 1
                                window.swipeDirection = 0
                                swappingDelay.start()
                            } else { // Swipe left
                                window.blurView = 1
                                window.swipeDirection = 1
                                swappingDelay.start()
                            }
                        } else { // Tap — focus here
                            var relativePoint = Qt.point(mouse.x / width, mouse.y / height)

                            if (aefLockTimer.running) {
                                focusState.state = "TargetLocked"
                                aefLockTimer.stop()
                            } else {
                                focusState.state = "AutomaticFocus"
                                window.aeflock = "AEFLockOff"
                            }

                            if (window.aeflock !== "AEFLockOn" || focusState.state === "TargetLocked") {
                                cam2.setFocusPoint(relativePoint.x, relativePoint.y)
                                focusPointRect.width = 60 * window.scalingRatio
                                focusPointRect.height = 60 * window.scalingRatio
                                window.focusPointVisible = true
                                focusPointRect.x = mouse.x - (focusPointRect.width / 2)
                                focusPointRect.y = mouse.y - (focusPointRect.height / 2)
                                afRestoreTimer.restart()
                            }

                            window.blurView = 0
                            configBarDrawer.close()
                            optionContainer.state = "closed"
                            visTm.start()
                        }
                    }
                }
            }

            onPinchUpdated: {
                camZoom.zoom = pinch.scale * camZoom.zoomFactor
            }

            Rectangle {
                id: focusPointRect
                border { width: 2; color: "#FDD017" }
                color: "transparent"
                radius: 5 * window.scalingRatio
                width: 80 * window.scalingRatio
                height: 80 * window.scalingRatio
                visible: window.focusPointVisible

                Timer {
                    id: visTm
                    interval: 500; running: false; repeat: false
                    onTriggered: window.aeflock === "AEFLockOff" ? window.focusPointVisible = false : null
                }
            }

            // Restore continuous AF 5 s after the last tap-to-focus (no further taps).
            // Skipped if the user has engaged AE/AF lock in the meantime.
            Timer {
                id: afRestoreTimer
                interval: 5000
                repeat: false
                onTriggered: {
                    if (window.aeflock !== "AEFLockOn") {
                        cam2.setAutoFocus()
                        window.focusPointVisible = false
                        afRestoredAnim.restart()
                    }
                }
            }

            // Brief focus ring centred on the viewfinder: signals that AF
            // has reverted from tap-locked to continuous.
            Rectangle {
                id: afRestoredIndicator
                anchors.centerIn: parent
                width: 120 * window.scalingRatio
                height: 120 * window.scalingRatio
                border { width: 2; color: "#FDD017" }
                color: "transparent"
                radius: 5 * window.scalingRatio
                opacity: 0

                SequentialAnimation {
                    id: afRestoredAnim
                    NumberAnimation { target: afRestoredIndicator; property: "opacity"; to: 1.0; duration: 150 }
                    PauseAnimation  { duration: 800 }
                    NumberAnimation { target: afRestoredIndicator; property: "opacity"; to: 0.0; duration: 400 }
                }
            }

            // 3x3 grid overlay
            Item {
                id: gridOverlay
                anchors.fill: parent
                visible: settings.gridEnabled === 1
                enabled: false
                z: 1
                Rectangle { x: parent.width / 3;       width: 1; height: parent.height; color: "#50ffffff" }
                Rectangle { x: parent.width * 2 / 3;   width: 1; height: parent.height; color: "#50ffffff" }
                Rectangle { y: parent.height / 3;      width: parent.width; height: 1;  color: "#50ffffff" }
                Rectangle { y: parent.height * 2 / 3;  width: parent.width; height: 1;  color: "#50ffffff" }
            }

            // Level indicator
            Item {
                id: levelIndicator
                visible: settings.levelEnabled === 1
                anchors.centerIn: parent
                width: parent.width * 0.35
                height: 30 * window.scalingRatio
                rotation: window.levelAngle
                enabled: false
                z: 2
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width
                    height: 2 * window.scalingRatio
                    color: window.isLevel ? "#4CAF50" : "#80ffffff"
                    radius: 1
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: 8 * window.scalingRatio
                    height: 8 * window.scalingRatio
                    radius: 4 * window.scalingRatio
                    color: window.isLevel ? "#4CAF50" : "#80ffffff"
                    border.width: 1
                    border.color: window.isLevel ? "#388E3C" : "#40ffffff"
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
            }
        }

        // Dim overlay during transitions.
        Rectangle {
            anchors.fill: parent
            z: 100
            opacity: window.blurView ? 1 : 0
            color: "#40000000"
            visible: opacity != 0
            Behavior on opacity { NumberAnimation { duration: 300 } }
        }
    }

    // ── Pipeline-error banner (kept for surfacing engine errors) ────────────
    property bool errorBannerVisible: false
    property string errorBannerText: ""
    Timer {
        id: errorBannerTimer
        interval: 5000
        repeat: false
        onTriggered: cameraItem.errorBannerVisible = false
    }
    Rectangle {
        id: errorBanner
        z: 10000
        anchors.top: parent.top
        anchors.topMargin: 16
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 24, errorBannerLabel.implicitWidth + 32)
        height: errorBannerLabel.implicitHeight + 20
        radius: 8
        color: "#dd8a1c1c"
        border.color: "#ffffff"
        border.width: 1
        visible: cameraItem.errorBannerVisible || opacity > 0
        opacity: cameraItem.errorBannerVisible ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 200 } }
        Text {
            id: errorBannerLabel
            anchors.fill: parent
            anchors.margins: 10
            text: cameraItem.errorBannerText
            color: "white"
            font.pixelSize: 14
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        MouseArea {
            anchors.fill: parent
            onClicked: cameraItem.errorBannerVisible = false
        }
    }

    // Pinch-zoom helper (drives handleSetZoom as the pinch scale changes).
    Item {
        id: camZoom
        property real zoomFactor: 2.0
        property real zoom: 0
        NumberAnimation on zoom { duration: 200; easing.type: Easing.InOutQuad }
        onScaleChanged: cameraItem.handleSetZoom(scale * zoomFactor)
    }

    // Box drawn around the detected QR code (tappable → action popup).
    Item {
        id: qrOverlay
        z: 9000
        anchors.fill: cam2   // map normalized QR points onto the letterboxed preview
        visible: cameraItem.qrVisible && !mediaView.visible
                 && (typeof cslate === "undefined" || cslate.state === "PhotoCapture")
        property bool valid: cameraItem.qrPoints && cameraItem.qrPoints.length === 4
        property real minX: valid ? Math.min(qrPoints[0].x, qrPoints[1].x, qrPoints[2].x, qrPoints[3].x) : 0
        property real maxX: valid ? Math.max(qrPoints[0].x, qrPoints[1].x, qrPoints[2].x, qrPoints[3].x) : 0
        property real minY: valid ? Math.min(qrPoints[0].y, qrPoints[1].y, qrPoints[2].y, qrPoints[3].y) : 0
        property real maxY: valid ? Math.max(qrPoints[0].y, qrPoints[1].y, qrPoints[2].y, qrPoints[3].y) : 0

        Rectangle {
            id: qrBox
            visible: qrOverlay.valid
            x: qrOverlay.minX * qrOverlay.width
            y: qrOverlay.minY * qrOverlay.height
            width:  Math.max(40 * window.scalingRatio, (qrOverlay.maxX - qrOverlay.minX) * qrOverlay.width)
            height: Math.max(40 * window.scalingRatio, (qrOverlay.maxY - qrOverlay.minY) * qrOverlay.height)
            radius: 8 * window.scalingRatio
            color: "#330099ff"
            border.color: "#3399ff"
            border.width: 3 * window.scalingRatio

            // Decoded text label just above the box.
            Rectangle {
                anchors.bottom: parent.top
                anchors.bottomMargin: 6 * window.scalingRatio
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(cameraItem.width - 24 * window.scalingRatio,
                                qrLabel.implicitWidth + 24 * window.scalingRatio)
                height: qrLabel.implicitHeight + 12 * window.scalingRatio
                radius: 8 * window.scalingRatio
                color: "#dd1d6fcf"
                Text {
                    id: qrLabel
                    anchors.centerIn: parent
                    width: parent.width - 16 * window.scalingRatio
                    text: cameraItem.qrText
                    color: "white"; font.pixelSize: 13 * window.scalingRatio
                    elide: Text.ElideRight; maximumLineCount: 1
                    horizontalAlignment: Text.AlignHCenter
                }
            }
            MouseArea { anchors.fill: parent; onClicked: cameraItem.handleQrTap() }
        }
    }

    FastBlur {
        id: vBlur
        // Cover just the preview viewport (like frozenFrame), not the whole window —
        // anchoring to parent stretched the preview across the letterbox/control area.
        anchors.fill: cam2
        opacity: window.blurView ? 1 : 0
        source: cam2
        radius: 128
        visible: opacity != 0
        transparentBorder: false
        Behavior on opacity { enabled: !window.blurInstant; NumberAnimation { duration: 300 } }
    }

    Glow {
        anchors.fill: vBlur
        opacity: window.blurView ? 1 : 0
        radius: 4
        samples: 1
        color: "black"
        source: vBlur
        visible: opacity != 0
        Behavior on opacity { enabled: !window.blurInstant; NumberAnimation { duration: 300 } }
    }

    // Frozen preview frame — holds ~what the user shot during the still-capture
    // stall, then fades out once fresh live frames resume.
    Image {
        id: frozenFrame
        anchors.fill: cam2
        z: 8000
        fillMode: Image.PreserveAspectCrop
        cache: false
        opacity: 0
        visible: opacity > 0
        property int baseCount: 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
    }

    Timer {
        id: frozenHideTimer
        interval: 4000   // safety: never hold the frozen frame indefinitely
        onTriggered: frozenFrame.opacity = 0
    }

    Connections {
        target: cam2
        // A few fresh live frames after the capture stall ⇒ preview is back; reveal it.
        function onFrameCountChanged() {
            if (frozenFrame.opacity > 0 && cam2.frameCount - frozenFrame.baseCount >= 3) {
                frozenFrame.opacity = 0
                frozenHideTimer.stop()
            }
            // Lift the camera-switch blur once the NEW camera has pushed a couple of
            // fresh frames (so it never uncovers the old camera's held frame).  Snap
            // it off (blurInstant still set → no fade) to match the instant snap-on,
            // then re-enable the fade for other blur users (the menu).
            if (cameraItem.switchBlurBaseCount >= 0
                && cam2.frameCount - cameraItem.switchBlurBaseCount >= 2) {
                cameraItem.switchBlurBaseCount = -1
                switchBlurSafety.stop()
                if (optionContainer.state === "closed")
                    window.blurView = 0
                window.blurInstant = false
            }
        }
    }
}
