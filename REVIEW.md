# FuriCam Code Review

Date: 2026-07-26
Scope: full source tree (`src/`), QML (`src/qml/`), packaging (`debian/`), plus a comparison with
upstream `furios-camera` and the compositor crash logs captured on-device.
Audience: written in plain language — every finding explains *why it matters*, not just what it is.

---

## Executive summary

**Crash investigation update (2026-07-26):** the on-device journal proves the shell died of a
segmentation fault (`phosh.service … status=11/SEGV`) and that this was its **12th crash in
~17 h**. The shell has a chronic instability of its own (gnome-keyring also segfaulted in the
same window). FuriCam does not appear in the log, but terminal-launched apps never do — and
the user reports the app printed its startup Wayland line (`qrcodehandler.cpp:36`) seconds
before this crash, so a launch *trigger* on the already-fragile shell is plausible. Getting a
backtrace (`systemd-coredump`) and reporting this log to the FuriOS/phoc maintainers is the
way forward for the shell crash itself.

The code review (read-only) did **not** find a line of code that provably kills phosh — but it
did find, in rough order of importance:

1. At launch the app opens the camera **on the UI thread**, freezing itself for 2–4 seconds
   while the window is already on screen, and it tears down and rebuilds the *entire* camera +
   graphics pipeline every time the window loses focus — launches are fragile and timing-dependent.
2. Several genuine race conditions that can crash **the app** mid-startup or mid-switch.
3. The only realistic way an app *could* contribute to a shell crash on this phone is a GPU
   driver fault, and this app does unusually exotic GPU work (importing Android camera buffers
   into the same graphics chip the shell uses) — while the log shows the shell's GPU-buffer
   import support is broken/absent (`EGL_EXT_image_dma_buf_import not supported`), so this
   graphics stack is already in a fragile fallback mode.
4. A long list of real performance problems — multi-second UI freezes after photos in some modes,
   ~400 MB memory spikes in HDR, blocking subprocess and D-Bus calls on the UI thread.
5. Two files that genuinely deserve splitting and a pile of dead Qt5-era code.

---

# Priority 1 — Startup stability (the phosh question)

## What the crash-time journal shows (confirmed evidence)

The full unfiltered journal around the 2026-07-26 09:13 crash settles several questions:

**1. The crash is confirmed, and it is a segfault in the shell:**

```
Jul 26 09:13:30 iPhone systemd[1]: phosh.service: Main process exited, code=killed, status=11/SEGV
Jul 26 09:13:30 iPhone systemd[1]: phosh.service: Failed with result 'signal'.
Jul 26 09:13:35 iPhone systemd[1]: phosh.service: Scheduled restart job, restart counter is at 12.
```

- `status=11/SEGV` = the shell's main process (the compositor) died of a segmentation fault.
  It was **not** the OOM killer (no `oom`/`killed process` lines anywhere) and not a clean
  exit — it is a genuine crash, just as the "silent death" pattern suggested.
- **Restart counter is at 12** — this was the *twelfth* time the shell crashed and was
  restarted in ~17 hours of uptime. The shell crashes regularly, roughly every 1–2 hours,
  whether or not anything unusual is happening.
- Just before the exit, every graphical client logs `Lost connection to Wayland compositor` /
  `Error reading events from display: Broken pipe` — they lost the server *before* systemd
  noticed the death, so the compositor process itself is what segfaulted.

**2. FuriCam does not appear in the journal — but that does NOT clear it (correction).**
Nothing named "furicam" is logged in the window. However, two things keep the question open.
First, the user reports launching the app **from the terminal** moments before the crash and
seeing it print its Wayland line right as the shell died — and that matches the code exactly:
`QRCodeHandler`'s constructor prints `WAYLAND_DISPLAY is already set to 'wayland-0'` to
stdout at startup (`qrcodehandler.cpp:36`). Second, a GUI app launched from a terminal prints
to the *terminal*, not to the journal, and creates no "Application launched by phosh" scope —
so the journal is **blind to terminal-launched apps**. The honest statement is therefore: the
journal neither proves nor disproves FuriCam's involvement in this instance; the user's own
account says the app started seconds before the segfault. What the log *does* prove is the
chronic instability in point 1 (12 restarts — the shell also crashes with no new apps around)
and that FuriCam is not the *only* thing segfaulting on this system (point 3). Whether the
launch *triggered* this instance remains open; the GPU-stress mechanism (C1 below) is the
plausible channel if it did.

