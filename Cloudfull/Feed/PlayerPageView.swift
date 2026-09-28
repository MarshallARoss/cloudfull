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
    /// The device's raw physical stance, fed from `OrientationMonitor`
    /// through `FeedView`. This value is not gated by any other condition.
    /// `isFullscreen` below applies `fullscreenAllowed` and the other rules,
    /// so the DEBUG probe can always report the stance the app actually saw.
    let deviceStance: Stance
    /// False while a sheet is up (trash, share, album picker, shrink
    /// confirm). Passed as its own parameter, separate from `deviceStance`,
    /// for the same reason: the raw stance and the allowed state can differ.
    let fullscreenAllowed: Bool
    /// Reports fullscreen state to `FeedView`, which applies
    /// `.scrollDisabled(isScrubbing || isFullscreen)` and hides the global
    /// chrome. Its shape matches `onScrubbingChanged`.
    let onFullscreenChanged: (Bool) -> Void
    /// The device's real top safe-area inset, measured by `FeedView` above
    /// the pager's `.ignoresSafeArea()`.
    /// This page's own `GeometryReader` sits under that modifier, so it
    /// reports `safeAreaInsets.top == 0`. Use this parameter instead, so the
    /// video moves down by the same amount as the top chrome.
    /// `FeedView.topChrome` uses the same measurement.
    let safeAreaTop: CGFloat
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

    /// Set once per successful `load()`, from `AVPlayerItem.presentationSize`:
    /// the display size, after the track's own `preferredTransform`.
    /// Resets to `false` at the top of every `load()`, and whenever the
    /// page leaves the preload window. A stale reading can never outlive
    /// its item.
    @State private var videoIsLandscape = false
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
    /// Resets to `false` only when `deviceStance` returns to portrait (the
    /// period ends) or `assetID` changes (a new video is a new decision).
    @State private var dismissedThisSpell = false

    /// Computed, not stored, so there is no state machine that can fall out
    /// of sync: every exit path works by making one term here false.
    /// `!isScrubbing` is a safety interlock: a scrub in flight has the pager
    /// `.scrollDisabled` and a `UILongPressGestureRecognizer` reading a
    /// fraction computed from an unrotated `stageWidth`. Ending the
    /// landscape period, rather than rotating a live scrub's coordinate
    /// space, is correct. A finger on the screen means the user is not
    /// rotating the phone.
    private var isFullscreen: Bool {
        isActive && videoIsLandscape && deviceStance.isLandscape && fullscreenAllowed
            && !dismissedThisSpell && !isScrubbing
    }

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
            // The fixed 9:16 stage.
            // Width is always this page's own full width. Height is always
            // width times 16/9, vertically centred. Both come only from
            // `proxy.size` and the 16:9 constant, never from the loaded
            // video's own dimensions. `proxy.size` tracks the screen,
            // since this page fills it. The bands above and below the
            // stage stay pixel-identical whatever plays next.
            // A video that is not 9:16 still letterboxes or pillarboxes
            // inside this box, through the `.resizeAspect` gravity in
            // `PlayerLayerView`.
            let stageWidth = proxy.size.width
            let stageHeight = stageWidth * 16 / 9
            // In fullscreen the canvas is the screen's own dimensions with
            // width and height swapped: a landscape-shaped box sized
            // `screenHeight × screenWidth`. It lays out un-rotated at that
            // size, then rotates ±90° below.
            // The rendered, post-rotation bounding box works out to exactly
            // `screenWidth × screenHeight`, the pager cell this page
            // already fills. Nothing overflows the `ScrollView`'s clip, and
            // no second presentation layer is needed. Outside fullscreen
            // this matches the 9:16 stage exactly.
            let canvasWidth = isFullscreen ? proxy.size.height : stageWidth
            let canvasHeight = isFullscreen ? proxy.size.width : stageHeight
            // A symmetric split of the space left over around
            // `canvasHeight`. This uses the same formula as
            // `FeedView.stageBandHeight`, computed locally here because
            // `ScrubberView`'s seam placement needs it and `FeedView`'s copy
            // is private to that type.
            // This is all the fullscreen canvas ever uses. Its centring
            // has nothing to do with the 9:16 stage or the island, so
            // `downShift` below is always zero for it.
            let halfLeftover = max(0, (proxy.size.height - canvasHeight) / 2)
            // Shifts the resting 9:16 stage down by the same amount
            // `FeedView.topBandHeight` adds to its own top band. The
            // video and the top chrome above it then never disagree about
            // where that edge is. See `StageGeometry.downShift`'s own comment for
            // the island-overlap problem this avoids. Zero in fullscreen: a
            // rotated landscape video has no top chrome above it to make
            // room for.
            // `safeAreaTop` is the parameter passed down from `FeedView`,
            // not `proxy.safeAreaInsets.top`, which reads 0 under the
            // pager's `.ignoresSafeArea()`. See the parameter's own comment.
            let downShift = isFullscreen ? 0 : StageGeometry.downShift(safeAreaTop: safeAreaTop, containerSize: proxy.size)
            let topSpace = halfLeftover + downShift
            // The black band this page leaves below the stage, reflecting
            // the down-shifted stage rather than a flat symmetric split.
            // `ScrubberView`'s idle-state seam reads this value, so its
            // line stays inside the real bottom band instead of drifting
            // into the video.
            let bottomSpace = isFullscreen
                ? halfLeftover
                : StageGeometry.bottomBand(safeAreaTop: safeAreaTop, containerSize: proxy.size)
            ZStack {
                Color.black

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
                    stageContent(bottomBand: bottomSpace)
                        .frame(width: canvasWidth, height: canvasHeight)
                        .clipped()
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
                        .overlay(alignment: .bottom) {
                            if !isFullscreen {
                                ScrubberView(
                                    progress: holder.progress,
                                    isScrubbing: isScrubbing,
                                    scrubFraction: scrubFraction,
                                    durationSeconds: holder.duration,
                                    bandHeight: bottomSpace,
                                    isActive: isActive,
                                    reduceMotion: reduceMotion,
                                    onStripDrag: handleScrubChanged,
                                    onStripEnded: endScrub
                                )
                            }
                        }
                        // One transition, in both directions, on the stage
                        // frame and the rotation angle.
                        // No Reduce Motion branch: the rotation shows the
                        // state change, so it runs even with Reduce Motion
                        // on, like pager paging.
                        .rotationEffect(isFullscreen ? deviceStance.contentRotation : .zero)
                        .animation(.easeInOut(duration: 0.25), value: isFullscreen)
                        .animation(.easeInOut(duration: 0.25), value: deviceStance.contentRotation)
                    Color.clear.frame(height: bottomSpace)
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
        // `initial: true` so the holder knows this page's intent from the
        // moment it exists, not only once that intent next changes.
        // The holder's stored intent, never a value captured by an async
        // task, decides whether playback starts.
        .onChange(of: isActive, initial: true) { _, newValue in
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
        .onChange(of: isFullscreen) { _, on in if on { Usage.shared.fullscreenEntered() } }
        .onChange(of: isFullscreen) { _, newValue in
            onFullscreenChanged(newValue)
        }
        // A new asset resets the dismiss latch, the chrome-reveal state and
        // `videoIsLandscape`, so it does not inherit state from the
        // previous video.
        .onChange(of: assetID) { _, _ in
            dismissedThisSpell = false
            chromeRevealed = false
            videoIsLandscape = false
        }
        // The other of the latch's two reset triggers: the landscape
        // period has ended.
        // Read here, not only through `isFullscreen` going false, because
        // the dismiss-button path must leave the latch holding even while
        // the device is still landscape.
        .onChange(of: deviceStance) { _, newStance in
            if !newStance.isLandscape {
                dismissedThisSpell = false
                chromeRevealed = false
            }
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
                // `isFullscreen` to read `false`.
                let wasFullscreen = isFullscreen
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
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Nothing re-arms playback after the system pauses the player
            // for a background transition. Do it explicitly on return.
            if newPhase == .active {
                holder.applyPlaybackState()
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
            endScrub()
            holder.release()
            if wasFullscreen {
                onFullscreenChanged(false)
            }
        }
    }

    /// How far the loading ring steps off dead centre in fullscreen, to
    /// clear the 68pt mute-flash badge that already owns that spot.
    /// The offset is the badge's 34pt radius, plus the ring's 15pt radius
    /// (a 20pt ring inside 5pt of disc padding), plus 8pt of clearance.
    private static let fullscreenLoaderDrop: CGFloat = 57

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
    private func loaderLift(bottomBand: CGFloat) -> CGFloat {
        max(Rail.seamClearance, StageGeometry.captionTopFromBottom - bottomBand + 8)
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
    /// The returned view type is the same for both states, so the tree
    /// keeps one stable identity across the fullscreen transition.
    private func stageContent(bottomBand: CGFloat) -> some View {
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
            PlayerLayerView(player: holder.player, onReadyForDisplay: { isReadyForDisplay = $0 }, attach: playerLayerMounted && !scrollGate.isScrolling)

            // Sits directly above `PlayerLayerView`, so it covers the
            // layer's own black while nothing has decoded yet. It fades
            // out the instant `isReadyForDisplay` reports a real frame is
            // on screen.
            // `.aspectFit` matches `PlayerLayerView`'s `.resizeAspect`
            // gravity, so the poster never crops relative to the video it
            // stands in for.
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
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                // No `.opacity`, no `.animation`, and no `.feedShadow()`
                // here, and all three absences are deliberate.
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
                // In fullscreen, move the ring down by
                // `fullscreenLoaderDrop` so the ring does not overlap the
                // mute badge. The badge is a 68pt circle at dead centre of
                // this same ZStack (`showMuteBadge` below). The badge is a
                // 700 ms flash on a tap. A tap in fullscreen also reveals
                // the chrome. So this pairing of fullscreen, still
                // buffering, and a user tap is not rare.
                //
                // The offset shifts the ring down in the stage's own
                // space. Because the stage rotates ±90° in fullscreen,
                // this reads on screen as a small step to one side of
                // centre, mirrored between the two stances. The mirror is
                // fine here. The ring stays beside the middle of the
                // screen in both stances, rather than jumping from one
                // screen corner to the opposite one.
                .offset(y: isFullscreen ? Self.fullscreenLoaderDrop : 0)
                .allowsHitTesting(false)
                .accessibilityLabel("Loading video")
                .accessibilityHidden(!showSpinner)
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
                // Centred in fullscreen, and it has to be. `stageContent`
                // lays out un-rotated, then turns +90° or -90° through
                // `.rotationEffect(deviceStance.contentRotation)` in
                // `body`. In landscape, a corner of this un-rotated layout
                // is not a corner of the screen. It maps to the top-left
                // in one stance and the bottom-right in the other. A
                // loader that jumps to the opposite screen corner when the
                // phone turns the other way would be a visible bug. Centre
                // is the same place in every stance.
                // A ternary on the alignment value, never an if/else
                // around the view. The modifier chain keeps one identity.
                // This is the rule the identity comment on `stageContent`
                // in `body` protects.
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: isFullscreen ? .center : .bottomLeading)
                .padding(.leading, isFullscreen ? 0 : 10)
                .padding(.bottom, isFullscreen ? 0 : loaderLift(bottomBand: bottomBand))
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
            // rotated canvas that `body` rotates as one unit. The chrome
            // rotates with the video and reads upright in the user's hand.
            // Mounted only for the duration of the landscape period,
            // matching `ScrubberView`'s own conditional mounting.
            if isFullscreen {
                FullscreenPlayerChrome(
                    revealed: $chromeRevealed,
                    revealNonce: chromeRevealNonce,
                    progress: holder.progress,
                    isMuted: isMuted,
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
            // present unconditionally on the centred page. Reports the raw
            // monitor stance (`deviceStance`), never the gated
            // `isFullscreen` value. This lets a test with a portrait video
            // that rotates distinguish the app seeing the rotation and
            // declining fullscreen from the rotation never reaching the
            // app.
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
        "fullscreen_state_\(isFullscreen ? "active" : "inactive")_\(deviceStance.probeName)_\(assetID)"
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
        // while `isFullscreen`. A long press on the rotated stage must
        // not start a scrub. There is no scrubbing in fullscreen, and the
        // rotated stage's x position is not the coordinate space
        // `stageWidth` assumes.
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

    /// Entry point for the stage long press (`StageLongPressScrubGesture`).
    /// The first tick of a hold decides which of two things it is, by
    /// where the finger is. Every later tick of the same hold sticks with
    /// that choice.
    /// In fullscreen the whole stage is a fast-forward zone. There is no
    /// scrubbing there at all. The rotated stage's local x is not the
    /// axis `fastForwardEdgeFraction` is measured on.
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

    private func load() async {
        wdMark("load")
        guard isPreloadable else { return }
        isLoading = true
        loadFailed = false
        // Reset at the top of every load, so a stale reading can never
        // outlive its item.
        videoIsLandscape = false
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
            videoIsLandscape = size.width > size.height && size.width > 0
            #if DEBUG
            // The readout follows `presentationSize` for as long as this
            // item is attached, rather than reading it once at ready.
            // AVFoundation can report `.zero` or a placeholder size until
            // a frame has actually decoded.
            PlaybackReadout.shared.notePlayed(size)
            holder.watchPresentationSize()
            #endif
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
    #if DEBUG
    /// The on-screen resolution readout. `presentationSize` can change
    /// after the item is ready, so it is observed rather than read once.
    private var presentationObservation: NSKeyValueObservation?

    func watchPresentationSize() {
        presentationObservation?.invalidate()
        guard let item = attachedItem else { return }
        presentationObservation = item.observe(\.presentationSize, options: [.initial, .new]) { observed, _ in
            let size = observed.presentationSize
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PlaybackReadout.shared.notePlayed(size) }
            }
        }
    }
    #endif

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
        #if DEBUG
        presentationObservation?.invalidate()
        presentationObservation = nil
        #endif
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
/// aspect-fit on black, with no default AVKit controls to interfere with
/// the app's own tap-to-mute gesture.
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

    func makeUIView(context: Context) -> PlayerLayerContainerView {
        let view = PlayerLayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
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
