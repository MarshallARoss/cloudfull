//
//  PhotoPostView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Photos
import CoreLocation

/// One post in the photo feed. The view owns the header, the photo, the
/// actions row, and the caption for one asset. Every action reads and
/// writes only `entry.assetID`. The view never refers to a separate idea
/// of "the current asset".
struct PhotoPostView: View {
    let entry: PhotoDeckEntry
    let isCurrent: Bool
    let isLiveOn: Bool
    /// True for the current post and its immediate neighbours only. At
    /// most three `PHLivePhoto` instances stay alive at once: the current
    /// post plus or minus one. This value controls whether `photoArea`
    /// mounts a real `LivePhotoStage`. See that method.
    let isNear: Bool
    /// True while this post's own centre band overlaps the screen's
    /// centre third. `PhotoFeedView` computes this from its own geometry
    /// stream. It drives Live autoplay and stop independently of
    /// `isCurrent`. A Live post can start playing mid-scroll if it
    /// dwells here long enough, and it stops the instant it leaves the
    /// band.
    let isInCenterBand: Bool
    let containerWidth: CGFloat
    @ObservedObject var trashService: TrashService
    @ObservedObject var shareCoordinator: ShareCoordinator
    /// Fires only while `isCurrent`. Lets `PhotoFeedView` render
    /// `photo_live_state_<playing|key|off>` for the current post only,
    /// without every mounted post writing to one shared piece of state.
    let onLiveStateChanged: (LivePhotoPlaybackState) -> Void
    /// Fires once `handleTrashTap()` queues this post's asset for
    /// deletion, matching `FeedPageContent.onAdvanceRequested`. Only
    /// `PhotoFeedView` owns `currentPostID`, the pager's own scroll
    /// binding, so it — not this view — animates the pager to the
    /// next post.
    /// The argument is how long the feed waits before it moves. Keep
    /// passes 0. A delete passes its crush duration, so the next post
    /// scrolls into place only after the crush finishes.
    let onAdvanceRequested: (_ after: TimeInterval) -> Void
    /// Fires true the moment a pinch starts and false the moment it ends.
    /// `PhotoFeedView` mirrors `FeedView.isScrubbing` and locks the
    /// vertical pager with `.scrollDisabled` for the gesture's full span,
    /// so a two-finger pinch is never read as a one-finger page drag.
    let onZoomingChanged: (Bool) -> Void
    /// How much of this post is currently above the top of the scroll
    /// view. The view asks this at tap time, so the value is never stale.
    /// The crush stops there instead of at zero — see `handleTrashTap`.
    let offscreenTopHeight: () -> CGFloat
    /// Non-nil once this post has been crushed away: the height it keeps
    /// from then on. `PhotoDeck` owns this value, not the view, because a
    /// `LazyVStack` unmounts far-away rows and would lose view state.
    let collapsedHeight: CGFloat?
    /// Asks the feed to slide down by (points, seconds) so this post's
    /// top is on screen before it crushes. See
    /// `PhotoFeedView.revealAbove(by:duration:)`.
    let onRevealRequested: (CGFloat, TimeInterval) -> Void

    /// Free properties plus one resource fetch, loaded once at mount.
    /// `nil` only for the brief span before the first `.task(id:)`
    /// returns.
    @State private var tier1: PhotoMetadata.Tier1?
    /// EXIF data and albums, current post only (tier 2). `nil` until it
    /// lands.
    @State private var tier2: PhotoMetadata.Tier2?
    /// True only while a tier-2 load for this post is running, and
    /// cleared by its own 3-second timeout below. This is the only input
    /// that lets `PhotoCaptionView` render "…", so a caption never sits
    /// on a placeholder for a request that already finished, never
    /// started, or returned nothing.
    @State private var tier2Pending = false
    /// Double optional. Outer `nil` means the lookup has not resolved yet.
    /// `.some(nil)` means it resolved with no place. `.some(x)` means it
    /// resolved with `x`. This matches `PlaceLookup`'s own cache shape.
    @State private var resolvedPlace: String??
    /// The image on screen: a degraded version first, then full quality.
    /// `PhotoImagePipeline` loads this for every asset, including Live
    /// Photos.
    @State private var stillImage: UIImage?
    /// Holds the previous frame during a crossfade. `.contentTransition(.opacity)`
    /// makes SwiftUI crossfade `stillImage` by interpolating two CPU-drawn
    /// display lists inside the CA commit
    /// (`RBInterpolatedDisplayListContents`), which can cost up to 66% of
    /// a hitched frame's main-thread time. A plain two-layer crossfade
    /// avoids this: `fadingOutImage` holds the previous frame, drawn
    /// underneath at full opacity, while `stillImage` (now on top)
    /// animates in through `stillImageOpacity`. A bare `.opacity` change
    /// lets Core Animation composite the crossfade on the GPU with no CPU
    /// redraw. The view clears this property 220 ms after the change,
    /// when the 0.2 s fade has finished. A scrolled-away cell then does
    /// not keep an extra layer alive.
    @State private var fadingOutImage: UIImage?
    @State private var stillImageOpacity: Double = 1
    /// True while `stillImage` is still PhotoKit's degraded frame. Drives
    /// the DEBUG load badge, and keeps the loading ring up for a cell
    /// that has only the low-res version while the original downloads
    /// remotely.
    @State private var isDegradedImage = false
    /// Flips true 0.6 seconds after this post mounts if no image has
    /// arrived yet. It never flips back to false. Once an image lands,
    /// `stillImage != nil` hides the ring instead.
    @State private var showLoadingRing = false
    /// iCloud download fraction, `nil` until PhotoKit reports one. Present
    /// only for an original that is not on the device.
    @State private var downloadFraction: Double?
    /// True once PhotoKit reports that this asset's original lives in
    /// iCloud. Swaps the loading ring's centre glyph for a cloud.
    @State private var isRemoteOriginal = false
    /// True when this cell's load request failed. The cell then shows a
    /// quiet failure message instead of staying a grey rectangle.
    @State private var loadFailed = false
    /// Milliseconds from the start of the load to the degraded frame and
    /// to the full-quality frame. The DEBUG per-cell badge
    /// (`-cloudfull-show-loads`) shows these values.
    @State private var degradedMs: Int?
    @State private var fullMs: Int?
    /// `true` when the place was already resolved the moment this post
    /// appeared, meaning the prefetch worked. `false` when the post had
    /// to wait for a live lookup. `nil` before either is known.
    @State private var placeWasPrefetched: Bool?
    /// Milliseconds the place took from this post becoming current. 0 for a
    /// prefetch hit.
    @State private var placeMs: Int?
    /// Drives the indeterminate sweep in `loadingOverlay` while no real
    /// download fraction exists yet.
    @State private var indeterminateSpin = false
    /// A single eased Core Animation runs on the GPU, with no per-frame
    /// main-thread work. It creeps the Live ring from 0 toward 90% over
    /// 10 seconds while no real download fraction leads it. Real
    /// progress takes over once it is ahead of the creep — see
    /// `applyLiveFetchProgress`. The Live ring never reads
    /// `downloadFraction`. That value belongs to the still image and
    /// does not reset after its download ends.
    @State private var liveRingCreep: Double = 0
    /// Keeps the Live ring drawn while it fills from wherever the creep got to
    /// up to 100 %. Cleared by that fill's own completion — see
    /// `finishLiveRing` — never on a timer.
    @State private var liveRingFinishing = false
    /// The finish animates the arc to 1.0 and this opacity to 0 together,
    /// over the same 0.22 seconds.
    @State private var liveRingOpacity: Double = 1
    /// True between `startLiveRingCreep` and `finishLiveRing`. A new
    /// creep can start only after a finish, so a running fetch never
    /// resets the arc to 0.
    @State private var liveRingCreepRunning = false
    /// The creep's slow second phase, held so a fetch that finishes
    /// inside the first 10 seconds can cancel it. A `.delay()`ed
    /// animation cannot be cancelled, so this phase runs as a `Task`
    /// instead.
    @State private var liveRingDriftTask: Task<Void, Never>?
    /// When the running creep began. The view compares a real download
    /// fraction against the creep's own value at this elapsed time, so a
    /// fraction only ever moves the arc forward — see
    /// `applyLiveFetchProgress`.
    @State private var liveRingCreepStartedAt: Date?

    @State private var likeBounceToken = 0
    /// Flips true the instant a trash tap queues this post's asset for
    /// deletion. This drives the post's layout height straight to 0
    /// (top-aligned, clipped — see the `.frame(height:)` below) in one
    /// animation. The next post moves up as this post's height
    /// decreases.
    /// The view never resets this flag to `false`. This view's own
    /// identity (`entry.id`) never survives past the prune that follows,
    /// so there is no state to undo the crush back to.
    /// The tap sets this flag and calls `PhotoDeck.markCollapsed`. The
    /// row then stays mounted as a collapsed placeholder.
    @State private var isCollapsedForDelete = false
    /// This post's natural height, updated by `.onGeometryChange` while
    /// the post is not collapsing. The crush animates from this value.
    @State private var measuredHeight: CGFloat?
    /// Ranges from 0 (untouched) to 1 (fully crushed), stepped by hand
    /// in `handleTrashTap`'s own roughly 60 Hz loop instead of left to
    /// an implicit SwiftUI animation. Inside this `LazyVStack`, SwiftUI
    /// does not sample `.frame(height:)` mid-flight under an ambient
    /// `withAnimation` or an `.animation(_:value:)` modifier: the frame
    /// jumps straight from the full height to the settled next post
    /// with no interpolated frame in between. Assigning a new `CGFloat`
    /// by hand every frame avoids this, because it never asks SwiftUI's
    /// `Animatable` machinery to interpolate anything.
    @State private var crushFraction: Double = 0
    /// True the moment this instance's crush loop ends, so the row can hand
    /// over to the zero-content placeholder — see `body`.
    @State private var crushFinished = false
    /// The live pinch scale, clamped to 1x–4x. `@GestureState` resets to
    /// its initial value (1) the instant the pinch ends, and SwiftUI
    /// wraps that reset in its own default spring transaction. That
    /// reset is the spring-back-on-release behaviour: nothing here
    /// commits a zoom level between gestures on purpose.
    @GestureState private var pinchScale: CGFloat = 1
    /// The pinch anchor. `MagnificationGesture` reports only a
    /// magnitude, so a zoom driven by it always grows from the photo's
    /// centre. `MagnifyGesture` also carries `startAnchor`, the point
    /// between the two fingers in this view's own unit space, which is
    /// the `scaleEffect` anchor a pinch-to-zoom needs.
    @GestureState private var pinchAnchor: UnitPoint = .center
    /// Bumped to ask `LivePhotoStage` for one playthrough — see that type's
    /// own doc comment. 0 until the first auto-play-on-band-dwell or tap.
    @State private var playNonce = 0
    /// "band" or "tap" — which call site is about to bump `playNonce`,
    /// always set in the same scope immediately before that bump so both
    /// land in the same SwiftUI update. `LivePhotoStage`'s own diagnostic
    /// only; see that type's `playReason` doc comment.
    @State private var playReason = "band"
    /// Bumped to ask `LivePhotoStage` to stop immediately and revert to
    /// the key photo, using `PHLivePhotoView.stopPlayback()`. 0 until the
    /// first stop.
    @State private var stopNonce = 0
    /// Latches so a post auto-plays at most once per dwell in the centre
    /// band — reset in `onChange(of: isInCenterBand)` below so leaving and
    /// re-entering (a scroll back) can trigger it again.
    @State private var hasAutoPlayedLive = false
    /// Per-post `@State`, not a value forwarded from `PhotoFeedView`. The
    /// paired-movie fetch this reflects starts on band entry, before the
    /// post is `isCurrent`. A parent that only tracks the current post's
    /// readiness would drop the `.fetching` state, and the ring would
    /// never show.
    @State private var liveReadiness: LiveReadiness = .idle