**3. The shell is not the only thing segfaulting.** 11 seconds later,
`gnome-keyring-daemon.service: Main process exited, code=killed, status=11/SEGV` (09:13:41).
Two unrelated processes segfaulting within seconds points at platform-level instability
(driver/library/memory), not at any single app.

**4. Kernel messages never reach the journal on this system** (zero `kernel:` lines in the
whole window), so GPU/Mali faults would not show up here — check them with
`sudo dmesg -T | grep -iE "mali|gpu|fault|reset"` around a crash time.

Other confirmed platform facts from the log:
- `phoc[363697]: EGL_EXT_image_dma_buf_import not supported` / `Linux dmabuf support
  unavailable`, and `phosh[363799]: Falling back to shm_open for shared memory buffers` —
  the compositor **cannot import GPU buffers from applications**; everything (including Qt
  apps) crosses via shared memory. The graphics stack is in a fragile fallback mode, and
  Xwayland falls back to software rendering (`Failed to initialize glamor`).
- `sensorfwd[1974]: Failed to write data to socket` fires ~26×/second for the entire window —
  sensorfw is stuck writing to a dead client session. Not the crash cause, but constant wasted
  work and log spam worth reporting to FuriOS. (FuriCam's `AccelReader` does stop its sensor
  session in its destructor, `accelreader.cpp:26-31`, so no direct accusation — but it does
  not release the session on a crash/kill either.)
- Post-crash, the on-screen keyboard crash-loops 6× with `cannot open display: :0` — harmless
  fallout of the restart, ignore.

**Bottom line from the log:** the shell has a **chronic, independent segfault problem** (12
restarts in 17 h, plus a second unrelated process — gnome-keyring — segfaulting in the same
window). The user-started-FuriCam-then-crash account is consistent with the log (terminal
launches are invisible to the journal), so this particular crash may well *follow* a FuriCam
launch — but on a shell this unstable, launches are triggers at most, not the root cause. The
next piece of evidence to collect is a backtrace — see below.

## How to capture the real crash record (what to run next time)

The phone stays up, so everything is in the current boot's journal. What actually works on
this device (verified against the captured log):

```sh
# 1. The confirmation — this is what found the SEGV record:
journalctl -b --since "2026-07-26 09:09:00" --until "2026-07-26 09:14:30" --no-pager \
    > ~/crash-window.log
grep -E "SEGV|Main process exited|coredump|oom|killed" ~/crash-window.log

# 2. A backtrace (coredumpctl is NOT installed by default on FuriOS):
sudo apt update && sudo apt install systemd-coredump
# ...then reproduce the crash once more, and:
coredumpctl list
coredumpctl info phoc          # or 'coredumpctl debug phoc' for gdb

# 3. GPU driver faults (kernel messages do NOT appear in the journal on this device):
sudo dmesg -T | grep -iE "mali|gpu|fault|reset" | tail -50

# 4. Correlate: was FuriCam (or anything else) running near each crash?
journalctl -b --no-pager | grep -iE "furicam|status=11/SEGV" | less
```

If `coredumpctl list` stays empty after installing, make journald persistent
(`Storage=persistent` in `/etc/systemd/journald.conf`, i.e. keep `/var/log/journal`) and
reproduce once more. The backtrace answers in one minute what static analysis can't: whether
the crash is in phoc itself, in the Mali/hybris GPU libraries, or somewhere else entirely.
**Also: file this log excerpt with the FuriOS/phoc maintainers** — a `status=11/SEGV` with
restart counter 12 on a stock shell is their bug to fix regardless of FuriCam.

## Candidate causes from the code review

### C1 — GPU driver fault via the zero-copy preview path (plausible mechanism; unprovable from code alone) — **High**

