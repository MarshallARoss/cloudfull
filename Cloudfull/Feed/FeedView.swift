//
//  FeedView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Foundation
import UIKit
import Photos
import CoreLocation

/// FeedView is a vertical pager. It shows one video per screen, from a
/// persistent, shuffled deck.
struct FeedView: View {
    @StateObject private var viewModel: DeckViewModel
    @StateObject private var trashService: TrashService
    @StateObject private var shrinkService: ShrinkService
    @State private var currentPageID: String?
    @State private var showTrash = false
    /// True while the app waits for the first deal after a cold launch.
    /// This stops a slow library scan from looking like a frozen screen.
    /// Set from a `.task` in the pre-first-deal branch of
    /// `content(safeAreaTop:)`, which SwiftUI cancels the moment that
    /// branch stops rendering.
    @State private var showVideosLoading = false
    /// Set by whichever page's `PlayerPageView` currently has a scrub in
    /// progress, through `onScrubbingChanged`. This flag, not gesture
    /// priority, guarantees that a horizontal drag on the scrubber strip
    /// never turns into a page change mid-scrub.
    @State private var isScrubbing = false
    /// A double tap on a video keeps it. `PlayerPageView` reports the
    /// double tap, and this counter bumps a per-page nonce. The page's own
    /// `FeedPageContent` watches that nonce and calls
    /// `keepFromDoubleTap()`. This keeps the keep logic, its guards, and
    /// the heart's bounce in one place. The key is the page id, not the
    /// asset id, so the same asset shown on two slots never fires the keep
    /// twice.
    @State private var doubleTapKeepNonces: [String: Int] = [:]
    /// True from a trash tap's `advanceToNextPage` until its scroll
    /// animation finishes. See that method.
    @State private var isAdvancing = false
    /// On iOS 26, `withAnimation { currentPageID = next }` does not
    /// animate the `.scrollPosition(id:)` pager; the page cuts in one
    /// frame instead of scrolling. An explicit animated `scrollTo` through
    /// the `ScrollViewReader` does animate, so the trash advance asks for
    /// one through this nonce.
    @State private var advanceNonce = 0
    @State private var advanceTargetID: String?
    /// Bumped after every prune that removes a page. The pager's
    /// `ScrollViewReader` then re-anchors on `currentPageID`.
    @State private var reanchorNonce = 0
    /// The asset the shrink confirm sheet presents, captured once when the
    /// rail button is tapped. `.sheet(item:)` uses this captured value
    /// instead of `.sheet(isPresented:)` reading the tapped page's asset
    /// live. A library change that moves the pager's cursor while the
    /// sheet is open can then never silently retarget the sheet onto a
    /// different video.
    @State private var shrinkTarget: ShrinkTarget?
    @State private var shrinkToastMessage: String?
    @State private var shrinkToastKind: ShrinkToastKind = .reclaimed
    @State private var shrinkToastRetryAssetID: String?
    @State private var shrinkToastTask: Task<Void, Never>?
    // Job ids already toasted for a terminal state. This stops a body
    // re-evaluation, after the toast's own auto-hide timer clears
    // `shrinkToastMessage`, from showing the same job's toast again.
    @State private var toastedShrinkJobIDs: Set<String> = []

    // MARK: - Landscape fullscreen

    /// Publishes the device's physical stance. `start()` runs inside the
    /// existing `.task`; `stop()` runs in `.onDisappear`.
    /// `UIDevice.current.orientation` is read only inside this type, never
    /// during a body pass.
    @StateObject private var orientation = OrientationMonitor()
    @Environment(\.scenePhase) private var scenePhase
    /// The signal from whichever page's `PlayerPageView` currently reports
    /// `isFullscreen == true`, through `onFullscreenChanged`. This mirrors
    /// `isScrubbing`. Only the centered page can ever be fullscreen, so at
    /// most one page's callback ever reports `true`.
    @State private var isFullscreen = false

    /// Owns the share flow end to end: the Wi-Fi guard, resolving a
    /// shareable file, presenting the system share sheet, and the album
    /// picker handoff. Per-feed state, not a singleton — built here in
    /// `init`, the same as `viewModel`, `trashService`, and
    /// `shrinkService`.
    @StateObject private var shareCoordinator: ShareCoordinator

    /// The shared `feed.isMuted` flag, read by `muteButton` in every
    /// build configuration. Declared outside `#if DEBUG` so `muteButton`
    /// compiles in Release too.
    @AppStorage("feed.isMuted") private var muteProbeState: Bool = false
    #if DEBUG
    /// Mirrors the launch-time cloud-key backfill's progress for the
    /// DEBUG `backfill_` probe. `@ObservedObject`, not `@StateObject`,
    /// because `BackfillProbe.shared` is a singleton that
    /// `CloudKeyBackfillLauncher` owns.
    @ObservedObject private var backfill = BackfillProbe.shared
    /// The rendered value of `shrinkVerificationProbe`. Recomputed only by
    /// the `.task(id: shrinkVerificationCompletionKey)` in `body`, never
    /// read fresh during a body pass. See that task's comment for why.
    @State private var shrinkVerificationCache = "shrink_verify_none"
    #endif

    /// This uses `.shared`, the same pattern `AssetKeyResolver` and
    /// `BackfillProbe` use elsewhere in this file. The store outlives
    /// any one `FeedView`. `DeckViewModel.start()` reads the same
    /// instance at launch.
    @ObservedObject private var optionsStore = FeedOptionsStore.shared
    /// The pager id of the end-of-date page. Not a deck entry, so every
    /// `deck.firstIndex(where:)` lookup on it finds nothing.
    private static let doneForTodayPageID = "done_today_page"

    private struct ShrinkTarget: Identifiable {
        let id: String
    }

    /// Job-state-driven glyph for the shrink done toast. Kept as its own
    /// small state enum, set alongside the message at the same call
    /// sites, rather than re-derived by parsing the message string.
    private enum ShrinkToastKind: Equatable {
        case reclaimed, kept, failed

        var glyph: String {
            switch self {
            case .reclaimed: return "checkmark.circle.fill"
            case .kept: return "heart.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }

    init(viewModel: DeckViewModel, trashService: TrashService, shrinkService: ShrinkService) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _trashService = StateObject(wrappedValue: trashService)
        _shrinkService = StateObject(wrappedValue: shrinkService)
        _shareCoordinator = StateObject(wrappedValue: ShareCoordinator())
    }

    /// True while the bin or the shrink sheet is open. Each can play a
    /// video of its own. Every feed page pauses in place through
    /// `PlayerHolder.setSuspended` and resumes when the sheet closes. The
    /// share sheet and the album picker play no video, so the feed keeps
    /// playing under them.
    private var isFeedSuspended: Bool {
        showTrash || shrinkTarget != nil
    }

    /// True unless the bin, the shrink sheet, the album picker, or the
    /// share sheet is open. `PlayerPageView` reads this before fullscreen
    /// starts.
    ///
    /// Hidden controls already stop a sheet from opening while
    /// fullscreen is on. So this value only needs to guard the start of
    /// fullscreen. Ending an active fullscreen session is
    /// `isFeedSuspended`'s job.
    ///
    /// `FeedView` exists only inside the authorized session. The
    /// permission gate and onboarding need no check of their own.
    private var fullscreenAllowed: Bool {
        !showTrash
            && shrinkTarget == nil
            && shareCoordinator.albumPickerTarget == nil
            && shareCoordinator.probeState == .idle
    }

    var body: some View {
        // The one place that measures the device's real top safe-area
        // inset. This reader sits above the pager's `.ignoresSafeArea()`,
        // so it reports the true inset (59pt on 16 Pro, 62pt on 17 Pro).
        // Every page and the top chrome derive the same
        // `StageGeometry.downShift` from this one number. The ZStack
        // below is sized to this reader, and the pager still ignores the
        // safe area inside it, so both draw over the same rectangle.
        GeometryReader { rootProxy in
            let safeAreaTop = rootProxy.safeAreaInsets.top
            ZStack {
            content(safeAreaTop: safeAreaTop)
            // The whole global chrome layer (mute, the shrink progress
            // capsule, the counters, the bin) hides while fullscreen is
            // on. Each page's own `bottomScrim` and `FeedPageContent` in
            // `pager` hide too.
            overlayControls
                .opacity(isFullscreen ? 0 : 1)
                .allowsHitTesting(!isFullscreen)
                .accessibilityHidden(isFullscreen)
            // Mounted once here, in the global overlay, never inside
            // `FeedPageContent`. `FeedPageContent` is instantiated once
            // per mounted page and would produce up to three
            // `chin_nav_button` elements.
            ChinNavigation(bottomBand: StageGeometry.bottomBand(safeAreaTop: safeAreaTop,
                                                               containerSize: rootProxy.size))
                .opacity(isFullscreen ? 0 : 1)
                .allowsHitTesting(!isFullscreen)
                .accessibilityHidden(isFullscreen)
            if viewModel.isApplyingOptions {
                // A visible loading state while a filter or sort change
                // re-deals the feed. Blocks taps under it. The pill
                // itself is `FeedStatusPill`, shared with the videos and
                // photos loading states below.
                ZStack {
                    Color.black.opacity(0.35)
                    FeedStatusPill(text: "Updating feed…")
                }
                .ignoresSafeArea()
                .transition(.opacity)
                .accessibilityIdentifier("feed_options_updating")
                .accessibilityLabel("Updating feed")
            }
            // Zero-size. Presents and dismisses the system share sheet
            // imperatively. Ships in every build — this is the real
            // share mechanism, not a test aid.
            ActivityViewControllerHost(coordinator: shareCoordinator)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .accessibilityIdentifier("share_sheet_host")
            #if DEBUG
            // Present in every branch of `content`, including the empty
            // state, never only in the pager. Tests read the pool size
            // off this probe even when the deck is empty. Debug-only: it
            // carries no VoiceOver label. It must not appear in a build a
            // screen-reader user sees.
            feedOptionsProbe
            muteStateProbe
            deckNextSlotProbe
            deckWindowProbe
            shrinkVerificationProbe
            shareProbe
            sharePresentationCountProbe
            albumVerificationProbe
            backfillProbe
            // `poolCountProbe`, `filteredPoolCountProbe`, and
            // `MainStallProbeView` are mounted by `GateProbes`
            // (Cloudfull/Storage/DebugProbes.swift), not here. `RootView`
            // unmounts `FeedView` outright while the mode is `.photos`.
            // `pool_total_`, `pool_filtered_`, and `main_stalls_` need to
            // keep reading independent of which mode is on screen.
            // `trash_rows_` lives there for the same reason.
            #endif
            }
            .frame(width: rootProxy.size.width, height: rootProxy.size.height)
        }
        // Hides the status bar and home indicator while fullscreen is on.
        // This is safe for the stage geometry. The pager and
        // `overlayControls` both already `.ignoresSafeArea()`, so
        // `proxy.size` — the only input to the stage math — does not
        // move when the inset does.
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .task {
            viewModel.start()
            trashService.start()
            // Warms the album list from whichever feed the app opens on,
            // so Add to Album usually has its answer ready before it is
            // ever tapped. A no-op once loaded; the fetch itself runs off
            // the main actor.
            AlbumListCache.shared.prewarm()
            currentPageID = viewModel.currentEntryID
            orientation.start()
            #if DEBUG
            // A no-op unless `-cloudfull-reset-stalls` was passed at
            // launch. When it was, the watchdog zeroes its counters and
            // re-arms its settle window now that the feed is actually on
            // screen.
            MainThreadWatchdog.shared.feedDidAppear()
            #endif
        }
        .onDisappear {
            orientation.stop()
        }
        // Device-orientation notifications do not arrive while the app is
        // backgrounded. A user who rotates back to portrait while
        // backgrounded would otherwise return to a stale landscape
        // stance. This is the one place the monitor is polled rather than
        // pushed. Returning to the foreground is exactly when a missed
        // change must be reconciled.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                orientation.refresh()
            } else {
                // The cursor write happens off the page-change tick, so
                // the app leaving the foreground is what makes it
                // durable.
                viewModel.flushPendingWrites()
            }
        }
        // `viewModel.currentEntryID` is the single source of truth for
        // which slot the view model considers current. This is the other
        // half of the binding, alongside the pager's own scroll-driven
        // writes below. `start()` and `pageBecameCurrent()` react to the
        // same scroll as the pager. They only ever set this to a value
        // that already equals `currentPageID`, so they never override
        // the user's own swipe. This matters only when the view model
        // moves the cursor on its own, in `handleLibraryChange()`'s
        // reconciliation, where nothing else tells the pager to follow.
        .onChange(of: viewModel.currentEntryID) { _, newValue in
            if let newValue, newValue != currentPageID {
                currentPageID = newValue
            }
        }
        // Cancels an in-flight share resolution the instant the pager moves
        // to a different page than the one sharing started on. The modal
        // share sheet covers the pager once it is up. The page can
        // change only during `.preparing`, before the sheet is up. For
        // example, a fast swipe away, or `handleLibraryChange` moving the
        // cursor because the shared asset vanished. Either way,
        // presenting a share sheet for a video no longer on screen would
        // be wrong. This is `cancelShare()`'s one call site.
        .onChange(of: currentPageID) { _, _ in
            if shareCoordinator.probeState == .preparing {
                shareCoordinator.cancelShare()
            }
        }
        // The one place options reach the deck. `apply` is idempotent, so
        // a duplicate notification costs nothing. `start()` reads the
        // same store for its own launch value, so the two never disagree.
        //
        // Do not use `initial: true`. On a cold launch it sets
        // `isApplyingOptions`. The Updating pill then shows over the
        // Loading pill. The two loading states must never show together.
        //
        // A feed created already holding new options still needs to see a
        // change eventually. That gap belongs in the deck's remount path,
        // which by definition cannot run on a cold launch. See
        // `reconcileAfterRemount`.
        .onChange(of: optionsStore.options) { _, newValue in
            viewModel.apply(options: newValue)
        }
        .sheet(isPresented: $showTrash) {
            TrashView(trashService: trashService)
        }
        // Presented from `ShareCoordinator.shareSheetFinished` when the user
        // picks "Add to Album" from the system share sheet.
        .sheet(item: $shareCoordinator.albumPickerTarget) { target in
            AlbumPickerView(assetID: target.id, coordinator: shareCoordinator)
        }
        .sheet(item: $shrinkTarget) { target in
            // The target id was captured when the rail button was tapped.
            // A library change can still remove it from the deck while
            // the sheet is open, for example if the asset was deleted
            // elsewhere. Dismiss the sheet rather than let it keep
            // offering a shrink for a video that no longer exists here.
            if viewModel.deck.contains(where: { $0.assetID == target.id }) {
                ShrinkConfirmView(assetID: target.id, shrinkService: shrinkService)
            } else {
                Color.clear.onAppear { shrinkTarget = nil }
            }
        }
        // `ShrinkService.ShrinkJob` has no `Equatable` conformance to key
        // an `onChange(of:)` off directly, and this view must not extend
        // that type. A cheap string signature of each job's id and state
        // stands in for it instead.
        .onChange(of: shrinkJobsSignature) { _, _ in
            handleShrinkJobsChanged()
        }
        #if DEBUG
        // Keys this `.task(id:)` off the newest completed job's own id
        // and state, not off `jobs` itself. `shrinkService.jobs`
        // republishes up to five times a second during an export, and
        // computing `shrinkVerificationIdentifier` directly costs three
        // live PhotoKit fetches (`pixelSize`, two `assetMeta`). Keying
        // off the completed job runs those fetches once per finished
        // job, off the render path, like every other precompute in this
        // file.
        .task(id: shrinkVerificationCompletionKey) {
            shrinkVerificationCache = computeShrinkVerificationIdentifier()
        }
        #endif
    }

