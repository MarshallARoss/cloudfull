//
//  PlayerPageView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import AVFoundation
import Combine
import UIKit
import os

/// One full-screen page in the video feed.
/// It loads its own `AVPlayerItem`, plays the clip while active, and loops
/// it at the end. A tap toggles mute.
struct PlayerPageView: View {
    let assetID: String
    let pageID: String
    let isActive: Bool
    /// True only for the pages near the current page.
    /// A page outside this window must not load or hold a decoded
    /// `AVPlayerItem`. iOS allows only a limited number of concurrent decode
    /// pipelines per process.
    let isPreloadable: Bool
    let viewModel: DeckViewModel
    /// Reports scrubbing state to `FeedView`, which applies
    /// `.scrollDisabled(isScrubbing)` to the pager.
    /// This disabled state, not gesture priority, stops a drag along the
    /// scrubber strip from changing the page mid-scrub.
    let onScrubbingChanged: (Bool) -> Void
    /// False while a sheet is up (trash, share, album picker, shrink
    /// confirm). A page can be `isActive` with a sheet open, so this is
    /// its own parameter rather than derived from that.
    let fullscreenAllowed: Bool
    /// Reports fullscreen state to `FeedView`, which applies
    /// `.scrollDisabled(isScrubbing || isFullscreen)` and hides the global
    /// chrome. Its shape matches `onScrubbingChanged`.
    let onFullscreenChanged: (Bool) -> Void
    /// Reports `allowsLandscapeCandidate` to `FeedView`, which ORs it
    /// with the hinge term and writes the result into
    /// `RotationPolicy.shared` — the one switch the scene delegate reads
    /// to decide whether the window may rotate at all. Its shape matches
    /// `onFullscreenChanged`; see that property's own comment.
    let onAllowsLandscapeChanged: (Bool) -> Void
    /// The device's real top safe-area inset, measured by `FeedView` above
    /// the pager's `.ignoresSafeArea()`.
    /// This page's own `GeometryReader` sits under that modifier, so it
    /// reports `safeAreaInsets.top == 0`. Use this parameter instead, so the
    /// video moves down by the same amount as the top chrome.
    /// `FeedView.topChrome` uses the same measurement.
    let safeAreaTop: CGFloat
    /// The device's real safe-area insets on every edge, measured by
    /// `FeedView` at the same root `GeometryReader` as `safeAreaTop`,
    /// for the same reason (this page's own reader reports them as
    /// zero, under the pager's `.ignoresSafeArea()`). Used only by the
    /// 1H fullscreen ring's own bottom-leading placement (step 9,
    /// `design/duo/duo_audit_apple_checklist.md` §5) — `.bottom`/
    /// `.leading` read as the home indicator's and the camera cutout's
    /// real clearance once the window is genuinely landscape (R4), not
    /// a flat, device-measured constant.
    let fullscreenSafeArea: EdgeInsets
    /// This frame's iPhone Duo geometry, measured by `FeedView` at the
    /// same root `GeometryReader` as `safeAreaTop`, for the same reason:
    /// this page's own reader sits under the pager's
    /// `.ignoresSafeArea()`, which would otherwise hide the bar column's
    /// safe-area inset. `DuoLayout.none` on a regular iPhone, which
    /// keeps `body`'s stage math reading exactly what it read before
    /// this parameter existed. See `DuoLayout.stageRect` and this
    /// file's `body` for how it is used.
    let duoLayout: DuoLayout
    /// Fires on a double tap anywhere on the stage.
    /// `FeedView` routes it to this page's own `FeedPageContent`, which owns
    /// the keep logic and the rail heart. The rail heart's bounce is the
    /// only visual feedback; the screen shows no large heart at its centre.
    let onDoubleTap: () -> Void
    /// True while a sheet with its own video (bin, shrink preview) is up
    /// over the feed. See `PlayerHolder.setSuspended`.
    let isSuspended: Bool

    @StateObject private var holder = PlayerHolder()
    /// See `ScrollPhaseGate`. No engine work runs while the pager moves.
    @ObservedObject private var scrollGate = ScrollPhaseGate.shared
    /// An `isActive` change that arrives mid-scroll. Applied once the pager
    /// is idle.
    @State private var pendingActive: Bool?
    /// Analytics only. The in-flight fold-playback measurement started
    /// by `recordFoldPlayback`, if one is still running. A new fold
    /// cancels the previous measurement instead of letting two
    /// overlap and both report a resume time.
    @State private var foldMeasureTask: Task<Void, Never>?
    /// Analytics only. The time of this page's own last play/pause
    /// edge, tracked by a dedicated `.onChange(of: holder.isPlaying)`
    /// so `recordFoldPlayback` can ask "was I playing AT the fold"
    /// instead of reading `holder.isPlaying` at commit time (1 s
    /// later, after `Usage`'s own debounce), by which point a
    /// fold-driven pause has often already landed.
    @State private var lastPlayAt: Date?
    @State private var lastPauseAt: Date?
    @State private var isLoading = true
    /// The asset's own Photos thumbnail, fetched with
    /// `PhotoLibraryService.thumbnail(for:side:)`. This thumbnail is local
    /// even for a video that iCloud has not downloaded yet.
    /// It shows under the player until the real first frame is ready, so a
    /// slow load never shows a black gap.
    @State private var poster: UIImage?
    /// Mirrors `PlayerLayerView.onReadyForDisplay`.
    /// True once the player layer has a decoded frame to paint. At that
    /// point `poster` fades away; nothing pulls it out from under the
    /// video.
    @State private var isReadyForDisplay = false
    /// Whether the spinner is actually drawn.
    /// Separate from `isLoading`. See `spinnerRevealKey` and the
    /// `.task(id: spinnerRevealKey)` on `CloudDownloadRing` below: a fast
    /// local load never flashes the spinner at all.
    @State private var showSpinner = false
    /// The real iCloud download fraction, for the cloud-ring loader.
    /// `nil` means nothing measurable is downloading: the copy is already
    /// on the phone, or the wait is player buffering rather than a PhotoKit
    /// fetch. The ring sweeps instead of filling when this is `nil`.
    @State private var downloadFraction: Double?
    /// The `load_seq_` probe's clock and latched events.
    /// Its mutating methods also run from the spinner-removal triggers that
    /// ship in every build (`hideSpinnerImmediately()` and the two
    /// `.onChange` triggers below). Only the DEBUG identifier that reports
    /// the values is `#if DEBUG`-gated.
    @State private var loadSeq = LoadSequence()
    @State private var loadFailed = false
    @State private var retryToken = UUID()
    @AppStorage("feed.isMuted") private var isMuted: Bool = false
    @State private var showMuteBadge = false
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Scrubber state
    //
    // Owned here, not in `ScrubberView`. `ScrubberView` only renders and
    // takes direct-entry gestures. The long-press-anywhere entry point must
    // attach to the whole stage, not only the 28pt strip. This lets both
    // entry points drive one shared state machine from this type.

    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0
    /// True while a stage hold is running the player at 2x. See
    /// `handleStageHold`. Mutually exclusive with `isScrubbing`: a hold is
    /// one of the two, decided on its first tick and never changed mid-hold.
    @State private var isFastForwarding = false
    /// Throttles seeks to one per 1/30 s, so a fast drag cannot flood
    /// `AVPlayer.seek` with more requests than it can service.
    @State private var lastSeekAt: Date = .distantPast
    /// The scrubber's grow and shrink motion is decorative, so it respects
    /// Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Landscape fullscreen state

    /// Owner-reported bug (pose 3, wide video): the stage visibly
    /// resized well after a swipe landed. Root cause: this used to be
    /// set only from `AVPlayerItem.presentationSize`, which needs a
    /// real player attached — gated behind `scrollGate.waitUntilIdle()`
    /// in `load()`, so a page that became active before its own
    /// `load()` reached that point showed the default 9:16 stage for
    /// its first frame(s), then jumped once attach finally happened.
    ///
    /// `loadAssetAspect()`'s own early `PHAsset.pixelWidth`/`pixelHeight`
    /// read now sets this first — see that method's own comment for
    /// why that read has no player, and so no scroll-gate, to wait on.
    /// `holder.presentationSize`'s own `.onChange` (below) still
    /// corrects it from the real decoded video if the two ever
    /// disagree (rotation metadata PhotoKit's own asset record does
    /// not always capture exactly). Resets to `false` at the top of
    /// every `load()`, and whenever the page leaves the preload
    /// window. A stale reading can never outlive its item.
    @State private var videoIsLandscape = false
    /// The same dual source as `videoIsLandscape` — `loadAssetAspect()`
    /// first, `holder.presentationSize` as a correction — kept as
    /// width ÷ height rather than a bare bool, so `useVideoAspect` can
    /// size the stage to the video's own shape instead of the fixed 9:16
    /// box every other case still wants. Reset alongside
    /// `videoIsLandscape`, to the same 9:16 default `DuoLayout.stageRect`
    /// itself defaults to, so a stale ratio can never outlive its item
    /// either.
    @State private var videoAspectRatio: CGFloat = 9.0 / 16.0
    /// True when the WINDOW itself is landscape. Set from `proxy.size`
    /// in `body`, the one place this page can measure its own real
    /// window shape; see that `onChange` for why a stored property is
    /// needed at all when `body` already has `proxy.size` directly:
    /// `isFullscreen` below is a plain computed property, read from
    /// `.onChange` modifiers chained outside the `GeometryReader`, where
    /// no `proxy` is in scope. `useVideoAspect` does not read this
    /// property at all; see its own comment.
    ///
    /// R4 (`design/duo/duo_audit_apple_checklist.md` Decision A, real
    /// interface rotation): this is now a POSITIVE term in `isFullscreen`
    /// below, not a negative one guarding a fake-rotation hack. A
    /// regular iPhone or a closed Duo turned sideways really rotates its
    /// window now (Info.plist lists all three orientations;
    /// `CloudfullSceneDelegate.supportedInterfaceOrientations(for:)`
    /// grants landscape through `RotationPolicy` exactly when
    /// `FeedView.allowsLandscape` says so), so this reads `true` at
    /// precisely the moment `isFullscreen` should engage, instead of
    /// needing to stay portrait for a `.rotationEffect` trick to work.
    /// An open Duo folded like a laptop (inner display) still reads
    /// `false` here — its window stays portrait even though the device
    /// itself is sideways — which is exactly why `isFullscreen` also
    /// needs `verticalSizeClass`, below.
    @State private var windowIsLandscape = false
    /// The exact size behind `windowIsLandscape`, kept only so
    /// `logRotationPose` can report real numbers — nothing in the
    /// layout itself reads this; `body` already has `proxy.size`
    /// directly wherever the layout needs it.
    @State private var windowSize: CGSize = .zero
    /// `.regular` only on the open Duo's INNER display — see this
    /// property's own use in `isFullscreen` for why that distinction
    /// matters, and `logRotationPose` for how it was confirmed.
    ///
    /// A plain `@Environment` property, unlike `toolbarVerticalEdge`
    /// (`DuoLayout.swift`'s `ToolbarVerticalEdgeReader`): size classes
    /// have existed since iOS 8, so there is no `@available` gate to
    /// work around here.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// `DuoLayout.classify`'s other size-class input (Decision B,
    /// `design/duo/duo_audit_apple_checklist.md` §4) — read here only for
    /// `logRotationPose`'s DEBUG probe, so a sim/device reading shows
    /// both axes the classifier actually consults, not just one.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Whether the fullscreen chrome (`FullscreenPlayerChrome`) is shown.
    /// Owned here, not in the chrome view. The tap gesture on the whole
    /// stage, which also drives tap-to-mute, can then toggle it. The
    /// latch resets below can also reach it.
    @State private var chromeRevealed = false
    /// The stage tap sets `chromeRevealed = true` unconditionally, not by
    /// toggling it, so a tap while the chrome is already up never hides it.
    /// But `FullscreenPlayerChrome` restarts its 3 s auto-hide timer
    /// through `.task(id: revealed)`, and a same-value assignment is not a
    /// change of that id. This nonce fixes that: it increments on every
    /// stage tap while fullscreen, and never resets elsewhere. Folded into
    /// the chrome's task id below, so every tap restarts the countdown, not
    /// only a false-to-true edge.
    @State private var chromeRevealNonce = 0
    /// The dismiss latch: true once the user has tapped `fullscreen_dismiss`
    /// during the current landscape period.
    /// Without it, every engagement condition would hold again on the next
    /// evaluation and fullscreen would re-engage immediately.
    ///
    /// R4: resets to `false` when `assetID` changes (a new video is a new
    /// decision) or when this page leaves the active slot (`isActive`
    /// goes `false` — "reset it on page change," `design/duo/duo_audit_apple_checklist.md`
    /// Decision A's own costs list). It no longer resets on "the device
    /// returns to portrait": there is no device-orientation read left in
    /// this file to notice that, since `allowsLandscapeCandidate` below
    /// feeds `FeedView`'s own rotation mask instead of a device stance.
    /// A real, owner-flagged behavior change: dismissing fullscreen on a
    /// page now holds it dismissed — the window will not offer landscape
    /// for that page again — until the user swipes away and back, even
    /// if the phone keeps turning.
    @State private var dismissedThisSpell = false

    /// Computed, not stored, so there is no state machine that can fall out
    /// of sync: every exit path works by making one term here false.
    /// `!isScrubbing` is a safety interlock: a scrub in flight has the pager
    /// `.scrollDisabled` and a `UILongPressGestureRecognizer` reading a
    /// fraction computed from an unrotated `stageWidth`. Ending the
    /// landscape period, rather than rotating a live scrub's coordinate
    /// space, is correct. A finger on the screen means the user is not
    /// rotating the phone.
    ///
    /// R4 (`design/duo/duo_audit_apple_checklist.md` Decision A point 4,
    /// real interface rotation): `windowIsLandscape` is now a POSITIVE
    /// term — the window really has rotated, which only happens once
    /// `FeedView.allowsLandscape` (fed by `allowsLandscapeCandidate`
    /// below) has already told `RotationPolicy`/the scene delegate this
    /// page permits it. There is no `.rotationEffect` canvas trick left
    /// to guard, and no device-orientation read anywhere in this
    /// condition — `deviceStance` does not appear here at all.
    ///
    /// `verticalSizeClass == .compact` replaces the old
    /// `horizontalSizeClass != .regular` term (F2's own fix,
    /// `design/duo/duo_audit_apple_checklist.md` §1): Apple's own
    /// guidance is to pick FIT vs FILL by size class, and vertical is
    /// the axis that actually separates "a real phone-shaped landscape
    /// window" (compact height — a regular iPhone, or the Duo's OUTER
    /// display turned sideways) from "the Duo's INNER display, open and
    /// wide" (regular height — pose 3/`.openWide`, same as an iPad's
    /// window). The inner display's own landscape video gets pose 3's
    /// FIT treatment instead (`useVideoAspect`, decided from
    /// `duoLayout.pose`, never from this property) — it is `.regular`
    /// height, so it never reaches here. A `nil` reading (a preview, or
    /// a transient moment before the environment resolves) reads
    /// `!= .compact`, which keeps fullscreen off rather than guessing.
    private var isFullscreen: Bool {
        isActive && videoIsLandscape && windowIsLandscape && verticalSizeClass == .compact
            && fullscreenAllowed && !dismissedThisSpell && !isScrubbing
    }

    /// Owner correction (Opus wireframe compare, pose 1H): FILL is the
    /// Duo's own 1H only — "wide video FILLS the screen, as today" is
    /// a statement about the Duo's closed-sideways pose, not about
    /// `isFullscreen` generally. A regular iPhone's screen is not the
    /// same shape as the video it plays (19.5:9 vs. 16:9, commonly),
    /// so FILL would crop there in a way the owner never asked for;
    /// the goal is that an iPhone 18 Pro looks exactly as it did
    /// before this pose-5 round. `duoLayout.pose == .closed` is what
    /// `isFullscreen` alone cannot tell apart — see that property's
    /// own comment on why it reads identically for a regular iPhone
    /// and the Duo's outer display.
    private var fillsScreenInFullscreen: Bool {
        isFullscreen && duoLayout.pose == .closed
    }

    /// Whether THIS page would permit the window to rotate into
    /// landscape right now — term 3 of Decision A's `allowsLandscape`
    /// rule (`design/duo/duo_audit_apple_checklist.md` §3): "(active
    /// page is a wide video && fullscreenAllowed && !dismissed)".
    /// Reported up to `FeedView` (`onAllowsLandscapeChanged`), which ORs
    /// it with the hinge term and writes the result into
    /// `RotationPolicy.shared` — see that type's own comment for why
    /// the write happens there and not here.
    ///
    /// Deliberately excludes `windowIsLandscape` and `verticalSizeClass`:
    /// this is the GATE that permits the window to rotate in the first
    /// place, so it cannot wait for the rotation it is deciding whether
    /// to allow. `isFullscreen` above is the narrower, already-rotated
    /// condition that actually engages the FILL chrome once this gate
    /// let the system rotate.
    ///
    /// Only the centered page can ever report `true` here, the same
    /// guarantee `isFullscreen`'s own callback (`onFullscreenChanged`)
    /// already relies on — `isActive` is the first term.
    private var allowsLandscapeCandidate: Bool {
        isActive && videoIsLandscape && fullscreenAllowed && !dismissedThisSpell
    }