**Evidence:** `src/camera2/PreviewRenderer.cpp:347-368` — every preview frame is imported as
`AImage → AHardwareBuffer → eglGetNativeClientBufferANDROID → eglCreateImageKHR →
GL_TEXTURE_EXTERNAL_OES` texture, drawn into a Qt FBO, then optionally fed through more GPU
passes (`FastBlur`/`Glow` in `Camera.qml:830-852`, `layer.effect ShaderEffect` in
`Camera.qml:522-530`).

**Why it matters:** on this phone, *everything* graphical — this app **and** the phosh
compositor — talks to the same Android Mali GPU driver through libhybris. If a GPU job hangs or
a buffer is misused, the driver can fault in a way that takes down the compositor's rendering
too. That is the only mechanism by which *any* app on this stack can realistically take phosh
down with it. Your journal strengthens the suspicion that this area is fragile: the compositor
can't even import GPU buffers (`EGL_EXT_image_dma_buf_import not supported`), so the graphics
stack is already running on fallbacks. Two aggravating details in the app: `eglCreateImageKHR`
failure is silently ignored (`PreviewRenderer.cpp:359-361`, no log, stale frame kept), and at
startup this pipeline switches on at the same moment the window first appears and several heavy
visual effects come online.

**Fix direction:** log every `eglCreateImageKHR`/`glEGLImageTargetTexture2DOES` failure; run an
experiment with `QT_QUICK_BACKEND=software` (disables the app's GPU use entirely — slow but a
clean bisect: if phosh never crashes then, the GPU path is implicated); keep the effects stack
(FastBlur etc.) off during the first seconds.

### C2 — The whole camera + graphics stack is destroyed and rebuilt on every focus change, and opening the camera blocks the UI thread for seconds — **High**

**Evidence:** `main.qml:91-101` — when the window loses `active`, QML calls
`window.stopCamera()`; `Camera.qml:200-203` — `handleStopCamera()` calls `cam2.stopCamera()`
**and** `cameraLoader.active = false`, which destroys the entire `Camera2Bridge` item, its
renderer, and closes the camera HAL. Regaining focus recreates everything (`Camera.qml:484`).
The open path itself — `Camera2Bridge::startCamera()` (`Camera2Bridge.cpp:126-289`) — runs
`enumerate()` → `open()` → `createCaptureSession` → `setRepeatingRequest` **synchronously on
the UI thread**; the code's own comments note a device open takes "2–4 s"
(`Camera2Bridge.cpp:673`).

**Why it matters:** two reasons. First, during those seconds the window is mapped but the app
cannot process input or draw — under phosh, focus can flip during startup (notification shade,
lock screen, overview), so a launch can land mid-teardown. Second, every teardown/rebuild
replays all the race windows in C3 below, and the initial launch is exactly when one of these
flips is most likely. This is the strongest app-side explanation for "sometimes it goes wrong
at launch" — but note it primarily endangers **the app**, not the shell directly.

**Fix direction:** move `startCamera()`/`stopCamera()` onto a worker thread (the QML side
already has `ready` to bind against); don't destroy the `Camera2Bridge` on hide — stop the
stream but keep the item alive; consider not reacting to transient `active` loss at all (only
to hide/minimize).

### C3 — Races between the UI thread and camera-driver callback threads can crash the app mid-startup or mid-switch — **High**

**Evidence:**
- `CameraSession.h:291` / `CameraSession.h:171` — `frameCallback_` and `analysisCallback_` are
  plain `std::function` **written from the UI thread** (`Camera2Bridge.cpp:213, 268` and
  `:301`) while Android "binder" threads **read and call them** (`CameraSession.cpp:1063-1065`,
  `:1040-1048`). Assigning a `std::function` on one thread while another thread invokes it is
  undefined behavior — a real, if intermittent, crash source.