    @ObservedObject private var resolver = AssetKeyResolver.shared
    @ObservedObject private var scrollGate = ScrollPhaseGate.shared
    /// The share picker uses this to select its expand and collapse
    /// animations, as `ChinNavigation` does.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The one cancel signal a pinch reliably gives. See the
    /// `.onChange(of: scenePhase)` on `photoArea` for why `@GestureState`
    /// cannot play that role.
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Share picker
    //
    // For a Live post, the Share button expands into a capsule that
    // holds a `LiquidSegmentedControl<ShareKind>`
    // (`ChinTabSegmentedControl.swift`), the same way `ChinNavigation`
    // expands.
    //
    // `sharePickerShellOpacity`, `sharePickerWordsOpacity`, and
    // `shareLabelOpacity` mirror `ChinNavigation`'s `wordsOpacity`/
    // `glyphOpacity` split, for the same reason: driving fades from state
    // set inside `expandSharePicker()`/`collapseSharePicker()`'s own
    // `withAnimation` calls, never from an `.animation(_:value:)`
    // modifier, keeps each fade its own transaction instead of cancelling
    // the frame's own spring.
    @State private var isSharePickerExpanded = false
    @State private var sharePickerShellOpacity: Double = 0
    @State private var sharePickerWordsOpacity: Double = 0
    @State private var shareLabelOpacity: Double = 1
    /// Bumped by every expand, collapse, or pick, so a stale delayed
    /// step in `handleSharePick` does nothing after the picker
    /// closes. This matches `ChinNavigation.selectionToken`.
    @State private var sharePickerToken = 0
    /// The real Share button's own on-screen frame, in
    /// `Self.sharePickerSpace`. This is both the picker's anchor, which
    /// is left-aligned with this button, and the collapsed end of its
    /// grow/shrink animation.
    @State private var shareButtonFrame: CGRect = .zero
    /// This post's own content size, in the same space — the picker's
    /// tap-outside catcher covers exactly this post (photo, caption and
    /// header included), not the whole screen; scrolling away is what
    /// dismisses it for posts further off.
    @State private var postContentSize: CGSize = .zero
    @Namespace private var sharePickerGlassNamespace

    private enum SharePickerGlassID: Hashable { case shell }
    private static let sharePickerSpace = "photoPostShareSpace"
    private static let sharePickerHeight: CGFloat = 56
    private static let sharePickerWidth: CGFloat = 200
    private static let sharePickerGap: CGFloat = 12
    private static let sharePickerControlInset: CGFloat = 2
    /// Same two numbers as `ChinNavigation.lensSlide`/`collapseSettle`: how
    /// long the lens is given to visibly land on the picked segment before
    /// the capsule starts collapsing, and how long that collapse is given
    /// to settle before `pickShare` fires the share sheet.
    private static let sharePickerLensSlide: TimeInterval = 0.25
    private static let sharePickerCollapseSettle: TimeInterval = 0.28

    private static let shareItems: [LiquidSegmentedControl<ShareKind>.Item] = [
        .init(value: .still, title: "Still", symbolName: "camera", identifier: "photo_share_still"),
        .init(value: .video, title: "Video", symbolName: "video", identifier: "photo_share_video"),
        .init(value: .live, title: "Live", symbolName: "livephoto", identifier: "photo_share_live"),
    ]

    // MARK: - Optical glyph sizes
    //
    // SF Symbols at the same point size do not render at the same
    // height. Rendered heights at 24 pt on a 3x screen:
    //
    //     heart  63 px tall   (the reference)
    //     share  63 px tall
    //     album  58 px tall   (too small)
    //     trash  77 px tall   (22% over)
    //
    // The album and trash glyphs use their own sizes so that their
    // height is near the heart's height. `actionGlyphBox` below keeps
    // every word on one baseline whatever each glyph ends up
    // measuring.
    private static let actionGlyphSize: CGFloat = 24
    // 20.5, a few percent under the height-matching 21.5: two filled
    // outline rectangles carry more ink than an open curve, so a boxy
    // glyph has to sit slightly smaller than its neighbours to weigh the
    // same.
    private static let albumGlyphSize: CGFloat = 20.5
    private static let trashGlyphSize: CGFloat = 21

    /// A shared height for every glyph in the actions row, so no
    /// symbol's own bounding box can push its word off the shared
    /// baseline.
    ///
    /// Do not constrain the width. A fixed-width box adds padding to
    /// narrow glyphs, so the gaps in the row become unequal. Letting
    /// width hug the ink leaves every gap to the `HStack`'s own
    /// spacing alone.
    private static let actionGlyphBox: CGFloat = 28

    /// The duration of the crush animation.
    private static let crushDuration: TimeInterval = 0.5
    /// The duration of the slide that brings an above-the-fold post
    /// fully on screen before its crush.
    private static let revealDuration: TimeInterval = 0.25
    /// When the slide begins, measured after the tap.
    private static let revealStart: TimeInterval = 0
    /// The height of the post above that stays visible after the
    /// slide.
    private static let revealMargin: CGFloat = 12
    /// The gap between `keep()`'s immediate heart fill and the
    /// scroll-up-and-in advance it schedules.
    private static let keepAdvanceDelay: TimeInterval = 0.15

    private var isKept: Bool { resolver.isShielded(entry.assetID) }
    private var deleteEnabled: Bool { !isKept && resolver.isDestructiveActionSafe }

    /// Whether this post's Share tap should show the three-way picker
    /// instead of going straight to the sheet. `-cloudfull-force-live-trio`
    /// (DEBUG only) treats every photo as Live for the picker alone. It
    /// never fakes a paired movie, so only the Still pick resolves to a
    /// real share under it. Video and Live still try their real PhotoKit
    /// lookup and fail softly (`ShareItemResolver.Failure.unsupported`)
    /// on a post with no paired video.
    private var isLiveForTrio: Bool {
        guard let tier1 else { return false }
        if tier1.isLivePhoto { return true }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-cloudfull-force-live-trio")
        #else
        return false
        #endif
    }

    var body: some View {
        // A crushed post keeps only the height that was already off screen
        // (0 when it was fully visible) and draws nothing: no image
        // request, no metadata, no chrome. The view keeps the
        // placeholder because removing the row changes the scroll
        // position — see `PhotoDeck.collapsedHeights`.
        // The instance that is mid-crush keeps rendering the real post, so
        // its animation finishes. Everything else — a rebuilt row, or this
        // one once the crush has ended — renders the placeholder, which
        // carries no `photo_page_` identity. Leaving the crushed post in
        // `postBody` would keep a deleted photo visible as a page element
        // for as long as the row stayed mounted.
        if let collapsedHeight, !(isCollapsedForDelete && !crushFinished) {
            Color.clear.frame(height: collapsedHeight)
        } else {
            postBody
        }
    }

