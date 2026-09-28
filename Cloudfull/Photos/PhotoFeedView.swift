//
//  PhotoFeedView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import SwiftData

/// Holds the photo pager's per-row frames without publishing them.
///
/// This class lives in `@State`. SwiftUI keeps the object alive for the
/// view's lifetime, and a property write on it does not invalidate the
/// view.
///
/// The derived values the body reads (`scrollAnchorID`, `centerBandIDs`)
/// stay in real `@State`. The code writes them at most about 20 times a
/// second, and only when they change. See the comment on
/// `PhotoFeedView.rowFrames` for the reasoning behind this design.
@MainActor
final class PhotoRowFrameStore {
    var frames: [String: CGRect] = [:]
    /// The scroll view's own top edge in `PhotoFeedView.viewportSpace`, the
    /// same coordinate space that `frames` uses. The code measures the
    /// rows in a space whose origin is the safe-area top, while
    /// `topClearance` is a screen-top number. Comparing the two directly
    /// places a stop-at-top crush too low by the safe-area height. The
    /// scroll view's frame changes only on rotation, not on scroll, so a
    /// read once per layout costs nothing per frame.
    var scrollTop: CGFloat = 0
    /// The UIKit scroll view under SwiftUI's `ScrollView`, found once by
    /// `ScrollViewFinder`. The reveal before a delete animates its
    /// `contentOffset` directly, because SwiftUI's own scroll command is
    /// deferred and re-animated on iOS 27.
    weak var uiScrollView: UIScrollView?
    /// The trailing edge of `recomputeGeometry`'s throttle. See that
    /// method. It lives here, not in `@State`, for the same reason as
    /// `frames`: a write to it must not invalidate the body.
    var trailingTask: Task<Void, Never>?
}