    @ViewBuilder
    private func content(safeAreaTop: CGFloat) -> some View {
        if !viewModel.hasDealtFirstDeck {
            // The first deal waits on a background library enumeration.
            // An empty deck means "no videos" only once the app has
            // actually looked. Until then this shows plain black, not a
            // `ContentUnavailableView`, which would flash for about
            // 100 ms on every cold launch. Every DEBUG probe is a
            // sibling in the outer `ZStack` and stays mounted through
            // this branch, exactly as it does through `emptyState`.
            //
            // A small loading indicator appears from the first frame, so
            // the user does not see a frozen screen during a slow
            // enumeration. A fast deal fades it back out, so the app
            // looks like it answered, not like a flash.
            Color.black.ignoresSafeArea()
                // A tap while "Loading videos…" is showing hits nothing.
                .onTapGesture { Usage.shared.loadingTap(mode: .videos) }
                .overlay {
                    if showVideosLoading {
                        // The same `FeedStatusPill` used for "Updating
                        // feed…," not a separate `ProgressView` block.
                        FeedStatusPill(text: "Loading videos…")
                            .accessibilityIdentifier("videos_loading")
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Loading videos")
                            .transition(.opacity)
                    }
                }
                .task {
                    guard !viewModel.hasDealtFirstDeck else { return }
                    withAnimation(.easeIn(duration: 0.15)) { showVideosLoading = true }
                }
        } else if viewModel.deck.isEmpty {
            // An empty deck means one of two things. The user needs to
            // know which: no videos exist, or the filters hid every
            // video.
            if optionsStore.options.isDefault {
                emptyState
            } else {
                noMatchesState
            }
        } else {
            pager(safeAreaTop: safeAreaTop)
        }
    }