- Teardown race: `closeSessionLocked()` (`CameraSession.cpp:638-662`) first unregisters the
  image listeners, but a callback already *running* on a binder thread can still be inside
  `onJpegImageAvailable`/`onAnalysisImageAvailable` when `freeStreamResources()` deletes the
  readers (`CameraSession.cpp:686-717`). Using a deleted `AImageReader` inside libhybris is a
  use-after-free crash. The analysis-stream listener is only cleared late (`:715`), after the
  session is already closed.

**Why it matters:** these fire precisely during camera switch / hide / startup churn — the
"sometimes" timing. A crashing client doesn't normally restart the compositor, but a client
dying in the middle of surface setup is exactly the situation that exercises compositor bugs.

**Fix direction:** guard the three `std::function` members with a small mutex (or swap them
under the same lock used for teardown), and in `close()` wait briefly for in-flight callbacks
to drain before deleting readers.

### C4 — Encoder startup failure paths corrupt encoder state — **Medium**

**Evidence:** `VideoEncoder.cpp:67-82` — if `AMediaCodec_configure`, `createInputSurface`, or
`AMediaCodec_start` fails, the function returns `false` but leaks `codec_` (and
`inputWindow_`), leaving `codec_` non-null, so every retry hits "already open" and fails
forever. `AudioEncoder.cpp:132-148` — `gst_bin_get_by_name` returns a new reference that is
never released (one GStreamer object leaked per recording session); `AudioEncoder.cpp:241` —
the audio track is marked added even if adding it failed, so audio is silently dropped.

**Why it matters:** a camera app on a phone must survive transient failures (slow storage, busy
codec). Today one failure poisons video recording until the app restarts, and a failed first
launch leaves the app half-crippled.

**Fix direction:** on any failure after codec creation, call the full teardown
(`AMediaCodec_delete`, release the surface) before returning false; unref the appsink; honor
the `addTrack` return value.

### C5 — Things checked and found OK (so you don't re-chase them)

- `PreviewRenderer::init()` verifies its GL/EGL function pointers and fails gracefully
  (`PreviewRenderer.cpp:238-243`); all rendering happens with Qt's GL context current on the
  render thread.
- Session-close waits (up to 2 s) for the HAL's `onClosed` before reopening
  (`CameraSession.cpp:654-659`) — good defense against close→open races.
- The binder thread pool needed to avoid the classic `ACameraDevice_close` deadlock is started
  (`CameraSession.cpp:51-74, 477`) — the author knew this trap and handled it.
- Error paths in `startPreview()` roll back cleanly (`CameraSession.cpp:484-636`);
  `Camera2Bridge` falls back to a safe 1280×720 preview if the chosen size is rejected
  (`Camera2Bridge.cpp:246-255`).

---

# Priority 2 — Performance

## High

**P1 — After every photo, heavy image processing runs on the UI thread (multi-second freeze).**
- Color correction: `Camera.qml:369-373` → `FileManager::applyColorCorrection`
  (`filemanager.cpp:871-925`): decodes a ~20 MP JPEG, does per-pixel floating-point math
  (~80 MB of pixel data), re-encodes — all on the UI thread, after *every* shot when enabled.
- Pixel-art filter: `Camera2Bridge.cpp:924` → `PixelFilter::applyToFile`
  (`pixelfilter.cpp:62-127`): full decode + re-encode of the photo on the UI thread per shot;
  it also rewrites the only copy of the photo **in place, at default JPEG quality (~75)**,
  silently degrading the quality-95 original, and a failed save destroys the original (no
  temp-file-then-rename).
- EXIF/GPS writes: `Camera.qml:375-381` → several exiv2 open+parse+write cycles per shot on
  the UI thread.

  **Fix:** move all post-save file work to a worker thread (the session already has one — the
  JPEG writer thread in `CameraSession`); write pixel-filter output to a temp file and rename;
  pass the quality setting through.

**P2 — Full-resolution JPEG decoded on the UI thread at startup and after every capture.**
`main.qml:1254-1262` — the little round gallery button uses `source: mediaView.lastImg` with
**no `asynchronous: true` and no `sourceSize`**, so Qt synchronously decodes the newest
~12–20 MP photo (tens of MB) on the UI thread at app start and again after every shot
(`MediaReview.qml:21, 165`). **Fix:** `asynchronous: true` plus `sourceSize` capped to the
button size (or use the existing thumbnail generator).

