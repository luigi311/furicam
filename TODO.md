# FuriCam TODO

Concrete, actionable items for a follow-up coding pass. Each entry has: what's wrong,
evidence (file:line), a fix sketch, and a "done when" check. Effort: **S** (< 1 h),
**M** (hours), **L** (a day+). Priorities: **P0** = do first (small, high value),
**P1** = real bugs, **P2** = features/improvements, **P3** = cleanup.

Background reading: `REVIEW.md` (full analysis). Do **not** start with big refactors —
the items below are deliberately scoped to be safe individually.

---

## P0 — small, high value (start here)

### 1. Flash never fires in pro/manual-exposure mode — S/M
- **Problem:** In pro mode the whole AF-assist torch dance happens (torch on, focus,
  torch off, pause, shutter) but the actual flash pulse never fires — because
  `CameraSession::capturePhoto()` deliberately skips the flash AE modes when AE is off:
  `if (ctlAeMode_ != ACAMERA_CONTROL_AE_MODE_OFF) { … }` (`src/camera2/CameraSession.cpp:1243-1248`).
  So in manual mode you get the weird timing (torch blinks, long pause) and *no flash*.
- **Fix sketch:** when flash is requested (mode 1, or mode 2 + dark) and AE is off, set
  `ACAMERA_FLASH_MODE_SINGLE` directly on the still request instead of relying on the AE
  flash modes. Verify on-device: this HAL is quirky (see comments at
  `Camera2Bridge.cpp:790-793` — ON_AUTO_FLASH never fires there; ON_ALWAYS_FLASH does).
- **Also:** the auto-flash (mode 2) and flash-on (mode 1) paths converge on
  `beginFlashAfCapture` but enter differently (`Camera2Bridge.cpp:767-786`); after the fix,
  sanity-check that auto and on behave identically in the dark (auto should differ only by
  not firing when bright).
- **Done when:** a manual-exposure (pro mode) shot with flash ON visibly fires the flash
  on-device; auto mode still skips the flash in bright light.

### 2. `disconnectFromBus()` kills the app's whole system D-Bus — S
- **Problem:** `src/qrcodehandler.cpp` calls
  `QDBusConnection::systemBus().disconnectFromBus(...)` **25 times** (lines 86, 92, 101,
  135, 164, 232, …), on error paths and normal paths of the Wi-Fi QR flow. The system bus
  is shared process-wide — closing it silently severs GPS (GeoClue), orientation
  (iio-sensor-proxy), NetworkManager and flashlight for the rest of the app's run.
- **Fix sketch:** delete all 25 calls. The connection is not ours to close.
- **Done when:** after scanning a Wi-Fi QR code (success or failure), GPS tagging and the
  device-orientation read still work.

### 3. Video bitrate slider has no effect — decide: strip (recommended) or fix — S
- **Problem:** three bugs stack so the slider can never work:
  1. `setVideoResolution()` resets `videoBitrate_` to the resolution floor on **every**
     call (`src/camera2/Camera2Bridge.cpp:654`), and it's called on entering video mode
     (`src/qml/Camera.qml:325`) and on every record start (`Camera.qml:336`) — the user's
     value is stomped before reaching the encoder.
  2. `videoBitrateKbps()` floors the value (`Camera2Bridge.cpp:575-578`), so anything
     below the floor (10/20/40 Mbps by resolution) is silently ignored anyway.
  3. `setVideoBitrate()` never emits `videoBitrateChanged` (`Camera2Bridge.cpp:606-612`).
- **Options:**
  - **Strip (recommended):** remove the slider (`src/qml/main.qml:2408-2457`) and the
    `videoBitrate` setting; always use the resolution floors. Simpler UI, and the encoder
    already gets sane defaults. User already leans this way — agreed.
  - **Fix:** don't reset `videoBitrate_` in `setVideoResolution` (only clamp), and emit
    `videoBitrateChanged` in `setVideoBitrate`.
- **Done when:** either the slider is gone and recordings still encode at the floor
  bitrates (check the `[camera] recording started … bps` log), or the chosen value
  survives entering video mode and starting a recording.

### 4. Gallery button decodes a full-size photo on the UI thread — S
- **Problem:** `src/qml/main.qml:1254-1262` loads `mediaView.lastImg` with no
  `asynchronous: true` and no `sourceSize` → synchronous multi-MB JPEG decode at startup
  and after every capture.