    /// `safeAreaTop` is the real inset, measured once in `body`. It is
    /// threaded into every `PlayerPageView` because their own readers sit
    /// under this pager's `.ignoresSafeArea()` and would otherwise read 0.
    private func pager(safeAreaTop: CGFloat) -> some View {
        ScrollViewReader { scrollProxy in
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                // The preload window comes from `viewModel.preloadableSlots`,
                // a precomputed `Set<Int>` of `DeckEntry.position` values,
                // refreshed at every site that assigns `currentIndex`. It
                // gives a ±1-page window, keyed by absolute slot, in O(1)
                // time. It stays correct after the deck trims its
                // consumed head, when the array index no longer matches
                // the slot number.
                ForEach(viewModel.deck) { entry in
                    let isActive = currentPageID == entry.id
                    let isPreloadable = viewModel.preloadableSlots.contains(entry.position)
                    // Gated on `isActive`, not merely on being the deck's
                    // last entry. The exhausted card then appears only
                    // once the user scrolls onto this page, not while it
                    // sits preloaded as a neighbor.
                    let isFinalExhausted = isActive && viewModel.isPoolExhausted && entry.id == viewModel.deck.last?.id
                    ZStack {
                        PlayerPageView(
                            assetID: entry.assetID,
                            pageID: entry.id,
                            isActive: isActive,
                            isPreloadable: isPreloadable,
                            viewModel: viewModel,
                            onScrubbingChanged: { isScrubbing = $0 },
                            deviceStance: orientation.stance,
                            fullscreenAllowed: fullscreenAllowed,
                            onFullscreenChanged: { isFullscreen = $0 },
                            safeAreaTop: safeAreaTop,
                            onDoubleTap: { doubleTapKeepNonces[entry.id, default: 0] += 1 },
                            isSuspended: isFeedSuspended
                        )
                        // Drawn between the video and this page's own caption
                        // and rail, so the gradient darkens behind the text
                        // and icons instead of washing over them. It
                        // travels with its own page during a swipe, instead
                        // of staying fixed while the caption it protects
                        // slides out from under it.
                        //
                        // Hidden while fullscreen is on, alongside
                        // `FeedPageContent` below and the global
                        // `overlayControls`. Only the centered page can
                        // ever be fullscreen. So gating every page's own
                        // scrim and content on this one `FeedView`-level
                        // flag works the same as gating just the active
                        // page. Every other page is off screen once
                        // fullscreen fills the pager.
                        bottomScrim
                            .opacity(isFullscreen ? 0 : 1)
                            .accessibilityHidden(isFullscreen)
                        FeedPageContent(
                            entry: entry,
                            isActive: isActive,
                            isFinalExhausted: isFinalExhausted,
                            hideForFullscreen: isFullscreen,
                            isScrubbing: isScrubbing,
                            viewModel: viewModel,
                            trashService: trashService,
                            shrinkService: shrinkService,
                            shareCoordinator: shareCoordinator,
                            onRequestShrink: { assetID in
                                Usage.shared.shrinkSheetOpened()
                                shrinkTarget = ShrinkTarget(id: assetID)
                            },
                            onAdvanceRequested: { advanceToNextPage(from: entry) },
                            onOpenBinRequested: { Usage.shared.binOpened(); showTrash = true },
                            safeAreaTop: safeAreaTop,
                            keepRequestNonce: doubleTapKeepNonces[entry.id] ?? 0
                        )
                        .opacity(isFullscreen ? 0 : 1)
                        .allowsHitTesting(!isFullscreen)
                        .accessibilityHidden(isFullscreen)
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(entry.id)
                    // Declares this page an accessibility container, rather
                    // than letting the identifier below settle onto a plain
                    // group. A bare `.accessibilityIdentifier` on a group
                    // copies onto every descendant element that has no
                    // identifier of its own, and it overrides the ones
                    // that do. As a container, the identifier lands on
                    // the page and stops there. The children keep their
                    // own: `rail_like`, `rail_share`, `rail_shrink`,
                    // `rail_trash`, `feed_caption`, `feed_coming_soon`.
                    .accessibilityElement(children: .contain)
                    // "page_<slot>_<assetID>". The slot lets a UI test
                    // tell two cases apart: the pager moved to the next
                    // page, which happens to hold the same video, or the
                    // swipe never registered. The two cases look
                    // identical when the identifier carries only the
                    // asset id. A test that cannot separate them must
                    // skip past two slots in a row with the same video.
                    // Asset ids contain no underscore, so the first one
                    // splits the two halves.
                    .accessibilityIdentifier("page_\(entry.id)")
                }
                // The end of "this date" is one more page after the last
                // video, paged like every other page. It uses the
                // welcome screen's style, not a glass card.
                if viewModel.showsDoneForTodayAtEnd {
                    DoneForTodayPage(
                        mode: .videos,
                        onReset: {
                            Usage.shared.onThisDateEnd(mode: .videos, tap: .keepScrolling)
                            optionsStore.reset()
                        },
                        otherModeTitle: "Go to Photos",
                        onGoToOtherMode: {
                            Usage.shared.onThisDateEnd(mode: .videos, tap: .toPhotos)
                            Usage.shared.modeSwitch(to: .photos, via: .endPage)
                            AppModeStore.shared.select(.photos)
                        }
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                        .id(Self.doneForTodayPageID)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        // Pulling down past the first video refreshes the feed: re-read the
        // library and re-deal. The system spinner is the whole UI; the
        // "Loading videos…" state the deck raises covers the rebuild itself.
        .refreshable { await viewModel.refresh() }
        // `ScrollPhaseGate`: every page defers its player lifecycle
        // (attach, play, pause, layer hookup) until this reads idle again.
        .onScrollPhaseChange { _, newPhase in
            ScrollPhaseGate.shared.update(isScrolling: newPhase != .idle)
            // A transient callout belongs to the item it fired on. Once
            // the feed moves, leaving it up would look like a second add
            // to the user. See `dismissCalloutForScroll`.
            if newPhase != .idle { shareCoordinator.dismissCalloutForScroll() }
        }
        .scrollPosition(id: $currentPageID)
        // No scroll indicator on a full-bleed, one-video-per-screen pager.
        // A scrollbar looks like a defect on this kind of vertical video
        // feed, not like a navigation aid.
        .scrollIndicators(.hidden)
        // Locks the pager for the whole span of a scrub, reported up from
        // whichever page's `PlayerPageView` has one in progress. The
        // scrubber uses `.simultaneousGesture`. This flag, not gesture
        // priority, stops a scrub from changing the page.
        //
        // `isFullscreen` extends the same mechanism and nothing else. A
        // swipe, a fling, or a bounce while fullscreen is on does
        // nothing, reusing the same modifier instead of adding a second
        // one.
        .scrollDisabled(isScrubbing || isFullscreen)
        .ignoresSafeArea()
        .background(Color.black)
        // `initial: true` registers the page the deck restores onto, or
        // the first page of a fresh deck, as current immediately. Without
        // it, that first slot's cursor and exhaustion bookkeeping never
        // runs until the user swipes away from it.
        .onChange(of: currentPageID, initial: true) { oldValue, newValue in
            guard let newValue else { return }
            wdMark("pageChange")
            // A page change counts as one post seen and, after the first
            // change, one swipe. A swipe back is when the new page sits
            // above the old one.
            Usage.shared.postSeen(mode: .videos)
            // Not while the trash tap's own advance is moving the pager.
            // That is not a swipe, and it must not consume the 5 s
            // after-delete window.
            if !isAdvancing, let oldValue,
               let from = viewModel.deck.firstIndex(where: { $0.id == oldValue }),
               let to = viewModel.deck.firstIndex(where: { $0.id == newValue }) {
                Usage.shared.swipe(mode: .videos, up: to < from)
            }
            viewModel.pageBecameCurrent(newValue)
            // A user swipe reports here once the pager has settled, so
            // pruning binned pages is safe. The trash tap's own
            // programmatic advance reports here at the start of its
            // animation and prunes in its completion instead.
            //
            // A shrink queues the original video for the bin without a
            // trash tap. The page being left behind can become queued
            // during an ordinary swipe, not only through the trash tap's
            // own advance. Pruning it while the pager is still moving
            // would remove that page and re-anchor the scroll under the
            // user's finger mid-gesture. This waits for the pager to go
            // idle first.
            if !isAdvancing {
                Task { @MainActor in
                    await ScrollPhaseGate.shared.waitUntilIdle()
                    guard currentPageID == newValue, !isAdvancing else { return }
                    if viewModel.pruneQueuedPages(keeping: newValue) {
                        reanchorNonce += 1
                    }
                }
            }
        }
        // Re-anchors after a prune. `ScrollView` keeps its offset, not
        // its anchored id, when pages above the current one leave the
        // `LazyVStack`. The reported id lands one page further on while
        // the view still draws the old page. An unanimated `scrollTo`
        // puts the offset back under the page the binding names.
        .onChange(of: reanchorNonce) { _, _ in
            guard let currentPageID else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollProxy.scrollTo(currentPageID, anchor: .top)
            }
        }
        // The trash advance: an explicit animated scroll to the next page
        // (see `advanceNonce`), then the same prune-on-rest as elsewhere.
        // `withAnimation { } completion:` does not work here: `scrollTo`
        // changes no animatable state of its own, so the completion fires
        // in the same frame. Pruning then would remove the binned page
        // before the slide even starts. The pager reports the
        // programmatic slide through `onScrollPhaseChange` like any other
        // scroll. This waits for the scroll to start and then to settle
        // before pruning.
        .onChange(of: advanceNonce) { _, _ in
            guard let nextID = advanceTargetID else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                scrollProxy.scrollTo(nextID, anchor: .top)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                await ScrollPhaseGate.shared.waitUntilIdle()
                guard advanceTargetID == nextID else { return }
                currentPageID = nextID
                isAdvancing = false
                advanceTargetID = nil
                if viewModel.pruneQueuedPages(keeping: nextID) {
                    reanchorNonce += 1
                }
            }
        }
        }
    }

    /// Shown when the library has zero videos. Lives inside `content`'s
    /// branch alongside `pager`. `shrinkVerificationProbe` and the
    /// other DEBUG probes, siblings in the outer `ZStack`, render
    /// exactly as they do for a non-empty deck. The top chrome also stays
    /// mounted over this state. `overlayControls` is never conditionally
    /// hidden, so `bin_open` and the counters stay reachable in every
    /// deck state.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Videos", systemImage: "video.slash")
        } description: {
            Text("Cloudfull plays the videos already in your photo library. Record one, or import one, and it will show up here.")
        } actions: {
            Button("Open Photos") { openPhotosApp() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("empty_library_open_photos")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        // This container needs the same guard `noMatchesState` uses for
        // `filter_empty_reset` inside `filter_empty_card`. A bare
        // identifier here would outrank `empty_library_open_photos`, the
        // button inside it. See the comment above `pager`'s
        // `page_<slot>_` identifier for the mechanism. No test covers
        // this. It is a precaution.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty_library_state")
    }

    /// Same as `TrashView.openPhotosApp()`. Opens the Photos app through
    /// the `photos-redirect://` URL. Duplicated rather than shared, so
    /// this file does not depend on `TrashView`.
    private func openPhotosApp() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Empty-match state
    //
    // Shows a "No videos match" card with a Reset button, in the same
    // style as the exhausted card. Same card shape as
    // `FeedPageContent.exhaustedCard`, on the full-screen black ground
    // `emptyState` uses, because with no pages there is no video for it
    // to sit over. The top chrome stays mounted over this state;
    // `overlayControls` is never conditionally hidden. The filter
    // button and the bin stay reachable with an empty deck, the same
    // promise `emptyState` makes.
    private var noMatchesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30))
                .foregroundStyle(.white)
            Text("No videos match")
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text("No video in your library matches the filters you picked. Change them, or reset to see everything again.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Button("Reset") { optionsStore.reset() }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .controlSize(.regular)
                .accessibilityIdentifier("filter_empty_reset")
                .accessibilityLabel("Reset filters")
                .accessibilityHint("Clears every filter and sort and shows the whole library again")
        }
        .padding(16)
        .frame(maxWidth: 320)
        .feedGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        // Without this, the bare identifier below would stamp onto
        // `filter_empty_reset`, the Button this container holds, and
        // outrank it. See the same failure mode documented above
        // `pager`'s `page_<slot>_` identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filter_empty_card")
    }

    // MARK: - Scrim
    //
    // A non-interactive gradient so white chrome stays legible on a
    // bright video frame. `.allowsHitTesting(false)`: a hit-testing
    // overlay over the pager would swallow `app.swipeUp()`.

    private var bottomScrim: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.35)],
            startPoint: .top,
            endPoint: .bottom
        )
        // The rail stands on the video. This gradient covers the lower
        // 320pt of the page, under most of the rail, so white glyphs
        // stay legible on a bright frame.
        .frame(height: 320)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Overlay layer: top chrome, toast
    //
    // The caption, rail, callout and exhausted card are in
    // `FeedPageContent`, mounted per page inside `pager`. They scroll
    // with their page instead of resetting to the incoming page's data
    // the instant a swipe starts. Only global chrome stays here: mute,
    // the shrink progress capsule, the counters, and the bin. It stays
    // fixed to the same screen position while every page scrolls
    // underneath it.

    // The `GeometryReader` fills the space it is given and aligns `.top`.
    // The `Spacer` below `topChrome` then lays out exactly as it would
    // in a bare `VStack`, and the stack's origin still sits on the
    // safe-area top. `proxy.safeAreaInsets.top` reports the device's
    // real inset (62pt on iPhone 17 Pro), the number
    // `topChromeTopPadding` needs.
    //
    // Read the inset only from this proxy. Do not read UIKit geometry in
    // a SwiftUI body, such as the key window's `safeAreaInsets` through
    // `UIApplication.shared.connectedScenes`. It forces a UIKit layout
    // pass and can stop the view graph from updating. The app then draws
    // its first frame and never re-renders again, even while other
    // state, such as the deck itself, keeps changing correctly.
    private var overlayControls: some View {
        // A `GeometryReader` placed under `.ignoresSafeArea()` reports
        // `safeAreaInsets == .zero`: the modifier consumes the inset
        // before the proxy sees it. Reading `.top` off such a proxy
        // always returns 0, which would misplace the chrome inside the
        // Dynamic Island. So this `GeometryReader` carries no
        // `.ignoresSafeArea()`. The proxy reports the real inset, and
        // the full-window height the stage math needs is reconstructed
        // as size plus insets.
        GeometryReader { proxy in
            let realTopInset = proxy.safeAreaInsets.top
            let fullWindow = CGSize(
                width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            )
            VStack(spacing: 0) {
                topChrome(safeAreaTop: realTopInset, containerSize: fullWindow)
                if let shrinkToastMessage {
                    shrinkToast(shrinkToastMessage)
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            // The stack starts at the safe-area top, since this reader is
            // inside the safe area, but `topChromeTopPadding` measures
            // from the window top. Subtract the inset the layout already
            // applied.
            .padding(.top, -realTopInset)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    // MARK: - Top chrome

    private func topChrome(safeAreaTop: CGFloat, containerSize: CGSize) -> some View {
        // Four independent glass pills. Do not wrap these in a
        // `GlassEffectContainer`. XCUITest then resolves the far-right
        // `bin_open` button's frame relative to the container. Its
        // synthesized tap lands at the top-left of the screen, on the
        // video, which toggles mute instead of opening the bin. The
        // left-edge filter button coincides with the container's
        // origin, so it keeps working and hides the problem. A finger
        // tap is always fine; only the synthesized XCUITest tap
        // coordinates are wrong.
        HStack(alignment: .top, spacing: 8) {
            // A tap on the video also toggles mute, with a center flash.
            // This pill is the second mute control.
            muteButton
            FilterMenuView(store: optionsStore, isFullscreen: isFullscreen)
            if let job = activeShrinkJob, let text = shrinkActiveProgressText {
                shrinkProgressCapsule(text, assetID: job.id)
            }
            Spacer(minLength: 8)
            counterCapsule
            binButton
        }
        .padding(.horizontal, 12)
        .padding(.top, topChromeTopPadding(safeAreaTop: safeAreaTop, containerSize: containerSize))
    }

    /// Height of the empty band the fixed 9:16 stage leaves above and below
    /// the video on this screen, before the island-clearance shift
    /// `topBandHeight` applies. `containerSize` is the full window.
    /// `overlayControls` rebuilds it as its `GeometryReader` proxy's size
    /// plus its safe-area insets — see the note on `overlayControls` for
    /// why. This avoids `UIScreen.main.bounds`, deprecated since iOS 16,
    /// which describes the whole device rather than this window and is
    /// not observable.
    private func stageBandHeight(containerSize: CGSize) -> CGFloat {
        StageGeometry.naturalBand(containerSize: containerSize)
    }

    /// The top band's height after `StageGeometry.downShift`. Matches
    /// `PlayerPageView`'s own identically named local value exactly, so
    /// the chrome and the video it sits above never disagree about where
    /// that edge is. See `downShift`'s own comment for why the stage
    /// itself needs to move to make room for the chrome.
    private func topBandHeight(safeAreaTop: CGFloat, containerSize: CGSize) -> CGFloat {
        stageBandHeight(containerSize: containerSize)
            + StageGeometry.downShift(safeAreaTop: safeAreaTop, containerSize: containerSize)
    }

    /// Returns the fixed chrome top from
    /// `StageGeometry.chromeTop(safeAreaTop:)`, just under the Dynamic
    /// Island.
    private func topChromeTopPadding(safeAreaTop: CGFloat, containerSize: CGSize) -> CGFloat {
        // The chrome sits at one fixed spot, just under the island
        // capsule. `StageGeometry.downShift` grows the band by exactly
        // enough for the video to start `chromeToVideoGap` below it.
        // Both numbers come from the same `StageGeometry` helpers, so
        // the pills and the video can never disagree.
        StageGeometry.chromeTop(safeAreaTop: safeAreaTop)
    }

    private var muteButton: some View {
        Button {
            muteProbeState.toggle()
        } label: {
            Image(systemName: muteProbeState ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .tint(.white)
        // Identifier gated directly on `isFullscreen`, the same pattern
        // every other top-chrome control uses.
        .accessibilityIdentifier(isFullscreen ? "" : "feed_mute_toggle")
        .accessibilityLabel(muteProbeState ? "Sound off" : "Sound on")
        .accessibilityHint("Double tap to turn sound \(muteProbeState ? "on" : "off")")
    }

    // MARK: - Shrink progress capsule

    private func shrinkProgressCapsule(_ text: String, assetID: String) -> some View {
        Button { shrinkService.cancel(assetID: assetID) } label: {
            HStack(spacing: 8) {
                Text("Shrinking")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                ProgressView(value: shrinkActiveProgressFraction)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 56)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                    // Always one line: without this, "Saving…" can wrap
                    // onto two lines when the row is tight.
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minHeight: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.white)
        .accessibilityIdentifier("shrink_progress")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel("Shrinking video, \(text) complete")
        .accessibilityHint("Double tap to cancel")
    }

    // MARK: - Shrink done toast

    private func shrinkToast(_ message: String) -> some View {
        Group {
            if let retryID = shrinkToastRetryAssetID {
                Button {
                    shrinkService.enqueue(assetID: retryID)
                    dismissShrinkToastNow()
                } label: { toastLabel(message) }
                .buttonStyle(.plain)
            } else {
                toastLabel(message)
            }
        }
        .accessibilityIdentifier("shrink_done")
        .accessibilityLabel(message)
        .transition(.opacity)
    }

    private func toastLabel(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: shrinkToastKind.glyph)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(shrinkToastKind == .failed ? .red : .white)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 320, alignment: .leading)
        .feedGlass(in: Capsule())
    }

    // MARK: - Counter capsule
    //
    // The `space_counter` identifier is on a bare `Text`. The wording and
    // the numbers behind it can change; the identifier does not. Exactly
    // two numbers exist, both on `TrashService`: `pendingBytes` (queued,
    // not yet freed) and `reclaimedBytes` (the all-time total freed by
    // completed Empty actions, persisted across launches, not a
    // per-session figure). Neither can double-count the other. A shrink's
    // savings are represented only by the queued original's own
    // `bytes - replacementBytes`.
    //
    // The `space_counter` Text is 1x1 and invisible. `M2TrashTests`,
    // `M5Tests`, and `M11Tests` read it by
    // `app.staticTexts["space_counter"]`. Do not use
    // `.accessibilityHidden`: it removes the element from the
    // accessibility tree those tests query. The on-screen byte figure is
    // in `binButton`.
    @ViewBuilder
    private var counterCapsule: some View {
        // The "x MB pending" pill hides while a video is shrinking, and
        // reappears updated once the shrink finishes. Mirrored in
        // `binBadgeText` below: the bin pill's own byte figure hides the
        // same way while a shrink is active.
        let showPending = trashService.pendingBytes > 0 && activeShrinkJob == nil
        if showPending {
            Text(pendingSpaceText)
                .accessibilityIdentifier("space_counter")          // identifier read by the UI tests
                .accessibilityLabel(pendingSpaceAccessibilityLabel)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Bin
    //
    // The glyph is `archivebox.fill`.

    private var binButton: some View {
        Button { Usage.shared.binOpened(); showTrash = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 15, weight: .medium))
                if let binBadgeText {
                    Text(binBadgeText)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(.white)
            // Use the system `.glass` style. A custom glass style in a
            // plain `Button` does not fire the action. No inner frame or
            // padding: `.controlSize(.small)` below sizes the pill on its
            // own. The tap-to-mute gesture on the page lives on the video
            // stage only, never on this top band, so a tap here always
            // reaches this button.
            .frame(minHeight: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.white)
        // Shakes on each addition once the bin is worth emptying. Same
        // modifier the Photos top bar uses, so the two bars cannot
        // disagree about the threshold or the intensity.
        .binShake(count: trashService.count)
        // See `FilterMenuView`'s identical `isFullscreen`-gated
        // identifier pattern.
        .accessibilityIdentifier(isFullscreen ? "" : "bin_open")
        // The count lives in the label itself, not a separate
        // `.accessibilityValue`. `XCUIElement.label` is what a VoiceOver
        // user hears first, and what `M2TrashTests` reads to confirm the
        // badge; it only reflects the label. The queued count has to be
        // part of it to be announced or observed at all.
        //
        // Do not add the byte figure to this label.
        // `M3ShrinkTests.binQueuedCount()` and `M5Tests.binQueuedCount()`
        // both call `label.filter(\.isNumber)` on this exact string.
        // `binQueuedCount()` reads only digits from it, so appending
        // "· 14 MB" would hand it "314" instead of "3". The byte figure
        // is on screen in `binBadgeText`. VoiceOver reads it from the
        // invisible `space_counter` text above.
        .accessibilityLabel(trashService.count > 0 ? "Bin, \(trashService.count) queued" : "Bin")
        .accessibilityHint("Opens the list of videos queued for deletion")
    }

    /// The bin pill's own on-screen text: just the count when nothing is
    /// pending, "1 · 14 MB" once there is. Uses the same `showPending`
    /// rule as `counterCapsule`. The byte figure disappears from the bin
    /// pill while a shrink job is active, and reappears, updated, once it
    /// is not. Keep the two rules the same.
    private var binBadgeText: String? {
        guard trashService.count > 0 else { return nil }
        let showPending = trashService.pendingBytes > 0 && activeShrinkJob == nil
        guard showPending else { return "\(trashService.count)" }
        return "\(trashService.count) · \(Fmt.bytes(trashService.pendingBytes))"
    }

    #if DEBUG
    /// "feed_options_<probeToken>", for example "feed_options_random_000t31"
    /// at default. One token, one source (`FeedOptions.probeToken`), so
    /// the probe and the deck-signature key can never disagree about
    /// what the live options are.
    private var feedOptionsProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("feed_options_\(optionsStore.options.probeToken)")
    }

    /// "mute_state_<bool>", the shared `feed.isMuted` flag. Lets
    /// `M5Tests.testScrubSeeksWithoutBreakingTapToMute` prove that
    /// tapping the video to mute still flips state. Invisible, always
    /// present, DEBUG only.
    private var muteStateProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("mute_state_\(muteProbeState)")
    }

    /// "deck_window_<prev>_<cur>_<next>": the asset ids, first 4
    /// characters each, or "none" past either end, at `currentIndex` ± 1
    /// in the live deck array. Lets a probe tell "the array is wrong"
    /// apart from "the pager is showing the wrong page for the array."
    private var deckWindowProbe: some View {
        let deck = viewModel.deck
        let index = viewModel.currentIndex
        func short(_ offset: Int) -> String {
            let i = index + offset
            guard deck.indices.contains(i) else { return "none" }
            return String(deck[i].assetID.prefix(4))
        }
        return Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("deck_window_\(short(-1))_\(short(0))_\(short(1))")
    }

    /// "deck_next_<n>": the absolute slot of the deck entry immediately
    /// after the currently centered page, or "deck_next_end" at the
    /// deck's true tail. Exception slots make "the next slot"
    /// unpredictable from the current slot number alone. The UI test
    /// harness reads this instead of assuming `current + 1`. See
    /// `DeckViewModel.debugNextSlotAfterCurrent`. Invisible, always
    /// present, DEBUG only.
    private var deckNextSlotProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier(
                viewModel.debugNextSlotAfterCurrent.map { "deck_next_\($0)" } ?? "deck_next_end"
            )
    }

    /// Mirrors `ShareCoordinator.probeState`, so the UI suite can prove
    /// the app's own state says it presented the share sheet, separate
    /// from proof that the system sheet is really on screen. Invisible,
    /// always present, DEBUG only.
    private var shareProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("share_probe_\(shareCoordinator.probeState.rawValue)")
    }

    /// "share_presented_count_<n>": a count of share sheets presented
    /// this launch. `shareProbe` is not enough. FeedView leaves the
    /// accessibility tree while the sheet is up, so a test polling
    /// `share_probe_` sees the element vanish rather than change. See
    /// `ShareCoordinator.presentedShareCount`.
    private var sharePresentationCountProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("share_presented_count_\(shareCoordinator.presentedShareCount)")
    }

    /// "album_verify_<assetID>_<albumID>_<count>": a real PhotoKit
    /// re-fetch of the album's count, through
    /// `PhotoLibraryService.assetCount(inAlbumWithIdentifier:)`, not an
    /// echo of the write request. This lets a UI test tell "wrote
    /// nothing" apart from "wrote the wrong thing." Reports
    /// `album_verify_none` until the first successful add.
    private var albumVerificationProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier(albumVerificationIdentifier)
    }

    private var albumVerificationIdentifier: String {
        guard let lastAlbumAdd = shareCoordinator.lastAlbumAdd else { return "album_verify_none" }
        return "album_verify_\(lastAlbumAdd.assetID)_\(lastAlbumAdd.albumID)_\(lastAlbumAdd.count)"
    }

    /// "backfill_<state>_<resolved>_<pending>_<total>": mirrors
    /// `CloudKeyBackfillLauncher`'s progress through `BackfillProbe.shared`.
    /// A sibling in the outer `ZStack`, so it is present in the
    /// empty-deck branch too.
    private var backfillProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier(
                "backfill_\(backfill.state.rawValue)_\(backfill.resolved)_\(backfill.pending)_\(backfill.total)"
            )
    }
    #endif

    // MARK: - Actions
    //
    // `toggleLike` and `handleTrashTap` live on `FeedPageContent` instead
    // of here. Each instance reads and writes only its own page's
    // `entry.assetID`. A tap always lands on the asset actually under
    // the user's thumb, including mid-swipe when two pages are partly
    // visible. `advanceToNextPage(from:)` below is the one piece that
    // stays here: only `FeedView` owns `currentPageID`, the pager's
    // scroll binding.

    /// Advances the pager to the slot after `entry`, not after
    /// `currentPageID`. A tap mid-swipe on the incoming page then
    /// advances from the tapped page. The scroll runs through
    /// `advanceNonce`.
    private func advanceToNextPage(from entry: DeckEntry) {
        guard let index = viewModel.deck.firstIndex(where: { $0.id == entry.id }) else { return }
        let nextIndex = index + 1
        guard viewModel.deck.indices.contains(nextIndex) else { return }
        let nextID = viewModel.deck[nextIndex].id
        // The deck prunes the binned page only after the pager stops on
        // `nextID`. `isAdvancing` tells the `currentPageID` handler to
        // skip the swipe count and the prune. See
        // `DeckViewModel.pruneQueuedPages` for the one-page-too-far
        // landing that pruning mid-flight causes.
        isAdvancing = true
        advanceTargetID = nextID
        advanceNonce += 1
    }

    /// Shows pending bytes, as `"<About >X pending"`. The `"About "`
    /// prefix appears when `hasEstimatedSizes` is true.
    private var pendingSpaceText: String {
        let prefix = trashService.hasEstimatedSizes ? "About " : ""
        return "\(prefix)\(Fmt.bytes(trashService.pendingBytes)) pending"
    }

    private var pendingSpaceAccessibilityLabel: String {
        "\(Fmt.bytes(trashService.pendingBytes)) pending. Freed after you empty the bin and Photos clears Recently Deleted."
    }

    /// Reports `TrashService.reclaimedBytes` as "<X> freed" — bytes
    /// completed Empty actions freed in total, across every launch, not
    /// `ShrinkService.sessionSavedBytes`.
    private var reclaimedSpaceText: String {
        // "freed", not "reclaimed": the longer word wraps the counter
        // onto two lines next to "pending".
        "\(Fmt.bytes(trashService.reclaimedBytes)) freed"
    }

    private var reclaimedSpaceAccessibilityLabel: String {
        "\(Fmt.bytes(trashService.reclaimedBytes)) reclaimed this session. Photos frees the space within 30 days."
    }

    // MARK: - Shrink progress badge and done toast

    /// The job the progress badge reports on: the first, FIFO, job still
    /// pending, exporting, or saving. `ShrinkService.enqueue` runs one
    /// export at a time. Only one job is ever in flight, though `jobs`
    /// can hold several queued behind it.
    private var activeShrinkJob: ShrinkService.ShrinkJob? {
        shrinkService.jobs.first { job in
            switch job.state {
            case .pending, .exporting, .saving:
                return true
            case .done, .doneOriginalKept, .failed:
                return false
            }
        }
    }

    private var isSavingActive: Bool {
        if case .saving = activeShrinkJob?.state { return true }
        return false
    }

    /// Text for the top-left badge. `.saving` has no numeric progress to
    /// report; the export finished, and the PhotoKit save is a single
    /// request. It shows a word instead of a stale or fabricated
    /// percentage.
    private var shrinkActiveProgressText: String? {
        guard let activeShrinkJob else { return nil }
        switch activeShrinkJob.state {
        case .pending:
            return "0%"
        case .exporting(let progress):
            // Capped at 99%: the export can report 1.0 progress before
            // the save starts, and 100% should mean fully done.
            let percent = Int((progress * 100).rounded())
            return "\(min(max(percent, 0), 99))%"
        case .saving:
            return "Saving…"
        case .done, .doneOriginalKept, .failed:
            return nil
        }
    }

    /// Sibling of `shrinkActiveProgressText`, purely for the progress
    /// capsule's `value` fraction. `.saving` has no numeric progress, but the
    /// bar should read as full while the save request is in flight.
    private var shrinkActiveProgressFraction: Double {
        guard let activeShrinkJob else { return 0 }
        switch activeShrinkJob.state {
        case .pending:
            return 0
        case .exporting(let progress):
            return min(max(progress, 0), 0.99)
        case .saving:
            return 1
        case .done, .doneOriginalKept, .failed:
            return 0
        }
    }

    /// A cheap, order-preserving fingerprint of every job's id and state,
    /// used purely as an `Equatable` key for `onChange(of:)`. See the
    /// note at that call site for why `ShrinkService.ShrinkJob` itself
    /// can't be used there directly.
    private var shrinkJobsSignature: String {
        shrinkService.jobs.map { "\($0.id)=\(shrinkStateTag($0.state))" }.joined(separator: "|")
    }

    private func shrinkStateTag(_ state: ShrinkService.JobState) -> String {
        switch state {
        case .pending:
            return "pending"
        case .exporting(let progress):
            return "exporting:\(Int((progress * 100).rounded()))"
        case .saving:
            return "saving"
        case .done(let newAssetID, let savedBytes):
            return "done:\(newAssetID):\(savedBytes)"
        case .doneOriginalKept(let newAssetID, let reason):
            return "doneOriginalKept:\(newAssetID):\(reason.rawValue)"
        case .failed(let reason):
            return "failed:\(reason)"
        }
    }

    /// Surfaces a brief toast the first time a job is observed in a terminal
    /// state. `toastedShrinkJobIDs` makes this idempotent across the
    /// repeated body re-evaluations a `@Published` job-array update
    /// triggers, so the same completion never toasts twice.
    ///
    /// `.failed` also shows a toast. Without it, the badge disappears
    /// with no message and no retry, and nothing tells the user the
    /// original was never touched.
    ///
    /// Nothing here touches the trash queue itself.
    /// `ShrinkService.onOriginalReadyToTrash`, wired in
    /// `PermissionGateView`, already queued or refused it by the time a
    /// job reaches any of these states.
    private func handleShrinkJobsChanged() {
        for job in shrinkService.jobs {
            guard !toastedShrinkJobIDs.contains(job.id) else { continue }
            switch job.state {
            case .done(_, let savedBytes):
                toastedShrinkJobIDs.insert(job.id)
                presentShrinkToast(
                    "Saved about \(Fmt.bytes(max(savedBytes, 0))). Original moved to bin.",
                    kind: .reclaimed,
                    retryAssetID: nil
                )
            case .doneOriginalKept(_, let reason):
                toastedShrinkJobIDs.insert(job.id)
                // Each reason gets a distinct message. A single
                // hardcoded message covering every kept-original outcome
                // could wrongly tell the user their video was liked.
                let message: String
                switch reason {
                case .liked:
                    message = "Shrunk copy saved. The original is liked, so it was kept."
                case .cancelled:
                    message = "Stopped after saving. The shrunk copy is in Photos; your original was kept."
                case .queueRefused:
                    message = "Shrunk copy saved. The original was kept."
                }
                presentShrinkToast(message, kind: .kept, retryAssetID: nil)
            case .failed(let reason):
                toastedShrinkJobIDs.insert(job.id)
                presentShrinkToast(
                    "Couldn't shrink: \(reason)",
                    kind: .failed,
                    retryAssetID: job.id
                )
            case .pending, .exporting, .saving:
                continue
            }
        }
    }

    /// Shows `message` in the toast and announces it directly to VoiceOver.
    /// The toast is the only notification anywhere in the app that a shrink
    /// finished, whether successfully, kept, or failed. It auto-hides after
    /// 2.5 seconds, and a plain `accessibilityLabel` on a view that was
    /// never focused is never actually spoken. `retryAssetID`, when
    /// non-nil, makes the toast itself tappable to re-enqueue the same
    /// asset. The rail's shrink button already reappears on a `.failed`
    /// job, since `isJobbed` excludes it, but nothing else points the user
    /// at it.
    private func presentShrinkToast(_ message: String, kind: ShrinkToastKind, retryAssetID: String?) {
        shrinkToastTask?.cancel()
        shrinkToastRetryAssetID = retryAssetID
        shrinkToastKind = kind
        withAnimation {
            shrinkToastMessage = message
        }
        AccessibilityNotification.Announcement(message).post()
        shrinkToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(2.5 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            dismissShrinkToastNow()
        }
    }

    private func dismissShrinkToastNow() {
        shrinkToastTask?.cancel()
        withAnimation {
            shrinkToastMessage = nil
        }
        shrinkToastRetryAssetID = nil
    }

    #if DEBUG
    /// Proves a shrink produced a real replacement asset in Photos, at
    /// the correct creation date, not only that the bin badge
    /// incremented. An implementation that skipped the export, or
    /// dropped the creation-date stamp, could still satisfy the badge
    /// alone.
    ///
    /// Format:
    /// "shrink_verify_<originalAssetID>_<newAssetID>_<width>_<height>_<dateMatches>_<origW>_<origH>".
    /// It encodes the newest completed job's replacement asset id. It
    /// also carries the replacement's pixel width and height, whether
    /// its `creationDate` matches the original's, and the source
    /// asset's own pixel width and height.
    ///
    /// The original's id leads so a caller can tell which job the
    /// reading belongs to. Without it, a test can only read "some job
    /// finished," with no way to confirm it was the one it triggered.
    ///
    /// Both dimensions are exposed, not just height. A preset targets
    /// the 1080p class regardless of portrait or landscape orientation,
    /// the same way `Fmt.isAboveShrinkThreshold`'s own short-side check
    /// does. Invisible, always present, DEBUG only.
    private var shrinkVerificationProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier(shrinkVerificationCache)
    }

    /// Changes only when a new job reaches a terminal `.done` or
    /// `.doneOriginalKept` reading, or an existing one's reading changes,
    /// never on an `.exporting` progress tick. Drives `.task(id:)` in
    /// `body`; see that call site's comment.
    private var shrinkVerificationCompletionKey: String {
        let completed = shrinkService.jobs.last { job in
            switch job.state {
            case .done, .doneOriginalKept: return true
            case .pending, .exporting, .saving, .failed: return false
            }
        }
        guard let job = completed else { return "none" }
        return "\(job.id)=\(shrinkStateTag(job.state))"
    }

    /// Off the render path — called only from the `.task(id:)` in `body`,
    /// never from a computed property `body` itself reads.
    private func computeShrinkVerificationIdentifier() -> String {
        let completed = shrinkService.jobs.last { job in
            switch job.state {
            case .done, .doneOriginalKept: return true
            case .pending, .exporting, .saving, .failed: return false
            }
        }
        guard let job = completed else { return "shrink_verify_none" }
        let newAssetID: String
        switch job.state {
        case .done(let id, _): newAssetID = id
        case .doneOriginalKept(let id, _): newAssetID = id
        case .pending, .exporting, .saving, .failed: newAssetID = ""
        }
        let library = PhotoLibraryService.shared
        let newSize = library.pixelSize(for: newAssetID)
        // The source asset's own dimensions. The original is only queued
        // for the trash at this point, never deleted, so it still
        // resolves.
        let originalSize = library.pixelSize(for: job.id)
        // Both dates must exist and agree. Two nils must never count as
        // a match, or a job that lost both creation dates would report a
        // false match.
        let newDate = library.assetMeta(for: newAssetID).creationDate
        let originalDate = library.assetMeta(for: job.id).creationDate
        let dateMatches = (newDate != nil) && (newDate == originalDate)
        return "shrink_verify_\(job.id)_\(newAssetID)_\(Int(newSize.width))_\(Int(newSize.height))_\(dateMatches)_\(Int(originalSize.width))_\(Int(originalSize.height))"
    }
    #endif
}