    /// True when the loaded video is landscape and this frame's pose is
    /// one the round-3 wireframes (`DUO_POSES.md`) FIT a wide video to
    /// its own shape rather than the fixed 9:16 box: open-wide (pose 3)
    /// or book (pose 4/4W). The stage then fits the video's own aspect
    /// ratio instead (`body` passes `videoAspectRatio` into
    /// `duoLayout.stageRect` exactly when this is true).
    ///
    /// Build 1 fix, step 2 — this replaces the old round's
    /// `isLandscapeFit`, which read `windowIsLandscape` (a real window
    /// rotation) instead of `duoLayout.pose`. That old property also
    /// hid the chrome/caption/chin the way `isFullscreen`'s rotation
    /// hack does; this one hides nothing — `FeedView.hidesGlobalChrome`
    /// no longer has a term for it, and `FeedPageContent.captionZone`
    /// always passes `hidden: false` — because the round-3 wireframes
    /// keep pose 3's rail, chin, chrome, caption, and status all
    /// visible over the video.
    ///
    /// Deliberately excludes `isActive`, `fullscreenAllowed`, and
    /// `isScrubbing` — spec requirement, step 1's build list: a
    /// neighbour page's own stage must already read its final aspect
    /// before it ever becomes active, the moment its own video loads
    /// (`videoIsLandscape` sets independent of `isActive`), so swiping
    /// onto it never jumps its layout. Compare `isFullscreen`, which
    /// DOES need `isActive` — only one page may ever claim the
    /// rotation hack's shared fullscreen state, where this value feeds
    /// only this page's own stage.
    ///
    /// Still excludes a VERTICAL video shown at this pose — requirement
    /// 7 (plan item 86): a vertical video must never be full-screened
    /// or aspect-fit when open. It stays in the normal 9:16-fit layout,
    /// which `duoLayout.stageRect`'s default aspect ratio already
    /// produces correctly — see that function's own comment.
    ///
    /// Owner re-adapt (Opus round-3 compare, pose 5): `.openTall`
    /// joins `.openWide`/`.book` here too — a wide video there used to
    /// stay in the fixed 9:16 box regardless of its own real shape,
    /// which pillarboxed it well short of that box's own bottom edge;
    /// the scrubber, pinned to the BOX's bottom (not the video's own
    /// visible one), then read "~170pt below the video." `DuoLayout
    /// .stageRect`'s own generic fallback path (`availableRect` +
    /// `fitRect`) already FITs whatever `aspectRatio` it is given for
    /// `.openTall` — the same path that pose's own TALL-video case
    /// already uses at the 9:16 default — so this needs no new branch
    /// there, only this property passing the video's own real shape
    /// through on pose 5 too, same as pose 3 already does.
    ///
    /// Owner re-adapt (pose pass): `.laptop` joins them — "widescreens
    /// don't take up the whole top half. they should." `DuoLayout
    /// .stageRect`'s own `.laptop` branch already FITs whatever
    /// `aspectRatio` it is given inside the real upright-half box
    /// (`[0, W] × [safeAreaTop + 10, division.minY − 14]`, that
    /// function's own comment); it only ever received the 9:16
    /// default before this, so a 16:9 video FIT into a 9:16-shaped box
    /// bound on HEIGHT, landing well short of the box's own full
    /// width — the owner's own "small box, ~190pt wide" report. A
    /// TALL video still reads `videoIsLandscape == false`, so it is
    /// unaffected either way — "tall videos stay as they are."
    private var useVideoAspect: Bool {
        videoIsLandscape && (duoLayout.pose == .openWide || duoLayout.pose == .book || duoLayout.pose == .openTall || duoLayout.pose == .laptop)
    }

    /// True at pose 3 (any video shape) and pose 4W (book with a
    /// landscape video) — build 4: the two cases the round-3
    /// wireframes (`DUO_POSES.md`) give a fixed SCREEN point instead
    /// of "today"'s stage-relative placement. See `ringFixedPoint`'s
    /// own comment for the actual points, and the `CloudDownloadRing`
    /// construction in `stageContent` for why this only ever toggles
    /// that instance's `.opacity`, never its mounting.
    ///
    /// Pose 4's own TALL-video case is deliberately excluded —
    /// `useVideoAspect` is `false` there, so it is not `.book` alone
    /// that matters, only `.book` together with a landscape video.
    private var usesFixedRingPoint: Bool {
        duoLayout.pose == .openWide || (duoLayout.pose == .book && useVideoAspect)
    }

    /// The fixed screen point `usesFixedRingPoint` cases use, in
    /// `containerSize`'s own coordinate space (0 at the page's own
    /// top) — the wireframe's own numbers (`DUO_POSES.md`): pose 3,
    /// `(48, H − 113)`, above the caption; pose 4W, `(44, H − 79)`.
    /// `nil` when `usesFixedRingPoint` is `false`.
    ///
    /// Both points are meant to sit outside pose 3's own stage box
    /// (which `openWideWideVideoRect`'s own comment, and the per-pose
    /// table, place well to the trailing side of x = 48 on every
    /// MEASURED window) — `stageContent`'s own `.clipped()` would cut
    /// off anything placed there from inside it, which is why this is
    /// a second, separate `CloudDownloadRing` mounted at `body`'s own
    /// outer level instead, never a repositioning of the existing one.
    ///
    /// Owner-reported bug (Opus wireframe compare, pose 3): the ring
    /// sat ON the video's own bottom-left corner on the real sim — a
    /// window narrower (relative to the bar/chrome columns it
    /// excludes) than whatever one `x = 48` was originally measured
    /// against, where `stage.minX` falls inside the ring's own 30pt
    /// disc instead of clear of it. `x` now clamps to the wireframe's
    /// own 48/44 only when the stage leaves room for it, and backs off
    /// to just clear of the stage's own real leading edge otherwise —
    /// derived from the live geometry `openWideWideVideoRect` already
    /// computes, not a second hand-measured number that can drift from
    /// the first the way the un-clamped constant did.
    /// Mirrored-layout round: `stageMaxX` is the new second input —
    /// the stage's own TRAILING edge, needed only when `isMirrored`
    /// moves the "clear of the stage, near the bezel" point to the
    /// TRAILING bezel instead (`stageRect`'s own `openWideWideVideoBox`/
    /// `bookStagePageBox` already move the stage itself there; this
    /// mirrors the SAME x the unmirrored case reads off `stageMinX`,
    /// off `containerSize.width - stageMaxX` instead).
    private func ringFixedPoint(containerSize: CGSize, stageMinX: CGFloat, stageMaxX: CGFloat) -> CGPoint? {
        let ringRadius = CloudDownloadRing.standardDiameter / 2 + CloudDownloadRing.discPadding
        if duoLayout.isMirrored {
            let clearOfStage = containerSize.width - stageMaxX - ringRadius - 6
            switch duoLayout.pose {
            case .openWide:
                return CGPoint(x: containerSize.width - min(48, clearOfStage), y: containerSize.height - 113)
            case .book where useVideoAspect:
                return CGPoint(x: containerSize.width - min(44, clearOfStage), y: containerSize.height - 79)
            default:
                return nil
            }
        }
        let clearOfStage = stageMinX - ringRadius - 6
        switch duoLayout.pose {
        case .openWide:
            return CGPoint(x: min(48, clearOfStage), y: containerSize.height - 113)
        case .book where useVideoAspect:
            return CGPoint(x: min(44, clearOfStage), y: containerSize.height - 79)
        default:
            return nil
        }
    }

    #if DEBUG
    private static let rotationLog = Logger(subsystem: "com.cloudfull.app", category: "Rotation")