- **Fix sketch:** `asynchronous: true` + `sourceSize` capped to the button size.
- **Done when:** startup and post-capture show no decode stall (compare with/without).

### 5. Missing `return` after NULL check — S
- **Problem:** `AppController::get_last_orientation_state` continues after a failed
  `g_settings_new` (`src/appcontroller.cpp:157-168`). Benign today (GLib warning),
  crash-prone pattern.
- **Fix sketch:** add `return;` inside the `if (!settings)` block.
- **Done when:** no GLib critical on startup when the schema is absent.

---

## P1 — real bugs

### 6. A failed capture silently misfiles the next photo — M
- **Problem:** `resultCb_` only registers `onCaptureCompleted`
  (`src/camera2/CameraSession.cpp:588-590`); `onCaptureFailed`/`onCaptureBufferLost`
  (fields exist, `src/camera2/Camera2NDK.h:449,452`) are never set. On a failed capture,
  the path stays queued in `pendingPhotoPaths_` and the **next** successful photo pops it —
  written to the old filename, `photoSaved` fires for the wrong file.
- **Fix sketch:** register both failure callbacks; on failure pop the matching path and
  fire `photoCallback_(path, false)`. Burst path (`captureBurst`) needs the same care.
- **Done when:** force a capture failure (e.g. cover lens + stress HAL) and confirm the
  next photo lands at its own correct path and the UI shows an error, not a wrong file.

### 7. Camera HAL death is logged but invisible — M
- **Problem:** `onDeviceDisconnected`/`onDeviceError` only log
  (`src/camera2/CameraSession.cpp:1931-1941`). The device is dead per the NDK contract,
  but the app keeps showing a frozen/black preview with no error and no retry.
- **Fix sketch:** `std::atomic<bool> deviceDead_` set in both callbacks; gate session ops;
  emit `cameraError()` up to QML; offer a reconnect (which is just `startCamera()`).
- **Done when:** killing the camera service on-device produces the error banner and a
  working recovery path.

### 8. Camera open/close blocks the UI thread for seconds; whole stack rebuilt on every focus change — L
- **Problem:** `Camera2Bridge::startCamera()` runs enumerate→open→session→repeating
  synchronously on the UI thread (`src/camera2/Camera2Bridge.cpp:126-289`; device open is
  2–4 s on this HAL). On window deactivate the app destroys the *entire* camera+GL stack
  (`src/qml/main.qml:91-101`, `src/qml/Camera.qml:200-210`) and rebuilds it on activate.
  This is the app's main stability/UX hazard (see REVIEW.md C2/C3, including the
  `std::function` callback races that must be fixed in the same pass).
- **Fix sketch:** move session open/close to a worker thread (bridge already has `ready`
  for QML to bind); on hide, stop streaming but keep the bridge item alive; guard
  `frameCallback_`/`analysisCallback_`/`photoCallback_` with a mutex and drain in-flight
  image callbacks before deleting readers in `close()`.
- **Done when:** launching, backgrounding, foregrounding and camera-flipping never freeze
  the UI; no ASAN/valgrind reports on the callback paths.

### 9. Post-capture processing runs on the UI thread — M
- **Problem:** color correction (`src/filemanager.cpp:871-925`), pixel filter
  (`src/camera2/Camera2Bridge.cpp:924` → `src/pixelfilter.cpp:62-127`) and EXIF writes run
  on the UI thread after every shot; the pixel filter also rewrites the photo **in place**
  at default JPEG quality.
- **Fix sketch:** move post-save file work to the session's writer thread or a
  `QThreadPool`; write filter output to a temp file + rename; pass through the quality
  setting.
- **Done when:** with a palette filter and color correction on, shot-to-shot time and UI
  responsiveness match the plain path.

### 10. HDR: wrap in try/catch, shrink peak memory, cap the debug log — S/M
- **Problem:** ~400 MB peak with unguarded OpenCV allocations on a detached thread →
  `std::terminate` under memory pressure (`src/hdrprocessor.cpp:91-185`);
  `hdrLog()` appends to `/tmp/hdr_debug.log` forever (RAM-backed tmpfs,
  `src/hdrprocessor.cpp:38-44`). Also capture the `hdrSaveEv0_` read by value
  (REVIEW.md A4).