/// One page's own bottom-band content: its caption — date, resolution,
/// duration, size — and its action rail (Keep, Share, Shrink, Delete).
/// Both scroll with that page's video instead of staying fixed to the
/// screen. Every action reads and writes this page's own `entry.assetID`,
/// never `FeedView`'s notion of "current." A tap lands on the asset
/// actually under the user's thumb even while two pages are visible
/// mid-swipe.
///
/// Accessibility identifiers (`rail_like`, `rail_share`, `rail_shrink`,
/// `rail_trash`, `feed_caption`, `feed_coming_soon`) attach only when
/// `isActive` is true, the same flag `PlayerPageView` uses to drive
/// playback. With ±1 page preloaded, up to three of these views can
/// exist at once. Without this gating, `app.buttons["rail_like"]`, the
/// singular lookup every UI test uses, would match more than one
/// element. XCTest would then raise "multiple matches" instead of
/// tapping anything. Off-center pages still render the same buttons,
/// fully interactive; only the identifier is missing, never the tap
/// target.
private struct FeedPageContent: View {
    let entry: DeckEntry
    let isActive: Bool
    let isFinalExhausted: Bool
    /// Mirrors `FeedView.isFullscreen`, passed down for exactly one
    /// reason; see `captionZone`'s own comment. Everything else in this
    /// hiding path — `.opacity`, `.allowsHitTesting`,
    /// `.accessibilityHidden` on the whole `FeedPageContent` — is
    /// applied once. It is applied from the outside, at the `FeedView`
    /// call site.
    let hideForFullscreen: Bool
    /// Mirrors `FeedView.isScrubbing`. While the scrubber is active, its
    /// "0:01 / 0:03" time label sits centered in the chin, the same row
    /// the caption occupies. The caption fades out for the duration of
    /// the scrub instead of colliding with it.
    let isScrubbing: Bool
    @ObservedObject var viewModel: DeckViewModel
    @ObservedObject var trashService: TrashService
    @ObservedObject var shrinkService: ShrinkService
    @ObservedObject var shareCoordinator: ShareCoordinator
    let onRequestShrink: (String) -> Void
    let onAdvanceRequested: () -> Void
    let onOpenBinRequested: () -> Void
    /// The real top safe-area inset, measured once in `FeedView.body` and
    /// passed down. A proxy read here sits under the pager's
    /// `.ignoresSafeArea()` and would read 0. This lets
    /// `StageGeometry.bottomBand` put the rail's bottom edge exactly
    /// where `PlayerPageView` puts the video's bottom edge.
    let safeAreaTop: CGFloat
    /// Bumped by `FeedView` on every double tap of this page's video — see
    /// `FeedView.doubleTapKeepNonces`. Watched below; each bump is one
    /// `keepFromDoubleTap()`.
    let keepRequestNonce: Int