    private var postBody: some View {
        // Zero inter-row spacing here. Each row supplies its own internal
        // padding: the header and actions row are each a fixed 44 pt,
        // `photoArea`'s frame is the photo's own aspect ratio with no
        // padding of its own, and `PhotoCaptionView` adds a small amount
        // of top padding itself.
        VStack(alignment: .leading, spacing: 0) {
            if let tier1 {
                headerRow(tier1)
                photoArea(tier1)
                actionsRow
                PhotoCaptionView(tier1: tier1, tier2: tier2, isCurrent: isCurrent, showsPlaceholder: tier2Pending)
                Text(tier1.timeSinceText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .accessibilityIdentifier(isCurrent ? "photo_meta_timesince" : "")
            } else {
                // Before tier 1 lands, size the placeholder from the aspect
                // ratio that `PhotoImagePipeline`'s own window fetch
                // already learned off the main thread. A square guess here
                // would resize every post the moment its metadata
                // arrived, reflowing the whole `LazyVStack` under the
                // user's finger.
                Color(white: 0.07)
                    .frame(height: containerWidth * (PhotoImagePipeline.shared.aspectRatio(for: entry.assetID) ?? 1))
            }
        }
        .padding(.bottom, 24)
        .background(Color.black)
        // Tracks this post's own natural height continuously, read before
        // the `.frame(height:)` below imposes any constraint, so a
        // collapsing cell never reports its own shrunk size back into
        // itself. This gives the crush a real `CGFloat` to animate from
        // instead of `nil`. The height freezes the instant the crush
        // starts.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, newHeight in
            guard !isCollapsedForDelete else { return }
            measuredHeight = newHeight
        }
        // Collapses this post's own layout height to 0 the instant a trash
        // tap queues it, `crushFraction` at a time — see that property's
        // own doc comment for why this is hand-stepped rather than left to
        // a SwiftUI animation. Top-aligned and clipped, so the bottom of
        // the photo disappears first as the frame shrinks. The next post
        // moves up as this post's height decreases, not this one sliding
        // away on its own.
        .frame(height: isCollapsedForDelete ? (measuredHeight ?? 0) * (1 - crushFraction) : measuredHeight, alignment: .top)
        // The clip belongs to the crush alone. Left unconditional, it
        // would also crop a pinch-zoom back to the post's own rect, since
        // the photo could never paint outside the box it started in.
        // Outside a crush this clip changes nothing: the content is
        // exactly the frame's size.
        .modifier(CrushClip(isActive: isCollapsedForDelete))
        // Same container rule as `FeedView.pager`'s `page_<slot>_`
        // identifier: declaring this a `.contain` container keeps the bare
        // identifier below from overriding identifiers like
        // `photo_rail_like` further down the tree.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo_page_\(entry.id)")
        .onChange(of: isLiveFetchingRingVisible) { _, visible in
            handleLiveRingVisibilityChange(visible)
        }
        // A band change may start a creep that could not start while the
        // post was off screen. It cannot restart one that is already
        // running, because `startLiveRingCreep` refuses that, so a post
        // that drifts out of the centre band and back during one fetch
        // never resets the arc.
        .onChange(of: isInCenterBand) { _, _ in
            startLiveRingCreep()
        }
        // A recycled row must not inherit the previous asset's arc or latch.
        .onChange(of: entry.assetID) { _, _ in
            resetLiveRing()
        }
        // `PhotoDeck` prefetches tier 1 (and tier 2) for the next two
        // posts and the previous one, off the main actor, as the current
        // index settles. A post that lands here usually finds its
        // metadata already cached in `PhotoMetadataCache` and skips the
        // PhotoKit round trip.
        .task(id: entry.assetID) {
            if let cached = await PhotoMetadataCache.shared.resolvedTier1(for: entry.assetID) {
                tier1 = cached
                return
            }
            guard !Task.isCancelled else { return }
            let result = await PhotoMetadata.tier1(for: entry.assetID)
            guard !Task.isCancelled else { return }
            tier1 = result
            PhotoMetadataCache.shared.store(tier1: result, for: entry.assetID)
        }
        // Cache-only, memory then disk. Renders a prefetched tier-2 hit
        // the instant this view appears, regardless of `isCurrent` or
        // scroll state, so a prefetched post shows its full caption on
        // the frame it lands. This never triggers a PhotoKit or network
        // load itself: a cache miss leaves `tier2` nil for the
        // current-and-idle-gated task below to fill in.
        .task(id: entry.assetID) {
            if let cached = await PhotoMetadataCache.shared.resolvedTier2(for: entry.assetID) {
                tier2 = cached
            }
        }
        // The two tasks above read the cache exactly once, on appear. A
        // value that `PhotoMetadataPrefetcher` stores a few hundred
        // milliseconds later would otherwise never reach this row until it
        // became current and idle. This task listens for
        // `PhotoMetadataCache`'s own change signal and re-reads both
        // synchronous getters the instant either fires, current or not,
        // scrolling or not: a couple of dictionary reads per signal, no
        // PhotoKit call, no per-frame work.
        .task(id: entry.assetID) {
            let appeared = Date()
            for await _ in PhotoMetadataCache.shared.changes(for: entry.assetID) {
                guard !Task.isCancelled else { return }
                if tier1 == nil, let value = PhotoMetadataCache.shared.tier1(for: entry.assetID) {
                    tier1 = value
                    logRowUpdated("tier1", since: appeared)
                }
                if tier2 == nil, let value = PhotoMetadataCache.shared.tier2(for: entry.assetID) {
                    tier2 = value
                    logRowUpdated("tier2", since: appeared)
                }
            }
        }
        // The same reactive-cache approach, applied to `PlaceLookup`'s own
        // cache. Guarded on `resolvedPlace == nil`, so this never
        // overwrites an answer that the current-and-idle task below (or
        // the place-cache task further down) has already settled,
        // including the legitimate "no coordinate at all" case those set
        // directly as `.some(nil)`.
        .task(id: entry.assetID) {
            let appeared = Date()
            for await _ in PlaceLookup.shared.changes(for: entry.assetID) {
                guard !Task.isCancelled else { return }
                guard resolvedPlace == nil, let value = PlaceLookup.shared.cachedPlace(for: entry.assetID) else { continue }
                resolvedPlace = .some(value)
                logRowUpdated("place", since: appeared)
            }
        }
        // Keyed on the asset alone, so the image request never waits on a
        // metadata round trip that has nothing to do with pixels.
        //
        // The first frame this task receives, however good it already is,
        // shows with no animation: it is the first paint. Every frame
        // after that crossfades in over 0.2 seconds, so a degraded-to-sharp
        // swap never hard-cuts.
        .task(id: entry.assetID) {
            // A post scrolled back to is already decoded and in the
            // pipeline's cache. Paint it synchronously, with no
            // placeholder frame and no PhotoKit round trip.
            if let cached = PhotoImagePipeline.shared.cachedImage(for: entry.assetID) {
                stillImage = cached
                isDegradedImage = false
                #if DEBUG
                degradedMs = 0
                fullMs = 0
                #endif
                return
            }
            // The full frame can be evicted from the LRU cache, but
            // the thumbnail (0.25 MB, against about 8 MB) usually
            // stays. Paint the thumbnail now. The stream below
            // replaces it with the full frame.
            if let thumb = PhotoImagePipeline.shared.cachedThumbnail(for: entry.assetID) {
                stillImage = thumb
                isDegradedImage = true
                #if DEBUG
                degradedMs = 0
                #endif
            }
            let started = Date()
            var receivedFirstFrame = stillImage != nil
            for await event in PhotoImagePipeline.shared.events(for: entry.assetID) {
                guard !Task.isCancelled else { return }
                switch event {
                case .image(let image, let isDegraded):
                    #if DEBUG
                    PhotoPerfProbe.shared.noteImageDelivery(prepared: true)
                    wdMark("photoImageIn")
                    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                    if isDegraded { degradedMs = elapsed } else { fullMs = elapsed }
                    #endif
                    loadFailed = false
                    if receivedFirstFrame {
                        // GPU-composited crossfade — see `fadingOutImage`'s
                        // own doc comment. No `.contentTransition`, no
                        // CA-commit CPU redraw. The old frame drops behind
                        // the new one immediately; only its opacity
                        // animates.
                        let outgoing = stillImage
                        stillImage = image
                        isDegradedImage = isDegraded
                        fadingOutImage = outgoing
                        stillImageOpacity = 0
                        withAnimation(.easeInOut(duration: 0.2)) {
                            stillImageOpacity = 1
                        }
                        Task {
                            try? await Task.sleep(nanoseconds: 220_000_000)
                            guard !Task.isCancelled, stillImage === image else { return }
                            fadingOutImage = nil
                        }
                    } else {
                        stillImage = image
                        isDegradedImage = isDegraded
                        receivedFirstFrame = true
                    }
                case .progress(let fraction):
                    downloadFraction = fraction
                case .remote:
                    if !isRemoteOriginal {
                        isRemoteOriginal = true
                        // An iCloud download still going 3 seconds after
                        // it was first seen counts as slow.
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled, isRemoteOriginal, isDegradedImage || stillImage == nil else { return }
                            Usage.shared.slowDownload()
                        }
                    }
                case .failed:
                    if stillImage == nil {
                        loadFailed = true
                        Usage.shared.photoLoadFailed()
                    }
                }
            }
        }
        // Show the ring after 0.6 s. A degraded frame usually arrives
        // in tens of milliseconds, so a post still blank at 0.6 s is
        // usually waiting on an iCloud download.
        .task(id: entry.assetID) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, stillImage == nil else { return }
            showLoadingRing = true
        }
        // Current post only, and never while the pager is moving: tier 2
        // and `PlaceLookup`.
        .task(id: "\(isCurrent)|\(scrollGate.isScrolling)|\(entry.assetID)") {
            guard isCurrent, !scrollGate.isScrolling else { return }
            if tier2 == nil {
                if let cached = await PhotoMetadataCache.shared.resolvedTier2(for: entry.assetID) {
                    tier2 = cached
                } else {
                    tier2Pending = true
                    // `isOriginalLocal` from tier 1: an iCloud-offloaded
                    // original answers "no camera fields" immediately
                    // rather than spending a content-editing round trip to
                    // find out.
                    let t2 = await PhotoMetadata.tier2(
                        for: entry.assetID,
                        isOriginalLocal: tier1?.isOriginalLocal
                    )
                    tier2Pending = false
                    guard !Task.isCancelled else { return }
                    tier2 = t2
                    PhotoMetadataCache.shared.store(tier2: t2, for: entry.assetID)
                }
            }
            if let coordinate = tier1?.coordinate {
                // Read the shared cache first, synchronously. A prefetched
                // place must paint on this post's very first frame, not
                // after a round trip that only discovers the answer was
                // already sitting there.
                if let alreadyKnown = PlaceLookup.shared.cachedPlace(for: entry.assetID) {
                    placeWasPrefetched = true
                    placeMs = 0
                    resolvedPlace = .some(alreadyKnown)
                } else {
                    let started = Date()
                    let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    let place = await PlaceLookup.shared.place(for: entry.assetID, location: location)
                    guard !Task.isCancelled else { return }
                    placeWasPrefetched = false
                    placeMs = Int((Date().timeIntervalSince(started) * 1000).rounded())
                    resolvedPlace = .some(place)
                    // Persist it, so the next sighting of this photo is free.
                    PhotoMetadataCache.shared.persistPlace(place, for: entry.assetID)
                }
            } else {
                resolvedPlace = .some(nil)
            }
        }
        // Every post reads the shared place cache as it arrives, not just
        // the current one, so a prefetched place paints on a neighbour on
        // the frame it scrolls in, instead of waiting for that post to
        // become current and start its own lookup. This is a synchronous
        // dictionary read, so it costs nothing to do for every mounted
        // post.
        .task(id: "place|\(entry.assetID)|\(tier1?.coordinate != nil)") {
            guard let tier1, tier1.coordinate != nil, placeWasPrefetched == nil else { return }
            guard let alreadyKnown = PlaceLookup.shared.cachedPlace(for: entry.assetID) else { return }
            placeWasPrefetched = true
            placeMs = 0
            if resolvedPlace == nil { resolvedPlace = .some(alreadyKnown) }
        }
        // Three seconds after a tier-2 load starts, the caption stops
        // showing "…". The request continues, and its result still
        // updates the caption.
        .task(id: "\(tier2Pending)|\(entry.assetID)") {
            guard tier2Pending else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            tier2Pending = false
        }
        // Marks the post seen after it has been the current post for 0.5
        // seconds.
        .task(id: "\(isCurrent)|\(entry.assetID)") {
            guard isCurrent else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            PhotoDeck.shared.markSeen(entry.assetID)
        }
        // Starts 0.25 seconds after the post's frame enters the middle
        // third of the screen, independently of whether the post is
        // current. Keyed so it re-checks whenever band membership, the
        // Live toggle, or tier 1 arriving could newly satisfy the guard.
        // The 0.25-second sleep is itself the dwell requirement: a post
        // that leaves the band before it elapses has this task cancelled,
        // since its `id` changes, before `playNonce` ever bumps. A quick
        // pass-through never triggers a play that starts after the post
        // has already scrolled on.
        .task(id: "\(isInCenterBand)|\(isLiveOn)|\(tier1?.isLivePhoto ?? false)|\(entry.assetID)") {
            guard isInCenterBand, isLiveOn, let tier1, tier1.isLivePhoto, !hasAutoPlayedLive else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, isInCenterBand else { return }
            hasAutoPlayedLive = true
            playReason = "band"
            playNonce += 1
        }
        // Leaving the band resets the latch, so scrolling back in can
        // auto-play again, and asks `LivePhotoStage` to stop right away
        // and revert to the key photo. A post that never actually started
        // playing simply ignores the stop, since
        // `LivePhotoStage.Coordinator` only acts on it while `isPlaying`.
        .onChange(of: isInCenterBand) { _, inBand in
            if !inBand {
                hasAutoPlayedLive = false
                stopNonce += 1
            }
        }
        // The named space `shareButtonFrame` and
        // `sharePickerOverlayLayer`'s catcher both read against. It is
        // also the space the plain size read below is sized from.
        //
        // Put after `CrushClip` so that the capsule is not clipped
        // during a crush, even on a short post. The capsule sits just
        // above the actions row inside the post's own bounds in the
        // normal case, but not always for an unusually short post.
        .coordinateSpace(name: Self.sharePickerSpace)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _, newSize in
            postContentSize = newSize
        }
        // The picker collapses the instant the feed actually starts
        // scrolling, the same as the chin nav's switcher.
        .onChange(of: scrollGate.isScrolling) { _, isScrolling in
            guard isScrolling, isSharePickerExpanded else { return }
            cancelSharePicker()
        }
        .overlay(alignment: .topLeading) {
            if isLiveForTrio {
                sharePickerOverlayLayer
            }
        }
    }

    // MARK: - Header row

    /// Line 1 is the bold date and time. Line 2 is the place, shown
    /// only after it resolves to a value. No placeholder shows while
    /// the place loads.
    private func headerRow(_ tier1: PhotoMetadata.Tier1) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tier1.dateText)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityIdentifier(isCurrent ? "photo_meta_date" : "")
                if let placeText {
                    Text(placeText)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityIdentifier(isCurrent ? "photo_meta_place" : "")
                }
            }
            Spacer(minLength: 8)
            badgeCluster(tier1)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    /// `nil`, which renders nothing, while there is no coordinate, while
    /// the place lookup is still in flight, or once it resolves to no
    /// place. This line never falls back to `tier1.dateText`, or a
    /// reformatted version of it.
    private var placeText: String? {
        guard tier1?.coordinate != nil else { return nil }
        switch resolvedPlace {
        case .none:
            return nil
        case .some(let value):
            if let value, !value.isEmpty { return value }
            return nil
        }
    }

    // MARK: - Badges

    private func badgeCluster(_ tier1: PhotoMetadata.Tier1) -> some View {
        HStack(spacing: 6) {
            ForEach(tier1.badges, id: \.self) { badge in
                badgeChip(badge)
            }
        }
    }

    @ViewBuilder
    private func badgeChip(_ badge: PhotoMetadata.Badge) -> some View {
        if badge == .live {
            HStack(spacing: 2) {
                Image(systemName: "livephoto")
                Text("LIVE")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .accessibilityIdentifier(isCurrent ? "live_badge" : "")
            .accessibilityLabel("Live Photo")
        } else {
            Image(systemName: badgeGlyph(badge))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .accessibilityIdentifier(isCurrent ? "photo_badge_\(badge.rawValue)" : "")
                .accessibilityLabel(badgeLabel(badge))
        }
    }

    private func badgeGlyph(_ badge: PhotoMetadata.Badge) -> String {
        switch badge {
        case .live: return "livephoto"
        case .screenshot: return "camera.viewfinder"
        case .portrait: return "person.crop.rectangle"
        case .panorama: return "pano"
        case .hdr: return "sun.max"
        case .raw: return "r.square"
        // The favourite badge uses a heart, not a star: Photos itself has
        // never used a star for this, and its own vocabulary is the
        // heart.
        //
        // The Keep control is also a heart. This badge is white and
        // is in the header. Keep is red when on and is in the
        // actions row.
        case .favorite: return "heart.fill"
        case .burst: return "square.stack.3d.up"
        case .edited: return "pencil.circle"
        }
    }

    private func badgeLabel(_ badge: PhotoMetadata.Badge) -> String {
        switch badge {
        case .live: return "Live Photo"
        case .screenshot: return "Screenshot"
        case .portrait: return "Portrait"
        case .panorama: return "Panorama"
        case .hdr: return "HDR"
        case .raw: return "RAW"
        case .favorite: return "Favorite"
        case .burst: return "Burst"
        case .edited: return "Edited"
        }
    }

    // MARK: - The photo

    /// The photo's own aspect ratio, height divided by width, read off
    /// tier 1's `dimensionsText` (for example "4032 × 3024", built
    /// straight from `PHAsset.pixelWidth`/`pixelHeight` in
    /// `PhotoMetadata.loadTier1`). This is known the instant tier 1
    /// lands, before a single pixel of the actual image or Live Photo has
    /// decoded, so `photoArea`'s frame below is right on its very first
    /// layout pass and never jumps once the real content arrives.
    /// The post is always the full post width; this ratio is the only
    /// input to the height, so the photo never crops. A corrupt asset
    /// reporting 0×0 falls back to a plain square rather than crashing or
    /// dividing by zero.
    private func pixelAspectRatio(_ tier1: PhotoMetadata.Tier1) -> CGFloat {
        // The pipeline already read this asset's pixel size off the
        // `PHAsset` and cached it. Prefer that dictionary read:
        // `photoArea` calls this method from `body`, which runs hundreds
        // of times per scroll for every mounted post, and the fallback
        // below splits a string, trims two substrings, and parses two
        // `Double`s every time.
        if let known = PhotoImagePipeline.shared.aspectRatio(for: entry.assetID), known > 0 {
            return known
        }
        let parts = tier1.dimensionsText.split(separator: "×").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), width > 0 else {
            return 1
        }
        return CGFloat(height / width)
    }

    @ViewBuilder
    private func photoArea(_ tier1: PhotoMetadata.Tier1) -> some View {
        let photoHeight = containerWidth * pixelAspectRatio(tier1)
        ZStack {
            // A dim placeholder at the final size. It is lighter than
            // the black feed background, so a loading post is
            // visible.
            Color(white: 0.07)
            // The still always draws, Live or not. It is the bottom
            // layer, so a Live post shows its own key photo from the
            // moment the pipeline has one.
            // Two stacked plain `Image`s: old underneath at full opacity,
            // new on top fading in through `stillImageOpacity` alone. No
            // `.contentTransition`, so Core Animation composites the
            // crossfade on the GPU instead of CoreGraphics redrawing both
            // frames into a display list on the main thread every frame.
            if let fadingOutImage {
                Image(uiImage: fadingOutImage)
                    .resizable()
            }
            if let stillImage {
                Image(uiImage: stillImage)
                    .resizable()
                    .opacity(stillImageOpacity)
            }
            // A Live post mounts the real `PHLivePhotoView` when it is
            // near the viewport (current plus or minus one) or already
            // dwelling in the centre band. `PHLivePhotoView`'s own
            // background is clear, so the still above shows through until
            // its `PHLivePhoto` has loaded, with no flash of grey on the
            // way in.
            //
            // `isInCenterBand` is a live geometry read
            // (`PhotoFeedView.centerBandMembership`, up to 20 times a
            // second during a scroll). `isNear` is index-based off the
            // settled current post. During a fast scroll, a post can
            // dwell in the centre band well before `isNear` catches up.
            //
            // Without `isInCenterBand`, a post in the band can have no
            // `LivePhotoStage`, and the `playNonce` bump is lost.
            // Including `isInCenterBand` here starts the fetch. The
            // view then receives the eventual play the moment the
            // dwell timer starts, not only once the post is also near.
            //
            // A separate cap in `LivePhotoLoader` bounds concurrent
            // `PHLivePhoto` decodes to 3 in flight. This gate is not a
            // limiter.
            if tier1.isLivePhoto && (isNear || isInCenterBand) {
                LivePhotoStage(
                    assetID: entry.assetID,
                    targetSize: CGSize(width: containerWidth, height: photoHeight),
                    isMuted: !isLiveOn,
                    playNonce: playNonce,
                    playReason: playReason,
                    stopNonce: stopNonce,
                    isInBand: isInCenterBand,
                    onStateChange: { state in
                        if isCurrent { onLiveStateChanged(state) }
                    },
                    onReadinessChange: { readiness in
                        logLiveReadiness(readiness)
                        liveReadiness = readiness
                        if case .fetching(let fraction) = readiness, let fraction {
                            applyLiveFetchProgress(fraction)
                        }
                    }
                )
            }
            if shouldShowLoadingState {
                loadingOverlay
                    .onAppear { startLiveRingCreep() }
            }
            #if DEBUG
            if Self.showLoadBadges {
                loadBadge
            }
            #endif
        }
        // The post is always full post width; height is the asset's own
        // aspect ratio, computed above. This frame uses no
        // `.aspectRatio(contentMode: .fit)`, which fits the content's own
        // intrinsic size and can silently shrink the width on a tall photo
        // when combined with a height cap, and no cap at all. A plain
        // `.resizable()` image or an exactly-sized `PHLivePhotoView` fills
        // this frame exactly, since the frame's own ratio is the asset's
        // ratio, so nothing here ever crops.
        .frame(width: containerWidth, height: photoHeight)
        .background(Color.black)
        .contentShape(Rectangle())
        // `.scaleEffect` is a visual transform only. It does not change
        // this view's reported size, so the `LazyVStack` row above and
        // below never reflow while a pinch is live. The anchor is where
        // the fingers landed, so the zoom grows out of the spot the user
        // grabbed.
        //
        // Three things must be true for a zoom to draw on top of the
        // actions row and caption:
        // - `.zIndex` here lifts the photo over its own siblings.
        // - The post root's `.clipped()` stops cropping unless a crush
        //   is actually running — see `CrushClip`.
        // - The row must outrank its neighbours in the `LazyVStack`.
        //   `onZoomingChanged` in `PhotoFeedView` drives this.
        //
        // `.simultaneousGesture`, not `.gesture`, so the pinch never has
        // to out-compete the `.onTapGesture`s below for recognition.
        .scaleEffect(pinchScale, anchor: pinchAnchor)
        .zIndex(pinchScale > 1 ? 1 : 0)
        .simultaneousGesture(zoomGesture)
        .onTapGesture(count: 2) { keep(source: .doubleTap) }
        .onTapGesture { replayLive(tier1) }
        // `zoomGesture`'s own `.onEnded` releases the lock. A gesture that
        // is cancelled never sends one, and a stuck lock leaves the whole
        // feed unscrollable. Both handlers exist because a gesture can be
        // cancelled two ways: the app going to the background mid-pinch,
        // and this post being torn down mid-pinch.
        //
        // An `.onChange(of: pinchScale)` at scale 1 is not safe, because a
        // pinch begins at exactly 1.0 and would fire on the gesture's own
        // first frames. It would then clear the lock that `.onChanged`
        // had just set. That leaves `zoomingPostID` nil, and with it the
        // row `.zIndex` that puts the zoom above the next post.
        // `@GestureState` is not a safe cancel signal for this reason.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { onZoomingChanged(false) }
        }
        .onDisappear { onZoomingChanged(false) }
    }

    // MARK: - Loading and failure states

    /// True when the post shows a loading or failure state: no image
    /// after 0.6 s, a failed request, or a degraded frame while the
    /// iCloud original downloads.
    ///
    /// The still-image fallback (`isDegradedImage && isRemoteOriginal`)
    /// never applies to a Live-on Live post: `isLiveFetchingRingVisible`
    /// governs that case instead. A Live-off post, and a non-Live post,
    /// use only the still-image rule.
    private var shouldShowLoadingState: Bool {
        if isLiveOn, tier1?.isLivePhoto == true {
            return isLiveFetchingRingVisible || liveRingFinishing
        }
        if stillImage == nil { return showLoadingRing || loadFailed }
        return isDegradedImage && isRemoteOriginal
    }

    /// This post's reason to show the Live ring just ended or just
    /// began.
    private func handleLiveRingVisibilityChange(_ visible: Bool) {
        if visible { startLiveRingCreep() } else { finishLiveRing() }
    }

    /// Rows mount before they are seen, so the creep starts when the post
    /// is actually on screen, in the centre band, not on mount. Off-screen
    /// the ring sits at 0; entering the band starts it.
    ///
    /// This function only ever starts the creep. Every call while a creep
    /// is already running does nothing, so re-entering the centre band
    /// mid-fetch carries on from where the arc is, instead of dropping it
    /// back to 0 and climbing again. A restart needs a finish in front of
    /// it, and a finish only happens when readiness actually leaves idle
    /// or fetching.
    private func startLiveRingCreep() {
        guard isInCenterBand, isLiveFetchingRingVisible, !liveRingCreepRunning else { return }
        liveRingCreepRunning = true
        liveRingFinishing = false
        liveRingCreepStartedAt = Date()
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { liveRingCreep = 0 }
        runCreep(over: Self.creepDuration)
    }

    /// Animates the arc from wherever it is up to 90% over `duration`,
    /// then hands it to the slow drift towards 97%.
    ///
    /// The arc slows as it approaches 90%, then moves slowly toward
    /// 97%, so it never stops before readiness ends it. Two Core
    /// Animations run per fetch, with no per-frame work.
    private func runCreep(over duration: TimeInterval) {
        withAnimation(.timingCurve(0.15, 0.55, 0.45, 1.0, duration: duration)) { liveRingCreep = 0.9 }
        liveRingDriftTask?.cancel()
        liveRingDriftTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, liveRingCreepRunning else { return }
            withAnimation(.linear(duration: 20)) { liveRingCreep = 0.97 }
        }
    }

    /// A real download fraction arrived for the paired movie.
    ///
    /// PhotoKit reports the fraction of the resource bytes, which reaches
    /// 1.0 the moment the bytes are down, while `.ready` still waits on
    /// the file write, the audio session, the player item, and the seek
    /// behind it. Measured on the simulator: 100% at 53 ms, ready at 8.5
    /// s. A floor of `max(realFraction, creep)` would snap the arc to
    /// full and leave it stalled there, since a fraction that has stopped
    /// changing says nothing about the time still to come.
    ///
    /// So a real fraction is not a floor. It pulls the creep forward: when
    /// it is ahead of the arc on screen, the arc catches up to
    /// it over 0.2 s and then keeps rising across whatever is left of the
    /// path. The ring reports real download progress when there is real
    /// progress to report, and it never stops moving either way. A
    /// fraction at or past the creep's own ceiling is ignored outright:
    /// only `finishLiveRing` draws a full circle, and a full circle means
    /// done.
    ///
    /// The catch-up is an animation, not a direct assignment. Setting the
    /// arc straight to the fraction and re-targeting it in the same
    /// update makes SwiftUI re-base the running animation, producing a
    /// single-frame step backwards.
    private func applyLiveFetchProgress(_ fraction: Double) {
        guard liveRingCreepRunning, !liveRingFinishing, let startedAt = liveRingCreepStartedAt else { return }
        guard fraction > 0, fraction < 0.9 else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let creep = Self.creepValue(atElapsed: elapsed)
        guard fraction > creep else { return }
        // The pull is bounded. PhotoKit reported 78% of the paired video
        // 23 ms after the ring appeared, because the resource was already
        // local, while `.ready` still took 26 s. An unbounded pull would
        // throw the arc three quarters of the way round in a fifth of a
        // second and leave it to crawl the rest. A fraction may lead the
        // creep, but only by so much, so the ring keeps roughly its
        // 10-second path while still showing real progress when a
        // download really is the thing being waited on.
        let target = min(fraction, creep + Self.maxProgressLead)
        liveRingDriftTask?.cancel()
        let remaining = max(Self.creepDuration - elapsed, 2)
        withAnimation(.easeOut(duration: 0.2), completionCriteria: .logicallyComplete) {
            liveRingCreep = target
        } completion: {
            guard liveRingCreepRunning, !liveRingFinishing else { return }
            runCreep(over: remaining)
        }
    }

    /// How far ahead of the creep a real download fraction may pull the arc.
    private static let maxProgressLead: Double = 0.15

    /// Seconds the creep takes to travel from 0 to 90 %.
    private static let creepDuration: TimeInterval = 10

    /// The creep curve, sampled at every 5% of its duration.
    ///
    /// `applyLiveFetchProgress` has to know what the arc is showing right
    /// now, to decide whether a real fraction is ahead of it, but SwiftUI
    /// has no readable presentation value for Core Animation to report.
    /// The curve is a fixed cubic bezier, so its own shape answers the
    /// question: these are `timingCurve(0.15, 0.55, 0.45, 1.0)` evaluated
    /// at x = 0, 0.05, … 1.0. The view reads this at most once per
    /// published 2% progress step, never per frame.
    private static let creepCurve: [Double] = [
        0.0000, 0.1628, 0.2945, 0.4042, 0.4974, 0.5773, 0.6464, 0.7063,
        0.7583, 0.8034, 0.8424, 0.8760, 0.9047, 0.9289, 0.9491, 0.9655,
        0.9784, 0.9881, 0.9948, 0.9987, 1.0000
    ]

    private static func creepValue(atElapsed elapsed: TimeInterval) -> Double {
        guard elapsed < creepDuration else {
            // Past the curve, the arc is on the slow drift from 90% to
            // 97%.
            return 0.9 + 0.07 * min((elapsed - creepDuration) / 20, 1)
        }
        let position = max(elapsed, 0) / creepDuration * Double(creepCurve.count - 1)
        let index = min(Int(position), creepCurve.count - 2)
        let step = position - Double(index)
        return 0.9 * (creepCurve[index] + (creepCurve[index + 1] - creepCurve[index]) * step)
    }

    /// The arc animates from wherever the creep left it up to 100% over
    /// 0.22 s, and the ring disappears the instant that animation lands.
    /// The completion handler clears `liveRingFinishing`, so the hide can
    /// never be early, a cut before 100%, or late, a hold after it.
    private func finishLiveRing() {
        liveRingDriftTask?.cancel()
        liveRingDriftTask = nil
        liveRingCreepStartedAt = nil
        guard liveRingCreepRunning || liveRingFinishing || liveRingCreep > 0 else { return }
        liveRingCreepRunning = false
        liveRingFinishing = true
        withAnimation(.easeOut(duration: 0.22), completionCriteria: .logicallyComplete) {
            liveRingCreep = 1
            liveRingOpacity = 0
        } completion: {
            liveRingFinishing = false
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { liveRingCreep = 0; liveRingOpacity = 1 }
        }
    }

    /// Clears every trace of a previous post's ring when a row is recycled
    /// under this view, so an incoming asset can never inherit a half-finished
    /// arc or a latch that would block its own creep.
    private func resetLiveRing() {
        liveRingDriftTask?.cancel()
        liveRingDriftTask = nil
        liveRingCreepStartedAt = nil
        liveRingCreepRunning = false
        liveRingFinishing = false
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { liveRingCreep = 0 }
    }

    /// The ring shows for `.idle`, not only `.fetching`, since idle
    /// means "not fetched yet", which counts as "not ready".
    /// `@State private var liveReadiness` defaults to `.idle`, so a
    /// freshly mounted post reads this as true from its very first
    /// frame, before `LivePhotoStage` has published anything.
    ///
    /// There is no `isNear || isInCenterBand` gate on this: a post
    /// that never mounted a `LivePhotoStage` still reads
    /// `liveReadiness` as `.idle`, since nothing has overwritten the
    /// `@State` default. This reports the post as not ready.
    ///
    /// This is the sole visibility rule for a Live-on Live post — see
    /// `shouldShowLoadingState` above, which never falls through to
    /// the still-image rule for that case.
    private var isLiveFetchingRingVisible: Bool {
        guard isLiveOn, tier1?.isLivePhoto == true else { return false }
        // A movie already written to disk needs no fetch, so there is
        // nothing for a ring to report in three cases:
        // - A replay.
        // - Re-entering the centre band.
        // - Scrolling back to a post whose row was recycled, which
        //   resets `liveReadiness` to its `.idle` default.
        // The store's own mirror survives all three cases, so the code
        // checks it ahead of readiness, not after.
        if LivePairedMovieCache.shared.isReady(entry.assetID) { return false }
        switch liveReadiness {
        // `.ready` (movie on disk, player seeked) still shows the capped
        // creep; only `.playing` ends it, so the ring stays on screen
        // until the video is actually playing.
        case .idle, .fetching, .ready: return true
        case .playing: return false
        }
    }

    /// Shown only while this post has no image at all. Three states, in
    /// the order they can happen:
    ///
    /// * nothing yet, under 0.6 s on screen: the bare dim placeholder, no
    ///   spinner, because a spinner that flashes for 80 ms is
    ///   distracting;
    /// * still nothing at 0.6 s: the ring, with a cloud glyph once
    ///   PhotoKit has said the original is in iCloud, filling with the
    ///   real download fraction once it reports one (the same ring
    ///   `FeedView.shareButton` uses for its own iCloud share download);
    /// * the request failed: one quiet line, never a grey rectangle
    ///   permanently.
    ///
    /// The ring and its cloud glyph always sit in the bottom-right
    /// corner of the photo. The failure message stays centred, since a
    /// centred "Couldn't load" reads better than one tucked in a corner.
    ///
    /// The ring is 20 pt across, with a 2 pt stroke, a 9 pt glyph, and a
    /// 10 pt corner inset.
    @ViewBuilder
    private var loadingOverlay: some View {
        if loadFailed, stillImage == nil {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20, weight: .regular))
                Text("Couldn't load")
                    .font(.system(size: 13))
            }
            .foregroundStyle(.white.opacity(0.55))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(isCurrent ? "photo_load_failed" : "")
        } else {
            // While the ring shows for a Live reason, the arc is
            // `liveRingCreep`, never `downloadFraction`. A Live ring
            // starts at 0 and has no indeterminate sweep. The still
            // image's own ring keeps its own behaviour.
            let liveRing = isLiveFetchingRingVisible || liveRingFinishing
            // One value draws the Live arc, and every change to it is an
            // explicit Core Animation: the creep, a push from a real
            // download fraction (`applyLiveFetchProgress`), and the fill
            // to 100% that ends it (`finishLiveRing`). A plain
            // `max(progress, creep)` here would let a
            // finished-but-not-ready download pin the arc at a full
            // circle for seconds.
            let ringFraction: Double? = liveRing ? liveRingCreep : downloadFraction
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 2)
                if let ringFraction {
                    Circle()
                        .trim(from: 0, to: max(ringFraction, 0.02))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        // The still image's ring has no animation of its
                        // own, so it keeps this implicit one. The Live
                        // ring must not have it: `.animation(_:value:)`
                        // overrides the ambient transaction for its
                        // subtree, so applying it to both would replace
                        // the creep's own 10-second curve with a
                        // 0.2-second linear one, jumping the arc to 90%
                        // in a fifth of a second. The creep and the
                        // finish are explicit `withAnimation` calls; they
                        // carry their own timing and need nothing here.
                        .modifier(LoadingRingArcAnimation(isLive: liveRing, fraction: ringFraction))
                } else {
                    // No fraction yet: a slow indeterminate sweep, so the
                    // ring reads as working rather than stuck at zero.
                    Circle()
                        .trim(from: 0, to: 0.18)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(indeterminateSpin ? 270 : -90))
                        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: indeterminateSpin)
                        .onAppear { indeterminateSpin = true }
                }
                Image(systemName: loadingRingGlyphName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 20, height: 20)
            .opacity(liveRing ? liveRingOpacity : 1)
            // Over a degraded photo the ring needs its own ground to stay
            // legible; over the dim placeholder this is invisible anyway.
            .padding(5)
            .background(Color.black.opacity(stillImage == nil ? 0 : 0.35), in: Circle())
            // A full-bleed frame then a corner pad, the same technique
            // `loadBadge` below uses, positions this within `photoArea`'s
            // ZStack without resizing or moving the still image,
            // `LivePhotoStage`, or the placeholder layers under it.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(10)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(isCurrent ? "photo_loading_ring" : "")
            .accessibilityLabel(loadingRingAccessibilityLabel)
        }
    }

    /// While the paired movie is loading, the glyph is the same cloud
    /// used for an iCloud still download, not a Live Photo glyph. The
    /// Live gate wins outright here: `shouldShowLoadingState` never
    /// reaches the still-image branch while a Live-on post's ring is up
    /// for this reason (see that property), so `isRemoteOriginal` below
    /// only ever fires for a Live-off or non-Live post.
    /// `liveRingFinishing` also counts as a Live reason. Without it,
    /// the glyph changes from the cloud to the photo during the
    /// 0.22 s finish animation.
    private var loadingRingGlyphName: String {
        if isLiveFetchingRingVisible || liveRingFinishing || isRemoteOriginal { return "icloud.and.arrow.down" }
        return "photo"
    }

    private var loadingRingAccessibilityLabel: String {
        if isLiveFetchingRingVisible || liveRingFinishing { return "Preparing Live Photo" }
        if isRemoteOriginal { return "Downloading from iCloud" }
        return "Loading photo"
    }

    #if DEBUG
    /// "place pre" means the place was already in the shared cache when
    /// this post appeared, so the prefetch worked. "place live 900 ms"
    /// means it was not, and the post waited that long with the image
    /// already on screen. "place none" means this photo has no
    /// coordinate at all, so there is nothing to prefetch and nothing to
    /// wait for.
    private var placeBadgeText: String {
        guard tier1?.coordinate != nil else { return "place none" }
        switch placeWasPrefetched {
        case .some(true): return "place pre \(placeMs ?? 0) ms"
        case .some(false): return "place live \(placeMs ?? 0) ms"
        case .none: return "place …"
        }
    }

    /// A DEBUG-only reporting aid (`-cloudfull-show-loads`), shown
    /// top-left of the photo, for example "deg 120 ms · full 900 ms ·
    /// net".
    private var loadBadge: some View {
        Text(loadBadgeText)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var loadBadgeText: String {
        var parts: [String] = []
        parts.append(degradedMs.map { "deg \($0) ms" } ?? "deg –")
        parts.append(fullMs.map { "full \($0) ms" } ?? "full –")
        parts.append(placeBadgeText)
        if isRemoteOriginal { parts.append("net") }
        if loadFailed { parts.append("FAIL") }
        if let liveReadinessBadgeText { parts.append(liveReadinessBadgeText) }
        return parts.joined(separator: " · ")
    }

    /// A reporting aid: "live fetching", "live ready", or "live playing",
    /// added to the same DEBUG badge. `nil`, meaning nothing appended,
    /// for a non-Live post and for a Live one that is simply idle, the
    /// common case already covered by the `deg`, `full`, and place
    /// fields.
    private var liveReadinessBadgeText: String? {
        guard tier1?.isLivePhoto == true else { return nil }
        switch liveReadiness {
        case .idle: return nil
        case .fetching(let progress):
            guard let progress else { return "live fetching" }
            return "live fetching \(Int((progress * 100).rounded()))%"
        case .ready: return "live ready"
        case .playing: return "live playing"
        }
    }

    /// Computed, not a stored `let`: this switch is both a Settings
    /// toggle and a launch argument, so the view reads it fresh each
    /// time. Reading a `Bool` off a singleton per body pass costs less
    /// than the badge it gates.
    static var showLoadBadges: Bool { DiagnosticsSwitch.shared.isOn }
    #endif

    /// A DEBUG aid (`-cloudfull-log-live`, the same gate `LivePhotoStage`
    /// itself uses): one line per `LiveReadiness` change this post's own
    /// stage publishes, so a log can confirm the ring's visibility rule
    /// is seeing the state it expects.
    private func logLiveReadiness(_ readiness: LiveReadiness) {
        #if DEBUG
        guard DiagnosticsGate.isOn("-cloudfull-log-live") else { return }
        let text: String
        switch readiness {
        case .idle: text = "idle"
        case .fetching(let progress): text = "fetching_\(progress.map { String(Int(($0 * 100).rounded())) } ?? "indeterminate")"
        case .ready: text = "ready"
        case .playing: text = "playing"
        }
        DiagnosticsLog.shared.log("LiveReadiness", "readiness_\(text)_\(entry.assetID)")
        #endif
    }

    /// `row_updated_<field>_<ms>ms_<assetID>` is written only when a
    /// reactive listener above actually moves a field from unknown to
    /// known, never on a signal that turns out to do nothing, since both
    /// guards above already keep that call site out of that path. This
    /// uses the same gate as `PlaceLookup.logLookup`
    /// (`-cloudfull-log-place`).
    private func logRowUpdated(_ field: StaticString, since appeared: Date) {
        #if DEBUG
        guard DiagnosticsGate.isOn("-cloudfull-log-place") else { return }
        let ms = Int((Date().timeIntervalSince(appeared) * 1000).rounded())
        DiagnosticsLog.shared.log("RowReactive", "row_updated_\(field)_\(ms)ms_\(entry.assetID)")
        #endif
    }

    // MARK: - Actions row

    /// Keep, Album, Share, and Trash sit side by side, left-aligned,
    /// with no `Spacer` pushing Trash to the far edge. A horizontal
    /// row reads better with the controls grouped together than
    /// spread to the edges.
    ///
    /// Each control is an icon-and-word pair that hugs its own
    /// content instead of sitting in a fixed 44x44 box, with a 6 pt
    /// gap and a 15 pt word. The row uses 14 pt gaps between
    /// controls.
    private var actionsRow: some View {
        // 14 pt gaps keep the four icon-and-word pairs inside 370 pt
        // of usable width. `.fixedSize` on each label prevents
        // wrapping. A label that is too long crowds the row instead
        // of wrapping to a second line.
        HStack(spacing: 14) {
            keepButton
            albumButton
            shareButton
            trashButton
            Spacer(minLength: 0)
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
    }

    private var keepButton: some View {
        Button(action: toggleKeepFromRail) {
            HStack(spacing: 6) {
                Image(systemName: isKept ? "heart.fill" : "heart")
                    .font(.system(size: Self.actionGlyphSize, weight: .regular))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, options: .speed(1.4), value: likeBounceToken)
                    .frame(height: Self.actionGlyphBox)
                Text("Keep")
                    .font(.system(size: 15, weight: .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(isKept ? .red : .white)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isCurrent ? "photo_rail_like" : "")
        .accessibilityLabel(isKept ? "Unkeep" : "Keep")
        .accessibilityAddTraits(isKept ? .isSelected : [])
        .accessibilityHint(isKept
            ? "Removes the protection on this photo"
            : "Protects this photo so Cloudfull can never delete it")
    }

    /// Mirrors the video rail's own share button (`FeedView.shareButton`):
    /// a light impact haptic on the tap itself, then the same
    /// cloud-glyph-plus-progress-ring in place of the arrow glyph while
    /// `ShareCoordinator` downloads the original from iCloud.
    /// `ShareCoordinator.beginShare(assetID:)` and `ShareItemResolver` are
    /// both asset-kind-agnostic already, since `resolveImage`'s own
    /// `writeResourceCopy` call reports the same 0...1 progress a video
    /// share does.
    ///
    /// A `ShareLink` path for a Live Photo, sending its already-decoded
    /// `PHLivePhoto` through `Transferable`, does not work: Messages
    /// disappears from the share sheet entirely, because the
    /// `Transferable` representation `PhotosUI` gives a `PHLivePhoto` is
    /// not a type Messages accepts. Every asset goes through the one
    /// UIKit sheet (`ShareCoordinator.beginShare`).
    ///
    /// A Live post's Share tap grows a capsule that looks and behaves
    /// like `ChinNavigation`'s own expanded switcher — see the "Share
    /// picker" section above and `sharePickerOverlayLayer` below — instead
    /// of opening a system `Menu`. All three picks use the same
    /// identifiers and the same `ShareCoordinator.beginShare(kind:)` call
    /// underneath, in `pickShare`. A non-Live post goes straight to the
    /// sheet.
    @ViewBuilder
    private var shareButton: some View {
        if isLiveForTrio {
            Button(action: expandSharePicker) {
                shareLabel
                    .opacity(shareLabelOpacity)
            }
            .buttonStyle(.plain)
            .disabled(isSharePickerExpanded)
            .allowsHitTesting(!isSharePickerExpanded)
            .accessibilityIdentifier(isCurrent ? "photo_rail_share" : "")
            .accessibilityLabel("Share")
            .accessibilityHint("Shows Still, Video, and Live share options for this photo")
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.sharePickerSpace))
            } action: { _, newFrame in
                shareButtonFrame = newFrame
            }
        } else {
            Button {
                Haptics.tap()
                shareCoordinator.beginShare(assetID: entry.assetID)
            } label: {
                shareLabel
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(isCurrent ? "photo_rail_share" : "")
            .accessibilityLabel("Share")
            .accessibilityHint("Opens the share sheet for this photo, including Add to Album")
        }
    }

    /// One of the Live share picker's three picks, fired only after the
    /// capsule has finished collapsing back into the plain button — see
    /// `handleSharePick`. The tap gives a haptic. The log tag
    /// (`share_trio_pick_<kind>`) keeps existing `diagnostics.log` tooling
    /// working.
    private func pickShare(_ kind: ShareKind) {
        Haptics.tap()
        #if DEBUG
        if DiagnosticsGate.isOn("-cloudfull-log-share") {
            let name: String
            switch kind {
            case .still: name = "still"
            case .video: name = "video"
            case .live: name = "live"
            }
            DiagnosticsLog.shared.log("PhotoShare", "share_trio_pick_\(name)_\(entry.assetID)")
        }
        #endif
        shareCoordinator.beginShare(assetID: entry.assetID, kind: kind)
    }

    // MARK: - Share picker

    /// The collapsed end of the capsule's grow-and-shrink animation: the
    /// real Share button's own measured frame, so the glass appears to
    /// grow exactly out of the button and shrink exactly back into it.
    private var sharePickerCollapsedRect: CGRect { shareButtonFrame }

    /// The expanded capsule is about 200 pt wide, clamped to the post's
    /// own width so it never runs off the right edge, and left-aligned
    /// with the Share button. Its bottom sits `sharePickerGap` above the
    /// actions row: the button is the top of the actions row, so
    /// anchoring off its own top edge (`minY`) places the capsule just
    /// above that row.
    private var sharePickerExpandedRect: CGRect {
        let maxWidth = max(postContentSize.width - shareButtonFrame.minX - 16, 80)
        let width = min(Self.sharePickerWidth, maxWidth)
        return CGRect(
            x: shareButtonFrame.minX,
            y: shareButtonFrame.minY - Self.sharePickerGap - Self.sharePickerHeight,
            width: width,
            height: Self.sharePickerHeight
        )
    }

    private var sharePickerRect: CGRect {
        isSharePickerExpanded ? sharePickerExpandedRect : sharePickerCollapsedRect
    }

    /// Layer 1, matching `ChinNavigation.shellGlass`'s own recipe: one
    /// `Color.clear` shape and one `glassEffectID`, so the frame change
    /// from the button's rect to the capsule's rect, and back, is one
    /// continuous piece of glass rather than two shapes cross-fading.
    /// Never hit-testable, so that taps reach the segmented control
    /// and the catcher underneath.
    private func sharePickerShell(rect: CGRect) -> some View {
        GlassEffectContainer(spacing: 0) {
            Color.clear
                .frame(width: rect.width, height: rect.height)
                .feedGlass(in: Capsule())
                .glassEffectID(SharePickerGlassID.shell, in: sharePickerGlassNamespace)
        }
        .opacity(sharePickerShellOpacity)
        .allowsHitTesting(false)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    /// Layer 2: the real `LiquidSegmentedControl<ShareKind>`, drawn on top
    /// of the glass, never inside it, following
    /// `ChinTabSegmentedControl.swift`'s own layering rule. Always
    /// mounted, like `ChinNavigation.content`, so its opacity animates
    /// instead of the view appearing at once. It is always sized and
    /// positioned to the expanded rect, since it has nothing useful to
    /// show at the button's own tiny collapsed size and is invisible
    /// there anyway.
    /// `selection: nil` means no preselected segment, so Apple's lens
    /// stays hidden until the first touch.
    private var sharePickerContent: some View {
        let rect = sharePickerExpandedRect
        return LiquidSegmentedControl(
            items: Self.shareItems,
            selection: nil,
            onSelect: handleSharePick,
            onReselect: handleSharePick
        )
        .frame(width: rect.width - Self.sharePickerControlInset * 2,
               height: rect.height - Self.sharePickerControlInset * 2)
        .position(x: rect.midX, y: rect.midY)
        .opacity(sharePickerWordsOpacity)
        .allowsHitTesting(isSharePickerExpanded)
        .accessibilityHidden(!isSharePickerExpanded)
    }

    /// The tap-outside catcher plus the capsule itself, in
    /// `ChinNavigation`'s own two-layer order: catcher first, so the
    /// capsule drawn after it wins hit testing over its own bounds, then
    /// the capsule. The layer is mounted for every Live post, not only
    /// while expanded. The grow and shrink animations need a view that
    /// stays mounted, not one that appears fresh at its final size.
    private var sharePickerOverlayLayer: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: postContentSize.width, height: postContentSize.height)
                .allowsHitTesting(isSharePickerExpanded)
                .onTapGesture { cancelSharePicker() }
                // Same reasoning as `ChinNavigation`'s own catcher: without
                // this, a swipe that starts inside the catcher's bounds (most
                // of this post) never reaches the pager underneath, so
                // `scrollGate.isScrolling` never flips and the capsule never
                // learns the feed is moving.
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { _ in
                            guard isSharePickerExpanded else { return }
                            cancelSharePicker()
                        }
                )
                .accessibilityHidden(true)

            sharePickerShell(rect: sharePickerRect)
            sharePickerContent
        }
    }

    /// The Share glyph and word dim to 0.35 while the capsule grows.
    /// The picker content fades in after a short delay. This matches
    /// `ChinNavigation.expand()`.
    private func expandSharePicker() {
        guard !isSharePickerExpanded else { return }
        Haptics.tap()
        sharePickerToken += 1
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.86)) {
            isSharePickerExpanded = true
            sharePickerShellOpacity = 1
            shareLabelOpacity = 0.35
        }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.18).delay(0.12)) {
            sharePickerWordsOpacity = 1
        }
    }

    /// Hides the picker content first, then animates the glass back
    /// to the button. This matches `ChinNavigation.collapse()`. The
    /// glass then does not distort visible content while it shrinks.
    private func collapseSharePicker() {
        guard isSharePickerExpanded else { return }
        sharePickerWordsOpacity = 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.88)) {
            isSharePickerExpanded = false
            sharePickerShellOpacity = 0
            shareLabelOpacity = 1
        }
    }

    /// Dismisses the picker with no pick in flight, on a tap outside
    /// or a scroll. Bumps the token first, so a pick that is
    /// mid-flight, past `handleSharePick`'s own `sharePickerLensSlide`
    /// wait but not yet past `sharePickerCollapseSettle`, does not go
    /// on to fire `pickShare` after the picker has already been
    /// dismissed a different way.
    private func cancelSharePicker() {
        sharePickerToken += 1
        collapseSharePicker()
    }

    /// A pick of a share kind. The lens is given `sharePickerLensSlide`
    /// to visibly land on the picked segment, then the capsule collapses
    /// back into the plain button. `pickShare` fires the share sheet only
    /// once that collapse settles.
    private func handleSharePick(_ kind: ShareKind) {
        sharePickerToken += 1
        let token = sharePickerToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sharePickerLensSlide) {
            guard token == self.sharePickerToken else { return }
            self.collapseSharePicker()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sharePickerCollapseSettle) {
                guard token == self.sharePickerToken else { return }
                self.pickShare(kind)
            }
        }
    }

    /// The Share control's content: the iCloud download ring during
    /// a share download, or the share glyph, and the word.
    private var shareLabel: some View {
        HStack(spacing: 6) {
            if let download = shareCoordinator.download, download.assetID == entry.assetID {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(download.fraction, 0.02))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: download.fraction)
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(width: 24, height: 24)
                #if DEBUG
                .onAppear { logShareRing(shown: true) }
                .onDisappear { logShareRing(shown: false) }
                #endif
            } else {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: Self.actionGlyphSize, weight: .regular))
                    .frame(height: Self.actionGlyphBox)
            }
            Text("Share")
                .font(.system(size: 15, weight: .regular))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.white)
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    #if DEBUG
    /// A DEBUG aid (`-cloudfull-log-share`). In a seeded library that
    /// resolves shares locally with no iCloud download, the ring above
    /// can appear and disappear inside a single frame, too fast to
    /// screenshot reliably. This line makes the state provable from
    /// `diagnostics.log` even when the ring was never visibly on screen
    /// long enough to catch. It uses the same gate style as
    /// `PlaceLookup.logLookup`/`logRowUpdated` (`-cloudfull-log-place`).
    private func logShareRing(shown: Bool) {
        guard DiagnosticsGate.isOn("-cloudfull-log-share") else { return }
        DiagnosticsLog.shared.log("PhotoShare", "share_ring_\(shown ? "shown" : "hidden")_\(entry.assetID)")
    }
    #endif

    /// Adding to an album is also possible several taps deep inside the
    /// system share sheet (`AddToAlbumActivity`). This is the same
    /// destination promoted to its own control, in the same
    /// icon-and-word layout as the other controls.
    ///
    /// This view presents nothing itself: `PhotoFeedView` already mounts
    /// the `.sheet(item: $shareCoordinator.albumPickerTarget)` that the
    /// share sheet's own route uses, so both paths land on one picker
    /// with one dismissal.
    private var albumButton: some View {
        Button {
            Haptics.tap()
            shareCoordinator.albumPickerTarget = .init(id: entry.assetID)
        } label: {
            HStack(spacing: 6) {
                // An outline glyph matches the drawing weight of the
                // other glyphs in this row. `actionGlyphBox` keeps the
                // word on the same baseline as its neighbours,
                // regardless of `albumGlyphSize`.
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: Self.albumGlyphSize))
                    .frame(height: Self.actionGlyphBox)
                Text("Album")
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .fixedSize()
            }
            // The same two modifiers its three neighbours carry. The
            // frame alone is not enough: without `.contentShape` the
            // button's hit area, and its accessibility frame, stays the
            // 29 pt the icon and word actually occupy, under Apple's
            // 44 pt touch minimum.
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityIdentifier(isCurrent ? "photo_rail_album" : "")
        .accessibilityLabel("Add to album")
        .accessibilityHint("Opens the album picker for this photo")
    }

    private var trashButton: some View {
        Button(action: handleTrashTap) {
            HStack(spacing: 6) {
                Image(systemName: trashGlyphName)
                    .font(.system(size: Self.trashGlyphSize))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: Self.actionGlyphBox)
                Text(trashLabelText)
                    .font(.system(size: 15, weight: .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .opacity(deleteEnabled ? 1 : 0.35)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .disabled(!deleteEnabled)
        .buttonStyle(.plain)
        .accessibilityIdentifier(isCurrent ? "photo_rail_trash" : "")
        .accessibilityLabel(trashAccessibilityLabel)
        .accessibilityHint(trashAccessibilityHint)
    }

    /// Mirrors `FeedView.trashIconName`/`trashLabel`: `trash.fill`, not
    /// merely a dimmed `trash`, once queued, since `deleteEnabled` itself
    /// stays true while queued, the same as the video rail's
    /// `RailState.deleteEnabled`.
    private var isQueuedForDeletion: Bool { trashService.isQueued(entry.assetID) }

    private var trashGlyphName: String {
        if !deleteEnabled { return "trash.slash" }
        return isQueuedForDeletion ? "trash.fill" : "trash"
    }

    private var trashLabelText: String {
        if isKept { return "Kept" }
        if !deleteEnabled { return "Delete" }
        return isQueuedForDeletion ? "Queued" : "Delete"
    }

    private var trashAccessibilityLabel: String {
        if isKept { return "Protected, cannot delete" }
        if !resolver.isDestructiveActionSafe { return "Delete photo, not ready yet" }
        return isQueuedForDeletion ? "Queued for deletion" : "Delete photo"
    }

    private var trashAccessibilityHint: String {
        if isKept { return "This photo is kept, so it can never be queued for deletion" }
        if !resolver.isDestructiveActionSafe { return "Cloudfull is still checking which photos you kept." }
        return "Queues this photo for deletion and removes it from the feed"
    }

    // MARK: - Actions, scoped to this post's own asset

    /// The rail heart toggles either direction. The photo's own double
    /// tap (`keep()` below) is keep-only.
    private func toggleKeepFromRail() {
        if isKept {
            let applied = unkeep()
            if applied {
                Usage.shared.action(.unkeep, source: .rail, mode: .photos)
            }
        } else {
            keep(source: .rail)
        }
    }

    /// Double-tap on the photo is keep-only, matching video's own
    /// double-tap rule: it never strips a protection the user already
    /// set. Toggling to Unkeep stays an explicit rail tap.
    private func keep(source: Usage.ActionSource) {
        guard !isKept else {
            Usage.shared.keepTapNoop(mode: .photos)
            likeBounceToken += 1
            return
        }
        let assetID = entry.assetID
        let applied = KeepStore.shared.keep(assetID: assetID)
        if applied {
            Usage.shared.action(.keep, source: source, mode: .photos)
            KeepsAlbum.shared.add(assetID)
        }
        // Keeping a photo takes priority over an existing trash queue
        // entry: restoring it here undoes any pending deletion.
        if trashService.restore(assetID: assetID) { Usage.shared.keepPulledFromBin(mode: .photos) }
        PhotoDeck.shared.noteKept(assetID: assetID)
        Haptics.tap()
        likeBounceToken += 1
        // The heart fill above is immediate; this is the advance about
        // 0.15 seconds later, reusing the same animated `scrollTo`
        // mechanism `handleTrashTap` drives directly — see
        // `onAdvanceRequested`/`PhotoFeedView.advanceToNextPost`. Unlike a
        // delete, the kept post is never removed from `deck.entries`, so
        // this scroll is the only visible change once it lands. This
        // fires for both the rail's Keep tap (`toggleKeepFromRail`) and
        // the photo's own double-tap, since both funnel through this
        // method.
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.keepAdvanceDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            onAdvanceRequested(0)
        }
    }

    @discardableResult
    private func unkeep() -> Bool {
        let assetID = entry.assetID
        let applied = KeepStore.shared.unkeep(assetID: assetID)
        if applied { KeepsAlbum.shared.remove(assetID) }
        PhotoDeck.shared.noteUnkept(assetID: assetID)
        return applied
    }

    private func handleTrashTap() {
        #if DEBUG
        if !deleteEnabled {
            DiagnosticsLog.shared.log("TrashQueue", "photo_tap_disabled_kept_\(isKept)_state_\(resolver.state.rawValue)")
        }
        #endif
        guard deleteEnabled else { return }
        let assetID = entry.assetID
        let queued = trashService.queue(assetID: assetID, mediaKind: .photo)
        guard queued else { return }
        Haptics.tap()
        Usage.shared.action(.delete, source: .rail, mode: .photos)
        Usage.shared.deleted(mode: .photos, width: tier1?.pixelWidth ?? 0, height: tier1?.pixelHeight ?? 0)
        DailyReminder.shared.noteFirstDelete()
        // Keep this row in `deck.entries`. Removing it now makes the
        // post disappear with no crush animation.
        PhotoDeck.shared.removeFromFuture(assetID: assetID, keepingEntryID: entry.id)
        // The loop below collapses this post's own height to 0. The feed
        // is told at once, so its settle logic stands down for the whole
        // crush instead of pruning this post and snapping the scroll
        // mid-crush. After `crushDuration` it prunes this post in place,
        // with no scroll.
        isCollapsedForDelete = true

        // The crush stops when this post's bottom meets the top of the
        // scroll view, keeping whatever height was already above the
        // screen. The content above the viewport is then exactly as it
        // was, so the scroll view has nothing to clamp, and no picture
        // above drops into view after a delete.
        //
        // A fully visible post keeps 0, which leaves the crush unchanged.
        let fullHeight = measuredHeight ?? 0
        // A post shrinks smoothly while its top is on screen, and
        // jumps when its top is above it. A post whose top is above
        // the screen is revealed first: the feed slides down until
        // the top sits just under the top filter controls, with a
        // sliver of the post above showing. The post then crushes,
        // all the way, top-anchored. The post above holds its top
        // edge throughout and never moves.
        let offscreen = min(max(offscreenTopHeight(), 0), fullHeight)
        let reveal = offscreen > 0 ? offscreen + Self.revealMargin : 0
        let revealDuration: TimeInterval = reveal > 0 ? Self.revealDuration : 0
        let target: Double = 1

        // Claimed now, not when the animation ends. The feed clears
        // `isAdvancing` before its own prune, which lets the settle
        // handler prune instead and bump `reanchorNonce`, and that
        // re-anchor is `scrollTo(anchor: .top)`, a second, separate
        // movement. Claiming the row up front closes both paths: every
        // prune skips it from this instant.
        PhotoDeck.shared.markCollapsed(entry.id, keeping: 0)

        // The crush always takes `crushDuration` (0.5 s). For an
        // above-the-fold post, the slide starts at `revealStart`
        // (0 s) and runs for `revealDuration` (0.25 s) during the
        // crush.
        let duration = Self.crushDuration
        onAdvanceRequested(duration)
        Task {
            var slideStarted = false
            let started = Date()
            while true {
                let elapsed = Date().timeIntervalSince(started)
                if reveal > 0, !slideStarted, elapsed >= Self.revealStart {
                    slideStarted = true
                    onRevealRequested(reveal, revealDuration)
                }
                let t = min(elapsed / duration, 1)
                crushFraction = Self.crushEase(t) * target
                if t >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
            }
            crushFinished = true
            wdMark("photoCrushDone")
        }
    }

    /// Cubic ease-in-out, sampled by hand roughly every 16 ms in
    /// `handleTrashTap`'s own crush loop — see `crushFraction`'s doc
    /// comment for why this is not a plain SwiftUI `Animation` curve.
    private static func crushEase(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Single tap on the photo, about 0.3 s after the double-tap window
    /// lapses. A non-Live photo does nothing. A Live photo, on or off,
    /// replays once.
    private func replayLive(_ tier1: PhotoMetadata.Tier1) {
        guard tier1.isLivePhoto else { return }
        playReason = "tap"
        playNonce += 1
    }

    /// The two-finger pinch uses `MagnifyGesture`, not the older
    /// `MagnificationGesture`, because only `MagnifyGesture` reports
    /// `startAnchor`. `startAnchor` is where the fingers landed, so the
    /// zoom grows from the spot the user grabbed, not the photo's
    /// centre.
    ///
    /// The pager is told to stand down (`onZoomingChanged`) for the
    /// gesture's whole span, from `.onChanged` to `.onEnded`, not merely
    /// while `pinchScale` differs from 1: the very first pinch frame must
    /// already have the pager locked, before `pinchScale` has visibly
    /// moved.
    ///
    /// Do not add drag-to-pan with a SwiftUI gesture.
    ///
    /// A separate `.simultaneousGesture(pan, including: pinchScale >
    /// 1 ? .all : .subviews)` can never fire. A gesture only picks up
    /// a touch sequence it was already watching when the fingers went
    /// down, and at that instant the scale is exactly 1, so the mask
    /// has it switched off.
    ///
    /// Folding the drag in as `SimultaneousGesture(MagnifyGesture(),
    /// DragGesture(minimumDistance: 0))` does fire, but it also
    /// swallows the feed's own one-finger scroll and the
    /// double-tap-to-keep outright. That drag half claims every touch
    /// sequence from its first pixel.
    ///
    /// Panning a zoomed photo needs a UIKit `UIPanGestureRecognizer`
    /// with `minimumNumberOfTouches = 2`, which never competes with a
    /// one-finger scroll.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchScale) { value, state, _ in
                state = min(max(value.magnification, 1), 4)
            }
            .updating($pinchAnchor) { value, state, _ in
                state = value.startAnchor
            }
            .onChanged { _ in onZoomingChanged(true) }
            .onEnded { _ in
                onZoomingChanged(false)
                Usage.shared.pinch()
            }
    }
}