- **Fix sketch:** try/catch around the whole pipeline; `frames.clear()` before Mertens;
  release `fusedFull` after `convertTo`; delete or gate `hdrLog()` behind an env var.
- **Done when:** HDR under low memory (e.g. with a memory hog running) degrades to an
  error banner instead of killing the app; `/tmp/hdr_debug.log` no longer grows.

### 11. Gallery: stop the full rescan on every delete — M
- **Problem:** `MediaReview.qml:99-111` — `refresh()` forces a full `FolderListModel`
  rescan (folder="" → restore). The comment claims "inotify is unavailable on device".
  **That claim is unverified and smells cargo-culted** — QFileSystemWatcher uses inotify
  and this is a normal Linux filesystem. Spend 15 minutes checking whether the watcher
  actually fails (and why) before replacing anything.
- **Fix sketch (in order of preference):** (a) if the watcher works, drop `refresh()`
  entirely; (b) if not, remove just the deleted index from view state instead of
  rescanning; (c) only if the model must change, a small C++ gallery model with
  incremental add/remove (which also fixes the eager-N-delegates issue, REVIEW.md P5).
- **Done when:** deleting a photo updates the gallery instantly without a visible reload,
  and a photo taken externally (another app) appears without restart.

### 12. `gsettings` subprocess on every gallery date read — S
- **Problem:** `FileManager::getTimeFormat()` spawns a blocking `gsettings` process per
  call (`src/filemanager.cpp:323-330`), called per gallery item
  (`src/qml/MediaReview.qml:87`).
- **Fix sketch:** read once and cache (or use the GSettings C API directly).
- **Done when:** swiping through photos spawns no processes (watch with `strace -f -e execve`).

### 13. Three blocking `ffprobe` runs on video-info drawer open — S/M
- **Problem:** `MetadataView.qml:36-39` → `getDocumentType`/`getVideoDimensions`/
  `getCodecId` each spawn ffprobe with a 3 s wait on the UI thread
  (`src/filemanager.cpp:687-789`).
- **Fix sketch:** one combined ffprobe call, async (reuse the `requestVideoDate` pattern).
- **Done when:** opening the drawer on a video never stalls; one probe process total.

### 14. Backgrounding mid-recording leaves a corrupt MP4 — M
- **Problem:** `CameraSession::close()` sets `recording_ = false` then tears the encoder
  down without finalizing (`src/camera2/CameraSession.cpp:422-462`) — the clip is left
  unplayable.
- **Fix sketch:** route `close()` through `stopRecording()` first (which finalizes via
  `endClip()`), or explicitly finalize in `close()` when a clip is active.
- **Done when:** backgrounding the app mid-record yields a playable MP4.

### 15. Tap-to-focus ignores the tap position (regression vs. furios-camera) — M
- **Problem:** the yellow square lands where you tapped, but the AF region is computed
  somewhere near the center. Cause: `Camera2Bridge::setFocusPoint`
  (`src/camera2/Camera2Bridge.cpp:1041-1051`) forwards the *view-normalized* tap
  coordinates unchanged to `CameraSession::setFocusPoint`
  (`src/camera2/CameraSession.cpp:1889-1929`), which maps them **directly** onto the
  sensor's active array — ignoring that the preview is *rotated* (sensor orientation),
  *cropped* (`cropScaleX/Y` for the still aspect), and *mirrored* (front camera). The old
  QtMultimedia path did this transform internally, which is why it worked in
  furios-camera.
- **Fix sketch:** apply the inverse of the mapping already proven in
  `Camera2Bridge::qrDecode` (`Camera2Bridge.cpp:1248-1266`, which maps sensor→viewfinder
  with rotation+crop): view→sensor is roughly
  `sensor = crop * R(+previewRotation) * (view − 0.5) + 0.5`, plus an x-flip when the
  front camera mirror is active. Clamp to the active array as today.
- **Done when:** tapping an object on screen focuses *that* object on both back and front
  cameras (verify the AF region in the HAL logs if needed), at multiple zoom levels.