    /// The single shared source of shield, queue, and safety facts. Read
    /// only from `makeRailState()`, never from `body` directly. Every
    /// accessor here (`isShielded`, `isQueued`, `isDestructiveActionSafe`)
    /// is an O(1) in-memory read. `generation` is what lets this page's
    /// `@State rail` react to a like, unlike, queue, restore, empty, or
    /// resolution event that happened on a different page.
    @ObservedObject private var resolver = AssetKeyResolver.shared

    /// Bumped only when this page's own like turns on. Drives this page's
    /// heart `.symbolEffect(.bounce)`. Local to the page rather than
    /// shared, so liking one page never bounces a neighbor's heart.
    @State private var likeBounceToken: Int = 0

    /// Bottom-left triage facts for this page. Loaded once per asset
    /// through `.task(id:)`, never as a computed property. A page's body
    /// re-evaluates up to five times a second while an export runs. This
    /// value arrives from `PhotoLibraryService.loadPageMeta(for:)`, which
    /// does its `PHAsset` reads off the main actor.
    // `fileprivate`, not `private`. The `PageFacts` to `PageMeta`
    // initializer below, in this same file, outside `FeedPageContent`'s
    // closing brace, names this type as `FeedPageContent.PageMeta` from
    // outside the struct body. `private`'s "enclosing declaration only"
    // rule does not permit that, even within the same file.
    fileprivate struct PageMeta: Equatable {
        var dateText: String = ""
        var detailText: String = ""
        var voiceOverLabel: String = ""
        /// Short side over 1080 or long side over 1920. Read from
        /// `PageFacts`, so the render path makes no extra PhotoKit fetch.
        var isAboveShrinkThreshold: Bool = false
        /// `PageFacts` carries a flat coordinate rather than a
        /// `CLLocation`. `CLLocation` is a reference type, and `PageFacts`
        /// crosses an isolation boundary from the background executor
        /// that read it. `captionZone`'s place lookup rebuilds a
        /// `CLLocation` from this on the main actor, at no extra cost.
        var coordinate: PageFacts.Coordinate? = nil
        /// Reverse-geocoded from `coordinate` by a separate `.task(id:)`,
        /// for the current page only — see `PlaceLookup` — never by the
        /// background load itself. `nil` until that lookup resolves, or
        /// forever if the asset has no location or the geocoder found
        /// nothing usable.
        var placeText: String? = nil
        /// False until the background load actually returns a real
        /// reading for this asset. Gates `RailState.deleteEnabled`: a
        /// page whose meta has not loaded yet offers no destructive
        /// action.
        var isLoaded: Bool = false

        // MARK: - `feed_facts_` probe fields
        //
        // From the same `PageFacts` reading, at no cost of a third
        // PhotoKit fetch. Raw values, not display strings: the probe
        // carries the exact facts a test's own predicate re-derives
        // from, independent of `detailText`/`dateText` above. An
        // assertion must never be an echo of the code under test.
        var pixelWidth: Int = 0
        var pixelHeight: Int = 0
        var durationMs: Int = 0
        var subtypeRaw: Int = 0
        /// -1 when the asset has no creation date.
        var createdMs: Int64 = -1
    }