/// Carries the still image ring's implicit 0.2 s smoothing, and only
/// that ring's.
///
/// The Live ring's arc is driven by explicit `withAnimation` calls, the
/// creep in `startLiveRingCreep` and the fill in `finishLiveRing`, and
/// `.animation(_:value:)` overrides the ambient transaction for whatever
/// it is attached to. Applied to both rings, it would replace the
/// creep's 10-second curve with a 0.2-second linear one and send the arc
/// to 90% almost instantly. Applied to neither, the still image's
/// download fraction would step in visible jumps. So it applies to
/// exactly one of them, here.
private struct LoadingRingArcAnimation: ViewModifier {
    let isLive: Bool
    let fraction: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLive {
            content
        } else {
            content.animation(.linear(duration: 0.2), value: fraction)
        }
    }
}

/// Applies `.clipped()` only while a crush is actually collapsing this
/// post's height.
///
/// A plain `.clipped()` on the post root is what the crush needs, since
/// the bottom of the photo has to disappear as the frame shrinks, but it
/// would also crop a pinch-zoom to the post's own rect. Outside a crush
/// the clip never does anything, since the post's content is exactly its
/// frame's size, so switching it off there costs nothing and lets a zoom
/// paint outward.
private struct CrushClip: ViewModifier {
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.clipped()
        } else {
            content
        }
    }
}