### 16. HDR: one burst frame per shot fails JPEG decode — M
- **Problem:** on-device log shows `qt.gui.imageio.jpeg: Corrupt JPEG data: premature end
  of data segment` once per HDR burst — one of the 3 frames is truncated and the fusion
  silently runs on the remaining two. Likely cause: the long-exposure (+3 EV, ~240 ms)
  frame's JPEG exceeds the HAL buffer, so no EOI marker is found by the trim in
  `onJpegImageAvailable` (`src/camera2/CameraSession.cpp:1438-1441`), or the EOI trim
  itself cuts early.
- **Fix sketch:** log which frame fails and its size; detect "no EOI found" explicitly
  and treat the burst as failed (error banner) rather than fusing 2 of 3; if it's the
  buffer, raise `maxImages`/size for the JPEG reader or clamp the +EV exposure so the JPEG
  fits. `HdrProcessor` should also loudly reject an undecodable frame instead of
  continuing silently.
- **Done when:** no `Corrupt JPEG data` warnings across 10 consecutive HDR shots, and a
  failed burst surfaces an error instead of a silently wrong result.

---

## P2 — features / improvements

### 17. Manual focus slider in pro mode — M
- **Status:** engine support already exists — `setFocusDistance(diopters)` end-to-end
  (`src/camera2/Camera2Bridge.h:236`, `src/camera2/CameraSession.cpp:1756-1760` sets
  AF off + focus distance), `minFocusDistance`/`focusDistanceCalibration` are exposed.
  Only the UI is missing.
- **Fix sketch:** add a focus-distance slider to the pro-mode drawer: range 0 (=infinity/
  auto) .. `minFocusDistance` diopters; only show when `minFocusDistance > 0`; show a note
  when `focusDistanceCalibration` is uncalibrated. Reset to 0 = return to autofocus.
- **Done when:** in pro mode the slider visibly moves focus near↔far and 0 restores AF.

### 18. Gallery performance pass — M/L
- **Problem:** `MediaReview` is created at startup; `FolderListModel` scans immediately;
  `Repeater` builds one full delegate per photo (REVIEW.md P5); gallery `Image`s use
  `cache: true` (~46 MB each kept).
- **Fix sketch:** gate the model on `mediaView.visible`; replace Repeater+SwipeView with
  a `ListView` (delegate recycling); drop `cache: true`.
- **Done when:** cold start with ~500 photos is visibly faster and memory after a long
  swipe session stays bounded.

### 19. Per-frame/battery polish — S
- `frameCountChanged` → QML every frame (`src/camera2/Camera2Bridge.cpp:213-219`) —
  throttle to ~5 Hz. Video drain thread polls 100×/s when idle
  (`src/camera2/VideoEncoder.cpp:147-149`) — back off when idle. `AccelReader` 30 Hz
  blocking D-Bus with 50 ms timeout (`src/accelreader.cpp:55,79`) — use async calls.
  QR decode uses `setTryHarder(true)` at ~6 Hz (`src/camera2/Camera2Bridge.cpp:1242`) —
  consider `tryHarder(false)` or lower rate; measure CPU.

---

## P3 — cleanup (safe when touching the area anyway)

### 20. Dead code deletion — S
- `src/qml/QrCode.qml` (has a 120 Hz timer; never instantiated), `src/qml/ZoomControl.qml`
  (references undefined `camera`), `src/windoweventfilter.*` (never installed),
  `WhiteBalanceController`/`MeteringController`/`HdrProcessor` QML instances
  (`src/qml/Camera.qml:73-74`) + their `qmlRegisterType` (`src/main.cpp:43-45`),
  `flashlightController` context property (unused), `FileManager` mkvinfo family
  (`runMkvInfo`, `getDuration`, `getVideoMetadata`, `getMultiplexingApplication`,
  `getWritingApplication`, `finalizeMkv`, `getVideoRotation`,
  `removeGStreamerCacheDirectory` — all zero QML callers).
- **Done when:** `grep -r` shows no references; app builds and behaves identically.