    @State private var meta = PageMeta()

    /// Every rail-relevant fact about this page's own asset. Do not
    /// compute this in `body`. It needs a `PHAsset.pixelSize` fetch for
    /// `canShrink`. With up to three pages mounted and an export
    /// republishing `jobs` about five times a second, that is many
    /// main-actor fetches. `isLiked` and `TrashService.isQueued` are O(1)
    /// resolver reads. `rail` is loaded once per relevant change instead,
    /// through `.task(id: railInputs)`, entirely from in-memory state.
    /// `body` itself then performs zero PhotoKit and zero SwiftData
    /// work, no matter how often it re-evaluates.
    private struct RailState {
        let liked: Bool
        let queued: Bool
        let jobbed: Bool
        let canShrink: Bool
        /// VoiceOver hint for the shrink button when `canShrink` is false.
        /// `nil` exactly when `canShrink` is true.
        let shrinkDisabledReason: String?
        /// Gates the delete button: false while this page's meta has not
        /// loaded, or while rotation resolution has not finished
        /// (`AssetKeyResolver.isDestructiveActionSafe`). This over-excludes
        /// a destructive action rather than ever exposing a kept video to
        /// one.
        let deleteEnabled: Bool

        /// The value before this page's first `.task(id: railInputs)`
        /// completes: no destructive action is offered, as a fail-safe
        /// initial shape. A one-turn lag on a rail glyph is invisible; a
        /// synchronous fetch on the render path is not.
        static let gated = RailState(
            liked: false,
            queued: false,
            jobbed: false,
            canShrink: false,
            shrinkDisabledReason: "Checking this video…",
            deleteEnabled: false
        )
    }

    @State private var rail = RailState.gated
    /// Both buttons open a sheet or preview after a short delay. The
    /// bounce gives feedback at once. Bumped on tap to drive the same
    /// `.symbolEffect(.bounce)` `likeButton` already uses, so the rail's
    /// three interactive glyphs all answer a touch the same way.
    @State private var albumBounceToken = 0
    @State private var shrinkBounceToken = 0

    /// Cache key for `rail`. Deliberately not keyed on `shrinkService.jobs`
    /// itself, or its export percentage. That array republishes up to
    /// five times a second during an export. Keying a `.task(id:)` off
    /// it would re-run this load at that rate, recreating the exact cost
    /// this precompute exists to remove. `shrinkService.isJobbed(_:)`
    /// only flips at the transitions the rail actually renders
    /// differently, from none to jobbed, and from jobbed to
    /// failed-and-retryable, which is the coarse signal this needs.
    private var railInputs: String {
        "\(entry.assetID)|\(resolver.generation)|\(shrinkService.isJobbed(entry.assetID))|\(meta.isLoaded)"
    }

    /// Reads only in-memory state. `resolver.isShielded`, `isQueued`,
    /// and `isDestructiveActionSafe` are all O(1) set or enum reads.
    /// `shrinkService.isJobbed` is a scan bounded by jobs started this
    /// session, and `meta.isAboveShrinkThreshold` is a stored `Bool`.
    /// Zero PhotoKit calls, zero SwiftData calls.
    private func makeRailState() -> RailState {
        let assetID = entry.assetID
        let liked = resolver.isShielded(assetID)
        let queued = resolver.isQueued(assetID)
        let jobbed = shrinkService.isJobbed(assetID)
        let aboveShrinkThreshold = meta.isAboveShrinkThreshold
        let destructiveSafe = resolver.isDestructiveActionSafe
        let canShrink = aboveShrinkThreshold && !liked && !queued && !jobbed && destructiveSafe
        let reason: String?
        if canShrink {
            reason = nil
        } else if !destructiveSafe {
            reason = "Cloudfull is still checking which videos you kept."
        } else if jobbed {
            reason = "This video is already being shrunk"
        } else if liked {
            reason = "Kept videos don't need shrinking"
        } else if queued {
            reason = "This video is queued for deletion"
        } else if !aboveShrinkThreshold {
            reason = "Only 4K videos can be shrunk"
        } else {
            reason = "This video can't be shrunk right now"
        }
        let deleteEnabled = !liked && !jobbed && destructiveSafe && meta.isLoaded
        return RailState(
            liked: liked,
            queued: queued,
            jobbed: jobbed,
            canShrink: canShrink,
            shrinkDisabledReason: reason,
            deleteEnabled: deleteEnabled
        )
    }

