// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2023 Droidian Project
// Copyright (C) 2024 Furi Labs
//
// Authors:
// Bardia Moshiri <fakeshell@bardia.tech>
// Erik Inkinen <erik.inkinen@gmail.com>
// Alexander Rutz <alex@familyrutz.com>
// Joaquin Philco <joaquinphilco@gmail.com>

import QtQuick 2.15
import QtMultimedia
import QtQuick.Layouts 1.15
import QtQuick.Controls 2.15
import Qt.labs.folderlistmodel 2.15
import Qt.labs.platform 1.1

Rectangle {
    id: viewRect
    property int index: -1
    property var lastImg: index == -1 ? "" : imgModel.get(viewRect.index, "fileUrl")
    property string currentFileUrl: viewRect.index === -1 || imgModel.get(viewRect.index, "fileUrl") === undefined ? "" : imgModel.get(viewRect.index, "fileUrl").toString()
    property var folder: cslate.state == "VideoCapture" ?
                         StandardPaths.writableLocation(StandardPaths.MoviesLocation) + "/furicam" :
                         StandardPaths.writableLocation(StandardPaths.PicturesLocation) + "/furicam"
    // Internal toggle used by refresh() to force FolderListModel rescan.
    property bool _refreshClearing: false
    // Index to restore after a refresh (e.g. delete keeps your scroll position).
    // -1 means "no preference" → land on the newest item (a fresh capture).
    property int pendingIndex: -1
    property var deletePopUp: "closed"
    property bool hideMediaInfo: false
    property bool showShapes: true
    property real scalingRatio: scalingRatio
    property var scaleRatio: 1.0
    property var vCenterOffsetValue: 0
    // True while a photo is pinch-zoomed in; disables the pager's horizontal
    // flick so dragging pans the zoomed photo instead of paging.
    property bool zoomed: false
    property var textSize: viewRect.height * 0.018
    property var mediaState: MediaPlayer.StoppedState
    // True once the user taps play on the current video; gates the MediaPlayer
    // Loader so swiping between videos only ever shows thumbnails (no player
    // create/destroy churn mid-swipe).  Reset whenever the current item changes.
    property bool videoPlaying: false
    // Display rotation (deg) for the current video; the muxer stores it as a hint
    // the QML VideoOutput doesn't auto-apply on this backend.
    property int videoRotation: 0
    property var videoAudio: false
    // Date shown in the header.  For videos this comes from a blocking ffprobe,
    // so it's computed on a short debounce (dateProbeTimer) once the pager
    // settles — running it inline on every currentFileUrl change would fire the
    // subprocess at the swipe's mid-point flip and stutter the finger-follow.
    property string mediaDateText: ""
    signal playbackRequest()
    signal closed
    color: "black"
    visible: false

    // Leave the gallery back to the viewfinder (same as the lower-left button).
    function closeReview() {
        viewRect.videoPlaying = false
        viewRect.visible = false
        viewRect.index = imgModel.count - 1
        viewRect.closed()
    }

    onCurrentFileUrlChanged: {
        // Stop any playback when moving to another item.  (Video rotation is
        // fetched lazily at play time — running ffprobe here would block the
        // swipe exactly as the current item flips at the pager's centre.)
        viewRect.videoPlaying = false
        viewRect.mediaState = MediaPlayer.StoppedState
        viewRect.updateMediaDate()
    }
    onVisibleChanged: if (viewRect.visible) viewRect.updateMediaDate()

    // Fills the header date for the current item.  Photo dates are a fast
    // (cached) EXIF read — set them straight away.  Video dates need ffprobe, so
    // kick off the async probe and fill the header in when it returns (never
    // blocks the swipe).  Also called on show because the gallery's index is set
    // before `visible` flips true, so the first item would otherwise stay "None".
    function updateMediaDate() {
        if (viewRect.index === -1 || !viewRect.visible) {
            viewRect.mediaDateText = "None"
        } else if (isVideoFile(currentFileUrl)) {
            viewRect.mediaDateText = ""
            fileManager.requestVideoDate(currentFileUrl)
        } else {
            viewRect.mediaDateText = fileManager.getPictureDate(currentFileUrl)
        }
    }

    Connections {
        target: fileManager
        function onVideoDateReady(fileUrl, date) {
            if (fileUrl === viewRect.currentFileUrl)
                viewRect.mediaDateText = date
        }
    }

    // Forces FolderListModel to rescan the folder by briefly setting the folder
    // to "" (one event-loop turn) then restoring it, bypassing Qt's change-batching.
    Timer {
        id: _refreshRestoreTimer
        interval: 50
        repeat: false
        onTriggered: { viewRect._refreshClearing = false }
    }

    function refresh() {
        viewRect._refreshClearing = true
        _refreshRestoreTimer.start()
    }

    // Video files may be .mp4 (current encoder) or .mkv (older recordings);
    // treat both as video throughout the gallery.
    function isVideoFile(u) {
        if (!u) return false
        u = u.toString()
        return u.endsWith(".mp4") || u.endsWith(".mkv")
    }

    Connections {
        target: thumbnailGenerator

        function onThumbnailGenerated(image) {
            viewRect.lastImg = thumbnailGenerator.toQmlImage(image);
        }
    }

    FolderListModel {
        id: imgModel
        // _refreshClearing momentarily empties the folder, forcing a full rescan
        // when it returns to false (needed because inotify is unavailable on device).
        folder: viewRect._refreshClearing ? "" : viewRect.folder
        showDirs: false
        nameFilters: cslate.state == "VideoCapture" ? ["*.mp4", "*.mkv"] : ["*.jpg"]
        // Sort by modification time, newest LAST, so onStatusChanged's
        // `count - 1` is the most recent capture.  (Name sort is wrong here:
        // it's case-sensitive, so legacy lowercase "image*" files sort after
        // the engine's "IMG_*" files and the newest-looking entry got stuck on
        // an old legacy photo.)
        sortField: FolderListModel.Time
        sortReversed: true

        onStatusChanged: {
            if (imgModel.status !== FolderListModel.Ready)
                return
            // Ignore the transient empty state during refresh()'s folder="" clear;
            // wait for the real rescan so pendingIndex isn't consumed early.
            if (viewRect._refreshClearing)
                return

            if (imgModel.count === 0) {
                viewRect.index = -1
            } else if (viewRect.pendingIndex >= 0) {
                // Delete/reload: stay at (clamped) position, don't jump to newest.
                viewRect.index = Math.min(viewRect.pendingIndex, imgModel.count - 1)
            } else {
                viewRect.index = imgModel.count - 1
            }
            viewRect.pendingIndex = -1

            if (cslate.state == "VideoCapture" && viewRect.isVideoFile(viewRect.currentFileUrl)) {
                thumbnailGenerator.setVideoSource(viewRect.currentFileUrl)
            } else {
                viewRect.lastImg = viewRect.currentFileUrl
            }
        }
    }

    // Empty-folder placeholder (SwipeView below is empty when there's no media).
    Loader {
        anchors.fill: parent
        active: viewRect.visible && imgModel.count === 0 && !viewRect._refreshClearing
        visible: active
        sourceComponent: emptyDirectoryComponent
    }

    // Horizontal paging view.  SwipeView gives native finger-following swipe
    // with snap; each page decodes only when it's the current one or an
    // immediate neighbour, so the next/previous photo is ready before you reach
    // it and paging never hard-cuts or waits on a fresh 12MP decode.
    SwipeView {
        id: mediaPager
        anchors.fill: parent
        visible: parent.visible && imgModel.count > 0
        clip: true
        // Native finger-following horizontal paging stays on, but a drag that
        // reads as vertical flips `verticalLock` (set from the page MouseArea),
        // which disables interactive mid-gesture so a diagonal up-swipe opens the
        // metadata drawer instead of accidentally paging.
        property bool verticalLock: false
        interactive: !viewRect.zoomed && deletePopUp === "closed" && !verticalLock

        // Two-way sync with viewRect.index without a binding loop: a guard flag
        // distinguishes user swipes (update viewRect) from external index
        // changes — nav arrows, delete, folder reload (update the pager).
        property bool syncing: false

        onCurrentIndexChanged: {
            if (syncing) return
            if (currentIndex !== viewRect.index)
                viewRect.index = currentIndex
        }

        Connections {
            target: viewRect
            function onIndexChanged() {
                if (viewRect.index >= 0 && viewRect.index !== mediaPager.currentIndex) {
                    mediaPager.syncing = true
                    mediaPager.setCurrentIndex(viewRect.index)
                    mediaPager.syncing = false
                }
            }
        }

        Repeater {
            model: imgModel
            delegate: mediaPageComponent
        }
    }

    // One page of the pager: a photo (with pinch-zoom / pan) or a video.
    Component {
        id: mediaPageComponent
        Item {
            id: page
            width: mediaPager.width
            height: mediaPager.height

            property string pageUrl: model.fileUrl ? model.fileUrl.toString() : ""
            property bool isVideo: viewRect.isVideoFile(pageUrl)
            property bool isCurrent: SwipeView.isCurrentItem
            // Only decode the current photo and its immediate neighbours (full-
            // res, so eager-loading all would be memory-heavy).
            property bool nearCurrent: Math.abs(index - mediaPager.currentIndex) <= 1

            // Per-video cached thumbnail (ffmpeg first frame); shown on every
            // video page so swiping is instant and we never spin up a
            // QMediaPlayer just to display a still.
            property string thumbUrl: ""
            function requestThumb() {
                if (!isVideo || thumbUrl !== "")
                    return
                var t = thumbnailGenerator.cachedThumbnail(pageUrl)
                if (t !== "")
                    thumbUrl = t
            }
            Component.onCompleted: if (isVideo && nearCurrent) requestThumb()
            onNearCurrentChanged: if (isVideo && nearCurrent) requestThumb()
            Connections {
                target: thumbnailGenerator
                function onThumbnailReady(videoUrl, thumbUrl) {
                    if (videoUrl === page.pageUrl)
                        page.thumbUrl = thumbUrl
                }
            }

            // ── Photo ───────────────────────────────────────────────────────
            // The metadata "peek" (shrink + lift so the photo clears the open
            // drawer) is applied to the container; pinch-zoom lives on the image
            // inside, so the two never fight over the same `scale` binding.
            Item {
                id: imageContainer
                anchors.fill: parent
                visible: !page.isVideo
                transformOrigin: Item.Center
                scale: page.isCurrent ? viewRect.scaleRatio : 1.0
                y: page.isCurrent ? viewRect.vCenterOffsetValue : 0

                Behavior on scale {
                    NumberAnimation { duration: 300; easing.type: Easing.InOutQuad }
                }
                Behavior on y {
                    enabled: !galleryDragArea.panning
                    NumberAnimation { duration: 300; easing.type: Easing.InOutQuad }
                }

                Image {
                    id: image
                    width: page.width
                    autoTransform: true
                    asynchronous: true
                    cache: true
                    transformOrigin: Item.Center
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    source: (!page.isVideo && page.nearCurrent) ? page.pageUrl : ""

                    // Pinch-zoom scale (1..4); pan offsets applied when zoomed.
                    property real panX: 0
                    property real panY: 0
                    x: image.panX
                    y: parent.height / 2 - height / 2 + image.panY

                    function clampPanX(v) {
                        var m = Math.max(0, (paintedWidth * scale - page.width) / 2)
                        return Math.max(-m, Math.min(m, v))
                    }
                    function clampPanY(v) {
                        var m = Math.max(0, (paintedHeight * scale - page.height) / 2)
                        return Math.max(-m, Math.min(m, v))
                    }

                    // Reset zoom/pan whenever this page stops being current.
                    Connections {
                        target: page
                        function onIsCurrentChanged() {
                            if (!page.isCurrent) {
                                image.scale = 1.0
                                image.panX = 0
                                image.panY = 0
                                viewRect.zoomed = false
                            }
                        }
                    }
                }

                PinchArea {
                    id: pinchArea
                    anchors.fill: parent
                    pinch.target: image
                    pinch.maximumScale: 4
                    pinch.minimumScale: 1
                    enabled: page.isCurrent && viewRect.visible

                    onPinchUpdated: {
                        if (pinchArea.pinch.center !== undefined)
                            image.scale = pinchArea.pinch.scale
                    }
                    onPinchFinished: {
                        image.panX = image.clampPanX(image.panX)
                        image.panY = image.clampPanY(image.panY)
                        viewRect.zoomed = image.scale > 1.01
                    }

                    MouseArea {
                        id: galleryDragArea
                        anchors.fill: parent
                        // Camera-preview pattern: the gesture MouseArea lives
                        // inside the PinchArea (which forwards single touches to
                        // it), so taps / vertical swipes are as reliable as the
                        // viewfinder's.  Horizontal drags are left to SwipeView so
                        // paging finger-follows; as soon as a drag reads vertical
                        // we lock the pager (verticalLock) so it can't page.
                        enabled: deletePopUp === "closed" && page.isCurrent
                        property real startX: 0
                        property real startY: 0
                        property real panStartX: 0
                        property real panStartY: 0
                        property bool panning: false
                        property string axis: ""      // "", "v" or "h"
                        property int decideThreshold: 8
                        property int swipeThreshold: 30

                        onPressed: function(mouse) {
                            startX = mouse.x
                            startY = mouse.y
                            panStartX = image.panX
                            panStartY = image.panY
                            panning = false
                            axis = ""
                            mediaPager.verticalLock = false
                        }

                        onPositionChanged: function(mouse) {
                            // Zoomed: drag pans the photo.
                            if (!pinchArea.pinch.active && image.scale > 1.01) {
                                panning = true
                                image.panX = image.clampPanX(panStartX + (mouse.x - startX))
                                image.panY = image.clampPanY(panStartY + (mouse.y - startY))
                                return
                            }
                            // Decide the axis early (before SwipeView's grab
                            // distance) so a vertical drag locks out paging while a
                            // horizontal drag is handed off to SwipeView.
                            if (axis === "") {
                                var dx = Math.abs(mouse.x - startX)
                                var dy = Math.abs(mouse.y - startY)
                                if (dx > decideThreshold || dy > decideThreshold) {
                                    if (dy > dx) {
                                        axis = "v"
                                        mediaPager.verticalLock = true
                                    } else {
                                        axis = "h"   // SwipeView takes over the drag
                                    }
                                }
                            }
                        }

                        onReleased: function(mouse) {
                            mediaPager.verticalLock = false
                            if (panning) {
                                panning = false
                                return
                            }
                            // Horizontal was handled by SwipeView; only react to
                            // vertical (drawer) and taps here.
                            if (axis === "h")
                                return
                            var deltaX = mouse.x - startX
                            var deltaY = mouse.y - startY
                            swipeGesture(deltaX, deltaY, swipeThreshold)
                        }
                    }
                }
            }

            // ── Video ───────────────────────────────────────────────────────
            Item {
                anchors.fill: parent
                visible: page.isVideo

                // Instant still while swiping / before playback.
                Image {
                    id: videoThumb
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: true
                    source: page.thumbUrl
                }

                // Gesture area for video pages — mirrors the photo one (axis
                // detection + verticalLock) so swipe-up/down and tap behave the
                // same over a video's thumbnail.  Disabled once playing so the
                // player's own controls take over.
                MouseArea {
                    anchors.fill: parent
                    enabled: deletePopUp === "closed" && page.isCurrent && !viewRect.videoPlaying
                    property real startX: 0
                    property real startY: 0
                    property string axis: ""
                    property int decideThreshold: 8
                    property int swipeThreshold: 30

                    onPressed: function(mouse) {
                        startX = mouse.x
                        startY = mouse.y
                        axis = ""
                        mediaPager.verticalLock = false
                    }
                    onPositionChanged: function(mouse) {
                        if (axis === "") {
                            var dx = Math.abs(mouse.x - startX)
                            var dy = Math.abs(mouse.y - startY)
                            if (dx > decideThreshold || dy > decideThreshold) {
                                if (dy > dx) { axis = "v"; mediaPager.verticalLock = true }
                                else axis = "h"
                            }
                        }
                    }
                    onReleased: function(mouse) {
                        mediaPager.verticalLock = false
                        if (axis === "h") return
                        swipeGesture(mouse.x - startX, mouse.y - startY, swipeThreshold)
                    }
                }

                // Player only exists while actually playing → no MediaPlayer
                // create/destroy churn (and no mid-swipe stutter) when paging.
                Loader {
                    anchors.fill: parent
                    active: page.isVideo && page.isCurrent && viewRect.videoPlaying
                    sourceComponent: videoOutputComponent
                }

                // Play overlay, shown over the thumbnail until playback starts.
                Rectangle {
                    anchors.centerIn: parent
                    width: 90 * viewRect.scalingRatio
                    height: 90 * viewRect.scalingRatio
                    radius: width / 2
                    color: "#2b292a"
                    visible: page.isCurrent && !viewRect.videoPlaying && !viewRect.hideMediaInfo

                    Image {
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: 2 * viewRect.scalingRatio
                        source: "icons/playVideo.svg"
                        sourceSize.width: 50 * viewRect.scalingRatio
                        sourceSize.height: 50 * viewRect.scalingRatio
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            viewRect.videoRotation = fileManager.getVideoRotation(page.pageUrl)
                            viewRect.videoPlaying = true
                            viewRect.mediaState = MediaPlayer.PlayingState
                        }
                    }
                }
            }
        }
    }

    function swipeGesture(deltaX, deltaY, swipeThreshold) {
        // Horizontal paging is handled natively by the SwipeView; here we only
        // react to vertical swipes and taps.
        if (Math.abs(deltaY) > Math.abs(deltaX) && Math.abs(deltaY) > swipeThreshold) {
            if (deltaY < 0) {                       // swipe up → metadata drawer
                metadataDrawer.open()
                viewRect.hideMediaInfo = false
            } else {                                // swipe down → close drawer, or
                if (metadataDrawer.opened)          // if already closed, exit to camera
                    metadataDrawer.close()
                else
                    viewRect.closeReview()
            }
        } else if (Math.abs(deltaX) < swipeThreshold && Math.abs(deltaY) < swipeThreshold) {
            viewRect.hideMediaInfo = !viewRect.hideMediaInfo
        }
    }

    Component {
        id: emptyDirectoryComponent

        Item {
            id: emptyDirectoryItem
            anchors.fill: parent

            Column {
                anchors.centerIn: parent

                Button {
                    implicitWidth: 200 * viewRect.scalingRatio
                    implicitHeight: 200 * viewRect.scalingRatio

                    icon.source: "icons/emblemPhotosSymbolic.svg"
                    icon.width: Math.round(200 * viewRect.scalingRatio)
                    icon.height: Math.round(200 * viewRect.scalingRatio)
                    icon.color: "#8a8a8f"

                    anchors.horizontalCenter: parent.horizontalCenter

                    background: Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                    }
                }

                Text {
                    text: "No media found"
                    color: "#8a8a8f"
                    font.bold: true
                    font.pixelSize: textSize * 2
                    style: Text.Raised
                    elide: Text.ElideRight
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }
    // Native bottom-edge Drawer, styled to match the settings panel in main.qml
    // (rounded dark background + drag handle, finger-following via `interactive`).
    Drawer {
        id: metadataDrawer
        edge: Qt.BottomEdge
        width: viewRect.width
        height: viewRect.height / 2.6
        dim: false
        modal: false
        interactive: viewRect.visible
        dragMargin: 0   // open via the swipe gesture, not an edge-grab that would
                        // steal touches from the bottom controls; still drag-to-dismiss

        background: Rectangle {
            color: "#2b292a"
            radius: 16 * viewRect.scalingRatio
            // Square off the bottom corners so the rounded top meets the screen edge.
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: parent.radius
                color: parent.color
            }
        }

        onOpened: {
            viewRect.scaleRatio = 0.7
            viewRect.vCenterOffsetValue = -(viewRect.height * 0.19)
        }
        onClosed: {
            viewRect.scaleRatio = 1.0
            viewRect.vCenterOffsetValue = 0
        }

        Column {
            anchors.fill: parent
            spacing: 0

            // Drag-handle pill, matching the settings drawer.
            Item {
                width: parent.width
                height: 18 * viewRect.scalingRatio
                Rectangle {
                    width: 40 * viewRect.scalingRatio
                    height: 4 * viewRect.scalingRatio
                    radius: 2 * viewRect.scalingRatio
                    color: "#666"
                    anchors.centerIn: parent
                }
            }

            MetadataView {
                id: metadataContent
                width: parent.width
                height: parent.height - 18 * viewRect.scalingRatio
                active: metadataDrawer.opened
                currentFileUrl: viewRect.currentFileUrl
                textSize: viewRect.textSize
                scalingRatio: viewRect.scalingRatio
            }
        }
    }

    Component {
        id: videoOutputComponent

        Item {
            id: videoItem
            anchors.fill: parent

            Connections {
                target: viewRect
                function onPlaybackRequest() {
                    playbackStateChangeHandler()
                }
            }

            MediaPlayer {
                id: mediaPlayer
                // The Loader only exists once the user hit play, so start
                // immediately on creation.
                autoPlay: true
                videoOutput: videoOutput
                audioOutput: AudioOutput {
                    muted: viewRect.videoAudio
                }
                source: viewRect.visible ? viewRect.currentFileUrl : ""

                onPlaybackStateChanged: {
                    if (mediaPlayer.playbackState === MediaPlayer.StoppedState) {
                        viewRect.mediaState = MediaPlayer.StoppedState
                        playVideoButtonFrame.visible = true
                    } else if (mediaPlayer.playbackState === MediaPlayer.PausedState) {
                        viewRect.mediaState = MediaPlayer.PausedState
                        playVideoButtonFrame.visible = true
                    } else {
                        viewRect.mediaState = MediaPlayer.PlayingState
                        playVideoButtonFrame.visible = false
                    }
                }
            }

            VideoOutput {
                id: videoOutput
                anchors.fill: parent
                orientation: viewRect.videoRotation
                visible: viewRect.currentFileUrl && viewRect.isVideoFile(viewRect.currentFileUrl)
            }

            function playbackStateChangeHandler() {
                if (mediaPlayer.playbackState === MediaPlayer.PlayingState) {
                    mediaPlayer.pause();
                } else {
                    if (viewRect.visible == true) {
                        mediaPlayer.play();
                    }
                }
            }

            MouseArea {
                id: galleryDragArea
                anchors.fill: parent
                enabled: deletePopUp === "closed"
                property real startX: 0
                property real startY: 0
                property string axis: ""
                property int decideThreshold: 8
                property int swipeThreshold: 30

                onPressed: function(mouse) {
                    startX = mouse.x
                    startY = mouse.y
                    axis = ""
                    mediaPager.verticalLock = false
                }
                onPositionChanged: function(mouse) {
                    if (axis === "") {
                        var dx = Math.abs(mouse.x - startX)
                        var dy = Math.abs(mouse.y - startY)
                        if (dx > decideThreshold || dy > decideThreshold) {
                            if (dy > dx) { axis = "v"; mediaPager.verticalLock = true }
                            else axis = "h"
                        }
                    }
                }
                onReleased: function(mouse) {
                    mediaPager.verticalLock = false
                    if (axis === "h") return
                    swipeGesture(mouse.x - startX, mouse.y - startY, swipeThreshold)
                }
            }

            // Tap-to-resume overlay when the video is paused mid-playback.
            Rectangle {
                id: playVideoButtonFrame
                anchors.centerIn: parent
                width: 90 * viewRect.scalingRatio
                height: 90 * viewRect.scalingRatio
                radius: width / 2
                color: "#2b292a"
                visible: false

                Image {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: 2 * viewRect.scalingRatio
                    source: "icons/playVideo.svg"
                    sourceSize.width: 50 * viewRect.scalingRatio
                    sourceSize.height: 50 * viewRect.scalingRatio
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        viewRect.mediaState = MediaPlayer.PlayingState
                        parent.visible = false
                        playbackRequest()
                    }
                }
            }
        }
    }

    Button {
        id: btnPrev
        implicitWidth: 60 * viewRect.scalingRatio
        implicitHeight: 60 * viewRect.scalingRatio
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        icon.source: "icons/goPreviousSymbolic.svg"
        icon.width: Math.round(btnPrev.width * 0.5)
        icon.height: Math.round(btnPrev.height * 0.5)
        icon.color: "white"
        Layout.alignment : Qt.AlignHCenter

        visible: viewRect.index > 0 && !viewRect.hideMediaInfo
        enabled: deletePopUp === "closed"

        background: Rectangle {
            anchors.fill: parent
            color: "transparent"
        }

        onClicked: {
            if ((viewRect.index - 1) >= 0 ) {
                viewRect.videoAudio = true
                viewRect.index = viewRect.index - 1
            }
        }
    }

    Button {
        id: btnNext
        implicitWidth: 60 * viewRect.scalingRatio
        implicitHeight: 60 * viewRect.scalingRatio
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        icon.source: "icons/goNextSymbolic.svg"
        icon.width: Math.round(btnNext.width * 0.5)
        icon.height: Math.round(btnNext.height * 0.5)
        icon.color: "white"
        Layout.alignment : Qt.AlignHCenter

        visible: viewRect.index < (imgModel.count - 1) && !viewRect.hideMediaInfo
        enabled: deletePopUp === "closed"

        background: Rectangle {
            anchors.fill: parent
            color: "transparent"
        }

        onClicked: {
            if ((viewRect.index + 1) <= (imgModel.count - 1)) {
                viewRect.videoAudio = true
                viewRect.index = viewRect.index + 1
            }
        }
    }

    Item {
        id: mediaMenu

        anchors.bottom: parent.bottom
        width: parent.width
        height: 70 * viewRect.scalingRatio

        Rectangle {
            anchors.fill: parent
            color: "#2b292a"
        }

        Loader {
            id: mediaMenuLoader
            anchors.fill: parent
            sourceComponent: viewRect.mediaState === MediaPlayer.PlayingState ? videoPlayingMenuComponent : videoStoppedMenuComponent
        }

        Component {
            id: videoStoppedMenuComponent

            Item {
                id: videoStoppedMenuItem

                Button {
                    id: btnClose
                    icon.source: "icons/cameraVideoSymbolic.svg"
                    icon.width: parent.width * 0.13
                    icon.height: parent.height * 0.8
                    icon.color: "white"
                    enabled: deletePopUp === "closed" && viewRect.visible
                    anchors.left: parent.left
                    anchors.leftMargin: 20 * viewRect.scalingRatio
                    anchors.verticalCenter: parent.verticalCenter

                    visible: !viewRect.hideMediaInfo

                    background: Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                    }

                    onClicked: {
                        viewRect.closeReview()
                    }
                }

                Button {
                    id: btnDelete
                    anchors.right: parent.right
                    anchors.rightMargin: 20 * viewRect.scalingRatio
                    anchors.verticalCenter: parent.verticalCenter
                    icon.source: "icons/editDeleteSymbolic.svg"
                    icon.width: parent.width * 0.1
                    icon.height: parent.width * 0.1
                    icon.color: "white"
                    visible: viewRect.index >= 0 && !viewRect.hideMediaInfo
                    Layout.alignment: Qt.AlignHCenter

                    background: Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                    }

                    onClicked: {
                        deletePopUp = "opened"
                        confirmationPopup.open()
                    }
                }

                Popup {
                    id: confirmationPopup
                    width: 200 * viewRect.scalingRatio
                    height: 80 * viewRect.scalingRatio

                    background: Rectangle {
                        border.color: "#444"
                        color: "#2b292a"
                        radius: 10 * viewRect.scalingRatio
                    }

                    closePolicy: Popup.NoAutoClose
                    x: (parent.width - width) / 2
                    y: (parent.height - height)

                    Column {
                        anchors.centerIn: parent
                        spacing: 10

                        Text {
                            text: viewRect.isVideoFile(viewRect.currentFileUrl) ? "  Delete Video?": "  Delete Photo?"
                            horizontalAlignment: parent.AlignHCenter

                            anchors.margins: 5 * viewRect.scalingRatio
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            color: "white"
                            font.bold: true
                            style: Text.Raised
                            styleColor: "black"
                            font.pixelSize: textSize
                        }

                        Row {
                            spacing: 20 * viewRect.scalingRatio

                            Button {
                                text: "Yes"
                                palette.buttonText: "white"
                                font.pixelSize: viewRect.textSize
                                width: 60 * viewRect.scalingRatio
                                height: confirmationPopup.height * 0.6
                                onClicked: {
                                    var tempCurrUrl = viewRect.currentFileUrl
                                    // Keep the scroll position: after the rescan land on
                                    // whatever now occupies this slot (clamped), instead
                                    // of snapping back to the newest item.
                                    viewRect.pendingIndex = viewRect.index
                                    fileManager.deleteImage(tempCurrUrl)
                                    viewRect.refresh()
                                    deletePopUp = "closed"
                                    confirmationPopup.close()
                                }

                                background: Rectangle {
                                    anchors.fill: parent
                                    color: "#3d3d3d"
                                    radius: 10 * viewRect.scalingRatio
                                }
                            }

                            Button {
                                text: "No"
                                palette.buttonText: "white"
                                font.pixelSize: viewRect.textSize
                                width: 60 * viewRect.scalingRatio
                                height: confirmationPopup.height * 0.6
                                onClicked: {
                                    deletePopUp = "closed"
                                    confirmationPopup.close()
                                }

                                background: Rectangle {
                                    anchors.fill: parent
                                    color: "#3d3d3d"
                                    radius: 10 * viewRect.scalingRatio
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    id: mediaIndexView
                    anchors.centerIn: parent
                    width: parent.width * 0.2
                    height: parent.height
                    color: "transparent"
                    visible: viewRect.index >= 0 && !viewRect.hideMediaInfo
                    Text {
                        text: (viewRect.index + 1) + " / " + imgModel.count

                        anchors.fill: parent
                        anchors.margins: 5
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                        color: "white"
                        font.bold: true
                        style: Text.Raised
                        styleColor: "black"
                        font.pixelSize: textSize
                    }
                }
            }
        }

        Component {
            id: videoPlayingMenuComponent

            Item {
                id: videoPlayingMenuItem
                anchors.fill: parent

                Button {
                    icon.source: "icons/cameraVideoSymbolic.svg"
                    icon.width: parent.width * 0.13
                    icon.height: parent.height * 0.8
                    icon.color: "white"
                    enabled: deletePopUp === "closed" && viewRect.visible
                    anchors.left: parent.left
                    anchors.leftMargin: 20 * viewRect.scalingRatio
                    anchors.verticalCenter: parent.verticalCenter

                    visible: !viewRect.hideMediaInfo

                    background: Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                    }

                    onClicked: {
                        viewRect.closeReview()
                    }
                }

                Button {
                    id: stopVideo
                    icon.source: "icons/pauseVideo.svg"
                    icon.width: parent.width * 0.13
                    icon.height: parent.height * 0.7
                    icon.color: "white"
                    enabled: viewRect.visible
                    anchors.centerIn: parent

                    visible: !viewRect.hideMediaInfo

                    background: Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                    }

                    onClicked: {
                        playbackRequest();
                    }
                }

                Button {
                    id: muteSoundButton
                    icon.source: !viewRect.videoAudio ? "icons/audioOn.svg" : "icons/audioOff.svg"
                    icon.width: parent.width * 0.12
                    icon.height: parent.height * 0.7
                    icon.color: "white"
                    enabled: viewRect.visible
                    anchors.right: parent.right
                    anchors.rightMargin: 20 * viewRect.scalingRatio
                    anchors.verticalCenter: parent.verticalCenter

                    visible: !viewRect.hideMediaInfo

                    background: Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                    }

                    onClicked: {
                        viewRect.videoAudio = !viewRect.videoAudio
                    }
                }

            }
        }
    }

    Rectangle {
        id: mediaDate
        anchors.top: parent.top
        width: parent.width
        height: 60 * viewRect.scalingRatio
        color: "#2b292a"
        visible: viewRect.index >= 0 && !viewRect.hideMediaInfo

        Text {
            id: date
            text: viewRect.mediaDateText

            anchors.fill: parent
            anchors.margins: 5
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            color: "white"
            font.bold: true
            style: Text.Raised 
            styleColor: "black"
            font.pixelSize: viewRect.textSize
        }
    }
}