/// A vertical, free-scrolling feed with one photo post per row.
///
/// The scroll uses plain deceleration. There is no view-aligned paging and
/// no snap to a post's top edge. A release mid-post stays exactly where
/// the finger left it, the same as a stock `ScrollView`.
///
/// "Current" is a geometric read, not a scroll target. See
/// `nearestCenterID` and `recomputeGeometry` below. A photo post's
/// height varies with its own aspect ratio and its header and caption.
/// There is no fixed page size to paginate against, unlike in
/// `FeedView`'s video pager.
struct PhotoFeedView: View {
    @ObservedObject private var deck = PhotoDeck.shared
    @StateObject private var trashService: TrashService
    @StateObject private var shareCoordinator: ShareCoordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayScale) private var displayScale

    /// The settled current post. It drives `isCurrent` on every child,
    /// tier 2 metadata and `PlaceLookup`, seen-marking, and the metadata
    /// prefetch window.
    ///
    /// This value does not come from `.scrollPosition(id:)` snapping. The
    /// settle handler promotes it from `scrollAnchorID` below only once
    /// `ScrollPhaseGate` goes idle. See the settle handler in `pager`.
    @State private var currentPostID: String?
    /// The post whose frame currently covers the viewport's vertical
    /// center, or, with no exact hit, the one with the most visible
    /// height. The code recomputes it from `rowFrames` about 20 times a
    /// second while the user scrolls.
    ///
    /// `recomputeGeometry` writes this from `rowFrames`. Seeding and
    /// `advanceToNextPost` also set it directly. It is a read of where the
    /// free-scrolling pager actually is, not a scroll target. A scroll
    /// target makes the pager snap to a post. `currentPostID` above is
    /// promoted from this value on settle.
    @State private var scrollAnchorID: String?
    /// Each mounted row's own frame, in `Self.viewportSpace` coordinates.
    /// The outer, non-scrolling container anchors this coordinate space,
    /// not the scrolling content, so the coordinates are screen-relative.
    /// This is the one geometry stream that both `scrollAnchorID` and
    /// `centerBandIDs` read.
    ///
    /// This value is a plain reference type, not `@State`. Storing the
    /// frame dictionary in `@State` publishes up to `rows × display rate`
    /// times a second while the user scrolls. Each publish invalidates
    /// this whole body: the `LazyVStack`, the `ForEach` over
    /// `deck.entries`, and the chrome. A plain reference box holds the
    /// same data with no publishing. Only the two derived values below,
    /// `scrollAnchorID` and `centerBandIDs`, stay in `@State`.
    /// `recomputeGeometry` writes them at most 20 times a second, and only
    /// when they change.
    @State private var rowFrames = PhotoRowFrameStore()
    /// Which mounted posts have their own center band — the middle third of
    /// their own height — overlapping the screen's center third. This is
    /// independent of `currentPostID` and settle, so a Live post can start
    /// playing mid-scroll.
    @State private var centerBandIDs: Set<String> = []
    @State private var lastGeometryComputeTime: Date = .distantPast
    /// Lets `advanceToNextPost`, which runs outside the `ScrollViewReader`
    /// closure, still drive an explicit, animated `scrollTo` after a
    /// delete. The pager has no `.scrollPosition(id:)` binding to do this
    /// through assignment alone.
    @State private var scrollProxy: ScrollViewProxy?
    @ObservedObject private var scrollGate = ScrollPhaseGate.shared
    /// The photo filter menu writes new filters here. The handler below
    /// hands them to the deck, which refreshes the pool and deals a fresh
    /// window. The deck reshuffles on a filter change here, not on every
    /// entry into Photos.
    @ObservedObject private var photoOptionsStore = PhotoOptionsStore.shared
    @State private var showTrash = false
    /// A loading state shown instead of plain black, set in this view's
    /// root `.task` if the deck has not yet dealt its first cycle. It
    /// never flips back to `false` once set.
    @State private var showLoadingIndicator = false
    /// True from a trash tap's `advanceToNextPost` call until its scroll
    /// animation completes. Mirrors `FeedView.isAdvancing`. See that
    /// property's comment.
    @State private var isAdvancing = false
    /// The id of the post being pinched right now, or nil.
    ///
    /// This value has two jobs. It locks the pager for the whole span of
    /// the gesture, mirroring `FeedView.isScrubbing` and
    /// `.scrollDisabled`. A two-finger pinch must never also register as
    /// a one-finger page drag. It also raises that one row's `.zIndex`
    /// above its neighbours. A row's own subtree cannot z-order itself
    /// against a sibling row. Without this the zoomed photo draws under
    /// the posts after it in the `LazyVStack`.
    @State private var zoomingPostID: String?
    /// Incremented after every prune that removes a row. The pager's
    /// `ScrollViewReader` re-anchors on `currentPostID` in response.
    /// Mirrors `FeedView.reanchorNonce`.
    @State private var reanchorNonce = 0
    /// A five-second watch, started after each Keep, for the direction of
    /// the user's next scroll. See `settleKeepFollowup`.
    @State private var keepWatch: Task<Void, Never>?
    @State private var keepWatchBaseOffset: CGFloat = 0
    /// Session-only state behind the top-bar Live toggle. `liveDefaultOn`
    /// below seeds it, but it never writes back into `liveDefaultOn`.
    ///
    /// Binding the toggle straight to
    /// `@AppStorage("settings.liveDefaultOn")` would let it silently
    /// rewrite the persisted default too, and nothing resets that key on
    /// its own. Keeping the two values separate avoids this.
    @State private var isLiveOn = true
    /// The persisted default behind the Live toggle. `SettingsView`'s own
    /// row reads and writes this same key. This view reads it once, in
    /// `.task`, to seed `isLiveOn`, and never writes it.
    @AppStorage("settings.liveDefaultOn") private var liveDefaultOn = true

    #if DEBUG
    /// Mirrors whichever post last reported itself both current and
    /// playing as a Live post, for the `photo_live_state_` accessibility
    /// identifier. Resets on a page change, so a stale reading from the
    /// previous current post can never linger.
    @State private var currentLiveState: LivePhotoPlaybackState?
    #endif

    init(trashService: TrashService) {
        _trashService = StateObject(wrappedValue: trashService)
        _shareCoordinator = StateObject(wrappedValue: ShareCoordinator())
    }

    /// The named ancestor for every row's `.onGeometryChange` frame read.
    /// The outer, non-scrolling `ZStack` in `body` applies this space. A
    /// row's `frame(in: .named(Self.viewportSpace))` is already
    /// screen-relative: it moves as the row scrolls, but the space itself
    /// does not.
    private static let viewportSpace = "photoFeedViewport"
    /// Caps how often a scroll frame's geometry turns into
    /// `scrollAnchorID`/`centerBandIDs`: about 20 Hz, well under the
    /// 0.25 s Live dwell window. No start or stop decision is ever delayed
    /// by more than one tick of this throttle.
    private let geometryComputeInterval: TimeInterval = 1.0 / 20

    var body: some View {
        // Counts how often a scroll invalidates this whole body. See
        // `PhotoPerfProbe`'s own doc comment for why that number, not the
        // watchdog's 250 ms stall count, is the number a simulator can
        // measure accurately.
        #if DEBUG
        let _ = PhotoPerfProbe.shared.noteFeedBody()
        let _ = wdMark("photoFeedBody")
        #endif
        GeometryReader { rootProxy in
            let safeAreaTop = rootProxy.safeAreaInsets.top
            // The image pipeline requests and caches images at exactly the
            // post's own width. It must learn that width from the same
            // layout the posts use. This call is idempotent; only a real
            // change does work.
            let _ = PhotoImagePipeline.shared.configure(widthPoints: rootProxy.size.width, scale: displayScale)
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                content(containerWidth: rootProxy.size.width, safeAreaTop: safeAreaTop, viewportHeight: rootProxy.size.height)
                // An opaque band that keeps a scrolling post's caption
                // from showing through behind the status-bar clock and the
                // top pills. It sits above the scroll content but below
                // the pills in z-order, drawn before `PhotoTopBar` below.
                // It never intercepts a touch, so the pills still get
                // every tap.
                topChromeBand(safeAreaTop: safeAreaTop)
                PhotoTopBar(
                    trashService: trashService,
                    isLiveOn: $isLiveOn,
                    safeAreaTop: safeAreaTop,
                    onOpenBinRequested: { Usage.shared.binOpened(); showTrash = true }
                )
                // Every mode mounts exactly one instance. `bottomBand: 0`
                // because Photos has no 9:16 stage.
                ChinNavigation(bottomBand: 0)
                // Zero-size. Presents and dismisses the system share sheet
                // imperatively. Mirrors `FeedView`'s identical host.
                ActivityViewControllerHost(coordinator: shareCoordinator)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                // `ShareItemResolver` can still fail — no eligible
                // resource, a cancelled fetch, or no Wi-Fi — even after
                // its resource-copy fallback. This callout makes that
                // visible, the same way `FeedView`'s own `railCallout`
                // does for video.
                if let calloutMessage = shareCoordinator.calloutMessage {
                    VStack {
                        Spacer(minLength: 0)
                        HStack {
                            Spacer(minLength: 0)
                            shareCallout(calloutMessage)
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 90)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: shareCoordinator.calloutMessage)
                }
                #if DEBUG
                poolCountProbe
                deckNextSlotProbe
                seenRowCountProbe
                liveStateProbe
                optionsProbe
                factsProbe
                PhotoPerfProbeView()
                PhotoDeckProbeView()
                inFlightProbe
                #endif
            }
            .ignoresSafeArea()
            .frame(width: rootProxy.size.width, height: rootProxy.size.height)
            .coordinateSpace(name: Self.viewportSpace)
        }
        // Photos unmounts the moment the chin nav leaves it, since
        // `RootView` switches on the mode. This is the exact edge on
        // which every photo download must stop, and later start again.
        .onDisappear { deck.suspendBackgroundWork() }
        .task {
            deck.resumeBackgroundWork()
            deck.start(modelContext: modelContext)
            KeepStore.shared.configure(modelContext: modelContext)
            trashService.start()
            // Loads the album list off the main actor. The first feed to
            // appear calls this, so Add to Album usually has data before
            // a tap. Later calls do nothing.
            AlbumListCache.shared.prewarm()
            currentPostID = deck.currentEntryID
            scrollAnchorID = deck.currentEntryID
            isLiveOn = liveDefaultOn
            // Restores the scroll position on return to Photos.
            // `PhotoDeck` is a singleton, so the deck survives a chin-nav
            // switch. This view does not survive the switch, and a
            // freshly mounted `ScrollView` always starts at offset 0.
            // `deck.currentEntryID` holds the post the user was actually
            // on, kept by `pageBecameCurrent`, so re-anchoring on it
            // restores the feed's position. This reuses the pruning
            // path's own `scrollTo(currentPostID, anchor: .top)`, see the
            // `reanchorNonce` handler, rather than a second scroll
            // mechanism. The yield lets the `LazyVStack` lay its rows out
            // first; without it the proxy has nothing to scroll to yet.
            if let restoreID = deck.currentEntryID,
               deck.entries.first?.id != restoreID {
                await Task.yield()
                guard currentPostID == restoreID else { return }
                reanchorNonce += 1
            }
            #if DEBUG
            // Switching modes reaches the photo feed. The watchdog's
            // `-cloudfull-reset-stalls` window, armed by `FeedView`'s own
            // appear, still holds the video pager's teardown `bufDur0`
            // stall. Re-arming here clears it, so a photo-mode reading
            // measures photos.
            MainThreadWatchdog.shared.feedDidAppear()
            PhotoPerfProbe.shared.reset()
            #endif
        }
        // Shows the loading pill only on a cold entry. `content()` draws
        // it only until the first deck is dealt. A warm re-entry skips
        // this.
        .task {
            guard !deck.hasDealtFirstDeck else { return }
            showLoadingIndicator = true
        }
        // On a fresh Photos entry, `deck.start(...)` can still be dealing
        // in the background when the `.task` above reads
        // `deck.currentEntryID`. That read can return nil. Then
        // `currentPostID` stays nil until the user scrolls. Post one does
        // not become current, so it gets no tier 2, no place, and no seen
        // mark. `deck.currentEntryID` publishes once dealing finishes, so
        // this re-seeds `currentPostID` from that later value. It only
        // runs while `currentPostID` is still unset, so it never
        // overwrites a page the user has already scrolled to.
        .onChange(of: deck.currentEntryID, initial: true) { _, newValue in
            guard currentPostID == nil, let newValue else { return }
            currentPostID = newValue
            scrollAnchorID = newValue
        }
        // Deliberately no `initial: true`. On a cold launch, applying
        // here too would flip `isApplyingOptions` for options the deck is
        // about to read anyway, stacking an "Updating feed…" pill on top
        // of the "Loading photos…" one. The two pills must never show at
        // once.
        //
        // This leaves one case: a feed created already holding new
        // options never sees a change here. That case belongs in the
        // deck's remount path, which cannot run on a cold launch. See
        // `PhotoDeck.reconcileAfterRemount`.
        .onChange(of: photoOptionsStore.options) { _, newValue in
            deck.apply(options: newValue)
        }
        .sheet(isPresented: $showTrash) {
            TrashView(trashService: trashService)
        }
        .sheet(item: $shareCoordinator.albumPickerTarget) { target in
            AlbumPickerView(assetID: target.id, coordinator: shareCoordinator)
        }
    }

    @ViewBuilder
    private func content(containerWidth: CGFloat, safeAreaTop: CGFloat, viewportHeight: CGFloat) -> some View {
        if !deck.hasDealtFirstDeck || deck.isReloadingForFilters {
            // Plain black until the first background enumeration actually
            // returns, mirroring `FeedView.content`'s identical guard,
            // with `loadingIndicator` layered on top once
            // `showLoadingIndicator` flips.
            ZStack {
                Color.black.ignoresSafeArea()
                    .onTapGesture { Usage.shared.loadingTap(mode: .photos) }
                // `deck.isReloadingForFilters` shows the indicator here
                // too, even on a warm re-entry that never sets
                // `showLoadingIndicator`, so a filter change never reads
                // as no response.
                if showLoadingIndicator || deck.isReloadingForFilters {
                    loadingIndicator
                }
            }
        } else if deck.entries.isEmpty {
            emptyState
        } else {
            pager(containerWidth: containerWidth, safeAreaTop: safeAreaTop, viewportHeight: viewportHeight)
        }
    }

    /// A centered spinner and label shown while nothing has loaded yet,
    /// identified as `photos_loading`. Mirrored on the Videos side by the
    /// same `videos_loading` state. Both, plus the "Updating feed…"
    /// overlay, share `FeedStatusPill` rather than each defining its own
    /// `ProgressView`.
    private var loadingIndicator: some View {
        FeedStatusPill(text: "Loading photos…")
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("photos_loading")
    }

    private func pager(containerWidth: CGFloat, safeAreaTop: CGFloat, viewportHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            // The near ring is the current post and its immediate
            // neighbours: three ids at most. Computing this with an index
            // scan inside the `ForEach` body would cost O(n) per row per
            // body pass, so O(n²) overall. Computing it once here avoids
            // that.
            let nearIDs = nearEntryIDs
            LazyVStack(spacing: 0) {
                ForEach(deck.entries) { entry in
                    PhotoPostView(
                        entry: entry,
                        isCurrent: currentPostID == entry.id,
                        isLiveOn: isLiveOn,
                        isNear: nearIDs.contains(entry.id),
                        isInCenterBand: centerBandIDs.contains(entry.id),
                        containerWidth: containerWidth,
                        trashService: trashService,
                        shareCoordinator: shareCoordinator,
                        onLiveStateChanged: { state in
                            #if DEBUG
                            currentLiveState = state
                            #endif
                        },
                        onAdvanceRequested: { advanceToNextPost(from: entry, after: $0) },
                        onZoomingChanged: { zoomingPostID = $0 ? entry.id : nil },
                        // Reads the live frame box at tap time, never a
                        // stale body pass. This is a method, not an
                        // inline closure body, so the `ForEach` body stays
                        // inside the type checker's time budget.
                        offscreenTopHeight: { offscreenTop(of: entry.id, safeAreaTop: safeAreaTop) },
                        collapsedHeight: deck.collapsedHeights[entry.id],
                        onRevealRequested: { revealAbove(by: $0, duration: $1) }
                    )
                    .id(entry.id)
                    // The pinched row outranks every other row for as
                    // long as the pinch lasts. The zoom then paints over
                    // the posts below it instead of under them.
                    .zIndex(zoomingPostID == entry.id ? 1 : 0)
                    // Each mounted row reports its own screen-relative
                    // frame the instant it moves, through one shared
                    // geometry stream. This costs less than a
                    // `GeometryReader` and `PreferenceKey` pair: no extra
                    // layer, and no tree-wide preference merge on every
                    // scroll frame. It needs no `.scrollTargetLayout()` or
                    // `.scrollPosition(id:)`, since it never asks the
                    // scroll view to snap.
                    .onGeometryChange(for: CGRect.self) { geometryProxy in
                        geometryProxy.frame(in: .named(Self.viewportSpace))
                    } action: { _, newFrame in
                        #if DEBUG
                        PhotoPerfProbe.shared.noteGeometryCallback()
                        wdMark("photoGeomCB")
                        #endif
                        // Writes into a plain box, so no publish and no
                        // body invalidation, then asks for a recompute.
                        // That recompute is itself throttled to about 20
                        // Hz, and it publishes only when the derived
                        // values change. See `rowFrames`.
                        rowFrames.frames[entry.id] = newFrame
                        recomputeGeometry(viewportHeight: viewportHeight, force: false)
                    }
                }
                // The end of "this date" is one full-height last row, in
                // the welcome screen's style.
                if deck.isDoneForToday {
                    DoneForTodayPage(
                        mode: .photos,
                        onReset: {
                            Usage.shared.onThisDateEnd(mode: .photos, tap: .keepScrolling)
                            photoOptionsStore.reset()
                        },
                        otherModeTitle: "Go to Videos",
                        onGoToOtherMode: {
                            Usage.shared.onThisDateEnd(mode: .photos, tap: .toVideos)
                            Usage.shared.modeSwitch(to: .videos, via: .endPage)
                            AppModeStore.shared.select(.videos)
                        }
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            // Placed inside the scroll content, so walking up from this
            // view's superview reaches the `UIScrollView` SwiftUI built.
            .background(ScrollViewFinder { rowFrames.uiScrollView = $0 })
        }
        // Plain deceleration: a release keeps its momentum, and a release
        // on a mid-screen post stays exactly there rather than inching
        // toward the top. No `.scrollTargetBehavior`, `.scrollTargetLayout()`,
        // or `.scrollPosition(id:)` binding — any of those would snap, or
        // report a page boundary that no longer exists.
        .onScrollPhaseChange { oldPhase, newPhase in
            ScrollPhaseGate.shared.update(isScrolling: newPhase != .idle)
            // A transient callout belongs to the post it fired on. Once
            // the feed moves, if it stays, it seems to apply to the next
            // post. See `dismissCalloutForScroll`.
            if newPhase != .idle { shareCoordinator.dismissCalloutForScroll() }
            // The first user scroll after a Keep decides swipe or back,
            // by direction, if it settles within five seconds. This
            // scroll must be interacting or decelerating, never the
            // app's own `.animating`.
            if newPhase == .idle, oldPhase == .interacting || oldPhase == .decelerating, keepWatch != nil {
                let y = rowFrames.uiScrollView?.contentOffset.y ?? keepWatchBaseOffset
                if y > keepWatchBaseOffset + 20 { settleKeepFollowup(.swipe) }
                else if y < keepWatchBaseOffset - 20 { settleKeepFollowup(.back) }
            }
        }
        .scrollIndicators(.hidden)
        // Locks the pager for a pinch's whole span, the same reasoning as
        // `FeedView.pager`'s `.scrollDisabled(isScrubbing || isFullscreen)`.
        .scrollDisabled(zoomingPostID != nil)
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.viewportSpace)).minY } action: { _, minY in
            rowFrames.scrollTop = minY
        }
        .background(Color.black)
        // Every post, not just the first, needs its header clear of the
        // status-bar clock. This is a plain content inset, since there is
        // no snap target to offset instead.
        .contentMargins(.top, topClearance(safeAreaTop: safeAreaTop), for: .scrollContent)
        // Pull down past the first photo to refresh, the same as the
        // video pager. The deck raises its "Loading photos…" state for
        // the rebuild itself.
        .refreshable { await deck.refresh() }
        .onAppear { scrollProxy = proxy }
        // Forces one recompute when scrolling stops, so the settled frame
        // is not lost to the 20 Hz throttle.
        .onChange(of: scrollGate.isScrolling) { _, isScrolling in
            guard !isScrolling else { return }
            recomputeGeometry(viewportHeight: viewportHeight, force: true)
        }
        // `PhotoDeck.pageBecameCurrent` fires on settle: wait for the
        // scroll gate to go idle, then confirm `scrollAnchorID` still
        // names the same post before promoting it to `currentPostID`. A
        // fast back-and-forth flick must never promote a post it only
        // passed through. This handler does nothing while a deliberate
        // advance, `advanceToNextPost` below, is already driving
        // `currentPostID` to its own target. That path calls
        // `pageBecameCurrent` itself.
        .onChange(of: scrollAnchorID, initial: true) { _, newValue in
            guard let newValue, !isAdvancing else { return }
            Task { @MainActor in
                await ScrollPhaseGate.shared.waitUntilIdle()
                guard scrollAnchorID == newValue, !isAdvancing else { return }
                guard currentPostID != newValue else { return }
                #if DEBUG
                currentLiveState = nil
                #endif
                // A settled post counts as seen. Direction comes from
                // order in the deck.
                if let old = currentPostID,
                   let from = deck.entries.firstIndex(where: { $0.id == old }),
                   let to = deck.entries.firstIndex(where: { $0.id == newValue }) {
                    Usage.shared.swipe(mode: .photos, up: to < from)
                }
                Usage.shared.postSeen(mode: .photos)
                currentPostID = newValue
                deck.pageBecameCurrent(newValue)
                if deck.pruneQueuedPages(keeping: newValue) {
                    pruneStaleRowFrames()
                    reanchorNonce += 1
                }
            }
        }
        // The deck can also drop leading entries once a single session's
        // scroll has pushed `entries` past its ceiling
        // (`PhotoDeck.pruneHistory`). Removing rows above the viewport
        // shrinks the content above it, so this needs the same re-anchor
        // a delete prune already applies, for the same reason.
        .onChange(of: deck.historyPruneNonce) { _, _ in
            pruneStaleRowFrames()
            reanchorNonce += 1
        }
        // Re-anchors after a prune. Mirrors `FeedView.pager`'s identical
        // `reanchorNonce` handler. See that call site's comment for why
        // the code needs an unanimated `scrollTo` once pages above the
        // current one leave the `LazyVStack`.
        .onChange(of: reanchorNonce) { _, _ in
            guard let currentPostID else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(currentPostID, anchor: .top)
            }
        }
        }
    }

    /// The current post and its immediate neighbours, as a set of entry
    /// ids. This is the `isNear` input for every row, computed once per
    /// body pass instead of by an O(n) index scan inside each row.
    private var nearEntryIDs: Set<String> {
        let entries = deck.entries
        guard !entries.isEmpty else { return [] }
        let centre = min(max(deck.currentIndex, 0), entries.count - 1)
        let lower = max(centre - 1, 0)
        let upper = min(centre + 1, entries.count - 1)
        return Set(entries[lower...upper].map(\.id))
    }

    /// A shared throttle: at most one recompute per
    /// `geometryComputeInterval`. Pass `force: true` to skip the throttle.
    /// The scroll-stop handler and the trailing task do this, so the
    /// final, settled geometry is never stuck behind the throttle window.
    private func recomputeGeometry(viewportHeight: CGFloat, force: Bool) {
        let now = Date()
        if !force, now.timeIntervalSince(lastGeometryComputeTime) < geometryComputeInterval {
            // This code requires a trailing edge here. A leading-edge-only
            // throttle drops the last geometry of a movement if it
            // arrives inside the window. The last geometry is the
            // settled one. On the delete path, a queued post's height
            // collapses to 0, and that final frame change arrives a few
            // milliseconds after the previous one. If the code drops it,
            // `scrollAnchorID` never names the post the collapse brought
            // to the center. The settle handler then never runs, and
            // `pruneQueuedPages` never removes the deleted post. See the
            // photo delete UI test. At most one task runs per window, and
            // any recompute that does run cancels it.
            scheduleTrailingRecompute(viewportHeight: viewportHeight)
            return
        }
        rowFrames.trailingTask?.cancel()
        rowFrames.trailingTask = nil
        lastGeometryComputeTime = now
        #if DEBUG
        PhotoPerfProbe.shared.noteGeometryRecompute()
        wdMark("photoGeomCompute")
        #endif
        let frames = rowFrames.frames
        // Both writes below are conditional. `scrollAnchorID` normally
        // holds the same id for many ticks in a row. `centerBandIDs`
        // changes only when a post crosses the screen's center third.
        // Most of these ticks publish nothing. An unconditional
        // assignment would re-run the body every time instead.
        let anchor = Self.nearestCenterID(frames: frames, viewportHeight: viewportHeight)
        if anchor != scrollAnchorID { scrollAnchorID = anchor }
        let band = Self.centerBandMembership(frames: frames, viewportHeight: viewportHeight)
        if band != centerBandIDs { centerBandIDs = band }
    }

    /// Runs one recompute at the end of the current throttle window, so
    /// the final frame of a movement is never the one that got dropped.
    /// At most one is ever in flight.
    private func scheduleTrailingRecompute(viewportHeight: CGFloat) {
        guard rowFrames.trailingTask == nil else { return }
        rowFrames.trailingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(geometryComputeInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            rowFrames.trailingTask = nil
            recomputeGeometry(viewportHeight: viewportHeight, force: true)
        }
    }

    /// The post whose frame covers the screen's vertical center, or, with
    /// no such post, the one with the largest visible height. `frames`
    /// are screen-relative (`Self.viewportSpace`), so `viewportHeight / 2`
    /// is the screen's center with no offset math needed.
    private static func nearestCenterID(frames: [String: CGRect], viewportHeight: CGFloat) -> String? {
        guard viewportHeight > 0 else { return nil }
        let centerY = viewportHeight / 2
        if let containing = frames.first(where: { $0.value.minY <= centerY && centerY <= $0.value.maxY }) {
            return containing.key
        }
        return frames.max(by: {
            visibleHeight($0.value, viewportHeight: viewportHeight) < visibleHeight($1.value, viewportHeight: viewportHeight)
        })?.key
    }

    private static func visibleHeight(_ frame: CGRect, viewportHeight: CGFloat) -> CGFloat {
        max(0, min(frame.maxY, viewportHeight) - max(frame.minY, 0))
    }

    /// Which posts have their own center band — the middle third of
    /// their own height — overlapping the screen's center third.
    /// Independent of `currentPostID`.
    private static func centerBandMembership(frames: [String: CGRect], viewportHeight: CGFloat) -> Set<String> {
        guard viewportHeight > 0 else { return [] }
        let screenBandStart = viewportHeight / 3
        let screenBandEnd = viewportHeight * 2 / 3
        var result: Set<String> = []
        for (id, frame) in frames where frame.height > 0 {
            let postBandStart = frame.minY + frame.height / 3
            let postBandEnd = frame.minY + frame.height * 2 / 3
            if postBandStart <= screenBandEnd, postBandEnd >= screenBandStart {
                result.insert(id)
            }
        }
        return result
    }

    /// Drops frame entries for rows no longer in `deck.entries`. Called
    /// after every prune, so a long scroll session's dictionary never
    /// grows past the deck's own live window.
    private func pruneStaleRowFrames() {
        let liveIDs = Set(deck.entries.map(\.id))
        rowFrames.frames = rowFrames.frames.filter { liveIDs.contains($0.key) }
    }

    /// Advances the pager to the next post after `entry`'s own position,
    /// not `currentPostID`. Mirrors `FeedView.advanceToNextPage(from:)`.
    /// It uses the tapped entry's own index, not the nominally current
    /// post, since a rapid tap mid-scroll could land on either. This is a
    /// no-op at the deck's true tail. The queued post then stays on
    /// screen, the same as `pruneQueuedPages` and the video equivalent
    /// already leave it. A later scroll or a fresh deal moves the user
    /// off it.
    ///
    /// A Keep tap does not remove `entry` from `deck.entries` the way a
    /// delete does. `currentPostID`, and therefore every child's
    /// `isCurrent`, deliberately stays on `entry` for the whole scroll
    /// animation below. This includes the kept post's own
    /// `photo_rail_trash` and `photo_rail_like` identifiers. It is
    /// promoted to `nextID` only once the animation finishes and the
    /// pager has actually settled there. This is not synchronous at the
    /// start, the way a plain settle would be. A kept post reads as
    /// current, heart filled, delete disabled, for the whole roughly
    /// 0.4 s the next post visibly scrolls into place. This matches what
    /// is on screen.
    ///
    /// `delay`: a delete passes its crush duration. `isAdvancing` goes
    /// true at once, so the settle handler does nothing while the post
    /// crushes. Once the crush finishes, the code prunes the crushed post
    /// in place with no scroll. See the body below.
    private func advanceToNextPost(from entry: PhotoDeckEntry, after delay: TimeInterval) {
        guard let index = deck.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let nextIndex = index + 1
        guard deck.entries.indices.contains(nextIndex) else { return }
        let nextEntry = deck.entries[nextIndex]
        let nextID = nextEntry.id
        isAdvancing = true
        #if DEBUG
        if delay > 0 {
            // Logs the post below's top and the post above's bottom,
            // about every 16 ms through the reveal, the crush, and after.
            let aboveID = index > 0 ? deck.entries[index - 1].id : nil
            Task { @MainActor in
                var below: [Int] = [], above: [Int] = []
                for _ in 0..<70 {
                    below.append(Int(rowFrames.frames[nextID]?.minY ?? -9999))
                    above.append(Int(aboveID.flatMap { rowFrames.frames[$0]?.maxY } ?? -9999))
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                DiagnosticsLog.shared.log("PhotoGap", "crush_below_top " + below.map(String.init).joined(separator: " "))
                DiagnosticsLog.shared.log("PhotoGap", "crush_above_bottom " + above.map(String.init).joined(separator: " "))
            }
        }
        #endif
        // Animating while the main thread is busy with a decode, a
        // settle, or a metadata write drops most of the scroll's frames.
        // It then reads as a jump rather than a move. Waiting for the
        // scroll gate to go idle lets the animation run when the main
        // thread is free. The Keep path also waits, bounded, for the
        // next post to actually have an image; the delete path below
        // does not. `isAdvancing` is already true, so the settle handler
        // does nothing for the whole wait.
        Task { @MainActor in
            if delay > 0 {
                // The crush leaves the next post wherever the collapse
                // carried it; nothing scrolls afterward. The crushed post
                // is 0 pt tall by then, so pruning it moves no content
                // and needs no re-anchor. A re-anchor here would
                // otherwise snap the feed to the top. Whatever post the
                // crush leaves nearest the center becomes current.
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                await ScrollPhaseGate.shared.waitUntilIdle()
                guard isAdvancing else { return }
                let landedID = scrollAnchorID ?? nextID
                #if DEBUG
                currentLiveState = nil
                #endif
                currentPostID = landedID
                deck.pageBecameCurrent(landedID)
                if deck.pruneQueuedPages(keeping: landedID) {
                    pruneStaleRowFrames()
                }
                // Cleared last. The settle handler does nothing while
                // this is true. Clearing it before the prune above would
                // let that handler prune again and bump `reanchorNonce`.
                // That call runs `scrollTo(anchor: .top)`, a second
                // movement on top of the crush.
                isAdvancing = false
                return
            }
            await ScrollPhaseGate.shared.waitUntilIdle()
            await Self.waitForImage(assetID: nextEntry.assetID)
            guard isAdvancing else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                scrollAnchorID = nextID
                scrollProxy?.scrollTo(nextID, anchor: .top)
            }
            deck.pageBecameCurrent(nextID)
            startKeepFollowupWatch()
            // This is not a `withAnimation` completion, because
            // `scrollTo` changes none of the animatable state here, so
            // that completion would fire in the same frame. The prune and
            // unanimated re-anchor below would then cut the slide short.
            // Waiting 400 ms (longer than the 0.35 s slide) and then for
            // the scroll gate to go idle avoids that.
            try? await Task.sleep(for: .milliseconds(400))
            await ScrollPhaseGate.shared.waitUntilIdle()
            guard isAdvancing else { return }
            isAdvancing = false
            #if DEBUG
            currentLiveState = nil
            #endif
            currentPostID = nextID
            if deck.pruneQueuedPages(keeping: nextID) {
                pruneStaleRowFrames()
                reanchorNonce += 1
            }
        }
    }

    /// A bounded wait. Returns as soon as the pipeline holds a decoded
    /// image for this asset, or after `maxWaitSeconds`, whichever comes
    /// first. The cap matters more than the wait. An advance that stalls
    /// on a slow iCloud download is worse than one that animates onto a
    /// placeholder. This never becomes a hang.
    private static func waitForImage(assetID: String, maxWaitSeconds: Double = 0.4) async {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while PhotoImagePipeline.shared.cachedImage(for: assetID) == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if Task.isCancelled { return }
        }
    }

    /// How much of `entryID`'s row currently sits above the top of the
    /// scroll view. Zero when the row is fully visible.
    private func offscreenTop(of entryID: String, safeAreaTop: CGFloat) -> CGFloat {
        guard let minY = rowFrames.frames[entryID]?.minY else { return 0 }
        // Both values use the same coordinate space. See `PhotoRowFrameStore.scrollTop`.
        let visibleTop = rowFrames.scrollTop + topClearance(safeAreaTop: safeAreaTop)
        return max(visibleTop - minY, 0)
    }

    /// A delete on a post whose top is above the screen first slides the
    /// feed down by `delta`, so the whole post is visible. Only then
    /// does it crush the post. UIKit animates the offset directly, so the
    /// slide is one continuous curve.
    private func revealAbove(by delta: CGFloat, duration: TimeInterval) {
        guard let scrollView = rowFrames.uiScrollView, delta > 0 else { return }
        var offset = scrollView.contentOffset
        offset.y = max(offset.y - delta, -scrollView.adjustedContentInset.top)
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            scrollView.contentOffset = offset
        }
    }

    /// Starts when the Keep advance begins. The phase check in
    /// `onScrollPhaseChange`, not the base offset here, is what keeps the
    /// app's own `.animating` slide from counting as a swipe.
    private func startKeepFollowupWatch() {
        keepWatch?.cancel()
        keepWatchBaseOffset = rowFrames.uiScrollView?.contentOffset.y ?? 0
        keepWatch = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            settleKeepFollowup(.stay)
        }
    }

    private func settleKeepFollowup(_ result: Usage.KeepFollowup) {
        guard keepWatch != nil else { return }
        keepWatch?.cancel()
        keepWatch = nil
        Usage.shared.keepFollowup(result)
    }

    private func topClearance(safeAreaTop: CGFloat) -> CGFloat {
        StageGeometry.chromeTop(safeAreaTop: safeAreaTop) + StageGeometry.chromeHeight + 12
    }

    /// A solid black band covers the status-bar clock and the top pill
    /// row. A scrolling post's header or caption never shows through
    /// behind them. The band is 6 pt shorter than `topClearance` above,
    /// so it ends between the pills and the first content row.
    private func topChromeBand(safeAreaTop: CGFloat) -> some View {
        Color.black
            .frame(maxWidth: .infinity)
            .frame(height: StageGeometry.chromeTop(safeAreaTop: safeAreaTop) + StageGeometry.chromeHeight + 6)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    // MARK: - Share callout (mirrors FeedView.railCallout)
    //
    // Each feed owns one `ShareCoordinator`. Only one post can ever be
    // sharing at a time. The callout shows unconditionally, with no
    // current-post check, unlike `FeedView`'s own `currentPageID`
    // cancel-on-change rule. `ShareCoordinator.calloutMessage` is still
    // exactly one value for the whole feed.

    private func shareCallout(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .feedGlass(in: Capsule())
            .accessibilityIdentifier("feed_coming_soon")     // kept fixed, and shared with FeedView's own callout
            .accessibilityLabel(message)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Photos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Cloudfull shows the photos already in your photo library. Take one, or import one, and it will show up here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo_empty_state")
    }

    #if DEBUG
    /// The `photo_pool_` accessibility identifier, encoding
    /// `PhotoDeck.poolCount`. Mirrors `FeedView.poolCountProbe`'s style:
    /// invisible, present unconditionally, and absent from release
    /// builds.
    private var poolCountProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("photo_pool_\(deck.poolCount)")
    }

    /// The `photo_options_` accessibility identifier, encoding
    /// `PhotoOptionsStore.options.probeToken`. Mirrors
    /// `FeedView.optionsProbe`'s reasoning: one function produces the
    /// token, so this probe and the deck signature can never disagree.
    private var optionsProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("photo_options_\(photoOptionsStore.options.probeToken)")
    }

    /// The `photo_facts_` accessibility identifier, encoding the current
    /// post's creation date, read from `PhotoDeck.debugCurrentCreatedMs`.
    /// Mirrors `FeedView`'s own `feed_facts_` probe.
    private var factsProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("photo_facts_\(deck.debugCurrentCreatedMs)")
    }

    /// The `photo_deck_next_` or `photo_deck_next_end` accessibility
    /// identifier. Mirrors `FeedView.deckNextSlotProbe`'s reasoning for
    /// the video deck.
    private var deckNextSlotProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier(
                deck.debugNextSlotAfterCurrent.map { "photo_deck_next_\($0)" } ?? "photo_deck_next_end"
            )
    }

    /// The `photo_inflight_` accessibility identifier, encoding live
    /// per-post image requests. Readable only while Photos is on screen.
    /// Leaving Photos unmounts this along with the feed, and
    /// `PhotoImagePipeline`'s own log line shows that requests stopped in
    /// the other mode.
    private var inFlightProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("photo_inflight_\(PhotoImagePipeline.shared.inFlightRequestCount)")
    }

    /// The `photo_seen_probe_` accessibility identifier, encoding
    /// `PhotoDeck.debugSeenRowCount`.
    private var seenRowCountProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("photo_seen_probe_\(deck.debugSeenRowCount)")
    }

    /// The `photo_live_state_` accessibility identifier, encoding the
    /// current post's own Live playback state, bridged up from whichever
    /// `PhotoPostView` last reported one while `isCurrent`. Reads "off"
    /// before any Live post has reported in, matching
    /// `LivePhotoPlaybackState.off`'s own resting-state meaning, rather
    /// than adding a fourth "none" case.
    private var liveStateProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("photo_live_state_\(currentLiveState?.rawValue ?? "off")")
    }
    #endif
}


/// A zero-size UIKit view placed inside the scroll content. Its only job
/// is to walk up to the `UIScrollView` SwiftUI built and hand it back.
/// Found once; the reference is weak.
private struct ScrollViewFinder: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.found = found
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: FinderView, context: Context) {}

    final class FinderView: UIView {
        var found: ((UIScrollView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view: UIView? = superview
            while let v = view {
                if let scroll = v as? UIScrollView { found?(scroll); return }
                view = v.superview
            }
        }
    }
}