    var body: some View {
        // The rail's bottom padding is the page's bottom band, where the
        // video's bottom edge sits, plus a small clearance; the caption
        // stays in the chin. This reader fills the same page cell
        // `PlayerPageView` does; both sit under the pager's
        // `.ignoresSafeArea()`. So `proxy.size` is the same container
        // size that view feeds `StageGeometry`.
        GeometryReader { proxy in
            let bottomBand = StageGeometry.bottomBand(safeAreaTop: safeAreaTop, containerSize: proxy.size)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                // `exhaustedCard` sits directly above the caption and
                // rail row, on whichever page is both the deck's last
                // entry and the one actually centered.
                if isFinalExhausted {
                    exhaustedCard
                        .padding(.bottom, 24)
                }
                HStack(alignment: .bottom, spacing: 0) {
                    captionZone
                    VStack(alignment: .trailing, spacing: 0) {
                        if isActive, let calloutMessage = shareCoordinator.calloutMessage {
                            railCallout(calloutMessage)
                        }
                        actionRail(bottomBand: bottomBand)
                    }
                    .animation(.easeInOut(duration: 0.2), value: shareCoordinator.calloutMessage)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            #if DEBUG
            pageFactsProbe
            #endif
        }
        // `loadPageMeta` does its PhotoKit reads on a background executor
        // and hands back a `Sendable` value type. This `await` frees the
        // main thread for the user's next swipe. Without it, up to three
        // mounted pages would each run their PhotoKit reads
        // synchronously, on the main thread, on every page change.
        .task(id: entry.assetID) {
            let facts = await PhotoLibraryService.shared.loadPageMeta(for: entry.assetID)
            guard !Task.isCancelled else { return }
            meta = PageMeta(facts)
            #if DEBUG
            // The readout compares this with what is on screen.
            if isActive { PlaybackReadout.shared.noteAsset(width: meta.pixelWidth, height: meta.pixelHeight) }
            #endif
        }
        .task(id: railInputs) {
            wdMark("railState")
            rail = makeRailState()
        }
        // Runs for the current page only, never a preloaded neighbor
        // page. Keyed on `meta.isLoaded` too, because `meta` starts empty
        // and this must wait for the background load to finish before
        // reading `meta.coordinate`. That reload also wipes
        // `meta.placeText`, which is fine, since this task re-runs right
        // behind it.
        .task(id: "\(isActive)|\(entry.assetID)|\(meta.isLoaded)") {
            guard isActive, meta.isLoaded else { return }
            // `PageFacts` carries a flat coordinate rather than a
            // `CLLocation` reference, because it crosses an isolation
            // boundary. Rebuilding it here costs an allocation and no
            // I/O.
            let location = meta.coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
            wdMark("placeLookup")
            let place = await PlaceLookup.shared.place(for: entry.assetID, location: location)
            guard !Task.isCancelled else { return }
            meta.placeText = place
        }
        .onChange(of: keepRequestNonce) { _, _ in
            keepFromDoubleTap()
        }
    }

    #if DEBUG
    /// "feed_facts_<w>_<h>_<durationMs>_<subtypes>_<createdMs>": the
    /// centered video's own facts, straight from `PageMeta`, which the
    /// background `loadPageMeta` load already fills from the `PageFacts`
    /// it returned.
    ///
    /// Same gate as `feed_caption`, `isActive && !hideForFullscreen`,
    /// plus `meta.isLoaded`. Without the loaded check, a page would
    /// attach the identifier for the zeroed `PageMeta()` default before
    /// that load lands. A probe reading it could then record that
    /// all-zero value as if it were the asset's real facts.
    ///
    /// Only the active, non-fullscreen, loaded page attaches the
    /// identifier. So `elementSnapshots(withPrefix:)`'s singular lookup
    /// can never match more than one of the up-to-three mounted pages.
    /// `createdMs` is `-1` when the asset has no creation date.
    /// Invisible, no VoiceOver label, DEBUG only.
    private var pageFactsProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier(
                isActive && !hideForFullscreen && meta.isLoaded
                    ? "feed_facts_\(meta.pixelWidth)_\(meta.pixelHeight)_\(meta.durationMs)_\(meta.subtypeRaw)_\(meta.createdMs)"
                    : ""
            )
    }
    #endif

    // MARK: - Bottom-left caption zone