**P3 — HDR fusion peaks at ~400 MB and can kill the app outright.** `hdrprocessor.cpp:91-185`:
three full-resolution OpenCV images (~60 MB each) plus aligned copies, plus a 240 MB float
buffer (`fusedFull`, held needlessly until the end, `:180-241`). Worse, the big allocations are
**not** inside try/catch (`:155, 180-185`), so under memory pressure OpenCV throws on a
detached worker thread → `std::terminate` → the whole app dies (this *is* an app crash,
exactly when the phone is busiest). Also `hdrLog()` appends to `/tmp/hdr_debug.log` forever
(`hdrprocessor.cpp:38-44`) — on a phone `/tmp` is RAM, so it's a slow permanent memory leak.
**Fix:** wrap the whole pipeline in try/catch, release buffers earlier (`frames.clear()` before
Mertens; drop `fusedFull` right after `convertTo`), cap or disable the debug log.

**P4 — Blocking calls on the UI thread in everyday flows.**
- `FileManager::getTimeFormat()` (`filemanager.cpp:323-330`) spawns a `gsettings` subprocess
  and waits for it — called for *every* photo date shown (`MediaReview.qml:87`), i.e. per
  gallery swipe; `getPictureMetaData` also reads the entire multi-MB JPEG into RAM per new
  photo (`filemanager.cpp:295-311`, softened by a one-entry cache).
- `AccelReader` polls the sensor service at ~30 Hz with a **blocking D-Bus call with a 50 ms
  timeout** (`accelreader.cpp:55, 79`) — a sluggish sensor service guarantees continuous
  stutter while the level feature is on; `start`/`stop` can block up to ~25 s (`:54, 63`).
- `MetadataView.qml:36-39` runs **three** sequential blocking `ffprobe` subprocesses (up to
  3 s each) on the UI thread when the video info drawer opens (`filemanager.cpp:687-709,
  749-789`).
- Wi-Fi QR popup re-walks all of NetworkManager over blocking D-Bus every 3 s
  (`main.qml:1587, 1611` → `qrcodehandler.cpp:532-551`).

  **Fix:** cache the time format (or read GSettings via the C API once), make the accel reader
  use sensorfw's change signal or an async D-Bus call, reuse the existing async
  `requestVideoDate` pattern for the other probes, throttle the signal-strength polling.

## Medium

**P5 — Startup loads the whole gallery eagerly.** `main.qml:1494` instantiates `MediaReview` at
launch even though it's invisible; inside it, `FolderListModel` scans `~/Pictures/furicam`
immediately (`MediaReview.qml:129-168`) and a `Repeater` creates one full delegate (≈15
QObjects each) **per photo on disk** (`MediaReview.qml:216-219`) — with 500 photos that's
~7,500 objects at launch. **Fix:** gate the model on `mediaView.visible` (set `folder` only
when opened) and replace `Repeater`+`SwipeView` with a `ListView` (delegate recycling).

**P6 — Per-frame costs.** `frameCountChanged` is emitted into QML for every preview frame
(`Camera2Bridge.cpp:213-219`), driving `Camera.qml:877-894`; acceptable alone, but combined
with the `FastBlur radius:128` + `Glow` chain sourced from the live preview during transitions
(`Camera.qml:830-852`) and the optional color-correction shader layer (`Camera.qml:522-530`),
the phone renders several full-screen multi-pass effects at 60 fps on a GLES2-class GPU.
Gallery images use `cache: true` (`MediaReview.qml:307`), so swiped photos accumulate ~46 MB
each in the global pixmap cache. **Fix:** cap blur radius/duration, drop `cache: true` for
gallery pages, throttle `frameCountChanged` to ~5 Hz.