### 21. Packaging + upstream regressions — S
- Restore `flags: Qt.FramelessWindowHint` and `Screen.orientationUpdateMask:
  Qt.PortraitOrientation` (upstream had them). Fix or drop the tray icon
  (`src/main.cpp:58-64` — path doesn't match the .install location, and a tray is
  pointless on phosh; dropping it is fine — it does **not** cause crashes, that's a myth).
  Confirmed by the on-device log: `qt.svg: Cannot open file '/usr/share/icons/furicam.svg'`,
  `QSystemTrayIcon::setVisible: No Icon set`, and `org.kde.StatusNotifierWatcher was not
  provided` — all three disappear once the tray is removed.
  Install `extra/furicam-radio.pkla` and `furicam.conf`→`/etc` (currently installed
  nowhere). Drop the stale Qt5-ABI `sed` in `debian/rules`.
- Also cosmetic: `Qt.labs.settings` is deprecated (warning at startup) — migrate the two
  `Settings` blocks in `main.qml` to the QtCore `Settings` type when convenient.
- **Done when:** package installs all files; no tray/SVG/D-Bus warnings at startup.

### 22. Hardening patches — S/M
- easyexif out-of-bounds reads (`src/exif.cpp:350-351, 698, 705, 769-848`).
- `DngWriter.cpp:237-253`: `bad_alloc` guard + validate `rowStrideBytes >= width*2`.
- `VideoEncoder::open` error paths leak/poison the codec (`src/camera2/VideoEncoder.cpp:67-82`);
  `AudioEncoder.cpp:132-148` appsink ref leak + `:241` ignored `addTrack` failure;
  `VideoEncoder.cpp:171,317` unchecked `AMediaMuxer_writeSampleData` (silent corrupt
  video on full storage) — surface a `cameraError` instead.

### 23. QML warning: "Cannot create new component instance before completing the previous" — S
- **Problem:** printed once near startup. Some `asynchronous: true` Loader gets
  re-triggered before its previous load finished — candidates: `cameraLoader` (toggled by
  window focus changes, `src/qml/main.qml:329-388`), `stateBtnLoader`/`shutterBtnLoader`
  (swapped on mode swipes, `main.qml:1279-1303`), `popupBodyLoader`. If it ever fires in a
  user-visible path, that area silently stays blank.
- **Fix sketch:** identify which Loader logs it (add `onStatusChanged` logging or run with
  `QML_IMPORT_TRACE`), then guard the toggle (`if (status === Loader.Ready || status ===
  Loader.Null)` before changing `active`/`sourceComponent`).
- **Done when:** the warning never appears across startup + a mode-swipe session.

### 24. ThumbnailGenerator probes the still-recording MP4 — S
- **Problem:** on-device log shows ffmpeg probing `VID_…mp4` *while it is still being
  recorded* → `exit: 183` (the MP4's moov atom isn't written until finalize), then a later
  retry succeeds. Harmless but noisy and wasted work; with worse timing it can leave the
  "failed" state cached for the session.
- **Fix sketch:** skip thumbnail requests for the path returned by
  `Camera2Bridge.recordingPath_` while `recording` is true (or simply ignore failures for
  files < 2 s old and let the next gallery open retry, which already works).
- **Done when:** no `exit: 183` thumbnail failures when opening the gallery right after
  starting/stopping a recording.

---

## Deliberately skipped (don't do these)

- **Big-bang file splits** (main.qml, CameraSession.cpp, FileManager god-class): fine as
  long-term hygiene (proposals in REVIEW.md), but only split a file when you're already
  touching it for a bug above. Splitting for its own sake now just creates new bugs.
- **QSystemTrayIcon as a crash fix:** it's a no-op on Wayland/phosh, harmless. Remove for
  uselessness (item 19), not for stability.
- **Test infrastructure:** nice, but only worth it if someone maintains it. If you want a
  start, unit-test the pure helpers only (`decimalToDMS`, `formatVideoDate`,
  `PixelFilter::loadPalette`, `toHalJpegQuality`).

## Watch-outs for the implementing agent

- This HAL is quirky; the code is full of verified workarounds (flash, torch/AE
  conflicts, session-close waits). Read nearby comments before "simplifying" anything —
  several odd-looking lines are load-bearing.
- `main.qml`↔`Camera.qml` communicate through a duck-typed `handle*` contract. Rename
  nothing without updating both sides.
- Measure before/after for perf items: startup time, shot-to-shot time, recording stop
  time. On-device numbers beat guesses.
- The QML `Settings` writes 10 hardcoded camera slots; if you touch resolution
  persistence, keep QML and C++ stores in sync (better: make C++ the single source,
  REVIEW.md "Duplicated logic").