    /// R5 (`design/duo/duo_audit_apple_checklist.md` Decision A/C):
    /// replaces `deviceStance` as the DEBUG probes' orientation reading,
    /// now that `OrientationMonitor` is gone. Reads the WINDOW's own
    /// real interface orientation — never a device orientation, and
    /// never for layout (`isFullscreen`/`allowsLandscapeCandidate`
    /// already read window shape and traits directly) — so this is a
    /// plain UIKit scene-geometry read, not the kind of
    /// `UIDevice.current.orientation` round-trip `OrientationMonitor`'s
    /// own header comment warned never to make from a body pass.
    ///
    /// `.landscapeLeft`/`.landscapeRight` are SWAPPED on the way out:
    /// `UIInterfaceOrientation`'s left/right naming is the opposite of
    /// the matching `UIDeviceOrientation` case — Apple's own, long-
    /// standing convention, confirmed empirically on this runtime (the
    /// simulator's own XCUITest log reports "Setting device orientation
    /// to Landscape Left … Interface orientation changed to Landscape
    /// Right" for the same physical turn). Swapping back is what keeps
    /// this probe reading in the same device-orientation terms
    /// `deviceStance.probeName` used to report, so `CloudfullUITests/M6Tests.swift`'s
    /// own `rotate(to:)` helper (which still thinks in device-orientation
    /// terms) needs no further change beyond R5's own.
    private var windowOrientationProbeName: String {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return "portrait" }
        switch scene.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: return "landscapeRight"
        case .landscapeRight: return "landscapeLeft"
        default: return "portrait"
        }
    }

    /// `CGRect?` as `"x,y,w,h"`, or `"none"` — the shared formatting
    /// `logRotationPose` uses for both `duoLayout.division` and
    /// `duoLayout.occlusion`, truncating the same way `windowSize`
    /// already does in that message.
    private func rectProbe(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
    }

    /// `"hinge-<status|nil>-<degrees|nil>"`, from `duoLayout.hinge`/
    /// `duoLayout.hingeDegrees`. Both are `nil` together until the
    /// first `onHingeChange` delivery — see `HingeReader`'s own
    /// comment — or always, on a device/OS with no hinge.
    private var hingeProbe: String {
        let status = duoLayout.hinge?.rawValue ?? "nil"
        let degrees = duoLayout.hingeDegrees.map { "\(Int($0))" } ?? "nil"
        return "hinge-\(status)-\(degrees)"
    }

    /// `-cloudfull-log-rotation`: one line per window-size, device-stance,
    /// pose, or hinge change, for example
    /// "rotation_landscapeLeft_hSC-compact_vSC-regular_466x678_pose-closed_div-none_occ-none_hinge-closed-0".
    /// This is how step 6's `horizontalSizeClass != .regular` term in
    /// `isFullscreen` was confirmed against the real sim, pose by pose,
    /// rather than assumed from the SDK headers alone — and, as of step 1,
    /// how `DuoLayout.classify`'s own pose and the fold-orientation
    /// (`div-`) arithmetic are confirmed the same way. R1's own build
    /// (Decision B) prints BOTH size classes, not one: `classify` now
    /// requires `horizontalSizeClass` AND `verticalSizeClass` to read
    /// `.regular` before calling a frame fully open (F2's own fix), so
    /// confirming that rule against a real DeviceHub pose needs both
    /// values visible in the same line. Read with
    /// `xcrun simctl spawn <UDID> log stream --predicate 'subsystem ==
    /// "com.cloudfull.app" and category == "Rotation"' --style compact`
    /// the same way `OrientationMonitor`'s own log is read. DEBUG-only
    /// and off by default, like every other `-cloudfull-log-` flag.
    /// Only `isActive` logs, so three mounted pages never triple every
    /// line.
    ///
    /// Round 2 (Opus diagnosis): adds `rawdiv-` (`duoLayout
    /// .debugRawDivision`, the un-offset, `.includeInactive` reading —
    /// see that field's own comment) and `insets-` (`top,leading,bottom,
    /// trailing`, `duoLayout.debugSafeAreaInsets`) after `hingeProbe`.
    /// `div-`/`occ-` already show the corrected, window-space,
    /// active-only values; this pair shows what the SDK reported before
    /// either correction, so a future containment-filter false negative
    /// (the book-as-tent bug this round fixed) shows both readings side
    /// by side instead of only the filtered one.
    /// Round 3 (owner bug, closed + a tall video still rotating):
    /// `allowsLandscape`/`aspect`/`wide` added, so this page's own
    /// `_hinge-closed-0_` line (the moment the bug reproduced) can be
    /// read against `RotationPolicy`'s own answer at the same moment
    /// — `aspect`/`wide` read `videoAspectRatio`/`videoIsLandscape`
    /// directly, so a stale aspect from the PREVIOUS page's own video
    /// shows up here as a mismatch against what the centred page
    /// actually holds, rather than staying a guess.
    ///
    /// Review fix: adds `barFallback-` (`duoLayout
    /// .usedBarWidthFallback`), the FB24906205 leading-bar fallback
    /// this file's own `current(...)` comment already promised a log
    /// field for — true whenever `width` came from
    /// `DuoLayout.fallbackBarWidth` rather than a real measured inset,
    /// so a real device check does not need to go looking for it.
    private func logRotationPose() {
        guard isActive, DiagnosticsGate.isOn("-cloudfull-log-rotation") else { return }
        let hSC = horizontalSizeClass.map { "\($0)" } ?? "nil"
        let vSC = verticalSizeClass.map { "\($0)" } ?? "nil"
        let insets = duoLayout.debugSafeAreaInsets
        // Owner re-adapt (Live Activity pass, pose 5): the SAME
        // `stageRect` call the body itself uses (line ~640 above,
        // same `windowSize`/`safeAreaTop`/aspect rule) — so a Live
        // Activity's own occlusion growth, and whether the stage
        // itself shifted or shrank in response, show on the same
        // line as the `occ-` reading that caused it, instead of
        // needing a guide-overlay screenshot to see either one.
        let stage = duoLayout.stageRect(
            containerSize: windowSize,
            safeAreaTop: safeAreaTop,
            aspectRatio: (useVideoAspect || duoLayout.pose == .openTall) ? videoAspectRatio : 9.0 / 16.0
        )
        // Owner re-adapt (ring-alignment bug, 3/4/4W): `ringCenteredColumnX`
        // is what the rail/chin/guide all actually land on — printing
        // it next to `occ-` makes the fix itself checkable from this
        // one line (does `ringX-` move to the trailing-inset number
        // once `occ-`'s own width crosses `wideOcclusionThreshold`)
        // instead of a screenshot pixel-crop every time.
        let ringX = duoLayout.ringCenteredColumnX(containerSize: windowSize, safeAreaTop: safeAreaTop)
        let message = "rotation_\(windowOrientationProbeName)_hSC-\(hSC)_vSC-\(vSC)_\(Int(windowSize.width))x\(Int(windowSize.height))"
            + "_pose-\(duoLayout.pose.rawValue)_div-\(rectProbe(duoLayout.division))_occ-\(rectProbe(duoLayout.occlusion))_\(hingeProbe)"
            + "_rawdiv-\(rectProbe(duoLayout.debugRawDivision))_insets-\(Int(insets.top)),\(Int(insets.leading)),\(Int(insets.bottom)),\(Int(insets.trailing))"
            + "_allowsLandscape-\(RotationPolicy.shared.allowsLandscape)_aspect-\(String(format: "%.3f", videoAspectRatio))_wide-\(videoIsLandscape)"
            + "_stage-\(rectProbe(stage))_ringX-\(ringX.map { String(format: "%.1f", $0) } ?? "nil")"
            + "_barFallback-\(duoLayout.usedBarWidthFallback)"
        Self.rotationLog.notice("\(message, privacy: .public)")
        DiagnosticsLog.shared.log("Rotation", message)
    }
    #else
    private func logRotationPose() {}
    #endif

    /// Re-running `.task` must react to the asset changing, the page
    /// entering or leaving the preload window, and an explicit retry tap.
    ///
    /// `isActive` is deliberately absent. Including it would cancel and
    /// restart the whole item load every time a page activates or
    /// deactivates. That would discard the preloaded work the window
    /// exists to build up. The cost is that a load still in flight when the
    /// user swipes finishes holding a stale `isActive`. `load()` must never
    /// act on its own captured copy; see `PlayerHolder.applyPlaybackState`.
    private var taskKey: String {
        "\(pageID)|\(isPreloadable)|\(retryToken)"
    }

    /// The poster's own task identity: the asset and the preload window
    /// only, never `retryToken`, never `isLoading`.
    /// A retry tap must never discard a poster already on screen. A page
    /// that re-enters the preload window re-seats its poster from the
    /// cache without a PhotoKit round trip.
    private var posterKey: String { "\(assetID)|\(isPreloadable)" }

    /// No grace period: the spinner appears the moment a page is not
    /// playing, and disappears the instant it is.
    /// The poster already covers the screen instead of bare black. The
    /// icon fades in over 0.2 s. A fast load barely shows it before it is
    /// cancelled.
    private static let spinnerGrace: TimeInterval = 0
    /// A buffer wait is a different state from the first load.
    /// The picture is frozen on screen, so show the loader at once. The
    /// loader only appears when the clip cannot keep up, so it does not
    /// flicker.
    private static let bufferSpinnerGrace: TimeInterval = 0

    /// `taskKey` plus `isLoading` plus `isActive`.
    ///
    /// `isActive` matters because the grace period must start when the page
    /// becomes active, not when its load began. A neighbour's load can
    /// start before the swipe lands on it. Without `isActive`, the grace
    /// would elapse while the page is still off screen. The spinner would
    /// then show the instant the page appears, instead of after a short
    /// wait. This term also makes the probe's t0 and the grace's t0 the
    /// same instant.
    ///
    /// This is the first-load clock only. It excludes `isWaitingForBuffer`
    /// on purpose. Folding that state in would restart the grace from zero
    /// the moment a real wait began, during a slow first load. The buffer
    /// wait has its own reveal task, with its own clock.
    private var spinnerRevealKey: String {
        "\(taskKey)|\(isLoading)|\(isActive)"
    }

    var body: some View {
        GeometryReader { proxy in
            // The video stage: the largest 9:16 box that fits the space
            // available for it, centred there.
            //
            // Before the iPhone Duo this was simpler: width was always
            // this page's own full width, and height was always width
            // times 16/9 — a box that could only ever be too TALL for a
            // tall iPhone's screen, never too wide, so centring it needed
            // only a vertical split (`halfLeftover` below). The Duo's
            // closed screen breaks that assumption: once
            // `duoLayout.stageRect` excludes the bar column from the
            // available width, that width can be narrow enough that a
            // 9:16 box sized from it would overflow the screen's actual
            // height — the likely root of the ring-offscreen bug item 86
            // flagged. `stageRect` picks whichever side actually binds,
            // the way `AVLayerVideoGravity.resizeAspect` already does for
            // the video itself one level in.
            //
            // On a regular iPhone `duoLayout` is `DuoLayout.none`, so
            // `stageRect` returns exactly the old width-derived box: width
            // is always the binding side there, because a phone screen is
            // always taller than 16:9. This stays pixel-identical to the
            // pre-Duo math by construction, not by a separate code path.
            //
            // An open Duo wide enough excludes a column of its own —
            // see `DuoLayout.railColumn(containerSize:safeAreaTop:)` —
            // which is why `safeAreaTop` is passed here too: that
            // column's width is sized to leave the stage exactly the
            // real top chrome's own band, not just the bare screen
            // height.
            //
            // The aspect ratio itself is the fixed 9:16 default except
            // in `useVideoAspect`: a landscape video at the open-wide or
            // book pose fits its OWN shape instead, so the stage reads
            // `videoAspectRatio` rather than leaving the portrait box
            // `stageRect` would otherwise still produce — see that
            // property's own comment for why a landscape window with a
            // 9:16 box was the bug this fixes.
            //
            // Owner re-adapt (pose 5, open-tall): reads the video's own
            // real aspect there even for a PORTRAIT video —
            // `useVideoAspect` alone never would, since it requires
            // `videoIsLandscape`. A narrower-than-9:16 clip (e.g.
            // 9:19.5) needs `stageRect` to actually SEE that narrower
            // ratio for its own new right-align branch to have
            // anything to act on; `videoAspectRatio` already defaults
            // to 9:16 before a real asset loads, so this reads
            // identically to the old default for that one frame, not
            // a jump once the real value lands.
            let stageRect = duoLayout.stageRect(
                containerSize: proxy.size,
                safeAreaTop: safeAreaTop,
                aspectRatio: (useVideoAspect || duoLayout.pose == .openTall) ? videoAspectRatio : 9.0 / 16.0
            )
            let stageWidth = stageRect.width
            let stageHeight = stageRect.height
            // R4: in fullscreen the canvas is simply the window's own real
            // size — no swap, no un-rotated pre-image. `windowIsLandscape`
            // (a term of `isFullscreen`) is only ever true once the
            // system has actually rotated this window, so `proxy.size`
            // here is already the landscape shape the screen shows; a
            // full-bleed canvas at that exact size is the pager cell this
            // page already fills. Outside fullscreen this matches the
            // 9:16 stage exactly, same as before.
            let canvasWidth = isFullscreen ? proxy.size.width : stageWidth
            let canvasHeight = isFullscreen ? proxy.size.height : stageHeight
            // A symmetric split of the space left over around
            // `canvasHeight`. This uses the same formula as
            // `FeedView.stageBandHeight`, computed locally here because
            // `ScrubberView`'s seam placement needs it and `FeedView`'s copy
            // is private to that type.
            // This is all the fullscreen canvas ever uses. Its centring
            // has nothing to do with the 9:16 stage or the island, so
            // `downShift` below is always zero for it.
            let halfLeftover = max(0, (proxy.size.height - canvasHeight) / 2)
            // The stage's own horizontal leftover within the full page
            // width, split by `stageRect`'s position rather than evenly:
            // `stageRect` already centres the box inside
            // `duoLayout.availableRect`, which sits flush against one
            // edge of the page when the bar column is on (excluded from
            // that rect) and spans the full page when it is off. Reusing
            // its position, instead of re-centring here, is what keeps
            // the video out of the bar column rather than merely
            // off-centre within it.
            // Zero on a regular iPhone: `stageRect.width` is already the
            // full page width there, so both sides come out to 0, same as
            // today. Zero in fullscreen too: the rotated canvas has no
            // bar column to dodge.
            let horizontalLeadingSpace = isFullscreen ? 0 : stageRect.minX
            let horizontalTrailingSpace = isFullscreen ? 0 : max(0, proxy.size.width - stageRect.maxX)
            // Shifts the resting 9:16 stage down by the same amount
            // `FeedView.topBandHeight` adds to its own top band, so the
            // video and the top chrome above it never disagree about
            // where that edge is. `safeAreaTop` is the parameter passed
            // down from `FeedView`, not `proxy.safeAreaInsets.top`,
            // which reads 0 under the pager's `.ignoresSafeArea()`. See
            // `resolvedDownShift`'s own doc comment (below `body`) for
            // the full reasoning — pulled out of this `let`, which the
            // Swift type checker could not resolve inline in
            // reasonable time once it grew a branch for
            // `useVideoAspect` too.
            //
            // The open-tall pose (bar off) reads this same path as the
            // closed bar column and a regular iPhone, deliberately: the
            // owner's own review asked for it to look like the closed
            // pose, chrome overlaid on the video rather than pushing it
            // down into its own band — see `DuoLayout.availableRect`'s
            // own comment for the reservation this undoes. An earlier
            // version read a different path here for that pose; it no
            // longer needs one.
            let downShift = resolvedDownShift(
                isFullscreen: isFullscreen,
                useVideoAspect: useVideoAspect,
                stageHeight: stageHeight,
                containerHeight: proxy.size.height
            )
            // Build 8b: pose 6's own `stageRect` already places the box
            // at the fold's own top clearance (`safeAreaTop + 10`), not
            // centred in the window's own leftover height the way
            // `halfLeftover` assumes — there is plenty of room BELOW
            // the stage here (the fold, then the whole bottom deck), so
            // a symmetric split would float the video too low. Reading
            // `stageRect.minY` directly, the same way
            // `horizontalLeadingSpace` already reads `stageRect.minX`
            // below, keeps the stage pinned to the fold instead.
            let topSpace = (duoLayout.pose == .laptop && !isFullscreen) ? stageRect.minY : halfLeftover + downShift
            // The black band this page leaves below the stage.
            // `ScrubberView`'s idle-state seam reads this value, so its
            // line stays inside the real bottom band instead of
            // drifting into the video.
            //
            // One formula for every case: the exact complement of
            // `topSpace` within the page, given `canvasHeight`. This is
            // algebraically identical to `StageGeometry.bottomBand`'s
            // own result whenever `topSpace` came from
            // `StageGeometry.downShift` (both reduce to
            // `naturalBand - downShift`), so every case this already
            // covered is unchanged.
            let bottomSpace = max(0, proxy.size.height - topSpace - canvasHeight)
            ZStack {
                // Owner: "I can't tell if the laptop video sits flush
                // on the fold." This page's own background is what
                // actually shows around the video in normal use (the
                // pager's own SHARED background, `FeedView
                // .pagerBackground`, sits behind every page and is
                // mostly covered by this one) — see
                // `DuoGuideColouredBackground`'s own comment for the
                // red/blue meaning, shared between the two rather than
                // defined twice.
                // Owner re-adapt: "turn OFF the red/blue colour fill,
                // keep all other guide lines" — `DuoGuides.isOn` alone
                // (`-cloudfull-duo-guides`) goes back to plain black
                // here; `DuoGuideColours.isOn`
                // (`-cloudfull-duo-guide-colours`, its own separate
                // flag, off by default) is the one this background
                // itself now also requires.
                #if DEBUG
                if DuoGuides.isOn && DuoGuideColours.isOn {
                    DuoGuideColouredBackground(duoLayout: duoLayout, safeAreaTop: safeAreaTop, containerSize: proxy.size, isWideVideo: useVideoAspect)
                } else {
                    Color.black
                }
                #else
                Color.black
                #endif
                Color.clear
                    // The one place `windowIsLandscape` is written.
                    // `proxy.size` is this `GeometryReader`'s own
                    // measurement of the real window, so comparing its
                    // width and height directly is the geometry-only
                    // test step 6 asks for — never a device check.
                    // `initial: true` so a page that mounts already
                    // inside a landscape window (for example, a fresh
                    // page scrolled to while the Duo is already open and
                    // sideways) reads it from the first frame, not only
                    // on the next rotation.
                    .onChange(of: proxy.size, initial: true) { _, newSize in
                        windowIsLandscape = newSize.width > newSize.height
                        windowSize = newSize
                        logRotationPose()
                    }

                VStack(spacing: 0) {
                    // `Color.clear.frame(height:)`, not `Spacer()`.
                    // The two views must stay the same type between
                    // fullscreen and non-fullscreen. Only the height number
                    // differs, through the ternaries above. So
                    // `stageContent` below keeps the same tree position and
                    // identity either way. See the comment on `stageContent`
                    // below for why that identity must never change.
                    Color.clear.frame(height: topSpace)
                    // This stays one chain, always mounted, rather than an
                    // if/else between fullscreen and non-fullscreen. The
                    // `AVPlayerLayer` instance must not move or rebuild
                    // during the transition.
                    // An if/else with `stageContent` duplicated in both
                    // branches would give the branches different
                    // `_ConditionalContent` types. SwiftUI would then tear
                    // down and rebuild the whole subtree on every flip of
                    // `isFullscreen`, including `PlayerLayerView.makeUIView`,
                    // which allocates a fresh `AVPlayerLayer`.
                    // Only the conditional below, over `ScrubberView` alone,
                    // and the guard at the top of `handleScrubChanged`
                    // change behaviour between the two states.
                    // The recognizer cannot be disabled selectively: this
                    // SwiftUI version of `UIGestureRecognizerRepresentable`
                    // declares only `gesture(_:)`, with no `GestureMask` or
                    // `isEnabled` overload.
                    stageContent(bottomBand: bottomSpace, containerSize: proxy.size)
                        .frame(width: canvasWidth, height: canvasHeight)
                        .clipped()
                        .duoGuideMark("stage", color: .purple, active: isActive)
                        // Tap-to-keep and tap-to-mute live on the stage, not
                        // on the whole page. A tap in the top black band, on
                        // or around the pills, must not toggle mute.
                        // The double tap is declared first, so a single tap
                        // delivers only after the roughly 0.3 s double-tap
                        // window passes.
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            onDoubleTap()
                        }
                        .onTapGesture {
                            // In fullscreen, the same tap also reveals the
                            // chrome.
                            // Setting `chromeRevealed = true` directly, not
                            // `.toggle()`, means a repeat tap never hides
                            // it. The chrome's own 3 s timer clears it.
                            toggleMute()
                            if isFullscreen {
                                chromeRevealed = true
                                chromeRevealNonce += 1
                            }
                        }
                        // A long press anywhere on the fixed 9:16 stage
                        // enters scrubbing, at the finger's current x
                        // position.
                        // The recognizer, not a SwiftUI gesture modifier, is
                        // what keeps the pager's pan alive here. See
                        // `StageLongPressScrubGesture` for the measurement
                        // behind that choice.
                        // Permanently attached. In fullscreen it is
                        // neutralised by the guard at the top of
                        // `handleScrubChanged`, not by detaching the
                        // recognizer.
                        .gesture(
                            StageLongPressScrubGesture(
                                minimumDuration: 0.35,
                                allowableMovement: 10,
                                stageWidth: stageWidth,
                                onScrubMoved: handleStageHold,
                                onScrubEnded: endStageHold
                            )
                        )
                        // Plays at 2x while an edge of the stage is held.
                        // A small pill at the top of the stage confirms the
                        // speed change, and disappears the instant the
                        // finger lifts.
                        .overlay(alignment: .top) {
                            if isFastForwarding {
                                Text("2×")
                                    .font(.system(size: 13, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .feedGlass(in: Capsule())
                                    .padding(.top, 12)
                                    .transition(.opacity)
                                    .allowsHitTesting(false)
                                    .accessibilityIdentifier(isActive ? "stage_fast_forward" : "")
                                    .accessibilityLabel("Playing at 2x speed")
                            }
                        }
                        .animation(.easeOut(duration: 0.15), value: isFastForwarding)
                        // Mounted after `.clipped()`, not as a plain ZStack
                        // child inside `stageContent`. This lets the idle
                        // line shift down into `bottomSpace`'s black band,
                        // so that clip never cuts off the idle line. See
                        // `ScrubberView`'s header comment and `seamOffset`.
                        // No scrubbing in fullscreen: `ScrubberView` is not
                        // mounted at all while `isFullscreen`, because its
                        // own `DragGesture` assumes an unrotated stage for
                        // its x-to-fraction math. Only the `ScrubberView`
                        // child is conditional here, never `stageContent`
                        // itself.
                        //
                        // Build 8b: pose 6 (laptop) also skips this
                        // instance. Its own scrubber lives in the shared
                        // bottom deck below the fold instead — a second,
                        // independently positioned `ScrubberView` mounted
                        // at `body`'s own outer level (`laptopScrubber`
                        // below), the same precedent
                        // `usesFixedRingPoint`'s ring already set for a
                        // control that must sit off the stage.
                        .overlay(alignment: .bottom) {
                            if !isFullscreen && duoLayout.pose != .laptop {
                                ScrubberView(
                                    progress: holder.progress,
                                    isScrubbing: isScrubbing,
                                    scrubFraction: scrubFraction,
                                    durationSeconds: holder.duration,
                                    // Build 4: pose 3/4/4W pass a literal
                                    // 0 — never the real `bottomSpace` —
                                    // so `ScrubberView.seamOffset` always
                                    // falls below `minimumSeamBand` and
                                    // the hairline stays on the video's
                                    // own bottom edge, the per-pose
                                    // table's "on video bottom edge" for
                                    // every one of these poses, tall or
                                    // wide video alike, regardless of how
                                    // much real black band this frame
                                    // happens to leave below the stage.
                                    // Pose 1V (`.closed`) joins them
                                    // (owner re-adapt, pose pass): on
                                    // this pose's own measured geometry
                                    // `bottomSpace` already computes to
                                    // 0 (the stage is already
                                    // height-bound, full container
                                    // height), so this is a no-op there
                                    // today — explicit rather than
                                    // relying on that coincidence, so a
                                    // differently-proportioned closed
                                    // window still lands the line on
                                    // the video's own edge.
                                    //
                                    // Pose 5 (`.openTall`) joins them
                                    // too (Opus round-3 compare, owner:
                                    // "pose 5 = like 1V") — was reading
                                    // the real `bottomSpace` instead,
                                    // which lifted the line by
                                    // `ScrubberView.trackBoxHeight`
                                    // whenever that band was 50pt or
                                    // more (`seamOffset`'s own rule),
                                    // "~16pt above the bottom edge" on
                                    // the sim.
                                    bandHeight: (duoLayout.pose == .openWide || duoLayout.pose == .book || duoLayout.pose == .closed || duoLayout.pose == .openTall)
                                        ? 0 : bottomSpace,
                                    isActive: isActive,
                                    reduceMotion: reduceMotion,
                                    onStripDrag: handleScrubChanged,
                                    onStripEnded: endScrub,
                                    // Owner re-adapt (pose pass, pose
                                    // 1V): "the line's slightly above
                                    // the bottom — it should be on the
                                    // bezel." Pose 1V — see
                                    // `ScrubberView.pinsToBottomEdge`'s
                                    // own comment for why this is safe
                                    // only where this view's own frame
                                    // bottom already IS the true screen
                                    // edge, with nothing below it to
                                    // extend into.
                                    //
                                    // Owner re-adapt (Opus wireframe
                                    // compare, poses 3/4): the same
                                    // "slightly above the edge" defect,
                                    // reported as "~15pt inside the
                                    // picture" there — without this,
                                    // the line draws at the TOP of its
                                    // own 28pt touch-target box
                                    // (`ScrubberView.trackBoxHeight`),
                                    // not flush with it. `bandHeight: 0`
                                    // just above already puts that box
                                    // on the video's own bottom edge
                                    // for these two poses; this is the
                                    // same fix 1V already needed to
                                    // land the visible LINE there too,
                                    // not just the box.
                                    //
                                    // Pose 5 (Opus round-3 compare):
                                    // same treatment as 1V, per the
                                    // owner's own "pose 5 = like 1V."
                                    pinsToBottomEdge: duoLayout.pose == .closed || duoLayout.pose == .openWide || duoLayout.pose == .book || duoLayout.pose == .openTall
                                )
                                .duoGuideMark("scrub", color: .brown, active: isActive)
                            }
                        }
                        // R4: no `.rotationEffect` — the window itself
                        // really rotates now (`windowIsLandscape`'s own
                        // comment), so there is no canvas angle left for
                        // this file to animate. The system's own rotation
                        // transition (~0.3 s) handles the turn; this
                        // `.animation` only smooths the discrete jump
                        // between the 9:16 stage frame and the full-bleed
                        // canvas (`canvasWidth`/`canvasHeight`'s own
                        // ternary) the instant `isFullscreen` itself flips,
                        // which can land a frame or two before or after
                        // the window's own size finishes settling.
                        .animation(.easeInOut(duration: 0.25), value: isFullscreen)
                    Color.clear.frame(height: bottomSpace)
                }
                // Insets the whole stage column off whichever edge the
                // bar sits on, closed. Both values are 0 outside that
                // case (see their own comments above), so this is a
                // no-op everywhere else. The VStack's own children ask
                // for exactly `canvasWidth` (the greedy `Color.clear`
                // spacers fill whatever width this padding leaves them,
                // and `stageContent` centres inside that at its default
                // alignment), so the two padding amounts need not match:
                // an uneven split still lands the stage exactly where
                // `stageRect` placed it.
                .padding(.leading, horizontalLeadingSpace)
                .padding(.trailing, horizontalTrailingSpace)
                // Build 4: the visible `CloudDownloadRing` for
                // `usesFixedRingPoint` — see that property's own
                // comment, and `ringFixedPoint`'s, for why this is a
                // second instance at `body`'s own outer level rather
                // than a repositioning of the one inside `stageContent`
                // (hidden there via `.opacity`, never unmounted, so its
                // `.task` triggers keep setting `showSpinner` for both).
                // `.accessibilityHidden(true)` always: the hidden
                // instance still carries the real "Loading video"
                // label, so VoiceOver never hears it twice.
                if usesFixedRingPoint, let fixedPoint = ringFixedPoint(containerSize: proxy.size, stageMinX: stageRect.minX, stageMaxX: stageRect.maxX) {
                    CloudDownloadRing(fraction: downloadFraction, isRunning: showSpinner)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .position(fixedPoint)
                        .duoGuideMark("cloud", color: .cyan, active: isActive)
                }
                // Build 8b: pose 6's own scrubber, in the shared bottom
                // deck below the fold — "rendered by P in its outer
                // ZStack (P owns `holder.progress`)," §2.6's own words.
                // `bandHeight: 0`, same reasoning as pose 3/4/4W's
                // identical literal above: this instance never sits on
                // the video's own bottom edge, so `ScrubberView
                // .seamOffset` must always read "below the minimum
                // seam band" and draw its line at the strip's own
                // position rather than shifted for a video seam that
                // is not there.
                if duoLayout.pose == .laptop,
                   let scrubberRect = duoLayout.laptopScrubberRect(containerSize: proxy.size, safeAreaBottom: fullscreenSafeArea.bottom) {
                    ScrubberView(
                        progress: holder.progress,
                        isScrubbing: isScrubbing,
                        scrubFraction: scrubFraction,
                        durationSeconds: holder.duration,
                        bandHeight: 0,
                        isActive: isActive,
                        reduceMotion: reduceMotion,
                        onStripDrag: handleScrubChanged,
                        onStripEnded: endScrub
                    )
                    .frame(width: scrubberRect.width, height: scrubberRect.height)
                    .position(x: scrubberRect.midX, y: scrubberRect.midY)
                    .duoGuideMark("scrub", color: .brown, active: isActive)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: taskKey) {
            await load()
        }
        // Split out of `load()`, so a Retry tap or a stale `isLoading` can
        // never discard or re-fetch a poster that is already correct.
        .task(id: posterKey) {
            await deliverPoster()
        }
        // Owner-reported bug (pose 3, wide video), round 2: the KVO fix
        // below still was not enough — `holder.presentationSize` needs
        // a real player attached, and `configure(with:)` (where that
        // KVO observation starts) is itself gated behind `scrollGate
        // .waitUntilIdle()` in `load()`. A page that became active
        // before `load()` reached that point still read the default
        // 9:16 stage for its first frame(s) after the swipe landed.
        // `loadAssetAspect()` has no player and no scroll gate to wait
        // on at all — see that method's own comment — so this is the
        // PRIMARY source now. Keyed on the same `taskKey` as `load()`
        // itself (not bare `assetID`), so it reruns in exactly the
        // same situations that one does — a new asset, a retry, and a
        // page re-entering the preload window after leaving it (the
        // `isPreloadable` term in `taskKey`) — the last of which bare
        // `assetID` alone would miss, since `assetID` would not have
        // changed. A neighbour page gets its real aspect the moment it
        // is created, long before it is ever swiped to.
        .task(id: taskKey) {
            await loadAssetAspect()
        }
        // `holder.presentationSize` is `configure(with:)`'s own KVO
        // observation on `AVPlayerItem.presentationSize` (`options:
        // [.initial, .new]`). With `loadAssetAspect()` above now the
        // primary source, this is a CORRECTION pass only: the decoded
        // video's own real shape, for the rare case it disagrees with
        // `PHAsset.pixelWidth`/`pixelHeight` (rotation metadata
        // PhotoKit's own asset record does not always capture
        // exactly). Harmless and a no-op whenever the two already
        // agree, which is the common case.
        .onChange(of: holder.presentationSize) { _, size in
            guard size.width > 0, size.height > 0 else { return }
            videoIsLandscape = size.width > size.height
            videoAspectRatio = size.width / size.height
        }
        // `initial: true` so the holder knows this page's intent from the
        // moment it exists, not only once that intent next changes.
        // The holder's stored intent, never a value captured by an async
        // task, decides whether playback starts.
        .onChange(of: isActive, initial: true) { _, newValue in
            if !newValue {
                // R4: "reset it on page change" — the dismiss latch's
                // other reset trigger, now that there is no device
                // orientation left to notice "the landscape period has
                // ended" (see `dismissedThisSpell`'s own comment). This
                // page leaving the active slot is the new reset point,
                // regardless of why (a swipe, a prune, a library change).
                dismissedThisSpell = false
                chromeRevealed = false
            }
            // A page handoff that lands while the pager is still moving
            // waits for idle. Play and pause are engine calls; see
            // `ScrollPhaseGate`.
            if scrollGate.isScrolling {
                pendingActive = newValue
            } else {
                applyActive(newValue)
            }
        }
        .onChange(of: scrollGate.isScrolling) { _, scrolling in
            if !scrolling { syncPlayerLayerMount() }
            guard !scrolling, let pending = pendingActive else { return }
            pendingActive = nil
            applyActive(pending)
        }
        .onChange(of: isPreloadable, initial: true) { _, _ in
            syncPlayerLayerMount()
        }
        .onChange(of: isSuspended, initial: true) { _, newValue in
            holder.setSuspended(newValue)
        }
        // `isFullscreen` is computed, not stored, but `FeedView` still needs
        // an edge signal to drive `.scrollDisabled(isScrubbing ||
        // isFullscreen)` and hide its own global chrome. This matches the
        // shape `onScrubbingChanged` already uses.
        .onChange(of: isFullscreen) { _, on in
            if on { Usage.shared.fullscreenEntered(pose: Usage.pose(duoLayout.pose, landscape: windowIsLandscape)) }
        }
        // Analytics only: registers/clears this page as the one
        // `Usage`'s pose tracker hands committed fold/unfold
        // transitions to, so a fold while this page is active can
        // measure whether its own playback kept going. See
        // `Usage.setFoldObserver`'s own doc comment for why a page
        // going inactive clears only its own registration, never a
        // different page's.
        .onChange(of: isActive, initial: true) { _, active in
            Usage.shared.setFoldObserver(pageID: pageID, handler: active ? { from, to, at in
                recordFoldPlayback(from: from, to: to, at: at)
            } : nil)
            // A neighbour swiped away within 1 s of a fold stays
            // mounted (SwiftUI never calls `onDisappear` on it), so a
            // measurement already running on the now-inactive page
            // must be cancelled here too, not only in `onDisappear`.
            if !active { foldMeasureTask?.cancel() }
        }
        .onDisappear {
            Usage.shared.setFoldObserver(pageID: pageID, handler: nil)
            foldMeasureTask?.cancel()
        }
        .onChange(of: isFullscreen) { _, newValue in
            onFullscreenChanged(newValue)
        }
        // R4: the gate half of the rotation story — see
        // `allowsLandscapeCandidate`'s own comment. Shape matches the
        // `isFullscreen` pair just above.
        .onChange(of: allowsLandscapeCandidate) { _, newValue in
            onAllowsLandscapeChanged(newValue)
        }
        // A new asset resets the dismiss latch, the chrome-reveal state,
        // `videoIsLandscape`, and `videoAspectRatio`, so it does not
        // inherit state from the previous video.
        .onChange(of: assetID) { _, _ in
            dismissedThisSpell = false
            chromeRevealed = false
            videoIsLandscape = false
            videoAspectRatio = 9.0 / 16.0
        }
        // R5: `OrientationMonitor`/`deviceStance` are gone, so there is
        // no device-orientation call site left to pair with the
        // `onChange(of: proxy.size)` log call above. Two independent
        // call sites remain for the same diagnostic: a pose can change
        // with no change to `proxy.size` at all — the fold opening while
        // the window itself stays whatever shape it already was — and
        // the hinge can change with no change to the classified pose —
        // every status short of the `.partial` + landscape combination
        // the tent alone needs.
        .onChange(of: duoLayout.pose) { _, _ in
            logRotationPose()
        }
        .onChange(of: duoLayout.hinge) { _, _ in
            logRotationPose()
        }
        // Owner re-adapt (Live Activity pass): a Live Activity's own
        // pill changes `occlusion` (pose 5 — the closed display's own
        // `occlusion` does NOT change, see `closedStatusWorstCaseBottom`'s
        // own comment in DuoLayout.swift) with no pose, hinge, or
        // `proxy.size` change alongside it, so neither call above ever
        // fired for it. This is the one line that lets
        // `-cloudfull-log-rotation` show occlusion growing/shrinking
        // around a Live Activity starting or ending.
        .onChange(of: duoLayout.occlusion) { _, _ in
            logRotationPose()
        }
        // Owner re-adapt (pose 3, wide-video right-align): a page
        // swipe to a different-shaped video changes `useVideoAspect`
        // (and the `stageRect` it feeds) with no pose/hinge/occlusion
        // change alongside it either — confirmed live this round, a
        // "the log says stage y 72, the guides show y 122" report
        // that turned out to be the log printing a STALE reading from
        // before the swipe, not a real disagreement: the SAME line,
        // re-triggered, matched the guide exactly. This is the fix —
        // the log now stays live across a page swipe too, not just a
        // pose/hinge/occlusion change.
        .onChange(of: useVideoAspect) { _, _ in
            logRotationPose()
        }
        .onChange(of: isMuted) { _, newValue in
            // `isMuted` is shared through `AppStorage` across every page,
            // so every live player, not only the one that was tapped, must
            // react.
            holder.setMuted(newValue)
        }
        // The first decoded frame.
        // `isReadyForDisplay` flips from false to true only once this layer
        // has a real frame to paint for the current item. AVFoundation
        // resets it on every item change, so it cannot leak a previous
        // video's readiness.
        .onChange(of: isReadyForDisplay) { _, ready in
            guard ready else { return }
            // The first frame is recorded for the probe, and nothing else.
            // A first frame is a still picture: it proves the layer has
            // something to paint, not that the video is running. Hiding
            // the loader here would let a frozen page look finished. Only
            // the rule below, the picture actually moving, takes the
            // loader away.
            loadSeq.markFirstFrame()
        }
        // The one rule that hides the loader: the video is actually
        // playing.
        // `holder.isPlaying` reflects `timeControlStatus == .playing`,
        // Apple's own definition of playback currently progressing. It is
        // false while the player waits on a buffer, even though its rate
        // is non-zero.
        .onChange(of: holder.isPlaying) { _, playing in
            guard playing else { return }
            loadSeq.markFirstFrame()
            downloadFraction = nil
            hideSpinnerImmediately()
        }
        // Analytics only: the last play/pause edge, for
        // `recordFoldPlayback`'s own "was playing at the fold" check —
        // see `lastPlayAt`'s own doc comment.
        .onChange(of: holder.isPlaying) { _, playing in
            if playing { lastPlayAt = Date() } else { lastPauseAt = Date() }
        }
        // The wait can also end without a rising `isPlaying` edge: the
        // page deactivates, a sheet comes up, or the item is released. The
        // loader must not outlive the wait.
        .onChange(of: holder.isWaitingForBuffer) { _, waiting in
            if !waiting { hideSpinnerImmediately() }
        }
        .onChange(of: isPreloadable) { _, within in
            if !within {
                // A page can leave the preload window mid-scrub, for
                // example when a library change tears this slot down
                // during an in-flight scrub.
                // `FeedView`'s pager must never stay permanently
                // `.scrollDisabled` because this page's own teardown
                // skipped telling it the scrub ended.
                //
                // Captured before any reset below mutates the terms
                // `isFullscreen` is computed from.
                // `wasFullscreen` must reflect this page's state at the
                // moment the page loses its preload window. It must not
                // reflect the state after the resets below force
                // `isFullscreen` to read `false`. `wasAllowsLandscape`
                // is the same capture for `allowsLandscapeCandidate`.
                let wasFullscreen = isFullscreen
                let wasAllowsLandscape = allowsLandscapeCandidate
                endScrub()
                holder.release()
                isLoading = true
                loadFailed = false
                // A page losing its player also releases its poster.
                // The next `load()`, if this slot is reused, fetches a
                // fresh one. A stale image must never sit over a released
                // player.
                poster = nil
                isReadyForDisplay = false
                // A page outside the preload window cannot be in
                // fullscreen, so these resets need no animation.
                videoIsLandscape = false
                videoAspectRatio = 9.0 / 16.0
                dismissedThisSpell = false
                chromeRevealed = false
                // `FeedView.isFullscreen` is edge-triggered `@State`, set
                // only from `onFullscreenChanged`. Without this call, a
                // page torn down outside the preload window while still
                // fullscreen would never fire the falling edge.
                // `FeedView.isFullscreen` then stays true.
                // Gated on `wasFullscreen`: an ordinary neighbour that was
                // never fullscreen must not report `false` here.
                // `onFullscreenChanged` is a single shared callback across
                // every mounted page. An unconditional call from a page
                // that was never fullscreen could race the active page's
                // own `true` and overwrite it with `false` a moment later.
                if wasFullscreen {
                    onFullscreenChanged(false)
                }
                // Same reasoning as `wasFullscreen` just above, for
                // `allowsLandscapeCandidate`'s own callback: a page torn
                // down outside the preload window while it was still
                // granting landscape must not leave `FeedView`'s own
                // `pageAllowsLandscape` stuck `true` forever.
                if wasAllowsLandscape {
                    onAllowsLandscapeChanged(false)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Nothing re-arms playback after the system pauses the player
            // for a background transition. Do it explicitly on return.
            if newPhase == .active {
                holder.applyPlaybackState()
            } else {
                // Analytics only. A fold measurement in flight when the
                // app leaves `.active` must not keep running into the
                // background and report against whatever session comes
                // next — see `Usage.commitPose`'s own `notifyObserver`
                // doc comment for the session-ending half of this same
                // rule.
                foldMeasureTask?.cancel()
            }
        }
        .onDisappear {
            // The same `wasFullscreen` guard as the `isPreloadable` branch
            // above, for the same reason. This callback is shared across
            // every mounted page. An ordinary page's disappearance must
            // never report `false` over the actually fullscreen page's
            // `true`.
            // Captured before `endScrub()` and `holder.release()`, even
            // though this page's own `isFullscreen` does not depend on
            // either: nothing below this line should change what gets
            // reported.
            let wasFullscreen = isFullscreen
            let wasAllowsLandscape = allowsLandscapeCandidate
            endScrub()
            holder.release()
            if wasFullscreen {
                onFullscreenChanged(false)
            }
            if wasAllowsLandscape {
                onAllowsLandscapeChanged(false)
            }
        }
    }

    /// `body`'s own vertical shift for the stage — pulled out of
    /// `body` as a plain function, not a local `let` with its own
    /// `if`/`else`, because the Swift type checker could not resolve
    /// `body`'s own `some View` expression in reasonable time with
    /// that much branching arithmetic inlined directly in it.
    ///
    /// `isFullscreen || useVideoAspect`: zero. The full-bleed fullscreen
    /// canvas (R4: the window itself is really landscape now, no
    /// rotated un-rotated-canvas trick left — see `canvasWidth`'s own
    /// comment) has no top chrome above it to make room for. The
    /// `useVideoAspect` stage (pose 3/4's wide video) has no reserved
    /// band to clear either — build 1 fix, step 2 un-hid this pose's
    /// chrome, but `DuoLayout.availableRect`'s own "overlay, never
    /// carve out height" rule already covers it the same way it
    /// already does the bar column and the open-tall column: the
    /// chrome draws ON the video's own top edge, full height, rather
    /// than pushing it down — both this case and the full-bleed canvas
    /// centre plainly in the available space, the same symmetric split
    /// `halfLeftover` already gives them.
    ///
    /// Otherwise: the existing `StageGeometry.downShift`, for every
    /// other case alike — a regular iPhone, the closed bar column, and
    /// the open-tall column (bar off). An earlier version read a
    /// separate path for the open-tall case, shifting the stage down
    /// by its own top chrome's full band; the owner's own review asked
    /// for that pose to look like the closed one instead, chrome
    /// overlaid on the video rather than pushed below a reserved band
    /// — see `DuoLayout.availableRect`'s own comment — so it now reads
    /// this one path like everything else, getting whatever small
    /// natural band `StageGeometry.downShift` finds on its own, same
    /// as the closed bar column already did.
    private func resolvedDownShift(
        isFullscreen: Bool,
        useVideoAspect: Bool,
        stageHeight: CGFloat,
        containerHeight: CGFloat
    ) -> CGFloat {
        if isFullscreen || useVideoAspect {
            return 0
        }
        return StageGeometry.downShift(safeAreaTop: safeAreaTop, stageHeight: stageHeight, containerHeight: containerHeight)
    }

    /// How far above the video's bottom edge the loading ring's own bottom
    /// sits, measured in the stage's own space.
    ///
    /// Normally this is just the rail's clearance, which puts the ring
    /// level with the rail's lowest glyph on the opposite side.
    ///
    /// The `max` handles a phone whose screen is already close to 16:9,
    /// where `bottomBand` computes to 0. An iPhone SE 3 at 375×667 is one
    /// example; see `StageGeometry.naturalBand`. There the video's bottom
    /// edge and the page's bottom edge are the same line. A flat 12pt of
    /// clearance would put the ring onto the caption's second line and
    /// onto the playhead strip. The playhead strip loses its own seam
    /// shift below a 50pt band; see `ScrubberView.seamOffset`. Neither
    /// problem shows on a larger phone, which is why this needs a rule
    /// rather than a constant. The same condition can also occur on
    /// certain folding-phone screen sizes.
    ///
    /// Owner-reported bug (Opus wireframe compare, pose 5): the ring
    /// overlapped the date/caption there. Root cause:
    /// `StageGeometry.captionTopFromBottom` alone assumes the REGULAR,
    /// un-lifted caption position (`FeedPageContent.captionZone`'s own
    /// `bottomPadding: 20`); it never accounted for that same
    /// function's `liftsForScrubber` case — `20 + 28` whenever the
    /// band falls under `ScrubberView.minimumSeamBand` (50), to clear
    /// the on-video scrubber hairline — which pose 5 (usually
    /// height-bound, so usually a small band) hits far more often than
    /// the phones this constant was originally tuned against. `extraLift`
    /// mirrors `liftsForScrubber`'s own gate exactly, 1:1, rather than
    /// a second, independent guess at when it applies: pose 1V
    /// (`.closed`) is excluded the same way `captionZone` excludes it
    /// (that pose's own caption never lifts, regardless of band), so
    /// this is a no-op there, unchanged from before.
    ///
    /// `containerSize` is this page's own `GeometryReader` proxy size,
    /// threaded in through `stageContent(bottomBand:containerSize:)` —
    /// this function has no reader of its own. Short-window spec
    /// (`ipad7.png`): ORed into `extraLift`'s own gate, the same way
    /// `FeedPageContent.captionZone`'s `liftsForScrubber` ORs it in — a
    /// regular-iPhone pose on a short iPadOS 26 window
    /// (`WindowChrome.isShortWindow`) can hit the same small `bottomBand`
    /// a Duo pose does, needs the same lift. The call site below already
    /// skips this function entirely while `isFullscreen` is on (it reads
    /// `fullscreenSafeArea.bottom` instead), so this needs no fullscreen
    /// guard of its own.
    private func loaderLift(bottomBand: CGFloat, containerSize: CGSize) -> CGFloat {
        let shortWindow = WindowChrome.isShortWindow(containerSize: containerSize, pose: duoLayout.pose)
        let extraLift: CGFloat = ((duoLayout.pose != .regularPhone && duoLayout.pose != .closed) || shortWindow) && bottomBand < 50 ? 28 : 0
        return max(Rail.seamClearance, StageGeometry.captionTopFromBottom - bottomBand + 8 + extraLift)
    }

    /// Everything that lives inside the fixed 9:16 stage: the video layer,
    /// its spinner, the load-failure card, and the mute-flash badge.
    /// Split out of `body` only so the stage `.frame(width:height:)` in
    /// `body` has one child to size, not four ZStack layers to size
    /// identically.
    ///
    /// `bottomBand` is the black strip this page leaves below the stage:
    /// the gap from the page's bottom edge up to the video's bottom edge.
    /// The loading ring needs it to know how much of the caption sits
    /// underneath.
    ///
    /// `containerSize` is `body`'s own `proxy.size` — threaded through
    /// only so `loaderLift(bottomBand:containerSize:)` below has it; see
    /// that function's own comment.
    ///
    /// The returned view type is the same for both states, so the tree
    /// keeps one stable identity across the fullscreen transition.
    private func stageContent(bottomBand: CGFloat, containerSize: CGSize) -> some View {
        ZStack {
            // A video layer redraw is expensive: adding or removing a
            // video layer makes iOS reconfigure video output while the
            // main thread waits.
            // The layer view is always mounted. Only its player connection
            // (`attach`) waits until the pager is idle and the page is in
            // the preload window. A page sliding in shows its poster and
            // nothing else; the connection completes once the swipe has
            // settled.
            // An if/else here, instead of always mounting the view, would
            // give the two branches different types. SwiftUI would then
            // build a new `AVPlayerLayer` on every flip. The old one
            // detaches while the new one attaches on another thread.
            //
            // Owner re-adapt (Opus wireframe compare, pose 1H): "wide
            // video FILLS the screen, as today" — the Duo's own 1H
            // only, via `fillsScreenInFullscreen` (see that property's
            // own comment on why `isFullscreen` alone is not enough).
            // This crops edge to edge instead of letterboxing there;
            // a regular iPhone's own fullscreen keeps today's FIT.
            // `PlayerLayerView` itself stays one stable instance
            // across the flip (see the comment just above); only its
            // own `videoGravity` updates reactively — see that type's
            // own `updateUIView`.
            PlayerLayerView(player: holder.player, onReadyForDisplay: { isReadyForDisplay = $0 }, attach: playerLayerMounted && !scrollGate.isScrolling, fillsScreen: fillsScreenInFullscreen)

            // Sits directly above `PlayerLayerView`, so it covers the
            // layer's own black while nothing has decoded yet. It fades
            // out the instant `isReadyForDisplay` reports a real frame is
            // on screen.
            // `contentMode` matches `PlayerLayerView`'s own gravity —
            // `.fill` in the Duo's own 1H, `.fit` otherwise — so the
            // poster never crops (or fails to crop) relative to the
            // video it stands in for.
            //
            // `poster`, written by `deliverPoster()`, drives every
            // re-render. The cache fallback exists for exactly one frame,
            // the page's first, before SwiftUI schedules its
            // `.task(id: posterKey)`. A warm poster is then on screen the
            // same frame the page lands. A cache read is an in-memory
            // lookup, not a PhotoKit call, so it is safe even from a body.
            //
            // The 0.4 s crossfade below is scoped to this container, not
            // the whole `stageContent` ZStack. So it cannot re-time a
            // sibling's own animation. In particular, it cannot re-time
            // the loading ring's 0.22 s sweep, which ends on the same
            // `isReadyForDisplay` event.
            // The modifier must sit on the container that holds the
            // conditional, not on the `Image` itself. The `Image` is
            // already gone by the time the removal animates.
            ZStack {
                if let displayPoster = poster ?? (isPreloadable ? PosterCache.shared.image(for: assetID) : nil),
                   !isReadyForDisplay {
                    Image(uiImage: displayPoster)
                        .resizable()
                        .aspectRatio(contentMode: fillsScreenInFullscreen ? .fill : .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // The Photos thumbnail is rarely frame 0, so the poster
            // crossfades into the first frame over 0.4 s.
            .animation(.easeInOut(duration: 0.4), value: isReadyForDisplay)

            // Driven by `showSpinner`, which the `.task` below flips true
            // once the page has been active and not ready for
            // `spinnerGrace`. That grace is currently zero, so a page
            // shows the spinner as soon as it is active and not yet ready.
            // Always mounted, rather than `if showSpinner`, so the ring
            // can run its own fade-in and its own finishing sweep. An `if`
            // would tear the ring down the instant `showSpinner` went
            // false, leaving nothing to animate out. Hidden from the
            // accessibility tree until shown.
            //
            // `CloudDownloadRing` is a deliberate copy of the photo feed's
            // ring: its size, its disc, its slow progress sweep, and its
            // closing sweep. Read
            // that file's header before changing any number in it.
            CloudDownloadRing(fraction: downloadFraction, isRunning: showSpinner)
                // Build 4: invisible, never removed, at pose 3/openWide
                // and pose 4W/book-with-a-wide-video — `usesFixedRingPoint`.
                // Those two need the ring at a fixed SCREEN point outside
                // this stage's own clipped box (see `ringFixedPoint`'s own
                // comment for why), so `body`'s own outer `ZStack` mounts
                // a second, purely visual instance at that point instead
                // — see the sibling mounted there. This instance stays
                // mounted and keeps every modifier below, unchanged,
                // rather than being wrapped in an `if`: the two `.task`
                // triggers a few lines down are the ONLY place that ever
                // sets `showSpinner = true`, and the comment above this
                // whole block already explains why an `if` must never
                // tear this down mid-sweep. `.opacity` hides the pixels
                // without touching that lifecycle; the visible duplicate
                // reads the same `showSpinner`/`downloadFraction` state.
                .opacity(usesFixedRingPoint ? 0 : 1)
                // No `.animation`, and no `.feedShadow()` here, and both
                // absences are deliberate.
                //
                // The ring owns its whole life from `isRunning`. It fades
                // itself in over 0.2 s. On the way out it sweeps the arc
                // the rest of the way round while fading, over 0.22 s.
                // An `.opacity` driven by `showSpinner` here would cut
                // that sweep off before a single frame reached the screen.
                //
                // `hideSpinnerImmediately` is the one place that ends the
                // wait and stamps `spinnerGoneAt`. It does not suppress
                // animation.
                //
                // The ring draws its own dark disc, which is also why
                // `.feedShadow()` is absent: the disc keeps the ring
                // visible over `FeedView.bottomScrim`.
                .allowsHitTesting(false)
                .accessibilityLabel("Loading video")
                .accessibilityHidden(!showSpinner)
                // Marked HERE, before the full-bleed
                // `.frame(maxWidth: .infinity, maxHeight: .infinity,
                // alignment: .bottomLeading)` a few lines down —
                // marking after that frame reported the WHOLE stage
                // (the same mistake the chin's own outer frame made),
                // not the small ring itself.
                .duoGuideMark("cloud", color: .cyan, active: isActive && !usesFixedRingPoint)
                // `feed_spinner` lives on a marker sibling below, not on
                // the ring itself. An indeterminate spinner never surfaces
                // an identifier in the accessibility tree, even with
                // `.accessibilityElement(children: .ignore)`.
                // This uses the same 1×1 `Color.clear` technique every
                // DEBUG probe in this app relies on.
                .overlay {
                    if isActive && showSpinner {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityIdentifier("feed_spinner")
                    }
                }
                // The ring sits bottom-leading, the mirror of the photo
                // feed's ring at `.bottomTrailing`
                // (`PhotoPostView.loadingOverlay`).
                //
                // The two padding numbers are the action rail's own, read
                // in the stage's space rather than the page's.
                // `FeedView.actionRail` uses `.padding(.trailing, 10)` and
                // `.padding(.bottom, bottomBand + Rail.seamClearance)`.
                // `bottomBand` is the distance from the page's bottom edge
                // up to the video's bottom edge. This view is already
                // inside the stage, so the same clearance alone lands the
                // ring level with the rail's lowest glyph. That is the
                // line where the caption area begins, and the caption
                // lives below it, so the ring cannot sit on the caption.
                //
                // A full-bleed frame, then corner padding. `.padding` on
                // the outside insets this: it takes the stage-sized
                // proposal, subtracts, and offers the remainder to the
                // `.frame`, which then expands to fill it.
                //
                // This padding resizes nothing else in this ZStack, but it
                // is not consequence-free: the padding puts the ring
                // inside `FeedView.bottomScrim`. The ring's own dark disc
                // keeps it visible there.
                //
                // Step 9 (`design/duo/duo_audit_apple_checklist.md` §5):
                // bottom-leading in fullscreen too now, the owner's own
                // "one rule" pick over keeping fullscreen centred — not a
                // Duo-only branch; every phone gets the same placement.
                // Safe to do now that the window is really landscape
                // (R4): `fullscreenSafeArea.bottom`/`.leading` read as
                // the home indicator's and the camera cutout's real
                // clearance for THIS view's own current frame, not a
                // flat, screenshot-measured constant — the same
                // reasoning `loaderLift` already applies for the
                // non-fullscreen case, just reading real safe-area
                // insets instead of the rail's own layout numbers, since
                // there is no rail column to mirror off of once the
                // whole canvas is the stage.
                //
                // A ternary on the padding VALUES, never an if/else
                // around the view or a different alignment per branch.
                // The modifier chain keeps one identity. This is the
                // rule the identity comment on `stageContent` in `body`
                // protects.
                // Mirrored-layout round: "caption + iCloud ring
                // bottom-trailing" — same opposite-the-rail principle,
                // the near-edge padding moving from leading to
                // trailing (and its own fullscreen safe-area reading
                // with it).
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: duoLayout.isMirrored ? .bottomTrailing : .bottomLeading)
                .padding(duoLayout.isMirrored ? .trailing : .leading, isFullscreen ? (duoLayout.isMirrored ? fullscreenSafeArea.trailing : fullscreenSafeArea.leading) + 10 : 10)
                .padding(.bottom, isFullscreen ? fullscreenSafeArea.bottom + 10 : loaderLift(bottomBand: bottomBand, containerSize: containerSize))
                // `spinnerRevealKey` folds `isLoading` and `isActive` into
                // the task's own identity. So SwiftUI's `.task(id:)`
                // cancel-and-restart cancels a pending reveal the instant
                // readiness arrives, the page changes, or activation
                // changes. No timer and no manual cancellation bookkeeping
                // are needed.
                // The explicit `Task.isCancelled` check after the sleep
                // matters: `try?` alone swallows the cancellation error but
                // does not stop execution. Without this check, a reveal
                // cancelled a moment too late would still flip
                // `showSpinner` on its way out.
                //
                // The buffer wait uses its own clock, `bufferSpinnerGrace`,
                // which is independent of the first-load grace.
                .task(id: "\(taskKey)|\(isActive)|\(holder.isWaitingForBuffer)") {
                    guard isActive, holder.isWaitingForBuffer, !isLoading else { return }
                    try? await Task.sleep(nanoseconds: UInt64(Self.bufferSpinnerGrace * 1_000_000_000))
                    guard !Task.isCancelled, holder.isWaitingForBuffer else { return }
                    showSpinner = true
                    loadSeq.spinnerAt = ProcessInfo.processInfo.systemUptime
                }
                .task(id: spinnerRevealKey) {
                    guard isActive, isLoading else {
                        // `isLoading` flips false at `.readyToPlay` in
                        // `load()`, which is not a frame. Only
                        // `holder.isPlaying` removes the spinner. Take it
                        // away here only for the other two legitimate
                        // reasons this guard can fail: deactivation, or a
                        // load failure.
                        if !isActive || loadFailed { hideSpinnerImmediately() }
                        return
                    }
                    try? await Task.sleep(nanoseconds: UInt64(Self.spinnerGrace * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    showSpinner = true
                    loadSeq.spinnerAt = ProcessInfo.processInfo.systemUptime
                }

            if loadFailed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                    Text("Couldn't load this video")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("It may still be downloading from iCloud.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                    Button("Retry") { retryToken = UUID() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .padding(.top, 4)
                        .accessibilityIdentifier("player_retry")
                }
                .multilineTextAlignment(.center)
                .padding(20)
                .feedShadow()
            }

            if showMuteBadge {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            // `ScrubberView` itself is mounted as an `.overlay` on
            // `stageContent` in `body`, not inside this ZStack. See the
            // overlay's own comment for why. Mounted on every page within
            // the preload window; identifiers are gated on `isActive`, the
            // same style used for the rail.

            // Inside the same ZStack as the video, so it sits inside the
            // same full-bleed canvas (R4: the window itself is really
            // landscape now — see `canvasWidth`'s own comment — so the
            // chrome needs no rotation of its own to read upright; it
            // just lays out directly in the real landscape space).
            // Mounted only for the duration of the landscape period,
            // matching `ScrubberView`'s own conditional mounting.
            if isFullscreen {
                // Owner correction (Opus wireframe compare, pose 1H):
                // "all controls hide" there — see `FullscreenPlayerChrome
                // .showsHairline`'s own comment. A regular iPhone's own
                // fullscreen keeps the hairline, unchanged.
                FullscreenPlayerChrome(
                    revealed: $chromeRevealed,
                    revealNonce: chromeRevealNonce,
                    progress: holder.progress,
                    isMuted: isMuted,
                    showsHairline: duoLayout.pose != .closed,
                    onDismiss: { dismissedThisSpell = true },
                    onToggleMute: toggleMute
                )
            }

            #if DEBUG
            // `scrubber_probe_<isScrubbing>_<currentMs>_<durationMs>`,
            // present unconditionally on the centred page, matching every
            // other DEBUG probe's style. `currentMs` reads the
            // finger-driven position while scrubbing, and the
            // periodic-observer-derived position otherwise.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier(isActive ? scrubberProbeIdentifier : "")

            // `fullscreen_state_<active|inactive>_<stance>_<assetID>`,
            // present unconditionally on the centred page. R5:
            // `<stance>` now reports `windowOrientationProbeName` — the
            // WINDOW's own real orientation, not a raw device reading
            // independent of `isFullscreen`. A portrait video that
            // correctly declines fullscreen now reports "portrait" here
            // too, since the window genuinely never rotates for it; see
            // that property's own comment for the full reasoning, and
            // `CloudfullUITests/M6Tests.swift`'s `testPortraitVideoIgnoresRotation`
            // for how that test proves the decline is correct rather
            // than a missed rotation.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier(isActive ? fullscreenStateIdentifier : "")

            // `load_seq_<pageID>_<posterMs>_<spinnerMs>_<firstFrameMs>_<spinnerGoneMs>`,
            // present unconditionally on the centred page. Each value is
            // milliseconds since this page became active, or -1 if that
            // event has not happened.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier(isActive ? loadSequenceIdentifier : "")
            #endif
        }
    }

    #if DEBUG
    private var fullscreenStateIdentifier: String {
        "fullscreen_state_\(isFullscreen ? "active" : "inactive")_\(windowOrientationProbeName)_\(assetID)"
    }
    #endif

    #if DEBUG
    private var loadSequenceIdentifier: String {
        "load_seq_\(pageID)_\(loadSeq.offset(loadSeq.posterAt))_\(loadSeq.offset(loadSeq.spinnerAt))"
            + "_\(loadSeq.offset(loadSeq.firstFrameAt))_\(loadSeq.offset(loadSeq.spinnerGoneAt))"
    }
    #endif

    #if DEBUG
    private var scrubberProbeIdentifier: String {
        wdMark("scrubProbe")
        let fraction = isScrubbing ? scrubFraction : holder.actualProgress
        let currentMs = Int((fraction * holder.duration * 1000).rounded())
        let durationMs = Int((holder.duration * 1000).rounded())
        return "scrubber_probe_\(isScrubbing)_\(currentMs)_\(durationMs)"
    }
    #endif

    // MARK: - Scrubbing

    /// Shared by both entry points: the 28pt strip's own `DragGesture` and
    /// the long-press-anywhere gesture on the stage.
    /// Starts scrubbing on the first call, then updates the finger
    /// position and throttles the seek to one per 1/30 s.
    private func handleScrubChanged(fraction: Double) {
        // `StageLongPressScrubGesture` is permanently attached, including
        // while `isFullscreen`. A long press on the fullscreen canvas
        // must not start a scrub. There is no scrubbing in fullscreen,
        // and the canvas's own full-bleed width (`canvasWidth`'s own
        // comment) is not the coordinate space `stageWidth` assumes.
        // Guarding here, rather than detaching the recognizer, keeps
        // `StageLongPressScrubGesture` itself unedited.
        guard !isFullscreen else { return }
        let clamped = min(max(fraction, 0), 1)
        if !isScrubbing {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                isScrubbing = true
                Usage.shared.scrub()
            }
            onScrubbingChanged(true)
            holder.pauseForScrub()
        }
        scrubFraction = clamped
        let now = Date()
        guard now.timeIntervalSince(lastSeekAt) >= (1.0 / 30.0) else { return }
        lastSeekAt = now
        seekToScrubFraction()
    }

    /// Width of each edge zone, as a fraction of the stage.
    /// A hold that starts in the outer quarter on either side plays at 2x.
    /// A hold that starts in the middle half scrubs instead.
    private static let fastForwardEdgeFraction: Double = 0.25

    /// Whether the video layer may connect to the player. Tracks
    /// `isPreloadable` and changes only while the pager is idle. See the
    /// comment at its mount point in `stageContent`.
    @State private var playerLayerMounted = false

    private func syncPlayerLayerMount() {
        guard !scrollGate.isScrolling else { return }
        let wanted = isPreloadable
        if playerLayerMounted != wanted {
            if !wanted { isReadyForDisplay = false }
            playerLayerMounted = wanted
        }
    }

    /// The real `isActive` handoff, run only while the pager is idle.
    private func applyActive(_ active: Bool) {
        holder.setActive(active)
        wdMark("afterSetActive")
        // t0 for the `load_seq_` probe is the instant the page becomes
        // active: the moment the user's swipe settled.
        active ? loadSeq.activate(ProcessInfo.processInfo.systemUptime) : loadSeq.deactivate()
    }

    /// Analytics only. Measures whether this page's own playback kept
    /// going across a fold/unfold `Usage` just committed — the same
    /// transition `poseChange` counts, never a raw mid-fold frame —
    /// and, if it stopped, how long until it plays again. Only runs
    /// for the page `Usage` has registered as active (see
    /// `.onChange(of: isActive)` above), so a fold while this page is
    /// preloading, or gone, never measures anything.
    ///
    /// `at` is the fold's own first-report time, not this call's own
    /// (which only happens once `Usage`'s 1 s debounce commits the
    /// transition). The entry guard reads from `lastPlayAt`/
    /// `lastPauseAt`, not a fresh `holder.isPlaying`, so it reflects
    /// the fold's own moment rather than whatever already happened in
    /// the second since. `stopped` and every resume bucket below are
    /// anchored to `at` too, for the same reason.
    private func recordFoldPlayback(from: Usage.Pose, to: Usage.Pose, at: Date) {
        guard wasPlaying(at: at) else { return }   // nothing was playing to keep going or stop
        foldMeasureTask?.cancel()
        // The session this fold belongs to. `.onChange(of: scenePhase)`
        // already cancels this task once the scene leaves `.active`,
        // but a measurement that was mid-sleep at that exact instant
        // must still be stopped from crediting whichever session comes
        // next — see `Usage.commitPose`'s own `notifyObserver` doc
        // comment for the other half of this same rule.
        let sessionID = Usage.shared.current.id
        // `holder` stays weak and optional throughout — read with `?`
        // at each step, never permanently unwrapped, so a page that
        // disappears mid-measurement is noticed at the very next check
        // instead of being held alive by this task.
        foldMeasureTask = Task { @MainActor [weak holder] in
            // `stopped` means "still not playing 1 s after the fold" —
            // wait for exactly that instant, rather than assuming (the
            // old bug's assumption) that this call already lands there
            // via `Usage`'s own debounce.
            let oneSecondAfterFold = at.addingTimeInterval(1)
            let untilOneSecond = oneSecondAfterFold.timeIntervalSinceNow
            if untilOneSecond > 0 { try? await Task.sleep(for: .seconds(untilOneSecond)) }
            guard !Task.isCancelled, let playingNow = holder?.isPlaying, Usage.shared.current.id == sessionID else { return }
            if playingNow {
                Usage.shared.foldPlayback(from: from, to: to, kept: true)
                return
            }
            Usage.shared.foldPlayback(from: from, to: to, kept: false)
            // Resume-time buckets, all anchored to the fold itself
            // (`at`), not to whichever checkpoint below happens to
            // notice it. Each checkpoint asks "has `lastPlayAt` moved
            // past `at` yet" — the persisted timestamp of the most
            // recent play edge — rather than sampling `holder.isPlaying`:
            // a resume that fires and is immediately paused again,
            // between two checkpoints, still set `lastPlayAt` and so is
            // still caught here, bucketed by its own timing rather than
            // by whether it happens to still be playing when checked.
            // The walk starts at 2 s, one past the 1 s mark `stopped`
            // was decided at, and is checked in order; the first
            // checkpoint where the edge has already landed wins. Past
            // the widest named bucket, one more, generous wait decides
            // `ge5` vs `never`.
            //
            // A cancellation reaching any of these waits — the page
            // swiping away, disappearing, or the app leaving `.active`,
            // same as the entry guard above — means the measurement
            // never got to see an outcome of its own. That still
            // counts as the fold's one resume bucket: `left`, gated by
            // the same session check as every other bucket here, so a
            // measurement orphaned by a session boundary never credits
            // the next session. So every `stopped` gets exactly one
            // resume bucket, named for whichever of these five ways it
            // resolved.
            @MainActor func leftIfCancelled() -> Bool {
                guard Task.isCancelled else { return false }
                if Usage.shared.current.id == sessionID { Usage.shared.foldResumeSeconds(bucket: "left") }
                return true
            }
            let thresholds: [(seconds: Double, bucket: String)] = [(2, "lt2"), (5, "lt5")]
            for (seconds, bucket) in thresholds {
                let remaining = seconds - Date().timeIntervalSince(at)
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                if leftIfCancelled() { return }
                guard Usage.shared.current.id == sessionID else { return }
                if let playAt = self.lastPlayAt, playAt > at { Usage.shared.foldResumeSeconds(bucket: bucket); return }
            }
            let maxWait = 30.0
            let remaining = maxWait - Date().timeIntervalSince(at)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            if leftIfCancelled() { return }
            guard Usage.shared.current.id == sessionID else { return }
            let resumed = self.lastPlayAt.map { $0 > at } ?? false
            Usage.shared.foldResumeSeconds(bucket: resumed ? "ge5" : "never")
        }
    }

    /// Analytics only. Reconstructs this page's playback state at a
    /// past instant from the last play/pause edges — see
    /// `lastPlayAt`'s own doc comment — rather than a fresh
    /// `holder.isPlaying`, which by the time `recordFoldPlayback` runs
    /// (commit time, 1 s after `at`) can have already flipped.
    ///
    /// Only the most recent play and the most recent pause are kept,
    /// so this can only reason about the state around those two edges.
    /// That is always enough in practice: `at` is always a recent
    /// fold moment, within a second or two of whichever edges exist.
    private func wasPlaying(at: Date) -> Bool {
        // Neither edge has fired yet on this page: no transition to
        // read, so the current state is also the state `at` held.
        if lastPlayAt == nil, lastPauseAt == nil { return holder.isPlaying }
        switch (lastPlayAt, lastPauseAt) {
        case (nil, .some(let pause)):
            // Only a pause has ever landed: whatever state came before
            // it (the same default as the no-edges case above) held up
            // until the pause, then stopped.
            return at < pause
        case (.some(let play), nil):
            // Only a play has ever landed: not yet playing before it,
            // playing from it on.
            return at >= play
        case (.some(let play), .some(let pause)) where play > pause:
            // The play is the more recent edge: playing from `play`
            // onward, and also in the stretch before the earlier
            // `pause` — the same state that later play resumed.
            return at >= play || at < pause
        case (.some(let play), .some(let pause)):
            // The pause is the more recent edge: playing only in the
            // gap between `play` and `pause`.
            return at >= play && at < pause
        default:
            return holder.isPlaying   // unreachable: nil/nil is handled above
        }
    }

    /// Entry point for the stage long press (`StageLongPressScrubGesture`).
    /// The first tick of a hold decides which of two things it is, by
    /// where the finger is. Every later tick of the same hold sticks with
    /// that choice.
    /// In fullscreen the whole stage is a fast-forward zone. There is no
    /// scrubbing there at all. The full-bleed canvas's local x is not the
    /// axis `fastForwardEdgeFraction` is measured on (same mismatch as
    /// `handleScrubChanged`'s own comment).
    private func handleStageHold(fraction: Double) {
        if isScrubbing {
            handleScrubChanged(fraction: fraction)
            return
        }
        if isFastForwarding { return }
        let edge = Self.fastForwardEdgeFraction
        let inEdgeZone = fraction <= edge || fraction >= 1 - edge
        if isFullscreen || inEdgeZone {
            isFastForwarding = true
            Usage.shared.holdFastForward()
            holder.setFastForward(true)
        } else {
            handleScrubChanged(fraction: fraction)
        }
    }

    private func endStageHold() {
        if isFastForwarding {
            isFastForwarding = false
            holder.setFastForward(false)
        }
        endScrub()
    }

    private func seekToScrubFraction() {
        let duration = holder.duration
        guard duration.isFinite, duration > 0 else { return }
        let seconds = scrubFraction * duration
        holder.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Ends scrubbing, if it was in progress.
    /// Runs a final, unthrottled seek, so the release position is exact
    /// even if the last `onChanged` tick was swallowed by the 1/30 s
    /// throttle. Then hands playback back to `applyPlaybackState()`, which
    /// respects `wantsPlayback`, so a scrub on a preloaded neighbour never
    /// starts it playing.
    private func endScrub() {
        guard isScrubbing else { return }
        seekToScrubFraction()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            isScrubbing = false
        }
        onScrubbingChanged(false)
        holder.applyPlaybackState()
    }

    /// Owner-reported bug fix (pose 3, wide video): `PHAsset.pixelWidth`/
    /// `pixelHeight` are known the moment PhotoKit resolves the asset
    /// record — metadata, not a decoded frame — so this needs no
    /// player, no `AVPlayerItem`, and therefore no `scrollGate
    /// .waitUntilIdle()` wait at all; `load()`'s own aspect read sits
    /// behind both of those (see `videoIsLandscape`'s own comment).
    /// Runs for every mounted page, not gated on `isPreloadable` the
    /// way `load()` is — the point is to have the real shape ready
    /// well before a page might ever become active, not merely once
    /// it does.
    ///
    /// PhotoKit reports these dimensions already display-oriented
    /// (after the asset's own rotation metadata), the same convention
    /// `AVPlayerItem.presentationSize` uses — see `holder
    /// .presentationSize`'s own `.onChange`, which corrects this
    /// reading in the rare case the two disagree.
    private func loadAssetAspect() async {
        let id = assetID
        let size = await Task.detached(priority: .userInitiated) { () -> CGSize? in
            guard let asset = PhotoLibraryService.fetchAsset(id) else { return nil }
            return CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
        }.value
        guard !Task.isCancelled, let size, size.width > 0, size.height > 0 else { return }
        videoIsLandscape = size.width > size.height
        videoAspectRatio = size.width / size.height
    }

    private func load() async {
        wdMark("load")
        guard isPreloadable else { return }
        isLoading = true
        loadFailed = false
        // Reset at the top of every load, so a stale reading can never
        // outlive its item.
        videoIsLandscape = false
        videoAspectRatio = 9.0 / 16.0
        isReadyForDisplay = false
        // Clears the four probe events, and re-stamps t0 if the page is
        // already active. A Retry tap restarts the whole sequence, rather
        // than reporting it against a t0 several seconds old.
        loadSeq.beginLoad(now: ProcessInfo.processInfo.systemUptime, isActive: isActive)

        // `DeckViewModel` is `nonisolated`, so this request set-up runs
        // off the main actor. The isolation is required: do not wrap this
        // call in a way that re-hops it onto the main actor.
        // The poster does not load here. It has its own
        // `.task(id: posterKey)` and `deliverPoster()`, so a slow item
        // never delays it and a Retry tap never restarts it.
        // PhotoKit delivers progress on an arbitrary thread. Hop to main,
        // and ignore anything that arrives for a page that has moved on.
        let progressKey = taskKey
        guard let item = await viewModel.playerItem(for: assetID, onProgress: { fraction in
            Task { @MainActor in
                guard self.taskKey == progressKey else { return }
                self.downloadFraction = fraction
            }
        }) else {
            if !Task.isCancelled {
                isLoading = false
                loadFailed = true; Usage.shared.videoLoadFailed()
            }
            return
        }
        guard !Task.isCancelled else { return }

        // `item` arrives warmed: its asset's `.isPlayable` and `.duration`
        // were already loaded on the background executor that produced
        // it, bounded at 3 s. This moves the container-parse cost of
        // `replaceCurrentItem(with:)` off the main thread.
        // Nothing may be inserted between the warm-up inside
        // `playerItem(for:)` above and this call, or it would force a
        // fresh, unwarmed parse.
        //
        // The attach is engine work, so it must never happen mid-swipe;
        // see `ScrollPhaseGate`.
        await scrollGate.waitUntilIdle()
        guard !Task.isCancelled else { return }
        holder.configure(with: item)
        holder.setMuted(isMuted)

        let ready = await holder.waitUntilReady()
        guard !Task.isCancelled else { return }

        isLoading = false
        if ready {
            loadFailed = false
            // `presentationSize` is the item's display size, after the
            // track's own `preferredTransform`. A portrait iPhone clip
            // encoded 1920×1080 with a 90° transform is a real, common
            // shape. Only `presentationSize` is guaranteed to describe
            // what the user will actually see.
            // This reads the already-loaded, already-awaited item, so it
            // makes no new PhotoKit fetches. Read off the main thread (see
            // `PlayerHolder.prerollAsNeighbour`), and the duration is
            // cached for the probe and seek math.
            let facts = await Task.detached(priority: .userInitiated) { () -> (CGSize, Double) in
                (item.presentationSize, item.duration.seconds)
            }.value
            guard !Task.isCancelled else { return }
            holder.noteReady(duration: facts.1)
            let size = facts.0
            // Owner-reported bug fix: `holder.presentationSize`'s own
            // `.onChange` (mounted in `body`) is now the PRIMARY writer
            // of `videoIsLandscape`/`videoAspectRatio` — it observes the
            // same `presentationSize` property but starts at attach, in
            // `configure(with:)`, well before this `waitUntilReady()`
            // call above even returns. This write stays as a fallback:
            // harmless whenever the two already agree, and a safety net
            // if the KVO observation were ever missed.
            videoIsLandscape = size.width > size.height && size.width > 0
            // Guards `size.height > 0` the same way `videoIsLandscape`
            // guards `size.width > 0`; a zero reading can only mean
            // `presentationSize` has not actually decoded yet (AVFoundation
            // can report `.zero` or a placeholder size until a frame has
            // decoded — see the probe comment just below), in which case
            // the 9:16 default stands until a later update, if any,
            // reports something real.
            if size.height > 0 {
                videoAspectRatio = size.width / size.height
            }
            // Apple does not publish the size of a proxy video, so this
            // measures the size the player actually shows. It compares
            // that size with the asset's own resolution
            // (`deleted.videos.res.*`).
            // Shipped, not DEBUG-gated. This is one dictionary increment
            // once per load, never per frame, alongside a PhotoKit request
            // and an item build that already cost milliseconds each.
            Usage.shared.videoServed(width: Int(size.width), height: Int(size.height))
            // Marks the asset seen only once the video actually reached a
            // playable state, so a failed iCloud stream stays in the
            // deck.
            viewModel.markSeen(assetID)
            #if DEBUG
            // Latched: the first call wins, and every later call is a
            // no-op, so a page loading on any launch is safe to report
            // from here.
            LaunchProbe.shared.markFirstPlayingFrame()
            #endif
            // Deliberately not `holder.setActive(isActive)`: this task may
            // have started several swipes ago, and its `isActive` is stale.
            holder.applyPlaybackState()
            // This task's own `isActive` may be several swipes stale, so
            // the decision belongs to the holder, not this closure.
            // `prerollAsNeighbour` no-ops on a page the holder knows wants
            // playback.
            // Called after `applyPlaybackState`, so nothing can delay the
            // active page's first frame.
            holder.prerollAsNeighbour()
        } else {
            loadFailed = true
        }
    }

    /// The poster's own delivery, independent of `load()`. A swipe must
    /// always show a frame immediately.
    private func deliverPoster() async {
        guard isPreloadable else { return }
        // A synchronous cache read first, before any suspension point.
        // A warm entry replaces the previous asset's poster in this same
        // body pass. A miss assigns nil, which clears a stale poster when
        // the slot is recycled onto a different video.
        poster = PosterCache.shared.image(for: assetID)
        if poster != nil {
            loadSeq.markPoster()
        }
        // Progressive: the closure runs once with the degraded frame the
        // instant PhotoKit has one, milliseconds, even for a video iCloud
        // has not downloaded. It runs again with the full-quality frame
        // when it arrives. See `PosterCache.poster(for:side:onImage:)`.
        // This must not wait up to 1.5 s for a sharp image as
        // `thumbnail(for:)` does for the trash grid.
        await PosterCache.shared.poster(for: assetID) { image in
            wdMark("posterSet")
            poster = image
            loadSeq.markPoster()
        }
    }

    /// The one place the wait is declared over, and what stamps
    /// `spinnerGoneAt`.
    ///
    /// This assignment runs with no animation suppression. The ring
    /// animates its own exit: the arc completes its circle as it fades,
    /// over 0.22 s, through `CloudDownloadRing.finish()`.
    ///
    /// Nothing else reads `showSpinner` as a visual property. Only the
    /// accessibility flag and the `feed_spinner` marker read it, and both
    /// should go the instant the wait ends. Both are plain booleans that
    /// cannot animate.
    private func hideSpinnerImmediately() {
        guard showSpinner else { return }
        showSpinner = false
        loadSeq.spinnerGoneAt = ProcessInfo.processInfo.systemUptime
    }

    private func toggleMute() {
        isMuted.toggle()
        Usage.shared.muteToggled(nowMuted: isMuted)
        holder.setMuted(isMuted)

        withAnimation {
            showMuteBadge = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation {
                showMuteBadge = false
            }
        }
    }
}

/// Every instant here is `ProcessInfo.processInfo.systemUptime`:
/// monotonic, the same clock `LaunchProbe` uses, unaffected by wall-clock
/// changes. `t0` is the moment the page became active, the moment the
/// user's swipe settled.
private struct LoadSequence {
    var activatedAt: TimeInterval?
    var posterAt: TimeInterval?
    var spinnerAt: TimeInterval?
    var firstFrameAt: TimeInterval?
    var spinnerGoneAt: TimeInterval?

    /// A new item begins loading.
    /// Clears the four events, and re-stamps t0 if the page is already
    /// active. A Retry tap restarts the whole sequence, rather than
    /// reporting it against a t0 several seconds old.
    mutating func beginLoad(now: TimeInterval, isActive: Bool) {
        posterAt = nil; spinnerAt = nil; firstFrameAt = nil; spinnerGoneAt = nil
        activatedAt = isActive ? now : nil
    }

    mutating func activate(_ now: TimeInterval) { activatedAt = now }
    mutating func deactivate() { activatedAt = nil }

    /// Latched: the first non-nil poster assigned, a cache hit or the
    /// first progressive delivery, wins.
    mutating func markPoster() {
        guard posterAt == nil else { return }
        posterAt = ProcessInfo.processInfo.systemUptime
    }

    /// Latched: the first of `isReadyForDisplay` true or `holder.isPlaying`
    /// true wins.
    mutating func markFirstFrame() {
        guard firstFrameAt == nil else { return }
        firstFrameAt = ProcessInfo.processInfo.systemUptime
    }

    /// Milliseconds since t0, clamped at 0. Returns -1 when the event has
    /// not happened, or the page is not active.
    func offset(_ event: TimeInterval?) -> Int {
        guard let activatedAt, let event else { return -1 }
        return max(0, Int(((event - activatedAt) * 1000).rounded()))
    }
}

/// Long-press anywhere on the stage starts scrubbing. This is implemented
/// as a bridged `UILongPressGestureRecognizer`, not as plain SwiftUI
/// gesture code.
///
/// The equivalent SwiftUI gesture,
/// `.simultaneousGesture(LongPressGesture(minimumDuration: 0.35, maximumDistance: 10).sequenced(before: DragGesture(minimumDistance: 0)))`,
/// assumes a swipe travels past 10pt long before 0.35 s. This fails the
/// long press and leaves the pan to the pager. In practice it blocks
/// paging.
/// Measured on iPhone 17 Pro / iOS 26.5, with that modifier attached.
/// Every swipe beginning inside the 9:16 stage produced zero page
/// changes. The identical swipe beginning a few points below the stage
/// paged every time. Without the modifier, paging works at the stage
/// centre.
/// `.simultaneousGesture` only declares simultaneity against other
/// SwiftUI gestures. SwiftUI's composite sequence recognizer still
/// claims the touch at touch-down, before the long press has had its
/// 0.35 s to fail. So `UIScrollView`'s pan never begins.
///
/// A `UILongPressGestureRecognizer` gives the same interaction with the
/// arbitration this needs:
///
/// - It declines to recognize as soon as the finger travels past
///   `allowableMovement`. A swipe is never delayed or swallowed.
/// - Its delegate returns `true` from `shouldRecognizeSimultaneouslyWith`.
///   It never demands exclusivity over the pager's own pan.
/// - After it recognizes, it keeps reporting `.changed` with the
///   finger's live position. Hold-then-drag is one recognizer, not a
///   sequence that hands a live touch to a second gesture.
///
/// Tap-to-mute, the 28pt strip's own `DragGesture`,
/// `.scrollDisabled(isScrubbing)`, and seeking, idle progress, and
/// identifier gating are all unaffected by this choice.
private struct StageLongPressScrubGesture: UIGestureRecognizerRepresentable {
    let minimumDuration: TimeInterval
    let allowableMovement: CGFloat
    /// Width of the stage the recognizer is attached to, so `.local` x can
    /// be turned into the 0...1 fraction `handleScrubChanged` expects.
    /// Passed in rather than read from `recognizer.view`, which is
    /// SwiftUI's own host view and not guaranteed to be the stage.
    let stageWidth: CGFloat
    let onScrubMoved: (Double) -> Void
    let onScrubEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = minimumDuration
        recognizer.allowableMovement = allowableMovement
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.minimumPressDuration = minimumDuration
        recognizer.allowableMovement = allowableMovement
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            onScrubMoved(context.converter.location(in: .local).x / max(stageWidth, 1))
        case .ended, .cancelled, .failed:
            onScrubEnded()
        default:
            break
        }
    }

    /// Exists only to answer `shouldRecognizeSimultaneouslyWith`. Two
    /// recognizers on overlapping views are mutually exclusive by
    /// default, and the pager's pan must never be excluded.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// Owns the `AVPlayer` for a single page.
/// It manages playback state, end-of-item looping, readiness,
/// audio-interruption recovery, and observer cleanup. A fresh instance is
/// created for each page.
@MainActor
private final class PlayerHolder: ObservableObject {
    let player = AVPlayer()

    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    /// What the page currently wants playback to be doing.
    /// The view keeps this current for every change of `isActive`,
    /// including the first.
    private var wantsPlayback = false
    /// The rate playback runs at whenever this holder plays: 1 normally,
    /// 2 while the user holds an edge of the stage.
    /// Every resume path (`applyPlaybackState`, `loop`, the interruption
    /// recovery) reads it. So a loop wrap or a phone call mid-hold does
    /// not silently drop back to 1x while the finger is still down.
    private var playbackRate: Float = 1

    /// The forward buffer kept for a neighbour page, so its download
    /// keeps running ahead of the user reaching it.
    private static let neighbourForwardBuffer: TimeInterval = 4.0

    /// True once this holder has issued a preroll for the current item
    /// and has not yet cancelled it. One preroll per item, so a body pass
    /// or a repeated readiness edge cannot stack requests.
    private var hasPrerolled = false

    /// True while `AVPlayer.timeControlStatus == .playing`: Apple's own
    /// signal that playback is currently progressing, distinct from a
    /// non-zero rate that is still waiting on a buffer.
    /// Published so `PlayerPageView` can take the spinner away the
    /// instant playback really starts, without polling a non-observable
    /// AVFoundation property from a body.
    @Published private(set) var isPlaying = false
    private var rateObservation: NSKeyValueObservation?

    /// `AVPlayerItem.presentationSize`, observed from the moment
    /// `configure(with:)` attaches the item — see that method's own
    /// `presentationObservation` for why this needs no "ready for
    /// display" gate of its own to start reporting a real value.
    /// `PlayerPageView` reads this `@Published` to set `videoIsLandscape`/
    /// `videoAspectRatio` as early as AVFoundation itself allows, rather
    /// than only once `load()`'s own later, slower read completes — see
    /// that `.onChange`'s own comment for the owner-reported bug this
    /// fixes (pose 3 wide video resizing right after a swipe).
    @Published private(set) var presentationSize: CGSize = .zero

    private func setIsPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
    }

    /// Flips the fast-forward rate on or off.
    /// Takes effect immediately if the player is currently playing;
    /// otherwise it is picked up by the next resume. Never starts
    /// playback on its own: a hold on a paused or preloaded neighbour
    /// page must not start it playing.
    func setFastForward(_ on: Bool) {
        playbackRate = on ? 2 : 1
        if wantsPlayback && !isSuspended {
            let rate = playbackRate
            Self.playerWorkQueue.async { [player] in player.rate = rate }
        }
    }

    // MARK: - Idle scrub progress

    /// A value from 0 to 1, updated by a 0.5 s periodic time observer
    /// added in `configure(with:)` and removed in `release()` and
    /// `deinit`.
    /// `PlayerPageView` reads it as `@Published` state instead of
    /// polling `player.currentTime()` from its own body.
    ///
    /// Every tick publishes, wrapped in `withAnimation(.linear(duration:
    /// 0.5))` in `publishProgress`, so the line glides continuously
    /// between ticks instead of jumping in visible steps. A 0.5 s tick
    /// keeps the observer cost low. The animation, not a faster tick,
    /// makes the line move smoothly. A loop wrap, or any backward seek,
    /// snaps instead of animating — see `publishProgress`.
    @Published private(set) var progress: Double = 0
    /// The player's real position as a 0...1 fraction, with no lookahead
    /// and no animation.
    /// `progress` above is the drawn line, and deliberately runs one tick
    /// (0.5 s × rate) ahead so it reaches the end together with the clip.
    /// Anything that needs the true position, such as the
    /// `scrubber_probe_` identifier, must use this property instead.
    @Published private(set) var actualProgress: Double = 0
    private var timeObserverToken: Any?

    /// The item handed to `configure(with:)`, kept here because the
    /// attach itself completes later on `playerWorkQueue`. See
    /// `configure`.
    private(set) var attachedItem: AVPlayerItem?

    /// Read by the DEBUG scrubber probe on every body pass.
    /// `AVPlayerItem.duration` returns `.indefinite`, a non-finite
    /// `CMTime`, before the item is ready. Cached by `load()` once the
    /// item is ready, and read off the main thread. So the DEBUG scrubber
    /// probe and the seek math never touch the item on the main thread.
    /// See `prerollAsNeighbour` for why that matters.
    private(set) var cachedDuration: Double = 0
    /// True from the moment `waitUntilReady()` succeeded until the next
    /// `configure` or `release`. The main-thread stand-in for
    /// `item.status`.
    private(set) var isItemReady = false

    // MARK: - Showing the user when the player is waiting
    //
    // Setting a non-zero rate moves the player to
    // `waitingToPlayAtSpecifiedRate` or `playing`. Which one depends on
    // whether enough media has buffered (AVPlayer.h).
    // `automaticallyWaitsToMinimizeStalling` has defaulted to true since
    // iOS 10, so a non-zero rate does not mean the video is actually
    // advancing.
    //
    // `isPlaying` must not be derived from `rate > 0`. The rate is
    // non-zero throughout a buffering wait too, so a frozen page would
    // report itself as playing and no loader would appear.
    // `timeControlStatus` tells the three states apart.
    //
    // `play()`, not `setRate:1.0`, starts playback: AVPlayer.h says a
    // direct rate set is no longer recommended for that purpose. `rate`
    // is set directly only for the 2x hold.

    /// True only while AVPlayer reports `waitingToPlayAtSpecifiedRate`:
    /// it wants to play and cannot yet. It has one writer, the
    /// `timeControlStatus` observation, so it always matches the current
    /// `timeControlStatus`.
    @Published private(set) var isWaitingForBuffer = false

    private func setWaitingForBuffer(_ waiting: Bool) {
        guard isWaitingForBuffer != waiting else { return }
        isWaitingForBuffer = waiting
    }
    /// Counts a real mid-play starve. Observation only: nothing acts on
    /// it, because `automaticallyWaitsToMinimizeStalling` already handles
    /// the recovery.
    private var bufferEmptyObservation: NSKeyValueObservation?
    /// Publishes `presentationSize` above and, in DEBUG, the on-screen
    /// resolution readout — both from the same KVO subscription, started
    /// in `configure(with:)` rather than waited for: `presentationSize`
    /// can change after the item is ready, so it is observed rather than
    /// read once, and shipped unconditionally now rather than only in
    /// DEBUG, since `PlayerPageView` depends on it for real layout.
    private var presentationObservation: NSKeyValueObservation?

    func noteReady(duration: Double) {
        cachedDuration = duration.isFinite && duration > 0 ? duration : 0
        isItemReady = true
    }

    var duration: Double { cachedDuration }

    /// Mute is a player mutation too, so it runs on the same queue as
    /// attach, rate, and seek, to avoid racing them.
    func setMuted(_ muted: Bool) {
        Self.playerWorkQueue.async { [player] in player.isMuted = muted }
    }

    /// Scrub entry: pause on the work queue like every other mutation.
    func pauseForScrub() {
        Self.playerWorkQueue.async { [player] in player.pause() }
    }

    /// The scrubber's own seek. `PlayerPageView` computes the target
    /// `CMTime`, since it owns the throttling and the finger-driven
    /// fraction, and hands it straight to `AVPlayer.seek`. Zero tolerance
    /// in both directions makes the playhead land exactly where the
    /// finger is, not merely near it.
    func seek(to time: CMTime) {
        Self.playerWorkQueue.async { [player] in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleInterruption(note)
            }
        }
        // KVO can deliver on any thread, so this hops to main before
        // touching main-actor state, the same shape
        // `PlayerLayerContainerView` uses for `isReadyForDisplay`.
        //
        // This observes `timeControlStatus`, not `rate`. A non-zero rate
        // is also true while the player sits in
        // `waitingToPlayAtSpecifiedRate`, so a frozen page could report
        // itself as playing and no loader would appear.
        // `timeControlStatus` is the property that tells the three
        // states apart, and it is what the loader follows.
        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            // A brief buffering-rate evaluation is not a wait worth a
            // loader.
            let evaluating = player.reasonForWaitingToPlay == .evaluatingBufferingRate
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.setIsPlaying(status == .playing)
                    self?.setWaitingForBuffer(status == .waitingToPlayAtSpecifiedRate && !evaluating)
                }
            }
        }
    }

    func configure(with item: AVPlayerItem) {
        wdMark("attach")
        removeEndObserver()
        removeTimeObserver()
        attachedItem = item
        isItemReady = false
        cachedDuration = 0
        // Started here, at attach, not waited for: this is what lets
        // `presentationSize` reach `PlayerPageView` before `load()`'s own
        // later, "ready for display"-gated read does — see that
        // property's own comment.
        presentationObservation?.invalidate()
        presentationObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] observed, _ in
            let size = observed.presentationSize
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.presentationSize = size
                    #if DEBUG
                    PlaybackReadout.shared.notePlayed(size)
                    #endif
                }
            }
        }
        // A paused neighbour under the automatic buffer policy (0) fills
        // only enough to reach `.readyToPlay` and then stops. There is no
        // forward playback for the automatic policy to run ahead of.
        // An explicit forward buffer keeps the download running while
        // the user watches the page in front of it. Set at attach, not
        // at readiness: attach is when the item starts loading, so a
        // value applied later misses the seconds that matter most. The
        // active page keeps the automatic policy, since a hand-picked
        // value is wrong once playback is real.
        let initialBuffer: TimeInterval = wantsPlayback ? 0 : Self.neighbourForwardBuffer
        Self.playerWorkQueue.async { item.preferredForwardBufferDuration = initialBuffer }
        hasPrerolled = false
        isWaitingForBuffer = false   // The observation reports it again for the new item.
        // This has defaulted to true since iOS 10. It is what makes a
        // non-zero rate wait for a healthy buffer rather than start on an
        // empty one. Set explicitly, so the behaviour the loader reports
        // is stated, not assumed.
        Self.playerWorkQueue.async { [player] in player.automaticallyWaitsToMinimizeStalling = true }
        // Counts a real mid-play starve, and only that.
        // `isPlaybackBufferEmpty` is also true at the end of every clip.
        // So comparing the time against the duration here, off the main
        // thread, excludes the end from the count. KVO delivers on any
        // thread; the count hops to main.
        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { observed, _ in
            guard observed.isPlaybackBufferEmpty else { return }
            let duration = observed.duration.seconds, now = observed.currentTime().seconds
            guard duration.isFinite, duration > 0, now.isFinite, now < duration - 0.5 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Usage.shared.videoStalledMidPlay() }
            }
        }
        // `replaceCurrentItem` parses an iCloud asset on the calling
        // thread. Every player mutation goes through the serial
        // `playerWorkQueue` — attach, rate, pause, seek-to-start, detach
        // — so they stay ordered and never run on the main thread. Reads
        // and the observers stay here. `attachedItem` is what
        // main-thread code uses instead of `player.currentItem`, which is
        // nil until the queue catches up.
        Self.playerWorkQueue.async { [player] in
            player.replaceCurrentItem(with: item)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` above guarantees this closure runs on the main
            // queue, so it is safe to assume MainActor isolation here.
            MainActor.assumeIsolated {
                self?.loop()
            }
        }
        progress = 0
        actualProgress = 0
        // `queue: .main` makes the closure below main-actor-isolated, the
        // same way the end-of-item observer above is. See the property
        // doc above for this observer's tick rate.
        // Registered from the work queue, since this is engine work; the
        // token comes back to the main actor. Callbacks still land on
        // `.main`.
        let generation = observerGeneration
        Self.playerWorkQueue.async { [player, weak self] in
            let token = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    self?.publishProgress(at: time)
                }
            }
            Task { @MainActor [weak self] in
                guard let self, generation == self.observerGeneration else {
                    // Superseded while registering: unregister on the queue.
                    Self.playerWorkQueue.async { player.removeTimeObserver(token) }
                    return
                }
                self.timeObserverToken = token
            }
        }
    }

    /// Bumped by every `configure` or `release`, so the generation check
    /// drops a time observer for an item that a later `configure` or
    /// `release` already replaced.
    private var observerGeneration = 0

    /// Publishes the new fraction, animated, except for a loop wrap or
    /// any other backward jump, which snaps instantly.
    /// Without that guard, `loop()`'s seek to zero would animate the line
    /// crawling backwards across the whole bar over half a second instead
    /// of resetting immediately.
    ///
    /// Each tick animates toward where the player will be one tick from
    /// now: current time + 0.5 s × rate, with 2x holds counting double.
    /// So the line arrives at the true position exactly as the player
    /// does, and at 1.0 exactly as the clip ends. Paused, at rate 0,
    /// there is no lookahead: the line snaps.
    private func publishProgress(at time: CMTime) {
        let seconds = time.seconds
        let total = duration
        guard seconds.isFinite, total > 0 else { return }
        // This observer runs on the main queue every 0.5 s. `player.rate`
        // is an engine read, so the intended rate is used here instead,
        // which is already known without touching the engine.
        let rate = (wantsPlayback && !isSuspended) ? Double(playbackRate) : 0
        let lookahead = rate > 0 ? 0.5 * rate : 0
        actualProgress = min(max(seconds / total, 0), 1)
        let fraction = min(max((seconds + lookahead) / total, 0), 1)
        guard fraction != progress else { return }
        if fraction < progress || lookahead == 0 {
            progress = fraction
        } else {
            withAnimation(.linear(duration: 0.5)) {
                progress = fraction
            }
        }
    }

    /// Suspends until the current item is ready to play or fails, or
    /// until 20 s pass. So a stalled iCloud download shows a retry state
    /// instead of hanging the spinner forever.
    func waitUntilReady() async -> Bool {
        guard let item = attachedItem ?? player.currentItem else { return false }
        // No `item.status` reads here on the main actor. The stream
        // below yields `.initial` first, so the already-ready case
        // resolves on its first element.

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await status in Self.statusUpdates(for: item) {
                    if status == .readyToPlay { return true }
                    if status == .failed { return false }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Status changes as a buffered stream, driven by classic KVO.
    ///
    /// Not `item.publisher(for: \.status).values`: `AsyncPublisher`
    /// re-requests demand only after handing over each element, and
    /// Combine's KVO publisher drops a change that lands while no demand
    /// is outstanding. The item reaches `.readyToPlay` about 150 ms after
    /// it is attached, inside that gap, which can drop the one transition
    /// this method exists to catch. `AsyncStream` buffers instead, so
    /// nothing is lost between iterations.
    private nonisolated static func statusUpdates(for item: AVPlayerItem) -> AsyncStream<AVPlayerItem.Status> {
        AsyncStream { continuation in
            let observation = item.observe(\.status, options: [.initial, .new]) { observed, _ in
                continuation.yield(observed.status)
            }
            continuation.onTermination = { _ in observation.invalidate() }
        }
    }

    /// Records what the page wants playback to be doing, and applies it.
    func setActive(_ active: Bool) {
        wdMark("setActive")
        wantsPlayback = active
        // Cancel before applying, re-arm after. A page that becomes
        // active must not carry a pending preroll into its own
        // `rate = playbackRate`. A page that stops being active becomes
        // a neighbour again, and is prerolled for the swipe back.
        if active { endNeighbourPreroll() }
        applyPlaybackState()
        if !active { prerollAsNeighbour() }
        wdMark("setActiveEnd")
    }

    /// Primes this neighbour's decode pipeline, so its first frame is
    /// decoded, and its own `AVPlayerLayer` already reports
    /// `isReadyForDisplay`, before the user swipes to it.
    /// It adds no decode pipeline: it primes the one the attached item
    /// already occupies.
    ///
    /// Every guard below is required. `prerollAtRate:` throws if the
    /// player's status is not `.readyToPlay` (AVPlayer.h), not the item's
    /// status that `waitUntilReady()` observes, and is valid only at
    /// rate 0. The `wantsPlayback` and `isSuspended` pair keeps this to
    /// neighbours. `applyPlaybackState` is about to set a real rate on
    /// the active page. A page under a sheet must not decode at all.
    func prerollAsNeighbour() {
        wdMark("preroll")
        guard !wantsPlayback, !isSuspended, !hasPrerolled, isItemReady, let item = attachedItem else { return }
        // Any call into AVFoundation from the main thread can wait on the
        // engine. This includes reads of `status` or `rate` and property
        // sets on the item, while the work queue is attaching or tearing
        // down an iCloud item.
        // So nothing below touches the player or the item on this
        // thread. The readiness checks use the cached `isItemReady`. The
        // buffer set runs on the work queue with the preroll itself.
        //
        // Re-applies the neighbour buffer here, so a page that becomes a
        // neighbour again regains it; attach sets it only once.
        Self.playerWorkQueue.async {
            item.preferredForwardBufferDuration = Self.neighbourForwardBuffer
        }
        hasPrerolled = true
        // `preroll(atRate:)` is not free on the calling thread. This
        // call site runs the instant a page stops being the active page,
        // while the new page starts its own decode.
        // Re-checks the guards after a 300 ms delay, which gives the new
        // page time to itself. Then it issues the preroll from the
        // player work queue, never the main thread.
        // `prerollGeneration` lets `endNeighbourPreroll()` invalidate a
        // delayed preroll that has not fired yet.
        prerollGeneration += 1
        let generation = prerollGeneration
        Self.playerWorkQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hasPrerolled, generation == self.prerollGeneration,
                      !self.wantsPlayback, !self.isSuspended else { return }
                let player = self.player
                Self.playerWorkQueue.async {
                    // The engine-side checks run here, on the work queue.
                    guard player.status == .readyToPlay, player.rate == 0,
                          player.currentItem?.status == .readyToPlay else { return }
                    player.preroll(atRate: 1) { _ in
                        // `finished == false` only means this preroll was
                        // superseded, by a time change, an incompatible
                        // rate change, or `cancelPendingPrerolls()`. Each
                        // of those is a state change this page acts on by
                        // other means.
                    }
                }
            }
        }
    }

    /// Bumped on every scheduled preroll and on every cancel, so a
    /// delayed preroll scheduled before a cancel never fires after it.
    private var prerollGeneration = 0

    /// Called the instant this page becomes the active one, before
    /// `applyPlaybackState()` sets a rate, and on release.
    /// Cancelling first keeps a pending preroll from racing the real
    /// `rate = playbackRate` that is about to follow.
    func endNeighbourPreroll() {
        // Runs unconditionally, above the `hasPrerolled` guard.
        // `configure(with:)` sets the neighbour buffer at attach, before
        // `player.status == .readyToPlay` can even be checked. So a page
        // whose preroll guard never passed still carries that value into
        // `setActive(true)`. The active page must return to
        // AVFoundation's automatic buffer policy regardless of whether a
        // preroll ever actually started.
        wdMark("bufDur0")
        if let item = attachedItem {
            Self.playerWorkQueue.async { item.preferredForwardBufferDuration = 0 }
        }
        prerollGeneration += 1
        guard hasPrerolled else { return }
        hasPrerolled = false
        wdMark("cancelPreroll")
        Self.playerWorkQueue.async { [player] in player.cancelPendingPrerolls() }
    }

    /// True while `FeedView` has a sheet up that can play its own video:
    /// the bin's preview, or the shrink preview. The feed page pauses in
    /// place and resumes when the sheet goes away.
    /// Independent of `wantsPlayback`: a page that is suspended and then
    /// swiped away still rewinds through `setActive(false)`, like any
    /// other.
    private var isSuspended = false

    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        // A sheet with its own video is up (bin preview, shrink preview):
        // stop priming a pipeline nobody is about to look at.
        if suspended { endNeighbourPreroll() }
        applyPlaybackState()
        if !suspended { prerollAsNeighbour() }
    }

    /// Applies the page's current intent to the player.
    ///
    /// Reads the intent from here, rather than taking one as a parameter.
    /// `PlayerPageView.load()` runs as an async task holding the view
    /// value it captured when the task began. And `taskKey` deliberately
    /// excludes `isActive`, so activating a page does not discard an
    /// in-flight preload. A slow load can therefore finish carrying an
    /// `isActive` from several swipes earlier. Acting on that stale value
    /// could start an already-scrolled-past page playing off screen, on
    /// top of the video actually shown.
    /// The view keeps `wantsPlayback` current through `setActive` for
    /// every change, including the initial one, so this is always the
    /// live answer.
    func applyPlaybackState() {
        guard wantsPlayback else {
            wdMark("pauseSeek0")
            Self.playerWorkQueue.async { [player] in
                player.pause()
                player.seek(to: .zero)
            }
            return
        }
        // Suspended, a sheet is up: hold position, with no rewind, so
        // the user comes back to the same frame they left.
        guard !isSuspended else {
            Self.playerWorkQueue.async { [player] in player.pause() }
            return
        }
        // Activates the audio session lazily, on first real playback,
        // rather than at app launch, and re-activates it here after any
        // interruption cleared the session.
        // With no item there is nothing to play yet, and claiming the
        // session now would interrupt audio the user already had running.
        guard attachedItem != nil else { return }
        wdMark("audioSession")
        // `setActive(true)` is an inter-process call to mediaserverd and
        // blocks for hundreds of milliseconds, so it runs on the work
        // queue rather than the main thread. On the serial work queue it
        // still precedes the rate set below.
        Self.playerWorkQueue.async { try? AVAudioSession.sharedInstance().setActive(true) }
        // `play()` starts normal speed, because it waits for a buffer
        // and recovers from a starve on its own. A direct `rate =` is
        // only for a live 2x hold, which by definition applies to a
        // video already playing. So there is nothing to wait for.
        wdMark("rateStart")
        startPlayback()
    }

    /// The one way this class starts or resumes playback.
    /// `play()` runs at normal speed, because AVPlayer.h says a direct
    /// `setRate:1.0` is no longer recommended for starting playback. A
    /// direct rate set is used only for a live 2x hold.
    /// The first play, a loop wrap, and the recovery after an
    /// interruption all come through here. So none of them can drop a
    /// hold or fall out of sync with it.
    private func startPlayback() {
        let rate = playbackRate
        Self.playerWorkQueue.async { [player] in
            if rate == 1 { player.play() } else { player.rate = rate }
        }
    }

    /// Fully releases the decoded item, not just pausing. So a page
    /// outside the preload window stops occupying one of the process's
    /// limited concurrent hardware video decode pipelines.
    func release() {
        wdMark("release")
        endNeighbourPreroll()      // The item is about to go away.
        let loggedItem = attachedItem   // Read below, after the detach.
        // This observation belongs to this item. Leaving it live would
        // keep reporting a starve for a clip nobody is watching.
        // `configure` installs a fresh one for the next item.
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        // Shipped unconditionally now — see `presentationObservation`'s
        // own comment on why this is no longer DEBUG-only.
        presentationObservation?.invalidate()
        presentationObservation = nil
        presentationSize = .zero
        attachedItem = nil
        isItemReady = false
        cachedDuration = 0
        Self.playerWorkQueue.async { [player] in player.pause() }
        removeEndObserver()
        removeTimeObserver()
        progress = 0
        actualProgress = 0
        // A swipe that pushes a page behind the old one out of the ±1
        // window detaches its item. That item is an iCloud stream whose
        // pipeline was live a moment ago. `replaceCurrentItem(with: nil)` is a
        // synchronous teardown, so it must not run on the main thread.
        // The detach runs on a serial background queue instead; the
        // player object stays owned here, and nothing on this page reads
        // the item after release.
        let player = self.player
        Self.playerWorkQueue.async {
            player.replaceCurrentItem(with: nil)
            // AVFoundation's own playback log is the only thing that
            // tells the two causes of uneven playback apart. Frames
            // dropped with no stalls mean something else took the video
            // decoder. Stalls mean the data ran out.
            //
            // Read the log last, on this same queue. Do not use
            // `Task.detached`: it would hold the item past release. Do
            // not use a second queue: no two queues may touch one
            // `AVPlayerItem` at once; see the single-serial-queue rule on
            // `playerWorkQueue`. The detach runs first, so reading the
            // log after it does not delay freeing the pipeline or the
            // next page's preroll. The item is already off the player by
            // the time this code runs.
            guard let item = loggedItem else { return }
            guard let events = item.accessLog()?.events, !events.isEmpty else {
                Task { @MainActor in Usage.shared.videoNoPlaybackLog() }
                return
            }
            // Every event, not just the last: a looping clip appends one per
            // wrap, so `.last` would report the final loop alone.
            let stalls = events.reduce(0) { $0 + $1.numberOfStalls }
            let dropped = events.reduce(0) { $0 + $1.numberOfDroppedVideoFrames }
            let watched = events.reduce(0.0) { $0 + max($1.durationWatched, 0) }
            // A neighbour that only prerolled never played: its frames are
            // not the user's experience and would land in the numerator
            // with no denominator.
            guard watched > 0.5 else { return }
            Task { @MainActor in
                Usage.shared.videoPlaybackLog(stalls: stalls, droppedFrames: dropped, secondsWatched: watched)
            }
        }
    }

    /// One serial queue for every player mutation on every page, so they
    /// stay ordered and never run on the main thread. See `release()`.
    static let playerWorkQueue = DispatchQueue(label: "com.cloudfull.player-work", qos: .utility)


    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            break // The system already paused the player.
        case .ended:
            guard let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                Self.playerWorkQueue.async { try? AVAudioSession.sharedInstance().setActive(true) }
                if wantsPlayback && !isSuspended { startPlayback() }
            }
        @unknown default:
            break
        }
    }

    private func loop() {
        Usage.shared.videoLooped()
        Self.playerWorkQueue.async { [player] in player.seek(to: .zero) }
        // Snaps the line to 0 here, rather than waiting up to one tick
        // for the periodic observer to notice the seek. Otherwise it
        // would park at the end for up to half a second on every loop
        // wrap.
        progress = 0
        actualProgress = 0
        if wantsPlayback && !isSuspended { startPlayback() }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func removeTimeObserver() {
        observerGeneration += 1
        if let timeObserverToken {
            Self.playerWorkQueue.async { [player] in player.removeTimeObserver(timeObserverToken) }
        }
        timeObserverToken = nil
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let timeObserverToken {
            let player = self.player
            Self.playerWorkQueue.async { player.removeTimeObserver(timeObserverToken) }
        }
        rateObservation?.invalidate()
        bufferEmptyObservation?.invalidate()
    }
}

/// A thin `UIViewRepresentable` around an `AVPlayerLayer`-backed view,
/// aspect-fit on black by default, with no default AVKit controls to
/// interfere with the app's own tap-to-mute gesture.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Forwards the layer's own `isReadyForDisplay` up to
    /// `PlayerPageView`, which fades its poster image out the instant
    /// the real video has a frame to paint.
    let onReadyForDisplay: (Bool) -> Void
    /// True only while the pager is idle and this page is in the preload
    /// window. Passed as a plain input, so SwiftUI re-runs `updateUIView`
    /// when it flips. False disconnects the layer from the player.
    let attach: Bool
    /// `PlayerPageView.fillsScreenInFullscreen`, passed straight
    /// through — Opus wireframe compare, pose 1H: "wide video FILLS
    /// the screen, as today." `.resizeAspectFill` crops edge to edge
    /// instead of letterboxing, but the Duo's own 1H only — owner
    /// correction: a regular iPhone's own fullscreen keeps today's
    /// FIT, since its screen is not the video's own shape and FILL
    /// would crop there. Read again, live, in `updateUIView` below:
    /// this stable `PlayerLayerContainerView` instance persists across
    /// the fullscreen flip on purpose (see `stageContent`'s own
    /// comment on why), so the gravity has to update in place rather
    /// than at creation only.
    let fillsScreen: Bool

    func makeUIView(context: Context) -> PlayerLayerContainerView {
        let view = PlayerLayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
        view.onReadyForDisplay = onReadyForDisplay
        // `hookUp` connects only when `attach` is true. `attach` is false
        // mid-swipe, when `makeUIView` usually runs: it runs exactly when
        // a new page scrolls into the lazy stack.
        hookUp(view)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerContainerView, context: Context) {
        wdMark("layerUpdate")
        hookUp(uiView)
        uiView.onReadyForDisplay = onReadyForDisplay
        let gravity: AVLayerVideoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }
    }

    /// Reading `playerLayer.player` on every SwiftUI update would wait
    /// on the engine lock. The container remembers the player it
    /// received (`assignedPlayer`), so no update ever asks the layer.
    /// The assignment itself happens only while the pager is idle.
    private func hookUp(_ view: PlayerLayerContainerView) {
        // Connects once, at idle, and never disconnects while the page
        // lives; the container's `deinit` does that.
        // Disconnecting a layer from a playing player is engine work on
        // the main thread. So this must not set the player to nil at
        // scroll start and reconnect it at idle.
        guard attach, view.assignedPlayer !== player else { return }
        view.assignedPlayer = player
        // On the main thread, deliberately: `AVPlayerLayer.player` is
        // not documented thread-safe. The cost is accepted because this
        // runs once per page, at idle, never mid-swipe.
        view.playerLayer.player = player
    }
}

private final class PlayerLayerContainerView: UIView {
    /// The player last assigned to `playerLayer`. See
    /// `PlayerLayerView.hookUp`.
    weak var assignedPlayer: AVPlayer?
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    deinit {
        // Disconnects explicitly, on the main thread, before the layer
        // goes. Never let dealloc detach it implicitly.
        playerLayer.player = nil
    }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }

    /// `isReadyForDisplay` flips from false to true only once the layer
    /// actually has a decoded frame to paint for the current item.
    /// AVFoundation resets it whenever a new item lands on the player.
    /// So it is the exact signal `PlayerPageView` needs to know when the
    /// poster underneath can fade away.
    var onReadyForDisplay: ((Bool) -> Void)?
    private var readyForDisplayObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        readyForDisplayObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            DispatchQueue.main.async {
                self?.onReadyForDisplay?(layer.isReadyForDisplay)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