**P7 — Recording path stalls.** `VideoEncoder::endClip()` busy-waits up to 2 s on the UI thread
(`VideoEncoder.cpp:197-215`), `AMediaCodec_stop/delete` and muxer finalize also run there
(`:223-229, 255-256`), and the drain thread wakes 100×/s forever while video mode is on
(`:147-149`) — battery. Also `AMediaMuxer_writeSampleData` return values are never checked
(`:171, 317`), so a full SD card yields a silently corrupt video. **Fix:** move stop/finalize
off the UI thread, sleep longer when idle, check muxer writes.

---

# Priority 3 — Maintainability

## File-split verdicts (only where it genuinely helps)

**Split: `src/qml/main.qml` (2,776 lines) — yes.** It currently contains the window shell, the
mode state machine, ~15 timers, the entire bottom control bar (~lines 1000-1500), the QR/Wi-Fi
popup system (~1503-1744), and a ~700-line settings drawer (~2034-2758). Minimal, concrete
split:
- `SettingsDrawer.qml` — everything from the settings drawer block (it only talks to `settings`
  and `cameraLoader.item`, both easy to pass in).
- `QrResultPopup.qml` — popup backdrop + wifi/qr components + button logic (~1503-1744).
- `MainControlBar.qml` — shutter/record/review/rotate buttons (~1000-1500).

main.qml keeps the window, state machines, timers, and the Loaders.

**Split: `src/camera2/CameraSession.cpp` (2,251 lines) — yes.** One class, but four distinct
jobs: device/session lifecycle, still capture (JPEG + burst + RAW/DNG + the writer thread,
~600 lines), recording/video mode (~500 lines), manual AE/AF controls (~350 lines). C++ lets
you split member functions of one class across files without changing any caller:
`CameraSessionCapture.cpp` (still/burst/RAW/writer + `onJpeg/RawImageAvailable`) and
`CameraSessionControls.cpp` (`applyControls` + all setters + AF/AE triggers). Lifecycle +
recording stay in `CameraSession.cpp`.

**Borderline: `src/qml/MediaReview.qml` (1,162 lines) — split lightly.** Move
`mediaPageComponent` (~440 lines: photo zoom/pan + video page) into `MediaPage.qml`. The rest
is cohesive gallery chrome; leave it.

**Borderline: `src/camera2/Camera2Bridge.cpp` (1,273 lines) — split lightly.** Extract the
flash/AE/AF polling sequencer (`beginAutoFlashCapture`/`beginFlashAfCapture`, `:794-852`) and
the HDR burst orchestration (`:729-765, 905-983`) into a `CaptureSequencer` helper class; the
QR decode + coordinate math (`:1228-1271`) into a small `QrDecoder.cpp`. The rest is a property
bag — fine.

**Don't split:** `Camera.qml` (896 lines, cohesive), `filemanager.cpp` (926) — but gather all
ffprobe/mkvinfo `QProcess` wrappers into one `VideoProbe` class (they're the blocking-call
problem from P4, so this pays off twice); `exif.cpp` (vendored third-party — patch bugs, never
restructure); `qrcodehandler.cpp` — instead move the NetworkManager D-Bus code (~400 lines)
into a `WifiConnector` class so the QR string parsing stays pure.

## Duplicated / diverging logic

- **White-balance mapping exists 3×**: `Camera2Bridge.cpp:1134-1148`, `camera_c.cpp:99-112`,
  and the dead `whitebalancecontroller.cpp`. One table will drift.
- **Resolution persistence is stored twice**: QML `settings.cameras` (`main.qml:191-200`)
  *and* C++ `savedResolutions_`/`cameraResolutions_` (`Camera2Bridge.h:375-377`),
  hand-synchronized at `Camera.qml:479-483` and `Camera2Bridge.cpp:232-244`. Any missed sync =
  wrong capture size. Keep one store (C++) and let QML query it.
- Zoom clamping in both `Camera.qml:245-249` and `CameraSession.cpp:1879-1887` (harmless but
  confusing).

## Dead code to delete (safe wins)

- `src/qml/QrCode.qml` — never instantiated; contains a **120 Hz self-restarting timer** and
  its own ZXing reader. `src/qml/ZoomControl.qml` — never instantiated; references an undefined
  global `camera`, would error if loaded.