    /// The date line: `meta.dateText` and, when a lookup found one,
    /// `meta.placeText`, joined on the same line — for example
    /// "<date> · <time> · <place>".
    private var dateLine: String {
        [meta.dateText, meta.placeText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var captionZone: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dateLine)                           // "<date> · <time> · <place>"
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                // Always one line. A long city name pushes this past the
                // chin's width, so it shrinks to 75% before it truncates.
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
            Text(meta.detailText)                    // "4K · 1:12 · 428 MB"
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .feedShadow()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.bottom, 20)
        // The caption uses the full width because the rail is on the
        // video, not in the chin.
        .padding(.trailing, 16)
        .opacity(isScrubbing ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: isScrubbing)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        // This is the one identifier in `FeedPageContent` that can stay
        // reachable while the view is fullscreen.
        // `.accessibilityElement(children: .combine)` synthesizes its own
        // accessibility node. That node does not always get the ancestor
        // `.accessibilityHidden(isFullscreen)` applied at the `FeedView`
        // call site. A plain `Button` such as `rail_like`, under the
        // same ancestor and the same flag, does get it. The other
        // identifiers `FeedPageContent` carries are unaffected, because
        // none of them combine children.
        //
        // So this view applies `.accessibilityHidden(hideForFullscreen)`
        // directly on the synthesized node, and removes the identifier
        // in fullscreen. Off-center pages still render, fully
        // interactive, just without the identifier.
        .accessibilityHidden(hideForFullscreen)
        .accessibilityIdentifier(isActive && !hideForFullscreen ? "feed_caption" : "")
        .accessibilityLabel(meta.placeText.map { "\($0). " + meta.voiceOverLabel } ?? meta.voiceOverLabel)
    }


    // MARK: - Rail callout
    //
    // Gated on `isActive`. `shareCoordinator.calloutMessage` is one value
    // shared by every rendered page. Without this gate, up to three
    // pages would each show the same "Added to Album" text over their
    // own rail at once. `app.descendants(matching: .any)["feed_coming_soon"]`,
    // a singular lookup used by `M4Tests.testAddCurrentVideoToNewAlbum`,
    // would match more than one element, and XCTest would report the
    // lookup as not found.

    private func railCallout(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .feedGlass(in: Capsule())
            .transition(.opacity)
            .accessibilityIdentifier("feed_coming_soon")     // UI tests use this identifier. The name does not describe the callout.
            .accessibilityLabel(message)
            .padding(.bottom, 8)
    }

    // MARK: - The action rail
    //
    // Order, top to bottom: Keep, Share, Album, Shrink, Delete. UI tests
    // address rail buttons by identifier, never by position, so this
    // order is safe to change.
    //
    // Every identifier below folds `!hideForFullscreen` into its existing
    // `isActive` gate. The ancestor `.accessibilityHidden(isFullscreen)`
    // does not always reach these elements. Each identifier checks
    // `!hideForFullscreen` directly.

    /// `bottomBand` is the black band below the video on this page. The
    /// rail's bottom edge sits `Rail.seamClearance` above the video's
    /// bottom edge, the playhead seam — on the video, not in the chin.
    private func actionRail(bottomBand: CGFloat) -> some View {
        VStack(spacing: Rail.spacing) {
            likeButton(rail)
            shareButton
            albumButton
            shrinkButton(rail)
            deleteButton(rail)
        }
        .padding(.trailing, 10)
        .padding(.bottom, bottomBand + Rail.seamClearance)
    }

    /// Adding to an album is also possible through the system share sheet
    /// (`AddToAlbumActivity`), several taps deep. This button promotes
    /// the same destination, the same sheet — `FeedView` already mounts
    /// `.sheet(item: $shareCoordinator.albumPickerTarget)` — onto the
    /// rail.
    private var albumButton: some View {
        Button {
            Haptics.tap()
            albumBounceToken += 1
            shareCoordinator.albumPickerTarget = .init(id: entry.assetID)
        } label: {
            // Outline glyph, matching the photo row: a single square with
            // a plus. `rectangle.stack.badge.plus` hangs a filled badge
            // below its own box, which reads heavier than its neighbors
            // and drags its label off their baseline.
            //
            // The size override is needed because a rectangle runs along
            // all four edges of its box. A heart, an arrow, and a trash
            // can only touch theirs at a few points. At an equal point
            // size, the rectangle looks larger.
            RailItem(systemName: "plus.rectangle.on.rectangle", label: "Album", glyphSize: Rail.album)
                .symbolEffect(.bounce, options: .speed(1.4), value: albumBounceToken)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isActive && !hideForFullscreen ? "rail_album" : "")
        .accessibilityLabel("Add to album")
        .accessibilityHint("Opens the album picker for this video")
    }

    private func likeButton(_ rail: RailState) -> some View {
        Button(action: toggleLike) {
            RailItem(
                systemName: rail.liked ? "heart.fill" : "heart",
                label: "Keep",
                tint: rail.liked ? .red : .white
            )
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, options: .speed(1.4), value: likeBounceToken)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isActive && !hideForFullscreen ? "rail_like" : "")
        .accessibilityLabel("Keep")
        .accessibilityAddTraits(rail.liked ? .isSelected : [])
        .accessibilityHint(rail.liked
            ? "Removes the protection on this video"
            : "Protects this video so Cloudfull can never delete it")
    }

    /// Always present on the rail, disabled rather than hidden when
    /// ineligible. A user scrolling past a liked or already-1080p video
    /// sees the same items every time, rather than the rail reflowing
    /// under their thumb.
    private func shrinkButton(_ rail: RailState) -> some View {
        Button {
            Haptics.tap()
            shrinkBounceToken += 1
            onRequestShrink(entry.assetID)
        } label: {
            RailItem(
                systemName: "arrow.down.right.and.arrow.up.left",
                label: "Shrink",
                tint: rail.canShrink ? .white : .white.opacity(0.4),
                glyphSize: Rail.shrink
            )
            .symbolEffect(.bounce, options: .speed(1.4), value: shrinkBounceToken)
        }
        .disabled(!rail.canShrink)
        .buttonStyle(.plain)
        .accessibilityIdentifier(isActive && !hideForFullscreen ? "rail_shrink" : "")
        .accessibilityLabel("Shrink")
        .accessibilityHint(rail.canShrink
            ? "Opens a preview of shrinking this video to 1080p before queuing the original for deletion"
            : rail.shrinkDisabledReason ?? "This video can't be shrunk right now")
    }

    /// Opens the system share sheet for this page's video. Never
    /// `.disabled(...)`: every refusal path, such as a vanished asset or
    /// the Wi-Fi guard, gives a spoken, visible answer through the rail
    /// callout instead.
    private var shareButton: some View {
        Button {
            shareCoordinator.beginShare(assetID: entry.assetID)
        } label: {
            if let download = shareCoordinator.download, download.assetID == entry.assetID {
                // The iCloud download shows as a cloud glyph with a
                // progress ring, in the rail. It replaces the Share
                // glyph, not a text callout.
                VStack(spacing: 3) {
                    // Do not refactor this into the feed's shared ring. A
                    // shared extraction can silently resize the glyph.
                    // This control owns these numbers; the feed's loader
                    // copies them, not the other way around.
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: max(download.fraction, 0.02))
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: download.fraction)
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: Rail.glyph * 0.55, weight: .medium))
                    }
                    .frame(width: Rail.hit - 6, height: Rail.hit - 6)
                    .frame(width: Rail.hit, height: Rail.hit)
                    Text("Share")
                        .font(Rail.labelFont)
                }
                .foregroundStyle(.white)
                .feedShadow()
                .contentShape(Rectangle())
            } else {
                RailItem(systemName: "arrowshape.turn.up.right", label: "Share")
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isActive && !hideForFullscreen ? "rail_share" : "")
        .accessibilityLabel("Share")
        .accessibilityHint("Opens the share sheet for this video, including Add to Album")
    }

    // The app shields liked videos, and a video mid-shrink or already
    // shrunk, from the trash queue entirely. Do not queue a video that
    // `ShrinkService` holds. PhotoKit can then delete the original
    // during the export. The export then saves a copy of a deleted
    // video. The button swaps to a disabled glyph in both cases, so it
    // neither looks tappable nor can fire `handleTrashTap` by any route.
    private func deleteButton(_ rail: RailState) -> some View {
        Button(action: handleTrashTap) {
            RailItem(
                systemName: trashIconName(rail),
                label: trashLabel(rail),
                tint: rail.deleteEnabled ? .white : .white.opacity(0.4),
                glyphSize: Rail.trash
            )
            .contentTransition(.symbolEffect(.replace))
        }
        // `deleteEnabled` folds in `rail.liked`, `rail.jobbed`, and the
        // fail-safe gate. The button stays disabled the whole time
        // rotation resolution has not landed, not only while liked or
        // mid-shrink.
        .disabled(!rail.deleteEnabled)
        .buttonStyle(.plain)
        .accessibilityIdentifier(isActive && !hideForFullscreen ? "rail_trash" : "")
        .accessibilityLabel(trashAccessibilityLabel(rail))
        .accessibilityHint(trashAccessibilityHint(rail))
    }

    private func trashIconName(_ rail: RailState) -> String {
        if !rail.deleteEnabled { return "trash.slash" }
        return rail.queued ? "trash.fill" : "trash"
    }

    private func trashLabel(_ rail: RailState) -> String {
        if rail.liked { return "Kept" }
        if rail.jobbed { return "Busy" }
        if !rail.deleteEnabled { return "Delete" }
        return rail.queued ? "Queued" : "Delete"
    }

    private func trashAccessibilityLabel(_ rail: RailState) -> String {
        if rail.liked { return "Protected, cannot delete" }
        if rail.jobbed { return "Shrinking in progress, cannot delete" }
        if !rail.deleteEnabled { return "Delete video, not ready yet" }
        return rail.queued ? "Queued for deletion" : "Delete video"
    }

    private func trashAccessibilityHint(_ rail: RailState) -> String {
        if rail.liked { return "This video is liked, so it can never be queued for deletion" }
        if rail.jobbed { return "This video is being shrunk, so it can't be queued for deletion until that finishes" }
        if !rail.deleteEnabled { return "Cloudfull is still checking which videos you kept." }
        return rail.queued
            ? "Removes this video from the trash queue"
            : "Queues this video for deletion and moves to the next video"
    }

    // MARK: - Exhausted card

    private var exhaustedCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white)
            Text("You've seen everything")
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text("Everything left is kept or queued for deletion. Restore something from the bin, or unkeep a video, to keep scrolling.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Button("Open Bin") { onOpenBinRequested() }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .controlSize(.regular)
                .accessibilityIdentifier("exhausted_open_bin")
                .accessibilityLabel("Open the bin")
                .accessibilityHint("Opens the list of videos queued for deletion")
        }
        .padding(16)
        .frame(maxWidth: 320)
        .feedGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity)
        // Same guard as `filter_empty_card`: without it, this bare
        // identifier would outrank `exhausted_open_bin` on the Button it
        // contains. No test resolves the inner button. It is a
        // precaution.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exhausted_card")
    }

    // MARK: - Actions, scoped to this page's own asset

    private func toggleLike() {
        let assetID = entry.assetID
        if viewModel.isLiked(assetID) {
            let applied = viewModel.unlike(assetID: assetID)
            if applied {
                Usage.shared.action(.unkeep, source: .rail, mode: .videos)
                KeepsAlbum.shared.remove(assetID)
            }
        } else if !trashService.pendingEmptyIDs.contains(assetID) {
            let applied = viewModel.like(assetID: assetID)
            if applied {
                Usage.shared.action(.keep, source: .rail, mode: .videos)
                KeepsAlbum.shared.add(assetID)
            }
            Haptics.tap()
            likeBounceToken += 1
        }
        // else: this asset is mid-delete inside `emptyBin()` right now, so
        // `TrashService.restore(assetID:)` would refuse it. PhotoKit may
        // already have removed the asset from the library by the time that
        // call would run. Skip the like entirely, rather than write a
        // `LikedEntry` that the restore behind it silently failed to back
        // up.
    }

    /// A double tap on the video. Keep-only, never unkeep: an accidental
    /// double tap must not strip protection from a video the user
    /// deliberately kept, so unkeeping stays an explicit rail tap. Same
    /// mid-delete guard as `toggleLike`. An already-kept video just
    /// bounces the rail heart again, so the tap is still acknowledged.
    private func keepFromDoubleTap() {
        let assetID = entry.assetID
        guard !trashService.pendingEmptyIDs.contains(assetID) else { return }
        if !viewModel.isLiked(assetID) {
            let applied = viewModel.like(assetID: assetID)
            if applied {
                Usage.shared.action(.keep, source: .doubleTap, mode: .videos)
                KeepsAlbum.shared.add(assetID)
            }
            Haptics.tap()
        } else {
            Usage.shared.keepTapNoop(mode: .videos)   // a double tap on an already-kept video
        }
        likeBounceToken += 1
    }

    /// A second tap on an already-queued page restores it, instead of
    /// queuing and advancing again. Without a queued and not-queued
    /// distinction visible in the rail, a repeat tap would move the pager
    /// forward while changing nothing else. The user would see this as a
    /// tap that did nothing, or worse, as a second video queued when
    /// only one was.
    ///
    /// Refuses a video with an active or completed shrink job the same
    /// way it refuses a liked one. The rail button is already disabled
    /// for this case. But this guard stops a delivered-late gesture from
    /// queuing the asset `ShrinkService` still holds mid-export. PhotoKit
    /// could otherwise delete it while the export runs. The export would
    /// then quietly save a copy of a video the user just deleted.
    private func handleTrashTap() {
        let assetID = entry.assetID
        guard !viewModel.isLiked(assetID), !shrinkService.isJobbed(assetID) else { return }
        if trashService.isQueued(assetID) {
            // A second trash tap on the page undoes the queue. It logs
            // `unqueuedInFeed`, which is separate from a bin Restore or
            // a Keep.
            if trashService.restore(assetID: assetID) { Usage.shared.unqueuedInFeed(mode: .videos) }
            return
        }
        let queued = trashService.queue(assetID: assetID)
        if queued { Usage.shared.action(.delete, source: .rail, mode: .videos) }
        if queued { Usage.shared.deleted(mode: .videos, width: meta.pixelWidth, height: meta.pixelHeight, durationMs: meta.durationMs) }
        if queued { DailyReminder.shared.noteFirstDelete() }
        if queued { Haptics.tap() }
        onAdvanceRequested()
    }
}

extension FeedPageContent.PageMeta {
    /// A straight copy. Every string was formatted on the background
    /// thread that read the asset; nothing here does work.
    init(_ facts: PageFacts?) {
        guard let facts else { self = .init(); return }
        self.init(
            dateText: facts.dateText,
            detailText: facts.detailText,
            voiceOverLabel: facts.voiceOverLabel,
            isAboveShrinkThreshold: facts.isAboveShrinkThreshold,
            coordinate: facts.coordinate,
            placeText: nil,
            isLoaded: true,
            pixelWidth: facts.pixelWidth,
            pixelHeight: facts.pixelHeight,
            durationMs: facts.durationMs,
            subtypeRaw: facts.subtypeRaw,
            createdMs: facts.createdMs
        )
    }
}

/// A rail item: a flat white glyph, no bubble, no material, with a small
/// caption underneath. The only chrome is the drop shadow that keeps it
/// legible on a bright frame.
struct RailItem: View {
    let systemName: String
    let label: String
    var tint: Color = .white
    /// Optical override for a glyph not drawn to the same visual weight as
    /// the rest of the rail — see the Album button's call site. Defaults
    /// to `Rail.glyph`.
    var glyphSize: CGFloat = Rail.glyph

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .medium))    // Rail.glyph by default
                .frame(width: Rail.hit, height: Rail.hit)           // 40 × 40
            Text(label)
                .font(Rail.labelFont)                               // 10 semibold
        }
        .foregroundStyle(tint)
        .feedShadow()
        .contentShape(Rectangle())
    }
}

#if DEBUG
/// The `main_stalls_` probe plus its visible readout, in a view of its
/// own, so only this view re-renders when the watchdog publishes, never
/// `FeedView` and its whole-deck `ForEach`.
///
/// Non-private, and mounted by `GateProbes`
/// (Cloudfull/Storage/DebugProbes.swift), not here. `RootView` unmounts
/// `FeedView` while the mode is `.photos`. A UI test swiping the photo
/// feed could never find `main_stalls_` if it were mounted only in
/// `FeedView`'s own `ZStack`. The watchdog itself, started by
/// `GateProbes.task`, runs the whole time regardless of mode.
struct MainStallProbeView: View {
    @ObservedObject private var watchdog = MainThreadWatchdog.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("main_stalls_\(watchdog.stallCount)_\(watchdog.worstGapMs)")
    }
}

/// The visible stall readout (`-cloudfull-show-stalls`). It is separate
/// from `MainStallProbeView` above because `GateProbes` mounts that
/// probe inside a `.frame(width: 1, height: 1)`. A readout placed inside
/// it would be proposed one point of space. It would draw wherever that
/// point happened to be, not at the bottom of the screen. `RootView`
/// mounts this view instead, at full size, so it can be read in Photos
/// mode as well as Videos. It carries no accessibility identifier: the
/// machine-readable `main_stalls_` probe is still exactly one element,
/// mounted once, by `GateProbes`.
struct MainStallReadoutView: View {
    @ObservedObject private var watchdog = MainThreadWatchdog.shared
    /// Observed, not read once: the readout can be turned on from
    /// Settings mid-session, and this view has to notice.
    @ObservedObject private var diagnostics = DiagnosticsSwitch.shared
    /// What the feed is actually playing, and what the asset is.
    @ObservedObject private var playback = PlaybackReadout.shared

    var body: some View {
        if diagnostics.isOn {
            VStack(alignment: .trailing, spacing: 1) {
                Text(playback.line)
                Text("stalls \(watchdog.stallCount) · worst \(watchdog.worstGapMs)ms @ \(watchdog.worstMark)")
                ForEach(Array(watchdog.recentStalls.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.trailing)
            .padding(.trailing, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

}
#endif