- `src/windoweventfilter.*` — never installed anywhere (dead in upstream too).
- `WhiteBalanceController`, `MeteringController`, `HdrProcessor` QML instances
  (`Camera.qml:73-74`) and their `qmlRegisterType` calls (`main.cpp:43-45`) — unused (WB goes
  through `cam2` now).
- `flashlightController` context property (`appcontroller.cpp:144, 149`) — zero QML references.
- `FileManager`: `runMkvInfo`, `getDuration`, `getVideoMetadata`,
  `getMultiplexingApplication`, `getWritingApplication`, `finalizeMkv`, `getVideoRotation`,
  `removeGStreamerCacheDirectory` — all zero QML references (mkvinfo-era leftovers; recordings
  are .mp4 now).

## Regressions vs. upstream furios-camera worth restoring

- `flags: Qt.FramelessWindowHint` and `Screen.orientationUpdateMask: Qt.PortraitOrientation`
  (upstream `main.qml:28,30`) were **lost** — phosh-specific window hints.
- Packaging: `extra/furicam-radio.pkla` and `furicam.conf`→`/etc` are no longer installed
  anywhere (`CMakeLists.txt:139-140` is a comment, no `install()`); the tray icon path in
  `main.cpp:58` doesn't match where `debian/furicam.install` puts the icon; `debian/rules`
  still carries a stale Qt5-ABI `sed`.
- The `blacklist` setting in `furicam.conf` is read (`main.qml:235`) but never honored anymore
  (upstream filtered cameras with it).
- `SettingsManager` caches `gpsOn` once at startup (`settingsmanager.cpp:20-29`) and holds a
  raw engine pointer forever — later GPS toggles are invisible to `restartGpsIfNeeded`
  (`appcontroller.cpp:135-140`).

## Smaller correctness bugs (will bite later)

- `CameraSession::close()` (`CameraSession.cpp:422-462`) sets `recording_ = false` and tears
  the encoder down **without finalizing** — backgrounding the app mid-recording leaves an
  unplayable MP4.
- `appcontroller.cpp:157-168` — missing `return` after the `g_settings_new` NULL check
  (harmless GLib warning today, a crash the day GLib semantics change).
- `exif.cpp:350-351, 698, 705` and the GPS block `:769-848` — out-of-bounds reads/UB on
  malformed EXIF; the gallery opens arbitrary files, so patch these upstream easyexif bugs.
- `VideoEncoder.cpp:158-171` — encoder output ignores `info.offset` (works today, spec
  violation); `AMediaMuxer_stop` runs even with zero samples written, leaving a junk 0-byte
  MP4.
- `DngWriter.cpp:237-253` — single ~100 MB allocation for RAW with no `bad_alloc` guard, and
  `rowStrideBytes` is trusted without checking.
- Ownership trap: `cameraLoader.item.*` duck-typed calls from `main.qml` into `Camera.qml`
  (the `handle*` functions) — rename one function and the button silently does nothing. Keep
  the contract comment at the top of `Camera.qml` updated and warn on missing methods.

---

# Addendum — verified items adopted from the second (DeepSeek-consolidated) review

A second AI review (`CONSOLIDATED_REVIEW.md`) was cross-checked against the code. Most of it
duplicates this report or overstates severities (see the assessment notes at the bottom of
this section). Four findings verified as real and not already covered above:

**A1 — `disconnectFromBus()` tears down the whole process's system D-Bus connection — High.**
`qrcodehandler.cpp` calls `QDBusConnection::systemBus().disconnectFromBus(...)` **25 times**
(verified; e.g. lines 86, 92, 101, 135, 164, 232), on both error and normal paths of the
Wi-Fi QR flow. The system-bus connection is shared process-wide: closing it silently severs
GeoClue (GPS), iio-sensor-proxy (orientation tagging), NetworkManager, and the flashlight
calls for the rest of the app's lifetime — nothing reconnects. **Why it matters:** after one
Wi-Fi QR scan (or a failed one), unrelated features quietly stop working until restart, with
no error shown. **Fix:** delete every `disconnectFromBus` call; never close the shared
connection from a helper.

**A2 — Camera death is logged but never surfaced — Medium.**
`CameraSession::onDeviceDisconnected`/`onDeviceError` (`CameraSession.cpp:1931-1941`) only
write a log line. Per the NDK contract, the device is dead after these callbacks — but the
app keeps acting as if it were alive: frozen/black preview, no error banner, no retry. **Why
it matters:** if the HAL wedges (a real possibility given the shell's instability), the app
looks "running" but is brain-dead until manual restart, and every later failure is
undiagnosable. **Fix:** set a `deviceDead_` atomic in both callbacks, gate session operations
on it, and emit `cameraError()` so QML can offer a reconnect.

**A3 — No capture-failure handler: a failed shot silently corrupts the next one — Medium.**
`resultCb_` registers only `onCaptureCompleted` (`CameraSession.cpp:588-590`); the NDK's
`onCaptureFailed`/`onCaptureBufferLost` (`Camera2NDK.h:449,452`) are never set. If a capture
fails, no JPEG arrives, so its path stays queued in `pendingPhotoPaths_` — and the **next**
photo's callback pops that stale entry: the new picture is written to the old filename and
`photoSaved` fires for the wrong file. **Why it matters:** wrong-file data loss exactly when
the camera is already misbehaving. **Fix:** register both failure callbacks; on failure, pop
the matching path and fire `photoCallback_(path, false)`.

**A4 — HDR worker thread: narrow use-after-free (mechanism corrected) — Low.**
The second review claims the detached thread's `QMetaObject::invokeMethod(this, …)` is the
hazard — it is not; Qt safely discards queued delivery to a destroyed receiver. The real
exposure is smaller: the detached worker itself reads `hdrSaveEv0_.load()`
(`Camera2Bridge.cpp:955`) and references `this` while the bridge may already be destroyed
(window hidden mid-fusion). **Fix:** capture the flag by value into the lambda, or track the
thread and join it in `~Camera2Bridge`.

**Assessment of the rest of that document (for the record):** its
`disconnectFromBus`-count (25) is accurate and was its best catch. But: its "deterministic
startup segfault" from NULL GSettings is wrong (GLib logs a critical and returns FALSE; the
schema exists on the target; the app demonstrably starts); its "HDR runs on the UI thread"
(MP-5) contradicts its own HP-2 and is false (fusion runs on a detached thread); its
"Settings are read before QML loads" race is false for the settings object (`main.qml` loads
synchronously; only `Camera.qml` loads async); its `QSystemTrayIcon` "most likely cause of
shell crashes" is unsupported speculation (the tray uses D-Bus, not Wayland, and is a no-op
on phosh — remove it for uselessness, not crash-proofing); its 60-second `finalizeMkv` freeze
targets dead code (zero QML callers); and its "orphan `None` file in repo root" does not
exist in this tree. Its roadmap order is otherwise reasonable.

---

# Top 3 things to fix first

1. **Hand the shell crash to its real owner, and de-fragile the app's startup anyway.** The
   journal proves the shell segfaults chronically (12th restart in 17 h, another process
   segfaulting in the same window) — install `systemd-coredump`, grab a backtrace next time,
   and file it with the FuriOS/phoc maintainers along with the 09:13:30 log excerpt. In
   parallel, move camera open/close off the UI thread and stop destroying the whole camera
   stack on every focus change (C1–C3) — that makes the app survive, and stress the shell
   less, no matter what the shell does.
2. **Fix the cross-thread races in `CameraSession`** (the `std::function` callbacks and the
   listener-vs-reader-delete teardown race, C3). These are genuine "sometimes crashes" bugs
   that fire exactly during launch/switch/backgrounding — the most likely explanation for any
   crash where FuriCam itself died around a shell restart.
3. **Move post-capture work off the UI thread and wrap HDR in try/catch** (P1, P3). This
   removes the multi-second freeze after every photo (color correction, pixel filter, EXIF),
   stops HDR from killing the app under memory pressure with its ~400 MB spike, and plugs the
   unbounded `/tmp/hdr_debug.log` RAM leak.
