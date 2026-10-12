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
import os

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

    /// R5 (`design/duo/duo_audit_apple_checklist.md` Decision A/C):
    /// `OrientationMonitor` is gone — no device orientation is read
    /// anywhere in this file. `isFullscreen`/`allowsLandscape` below
    /// read the window's own real shape and traits, through
    /// `PlayerPageView`'s own `isFullscreen`/`allowsLandscapeCandidate`.
    @Environment(\.scenePhase) private var scenePhase
    /// The vertical bar's edge on the iPhone Duo's closed screen; `nil`
    /// on a regular iPhone, on the open Duo, and on anything below iOS
    /// 27.1 (this plain stored property's default).
    ///
    /// Not read with a plain `@Environment(\.toolbarVerticalEdge)`
    /// property: Swift refuses `@available` on a stored property, and
    /// that environment key only exists from iOS 27.1, so a stored
    /// property for it cannot be declared unconditionally on a type
    /// whose own deployment target is lower. `ToolbarVerticalEdgeReader`
    /// below is the standard workaround — a zero-size helper view that
    /// is itself `@available`-marked, mounted only inside an
    /// `if #available` branch in `body`, which writes into this plain,
    /// always-available property instead.
    ///
    /// Review follow-up (SHOULD-FIX): because of the limitation above,
    /// this value still starts `nil` for `body`'s own first pass on a
    /// closed Duo — `ToolbarVerticalEdgeReader`'s `onChange(of:
    /// initial: true)` (`DuoLayout.swift`) only updates this property
    /// one render cycle later, not within that same first `body` call.
    /// A true zero-lag fix needs the content that reads `duoLayout`
    /// (effectively this whole view) to live INSIDE a child view that
    /// itself declares `@Environment(\.toolbarVerticalEdge)` — the
    /// only place SwiftUI actually injects the live value — since a
    /// value a child reads can never flow back into a `let` the parent
    /// already computed earlier in that same `body` call, state copy
    /// or not. That is a real restructuring of this file's `body`, not
    /// a local change, with no simulator available this pass to verify
    /// it keeps a regular iPhone pixel-identical, so it is deferred
    /// rather than risked here. `DuoLayout.seenFoldable` (review fix,
    /// BLOCKER finding 1) already closes the one case this lag could
    /// actually mis-mirror — the closed Duo's first-ever frame with
    /// `leftHandedControls` on — for every launch after the first.
    @State private var toolbarVerticalEdge: HorizontalEdge?
    /// Mirrored-layout round: the owner's own "Left-handed controls"
    /// setting (`SettingsView`'s own toggle) — fed to `DuoLayout.current`
    /// below, the same "the caller reads it live" rule every other
    /// parameter there already follows. Owner decision: "the Duo
    /// always follows the system bar side; the Left-handed controls
    /// setting applies only on regular iPhones." Review fix: this
    /// setting now only takes effect with no system bar at all AND on
    /// a device that is not a foldable at all — never on an iPhone
    /// Duo, bar-on or bar-off, which always follows the bar/system
    /// side instead; see `DuoLayout.isMirrored`'s own comment.
    @AppStorage("settings.leftHandedControls") private var leftHandedControls = false
    /// This frame's hinge reading, from `HingeReader` — `DuoLayout.swift`'s
    /// own mirror of `ToolbarVerticalEdgeReader`, mounted the same way,
    /// just below it. `nil` until the first `onHingeChange` delivery
    /// (which has no `initial:` — see `HingeReader`'s own comment) or on
    /// a device/OS with no hinge at all.
    @State private var hingeStatus: DuoHingeStatus?
    /// `DeviceHinge.angle.degrees` alongside `hingeStatus`, read by
    /// `logRotationPose`'s DEBUG probe only.
    @State private var hingeDegrees: Double?
    /// Owner re-adapt (pose pass, book pose, second round): the book
    /// pose's (4/4W) right-page grid's own real bottom edge, in
    /// window space — replaces `DuoRightPageMetrics.shared`, an async
    /// singleton `DuoRightPage.reload()` used to publish by hand after
    /// its own PhotoKit query finished. That publish could lag or race
    /// a page change (a new `DuoRightPage` mounts, a stale one's
    /// `.onDisappear` clears the value, or the query simply has not
    /// finished yet), which left `FeedPageContent.duoBookCaption`
    /// reading a stale or `nil` value and falling back to its own old
    /// screen-bottom anchor — the owner's own "sits at the bottom, not
    /// under the grid" report.
    ///
    /// This value instead comes from `DuoRightGridBottomKey`, a
    /// `PreferenceKey` `DuoRightPage`'s own grid reports from a
    /// `GeometryReader` background — SwiftUI's own layout pass, not an
    /// async callback, so there is nothing for it to race: whatever
    /// the grid is ACTUALLY showing right now is what this reads,
    /// every frame, including instantly on the first one. Caught once
    /// here, on the ZStack both `DuoRightPage` and the pager (which
    /// mounts `FeedPageContent`) are siblings inside, then threaded
    /// down to each `FeedPageContent` the same way `safeAreaBottom`
    /// already is.
    @State private var duoRightGridBottomY: CGFloat?
    /// Pose 6 (laptop), round 4: the active page's own caption date
    /// line (`FeedPageContent.duoLaptopCaption`) — owner re-adapt:
    /// "put the filters in the top right of the bottom section,
    /// across and aligned from the date and time," so the Mute/
    /// Filter/Bin group (`laptopDeckControls`) needs this line's real
    /// vertical centre, not the caption block's as a whole.
    ///
    /// Owner re-adapt (round-4 review, BLOCKER): measured in a named
    /// `"duoPage"` coordinate space, not `.global` — the per-page
    /// `ZStack` the pager mounts (`FeedView.body`'s own
    /// `ScrollView`/`LazyVStack`/`ForEach`) declares that space, so a
    /// position read against it is relative to THAT page's own
    /// content, not the screen. `.global` read the date line's real,
    /// live screen position, which moves throughout any interactive
    /// drag on the vertical pager — not only a committed page change —
    /// so this value (and the group reading it) used to chase every
    /// swipe/pull instead of staying put until a new page actually
    /// settled active. A page's own content never moves relative to
    /// its own `"duoPage"` origin mid-drag, only the page itself moves
    /// on screen, so the named-space reading stays fixed through the
    /// whole gesture and only changes when `isActive` genuinely picks
    /// a different page — which, for a page sized to fill the window
    /// the way every pager slide here is, reads as the same number
    /// `.global` would have given once that page was fully settled at
    /// the top. The same `GeometryReader`/`PreferenceKey` technique
    /// `duoRightGridBottomY` just above already uses — see that
    /// property's own comment — caught at the same ZStack, reported
    /// only by the page `FeedPageContent.isActive` marks active (see
    /// `LaptopCaptionDateLineCenterKey`'s own comment), so a preloaded
    /// neighbor page can never steal it mid-swipe. `nil` outside pose
    /// 6, or before the active page's own caption has laid out even
    /// once this launch; `laptopDeckControls` now hides the group with
    /// `.opacity(0)` for that one frame instead of guessing a Y.
    @State private var laptopCaptionDateLineCenterY: CGFloat?
    /// Pose 6 (laptop), round 4: the Mute/Filter/Bin group's
    /// (`laptopDeckControls`) own real, just-laid-out frame, in
    /// window space — `FeedPageContent.duoLaptopCaption` keeps its
    /// own caption text clear of it, the same live-measurement
    /// reasoning as `laptopCaptionDateLineCenterY` just above, mounted
    /// once (never per-page), so there is no reduce ambiguity to guard
    /// against here. `nil` outside pose 6, or before the group has
    /// ever laid out this launch; `duoLaptopCaption` falls back to its
    /// own old near-full-width clearance for that one frame.
    ///
    /// Mirrored-layout round: renamed from `laptopControlGroupLeadingX`
    /// (a plain `CGFloat?`) to the whole frame — `duoLaptopCaption`
    /// reads `.minX` unmirrored, `.maxX` mirrored; see
    /// `LaptopControlGroupFrameKey`'s own comment.
    @State private var laptopControlGroupFrame: CGRect?
    /// Pose 3/4/4W's own Bin capsule (`chromeColumnBinCapsule`) — its
    /// real, just-laid-out height, in window space. Empty (`Rail.hit`,
    /// the same plain-circle height Mute/Filter use) until the bin has
    /// items and the capsule grows downward for the count/size lines;
    /// `chromeColumn` reads this to shift the WHOLE group (Mute,
    /// Filter, Bin) up by half the growth, keeping Filter on the
    /// rail's own vertical centre only while the bin is empty and
    /// clear of the rail labels/video edge once it is not. One global
    /// `GeometryReader` (`chromeColumn` mounts once, not per page), so
    /// no `reduce`-ambiguity guard is needed here either — same
    /// reasoning as `laptopControlGroupLeadingX` just above.
    @State private var chromeBinCapsuleHeight: CGFloat = Rail.hit
    /// Both read by `DuoLayout.classify` (Decision B,
    /// `design/duo/duo_audit_apple_checklist.md` §4): neither axis alone
    /// identifies a display — a 17 Pro resized large enough in iPhone
    /// Mirroring also reads `.regular` width, which is exactly the audit's
    /// F2 finding — so the classifier requires BOTH `horizontalSizeClass`
    /// and `verticalSizeClass` to read `.regular` before calling a frame
    /// fully open. Plain `@Environment` reads, no `#available` gate — size
    /// classes predate iOS 27.1.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The signal from whichever page's `PlayerPageView` currently reports
    /// `isFullscreen == true`, through `onFullscreenChanged`. This mirrors
    /// `isScrubbing`. Only the centered page can ever be fullscreen, so at
    /// most one page's callback ever reports `true`.
    @State private var isFullscreen = false
    /// The signal from whichever page's `PlayerPageView` currently reports
    /// `allowsLandscapeCandidate == true`, through `onAllowsLandscapeChanged`
    /// — the page half of `allowsLandscape` below. Same shape as
    /// `isFullscreen`; only the centered page can ever report `true`.
    @State private var pageAllowsLandscape = false

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
    /// Every `.duoGuideMark` reporting view's own frame this frame —
    /// see `DuoGuideMarksKey`'s own comment. Caught by the
    /// `.onPreferenceChange` next to `duoRightGridBottomY`'s own,
    /// rendered by `duoGuidesOverlay`.
    @State private var duoGuideMarks: [DuoGuideMark] = []
    /// Owner (pose pass): the legend's own dark backing covered real
    /// content (pose 3's caption, then pose 5's own Mute/Filter —
    /// `pose5TopRow` sits top-LEADING there, the same corner every
    /// other pose left clear). No fixed corner is free in every pose,
    /// so the legend now starts collapsed to a small toggle instead
    /// of guessing a new corner that the NEXT pose fix could collide
    /// with too. See `duoGuideLegend`'s own comment.
    @State private var duoGuideLegendExpanded = false
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

    /// True while fullscreen mode (a regular iPhone or a closed Duo
    /// really rotated into landscape, R4) hides the GLOBAL chrome — the
    /// top mute/filter/bin row (`overlayControls`) and the chin
    /// (`ChinNavigation`).
    ///
    /// Build 1 fix, step 2: this used to also hide for `isLandscapeFit`
    /// (a real-rotation horizontal video, open Duo only — the old
    /// round's step 6). The round-3 wireframes (`DUO_POSES.md`) call
    /// for pose 3's chrome to stay up instead: rail, chin, chrome,
    /// caption, and status all visible over a wide video's own FIT
    /// layout. `isLandscapeFit` itself is gone — see
    /// `PlayerPageView.useVideoAspect`, its pose-gated replacement for
    /// the stage/aspect-ratio math alone, with no chrome-hiding role of
    /// its own left to inherit.
    private var hidesGlobalChrome: Bool { isFullscreen }

    /// Decision A's own `allowsLandscape` rule
    /// (`design/duo/duo_audit_apple_checklist.md` §3, R4): "(active page
    /// is a wide video && fullscreenAllowed && !dismissed) || hinge ==
    /// .partiallyOpen". `pageAllowsLandscape` is the first clause,
    /// reported up by whichever page is centered (`PlayerPageView
    /// .allowsLandscapeCandidate`, through `onAllowsLandscapeChanged`).
    /// The hinge clause is independent of any page's own content — a
    /// partially-open hinge permits the OUTER display to rotate into the
    /// tent (pose 2) even while a portrait video sits on screen, which
    /// is what lets the 1H → 2 flow (closed, sideways → tent) begin
    /// without first dismissing or changing videos.
    ///
    /// The one write site is the `.onChange(of: allowsLandscape, initial:
    /// true)` in `body`, which hands this value to `RotationPolicy
    /// .shared` — the single switch `CloudfullSceneDelegate
    /// .supportedInterfaceOrientations(for:)` actually reads.
    private var allowsLandscape: Bool {
        pageAllowsLandscape || hingeStatus == .partial
    }

    /// `DuoLayout.current`, behind the `#available` check its own
    /// declaration requires. Returns `DuoLayout.none` on anything below
    /// iOS 27.1, so every caller downstream — today, `PlayerPageView` —
    /// reads the same "no Duo furniture" value a regular iPhone always
    /// had, with no availability check of its own to write.
    private func resolvedDuoLayout(rootProxy: GeometryProxy) -> DuoLayout {
        if #available(iOS 27.1, *) {
            return DuoLayout.current(
                proxy: rootProxy,
                toolbarVerticalEdge: toolbarVerticalEdge,
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                hinge: hingeStatus,
                hingeDegrees: hingeDegrees,
                leftHandedControls: leftHandedControls
            )
        }
        return .regularPhone(leftHandedControls: leftHandedControls)
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
            // Step 9 (`design/duo/duo_audit_apple_checklist.md` §5): the
            // 1H fullscreen ring's own bottom-leading inset, expressed
            // as the real safe-area insets instead of a flat constant —
            // same reasoning as `safeAreaTop` just above (this reader
            // sits above the pager's own `.ignoresSafeArea()`, the one
            // place these numbers are not already zeroed by it).
            // Fullscreen is a real landscape window now (R4): SwiftUI
            // reports `.bottom`/`.leading` relative to THIS view's own
            // current frame, so these already read as the home
            // indicator's and the camera cutout's real clearance in
            // that orientation, not a device-specific guess.
            let fullscreenSafeArea = rootProxy.safeAreaInsets
            // Round 2 (Opus diagnosis, owner-reported pose 5/6/book
            // misreads): `rootProxy` does not ignore the safe area, so
            // `rootProxy.size` is the SAFE-AREA CONTENT rect, not the
            // window — the same "reconstruct the real window" step
            // `overlayControls`'s own nested `GeometryReader` already
            // takes for `fullWindow`. `DuoLayout.current` below now
            // normalises `occlusion`/`division` into this same TRUE
            // window space (see that function's own comment), so any
            // caller that still hands it `rootProxy.size` instead of
            // this reconstructed size is comparing window-space
            // regions against a safe-area-shrunk box — the root cause
            // behind the book pose misreading as a tent (the vertical
            // division's own height exceeded a landscape window's
            // shorter safe-area height) and pose 5's own top row/rail
            // anchors landing off-screen. Every call below that reads
            // `duoLayout`'s own `occlusion`/`division`-derived geometry
            // must use `windowSize`, never `rootProxy.size` — except
            // `ChinNavigation`'s own `railBottom:` argument, deliberately
            // left reading `rootProxy.size` below: that one also feeds
            // `StageGeometry.bottomBand`'s fallback path for every
            // regular-iPhone chin position, and changing its own
            // containerSize would move the chin on a regular iPhone,
            // which must stay byte-for-byte.
            let windowSize = CGSize(
                width: rootProxy.size.width + fullscreenSafeArea.leading + fullscreenSafeArea.trailing,
                height: rootProxy.size.height + fullscreenSafeArea.top + fullscreenSafeArea.bottom
            )
            // Classified synchronously from this same proxy, every pass —
            // no debounce. Audit finding F3's own fix
            // (`design/duo/duo_audit_apple_checklist.md`): an earlier
            // version withheld a changed `pose` for 250 ms to hide a
            // transient misclassification from a stale cross-display
            // `.division` frame — a frame `DuoLayout.current`'s own
            // `windowBounds.contains(frame)` containment filter (see that
            // function's own comment) already removes at the source, so
            // the debounce delayed every REAL transition (a fold, an
            // unfold, a Mirroring resize) for no remaining benefit.
            // `.animation(.default, value: duoLayout.pose)` below, not a
            // debounce, is what smooths a real transition's layout jump.
            let duoLayout = resolvedDuoLayout(rootProxy: rootProxy)
            ZStack {
            // Zero-size; only ever updates `toolbarVerticalEdge` above.
            // See that property's own comment for why the read is
            // confined to this helper rather than a plain `@Environment`
            // property on `FeedView` itself.
            if #available(iOS 27.1, *) {
                ToolbarVerticalEdgeReader { toolbarVerticalEdge = $0 }
                // Zero-size; only ever updates `hingeStatus`/`hingeDegrees`
                // above. Mounted right next to `ToolbarVerticalEdgeReader`
                // — see `HingeReader`'s own comment for why its first
                // delivery, unlike that reader's, may arrive after this
                // frame.
                HingeReader { status, degrees in
                    hingeStatus = status
                    hingeDegrees = degrees
                }
            }
            content(safeAreaTop: safeAreaTop, fullscreenSafeArea: fullscreenSafeArea, duoLayout: duoLayout, containerSize: windowSize)
            // The whole global chrome layer (mute, the shrink progress
            // capsule, the counters, the bin) hides while `isFullscreen`
            // (the rotation hack) is on — see `hidesGlobalChrome`'s own
            // comment. Each page's own `bottomScrim` and `FeedPageContent`
            // in `pager` hide on plain `isFullscreen` too.
            overlayControls(duoLayout: duoLayout)
                .opacity(hidesGlobalChrome ? 0 : 1)
                .allowsHitTesting(!hidesGlobalChrome)
                .accessibilityHidden(hidesGlobalChrome)
            // Mounted once here, in the global overlay, never inside
            // `FeedPageContent`. `FeedPageContent` is instantiated once
            // per mounted page and would produce up to three
            // `chin_nav_button` elements.
            //
            // `railBottom` is 0 (its default) on every other host
            // (`SettingsView`, `PhotoFeedView`), which keeps the chin's
            // plain fixed anchor there with no dependence on this
            // view's own geometry at all. Only here, in Videos mode,
            // is there a real rail for the chin to ever need to clear.
            ChinNavigation(bottomBand: StageGeometry.bottomBand(safeAreaTop: safeAreaTop,
                                                               containerSize: rootProxy.size),
                           railBottom: duoLayout.railBottom(safeAreaTop: safeAreaTop, safeAreaBottom: fullscreenSafeArea.bottom, containerSize: rootProxy.size),
                           railAlignedCenter: duoLayout.railAlignedChinCenter(safeAreaTop: safeAreaTop, safeAreaBottom: fullscreenSafeArea.bottom, containerSize: windowSize),
                           railAlignedTopClamp: duoLayout.railAlignedTopClamp(containerSize: windowSize, safeAreaBottom: fullscreenSafeArea.bottom),
                           safeAreaBottom: fullscreenSafeArea.bottom,
                           isMirrored: duoLayout.isMirrored)
                .opacity(hidesGlobalChrome ? 0 : 1)
                .allowsHitTesting(!hidesGlobalChrome)
                .accessibilityHidden(hidesGlobalChrome)
                // "chin" is marked INSIDE `ChinNavigation`, on the
                // small `switcher(...)` view itself, not here — this
                // call site's own frame is the whole window (its
                // `GeometryReader`/`ZStack(alignment: .bottomTrailing)`
                // own body), not the visible button. Owner re-adapt
                // (pose pass): the first round marked this coarser
                // outer frame; tightened once the owner pointed out
                // the box was far bigger than the circle on screen.
            // Step 12: the book pose's (4/4W) right page — mounted once
            // here, never inside `FeedPageContent`, for the same reason
            // `ChinNavigation` is — see `DuoRightPage`'s own header
            // comment. `currentAssetID` comes from the pager's own
            // cursor (`currentPageID`), not `viewModel.currentIndex`:
            // the two can disagree for a frame during a prune/reanchor,
            // and `currentPageID` is what the pager itself is actually
            // centred on right now.
            if duoLayout.pose == .book,
               let rightPageRect = duoLayout.rightPage(containerSize: windowSize, safeAreaTop: safeAreaTop),
               let currentAssetID = currentPageID.flatMap({ id in viewModel.deck.first(where: { $0.id == id })?.assetID }) {
                DuoRightPage(
                    currentAssetID: currentAssetID,
                    rect: rightPageRect,
                    viewModel: viewModel,
                    trashService: trashService,
                    onPlay: playNextFromRightPage
                )
                // Round 2: `rightPageRect` is now in TRUE window space
                // (`windowSize`, above). Without `.ignoresSafeArea()`
                // here, this view's own `.position()` would still be
                // read inside `rootProxy`'s own safe-area-shrunk local
                // space — the same mismatch bug, just on this one
                // mount — the same fix `ChinNavigation`'s own body
                // already applies to itself, and the pager applies to
                // the whole `ScrollView`.
                .ignoresSafeArea()
                .opacity(hidesGlobalChrome ? 0 : 1)
                .allowsHitTesting(!hidesGlobalChrome)
                .accessibilityHidden(hidesGlobalChrome)
            }
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
            //
            // Drawn last, above every other child in this ZStack
            // (including `overlayControls`/`ChinNavigation`), so the
            // guides are never hidden behind real chrome — see
            // `duoGuidesOverlay`'s own comment.
            if Self.showsDuoGuides {
                // Owner (round-4 pass): every mark drew ~82pt (laptop)
                // or ~59pt (pose 5) too low — exactly `safeAreaTop` for
                // each pose. This whole overlay positions in TRUE
                // window space (`windowSize`, every DuoLayout rect, and
                // every `.duoGuideMark`'s own `.global` reading), but
                // without `.ignoresSafeArea()` here, its own
                // `.position()` calls were read inside `rootProxy`'s
                // safe-area-SHRUNK local space instead — `(0,0)` there
                // sits `safeAreaTop` below true window `(0,0)`. The
                // exact mismatch `DuoRightPage`'s own mount comment
                // already documents, and `ChinNavigation`'s own body
                // and the pager's own `ScrollView` already both apply
                // this same fix to themselves — this mount was simply
                // missing it.
                duoGuidesOverlay(duoLayout: duoLayout, safeAreaTop: safeAreaTop, safeAreaInsets: fullscreenSafeArea, containerSize: windowSize)
                    .ignoresSafeArea()
            }
            #endif
            }
            .frame(width: rootProxy.size.width, height: rootProxy.size.height)
            // Smooths a real pose transition (a fold, an unfold, a
            // Mirroring resize) instead of the removed 250 ms debounce —
            // see `duoLayout`'s own comment above. A regular iPhone's
            // `pose` never changes (always `.regularPhone`), so this is a
            // no-op there: zero risk to the "byte-for-byte" promise.
            .animation(.default, value: duoLayout.pose)
            // See `duoRightGridBottomY`'s own comment. This ZStack is
            // the nearest ancestor both `DuoRightPage` and the pager
            // (which mounts `FeedPageContent`) sit inside as siblings,
            // so it is where `DuoRightGridBottomKey`'s bubbled-up value
            // is caught, once, and handed down from here.
            .onPreferenceChange(DuoRightGridBottomKey.self) { duoRightGridBottomY = $0 }
            // Same catch point, same reasoning, for pose 6's own pair
            // of live measurements — see `laptopCaptionDateLineCenterY`/
            // `laptopControlGroupFrame`'s own comments.
            .onPreferenceChange(LaptopCaptionDateLineCenterKey.self) { laptopCaptionDateLineCenterY = $0 }
            .onPreferenceChange(LaptopControlGroupFrameKey.self) { laptopControlGroupFrame = $0 }
            // Same catch point, same reasoning, for pose 3/4/4W's own
            // Bin capsule height — see `chromeBinCapsuleHeight`'s own
            // comment.
            .onPreferenceChange(ChromeBinCapsuleHeightKey.self) { chromeBinCapsuleHeight = $0 }
            #if DEBUG
            // Same catch point, same reasoning, for every
            // `.duoGuideMark` reporting view — see `DuoGuideMarksKey`'s
            // own comment.
            .onPreferenceChange(DuoGuideMarksKey.self) { duoGuideMarks = $0 }
            #endif
        }
        // Hides the status bar and home indicator while `hidesGlobalChrome`
        // (`isFullscreen`) is on, the same chrome-hide condition
        // `overlayControls`/`ChinNavigation` already use. This is safe
        // for the stage geometry. The pager and `overlayControls` both
        // already `.ignoresSafeArea()`, so `proxy.size` — the only
        // input to the stage math — does not move when the inset does.
        .statusBarHidden(hidesGlobalChrome)
        .persistentSystemOverlays(hidesGlobalChrome ? .hidden : .automatic)
        // R4: the one write site for `RotationPolicy.shared` — see
        // `allowsLandscape`'s own comment. `initial: true` syncs the
        // scene's mask the moment this view first appears, not only on
        // the next change; a same-value write is already a no-op inside
        // `RotationPolicy` itself. `RotationPolicy` needs no `#available`
        // gate of its own — every API it calls (`UIWindowScene`,
        // `setNeedsUpdateOfSupportedInterfaceOrientations`) predates this
        // app's iOS 26.0 deployment target; only the SCENE DELEGATE
        // method that reads `allowsLandscape` back out
        // (`supportedInterfaceOrientations(for:)`) is iOS 27-gated, by
        // the OS itself simply never calling it on an older one.
        .onChange(of: allowsLandscape, initial: true) { _, newValue in
            RotationPolicy.shared.update(allowsLandscape: newValue)
        }
        .task {
            viewModel.start()
            trashService.start()
            // Warms the album list from whichever feed the app opens on,
            // so Add to Album usually has its answer ready before it is
            // ever tapped. A no-op once loaded; the fetch itself runs off
            // the main actor.
            AlbumListCache.shared.prewarm()
            currentPageID = viewModel.currentEntryID
            #if DEBUG
            // A no-op unless `-cloudfull-reset-stalls` was passed at
            // launch. When it was, the watchdog zeroes its counters and
            // re-arms its settle window now that the feed is actually on
            // screen.
            MainThreadWatchdog.shared.feedDidAppear()
            #endif
        }
        // The cursor write happens off the page-change tick, so the app
        // leaving the foreground is what makes it durable.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            viewModel.flushPendingWrites()
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
            // R4 fix: the other half of the race guard in
            // `onAllowsLandscapeChanged` below — see that closure's own
            // comment. A page change always starts from "no landscape
            // grant," the same way `PlayerPageView.dismissedThisSpell`
            // resets on its own page-change edge; the new centered
            // page's own report (once its video's shape is known) sets
            // this back to `true` if it actually qualifies.
            pageAllowsLandscape = false
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
        // Owner bug (closed pose ignores all touches): logs every
        // touch's own location, under `-cloudfull-log-touches`, at
        // the ROOT of this view — the outermost `GeometryReader` the
        // whole of `body` sits inside — so a live capture can show
        // whether a touch reaches this app's own view hierarchy AT
        // ALL in the closed pose, ruling out a Device Hub/simulator
        // input issue before chasing an app-side hit-testing
        // regression. `simultaneousGesture` neither consumes the
        // touch nor changes hit-testing on its own; it only reports
        // whatever already reaches this view. Read with the same
        // `xcrun simctl spawn <UDID> log stream --predicate
        // 'subsystem == "com.cloudfull.app" and category == "Touch"'`
        // pattern every other `-cloudfull-log-` flag already uses.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard DiagnosticsGate.isOn("-cloudfull-log-touches") else { return }
                    let message = "touch_\(Int(value.location.x)),\(Int(value.location.y))"
                    Self.touchLog.notice("\(message, privacy: .public)")
                    DiagnosticsLog.shared.log("Touch", message)
                }
        )
        #endif
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
    private func content(safeAreaTop: CGFloat, fullscreenSafeArea: EdgeInsets, duoLayout: DuoLayout, containerSize: CGSize) -> some View {
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
            pager(safeAreaTop: safeAreaTop, fullscreenSafeArea: fullscreenSafeArea, duoLayout: duoLayout, containerSize: containerSize)
        }
    }

    /// `safeAreaTop` is the real inset, measured once in `body`. It is
    /// threaded into every `PlayerPageView` because their own readers sit
    /// under this pager's `.ignoresSafeArea()` and would otherwise read 0.
    /// `fullscreenSafeArea`/`duoLayout` are threaded the same way, for
    /// the same reason: this pager's own `.ignoresSafeArea()` would
    /// otherwise hide the bar column's safe-area inset, or the 1H ring's
    /// own fullscreen insets, from a reader placed any lower.
    private func pager(safeAreaTop: CGFloat, fullscreenSafeArea: EdgeInsets, duoLayout: DuoLayout, containerSize: CGSize) -> some View {
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
                            fullscreenAllowed: fullscreenAllowed,
                            onFullscreenChanged: { isFullscreen = $0 },
                            // R4 fix: `entry.id == currentPageID` is
                            // re-checked LIVE here, not the `isActive`
                            // snapshot this closure captured at creation
                            // time — the pager may already have moved on
                            // by the time this fires. Without this
                            // guard, a page swiped past quickly (rapid
                            // swipes, or a UI test) can report `true`
                            // and leave `pageAllowsLandscape` stuck
                            // granting landscape for a page that never
                            // asked for it; confirmed on the 17 Pro sim
                            // (a portrait video's window genuinely
                            // rotated to landscape after scrolling past
                            // a wide one). `.onChange(of: currentPageID)`
                            // above is this guard's other half: it resets
                            // the flag on every page change, since a
                            // dropped stale report here must not leave a
                            // stale `true` standing either.
                            onAllowsLandscapeChanged: { newValue in
                                guard entry.id == currentPageID else { return }
                                pageAllowsLandscape = newValue
                            },
                            safeAreaTop: safeAreaTop,
                            fullscreenSafeArea: fullscreenSafeArea,
                            duoLayout: duoLayout,
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
                        // `FeedPageContent` below — both on plain
                        // `isFullscreen`, never `hidesGlobalChrome`.
                        // `overlayControls` and the chin are the ones
                        // that hide for that state; see
                        // `hidesGlobalChrome`'s own comment. Only the
                        // centered page can ever be fullscreen. So
                        // gating every page's own scrim and content on
                        // this one `FeedView`-level flag works the same
                        // as gating just the active page. Every other
                        // page is off screen once
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
                            onRequestShrink: requestShrink,
                            onAdvanceRequested: { advanceToNextPage(from: entry) },
                            onOpenBinRequested: { Usage.shared.binOpened(); showTrash = true },
                            safeAreaTop: safeAreaTop,
                            safeAreaBottom: fullscreenSafeArea.bottom,
                            duoLayout: duoLayout,
                            duoRightGridBottomY: duoRightGridBottomY,
                            laptopControlGroupFrame: laptopControlGroupFrame,
                            keepRequestNonce: doubleTapKeepNonces[entry.id] ?? 0
                        )
                        .opacity(isFullscreen ? 0 : 1)
                        .allowsHitTesting(!isFullscreen)
                        .accessibilityHidden(isFullscreen)
                    }
                    // Named, not `.global` — see
                    // `laptopCaptionDateLineCenterY`'s own comment for
                    // why a per-page space is what keeps that
                    // measurement from chasing a live scroll/pull on
                    // this pager.
                    .coordinateSpace(.named("duoPage"))
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
        // R4: `anchor: .top` (`design/duo/duo_audit_apple_checklist.md`
        // §3's own risk note — "the pager must keep its page through the
        // size change"). Each page fills the viewport exactly
        // (`.containerRelativeFrame([.horizontal, .vertical])`), so
        // pinning the current page's own top-leading edge to the
        // viewport's own top-leading edge is what keeps it the page on
        // screen, not some fraction of it, through the window's own
        // resize during a real rotation — the same anchor the
        // `reanchorNonce`/`advanceNonce` paths below already pass to
        // `scrollProxy.scrollTo`, so every programmatic and
        // gesture-driven re-anchor in this pager now agrees.
        .scrollPosition(id: $currentPageID, anchor: .top)
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
        //
        // `hidesGlobalChrome` reduces to plain `isFullscreen` now (step
        // 2 build 1 fix removed its other term), so this is the same
        // condition spelled out directly rather than through that name
        // — the pager's own disable has nothing to do with chrome.
        .scrollDisabled(isScrubbing || isFullscreen)
        .ignoresSafeArea()
        .background(pagerBackground(duoLayout: duoLayout, safeAreaTop: safeAreaTop, containerSize: containerSize))
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
                .accentButtonLabel()
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
    private func overlayControls(duoLayout: DuoLayout) -> some View {
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
            let realBottomInset = proxy.safeAreaInsets.bottom
            let fullWindow = CGSize(
                width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            )
            // Build 3: pose 3/4/4W (`DuoLayout.classify` → `.openWide`/
            // `.book`) move Mute, Filter, and Bin off this row entirely,
            // into their own column beside the rail/bar column — see
            // `chromeColumn`'s own comment. `topChrome` itself still
            // renders, for the shrink-progress capsule alone; see that
            // function's own comment on why.
            let usesChromeColumn = duoLayout.pose == .openWide || duoLayout.pose == .book
            // Build 6: pose 5 (`.openTall`) moves the same three
            // controls into one row, y-centred on `DuoLayout
            // .statusBlock` — see `pose5TopRow`'s own comment.
            //
            // Owner re-adapt (pose pass, 1V): "Mute/Filter/Bin at the
            // very top ... like pose 5's top row now does" — pose 1V
            // (`.closed`) reuses this exact mechanism now too, rather
            // than a parallel one. The name stays `pose5TopRow`
            // (avoiding a sprawling rename across this file); see that
            // function's own comment for why its row-building logic
            // already generalizes to both poses untouched.
            let usesPose5TopRow = duoLayout.pose == .openTall || duoLayout.pose == .closed
            // Build 8b: pose 6 (laptop) mounts its own shared bottom
            // deck here — the Mute/Filter/Bin group and
            // Previous/Next are the two pieces of §2.6 genuinely
            // global to the screen, not to any one page; see
            // `laptopDeckControls`'s own comment and this group's
            // header comment in `DuoLayout`.
            let usesLaptopDeck = duoLayout.pose == .laptop
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    topChrome(duoLayout: duoLayout, safeAreaTop: realTopInset, containerSize: fullWindow)
                    if let shrinkToastMessage {
                        shrinkToast(shrinkToastMessage)
                            .padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                }
                if usesChromeColumn {
                    // No `.frame`/coordinate wrapper needed: each of
                    // this `Group`'s children carries its own
                    // `.position(_:)`, which already places it directly
                    // within this `ZStack`'s own space — the same
                    // "0 at the true window top" space `topChrome`'s
                    // `containerSize: fullWindow` argument already
                    // assumes, via this view's own `.padding(.top:)`/
                    // `.frame` pair below.
                    chromeColumn(duoLayout: duoLayout, safeAreaTop: realTopInset, safeAreaBottom: realBottomInset, containerSize: fullWindow)
                }
                if usesPose5TopRow {
                    pose5TopRow(duoLayout: duoLayout, safeAreaTop: realTopInset, containerSize: fullWindow)
                }
                if usesLaptopDeck {
                    laptopDeckControls(duoLayout: duoLayout, safeAreaBottom: realBottomInset, containerSize: fullWindow)
                }
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

    /// Build 3: suppresses Mute, Filter, the counter, and Bin at pose
    /// 3/4/4W — `chromeColumn` renders those instead, positioned at
    /// `DuoLayout.zigzagCenters` rather than flowing left to right.
    /// Build 6 adds pose 5 to the same suppression — `pose5TopRow`
    /// renders those instead, y-centred on `DuoLayout.statusBlock`.
    /// This function still renders for one thing even so: the
    /// shrink-progress capsule, which the round-3 wireframes
    /// (`DUO_POSES.md`) do not mention at all (a rare, transient
    /// state, not a fixture of any one pose). Letting it keep this
    /// row, rather than inventing a position the wireframes never
    /// specified, is the smaller assumption. Its row no longer
    /// reserves the chrome column's own width — see `duoLayout
    /// .availableRect`'s comment — so this is a known, accepted
    /// imperfection if a shrink is active while the chrome column or
    /// pose-5 row also shows; flagged for the owner's own look at the
    /// sim.
    private func topChrome(duoLayout: DuoLayout, safeAreaTop: CGFloat, containerSize: CGSize) -> some View {
        // Build 8b: pose 6 (laptop) adds to this suppression too. Mute,
        // Filter, and Bin move into the bottom deck's own group
        // (`laptopDeckControls`); nothing interactive belongs above the
        // fold — the build-list's own check for this step, "Duo 6:
        // nothing interactive above the fold." Pose 1V (`.closed`)
        // joins them in the owner's own pose-pass re-adapt — see
        // `usesPose5TopRow`'s own comment just above.
        let suppressDefaultRow = duoLayout.pose == .openWide || duoLayout.pose == .book
            || duoLayout.pose == .openTall || duoLayout.pose == .laptop || duoLayout.pose == .closed
        // Four independent glass pills. Do not wrap these in a
        // `GlassEffectContainer`. XCUITest then resolves the far-right
        // `bin_open` button's frame relative to the container. Its
        // synthesized tap lands at the top-left of the screen, on the
        // video, which toggles mute instead of opening the bin. The
        // left-edge filter button coincides with the container's
        // origin, so it keeps working and hides the problem. A finger
        // tap is always fine; only the synthesized XCUITest tap
        // coordinates are wrong.
        // Mirrored-layout round (item D, regular iPhone): the row's own
        // child order reverses, same idea as `pose5TopRow`'s own
        // mirror — "top row mirrored, Bin top-left." The shrink
        // progress capsule (not suppressed on any pose) stays the
        // child next to the `Spacer`, on whichever side that now is.
        //
        // Review fix: Bin must be the OUTERMOST control in the
        // mirrored row, not the counter — the owner's own rule, "Bin
        // outermost, same as the mirrored top row," confirmed against
        // `pose5TopRow`'s own mirrored branch just below in this file
        // (`binButton()` first, then `counterCapsule`). This row used
        // to read counter-then-Bin, the one pair out of step with that
        // rule.
        return HStack(alignment: .top, spacing: 8) {
            if duoLayout.isMirrored {
                if !suppressDefaultRow {
                    binButton()
                    counterCapsule
                }
                Spacer(minLength: 8)
                if let job = activeShrinkJob, let text = shrinkActiveProgressText {
                    shrinkProgressCapsule(text, assetID: job.id)
                }
                if !suppressDefaultRow {
                    FilterMenuView(store: optionsStore, hidesChrome: hidesGlobalChrome)
                        .duoGuideMark("top.filter", color: .teal)
                    muteButton
                }
            } else {
                // A tap on the video also toggles mute, with a center
                // flash. This pill is the second mute control.
                if !suppressDefaultRow {
                    muteButton
                    FilterMenuView(store: optionsStore, hidesChrome: hidesGlobalChrome)
                        .duoGuideMark("top.filter", color: .teal)
                }
                if let job = activeShrinkJob, let text = shrinkActiveProgressText {
                    shrinkProgressCapsule(text, assetID: job.id)
                }
                Spacer(minLength: 8)
                if !suppressDefaultRow {
                    counterCapsule
                    binButton()
                }
            }
        }
        .padding(.horizontal, 12)
        // Clamped to the stage's own available width — clear of the
        // rail column, whichever case put one there (steps 3/5) —
        // instead of the full window. On a regular iPhone, or an open
        // Duo too narrow for a column, `availableRect` returns the
        // full window unchanged, so `binButton`'s trailing edge lands
        // exactly where it always has.
        // Mirrored-layout round: `availableRect` already excludes the
        // column from whichever edge it is on — this outer alignment
        // must match that same edge (PhotoTopBar's identical call site
        // has the same fix), or the row would still start at x=0 even
        // with its own children already reversed above, landing on
        // top of a mirrored column instead of clear of it.
        .frame(width: duoLayout.availableRect(containerSize: containerSize, safeAreaTop: safeAreaTop).width,
               alignment: duoLayout.isMirrored ? .trailing : .leading)
        .padding(.top, topChromeTopPadding(safeAreaTop: safeAreaTop, containerSize: containerSize))
        // Keeps `muteButton` (the row's own leading edge) clear of the
        // display's own rounded top corner — reported on the open-wide
        // (landscape, bar-on) pose, where this row starts flush at the
        // window's leading edge and the corner there is big enough to
        // actually clip it. `containerCornerOffset`, not a hand-tuned
        // margin: it is iOS 26's own API for exactly this (confirmed
        // in the SwiftUICore swiftinterface — `GeometryProxy.
        // containerCornerInsets`/`View.containerCornerOffset(_:sizeToFit:)`,
        // both `@available(iOS 26.0, …)`, no gate needed against this
        // app's own deployment target). A no-op on a regular iPhone
        // and on the Duo's other poses, where the existing padding and
        // safe area already clear the corner on their own; this only
        // nudges the row further in when they do not.
        .containerCornerOffset(.top)
    }

    // MARK: - Chrome column (build 3)

    /// Pose 3/4/4W's replacement for `topChrome`'s own Mute, Filter,
    /// and Bin: the same three controls, unchanged, each centred on
    /// one of `DuoLayout.zigzagCenters`'s three points instead of
    /// flowing left to right — "each button is level with a gap
    /// between two rail buttons" (`DUO_POSES.md`).
    ///
    /// Owner re-adapt: this used to ALSO repeat the count as its own
    /// line under Bin, "counter one line 4pt under Bin" — a real
    /// doubled-badge bug, "it shows the count and space twice." Shown
    /// once, below, not twice.
    ///
    /// Owner re-adapt (round-4 review, BLOCKER): `binButton`'s own
    /// inline badge — the fix for that first doubled-badge report —
    /// widens its capsule for "count · size," and `.position()` here
    /// centres that WIDER capsule on a fixed point with no `HStack`
    /// flow to push a neighbour out of the way the way `topChrome`/
    /// `pose5TopRow`/`laptopDeckControls` all have; its own right half
    /// ran over the rail's Shrink icon. An interim fix (`104c599`)
    /// kept Bin a plain circle here and drew the count/size as a
    /// separate, clamped label underneath it.
    ///
    /// Owner re-adapt (round-5 wireframe, "Bin open" row): replaces
    /// that interim fix with the approved design —
    /// `chromeColumnBinCapsule` grows DOWNWARD into a tall capsule
    /// instead (icon, count, size, stacked), so it never needs to run
    /// sideways into the rail at all. Because only Bin grows, Mute and
    /// Filter both shift UP by half of whatever `chromeBinCapsuleHeight`
    /// grows past `Rail.hit` (`extraShift` below) — Bin's own
    /// `.position()` stays on `centers[2]` UNCHANGED: positioning a
    /// view at its own centre means a capsule that grows by
    /// `extraHeight` total already extends `extraHeight / 2` below
    /// that unmoved point on its own, with no separate offset needed
    /// here. The net result reads as "the whole group shifts up by
    /// half the extra height, and Bin alone also grows down from
    /// there" — group ↔ rail labels/video-edge clearance, Bin ↔ the
    /// chin below it — without the two fighting each other.
    private func chromeColumn(duoLayout: DuoLayout, safeAreaTop: CGFloat, safeAreaBottom: CGFloat, containerSize: CGSize) -> some View {
        let centers = duoLayout.zigzagCenters(containerSize: containerSize, safeAreaTop: safeAreaTop, safeAreaBottom: safeAreaBottom)
        let extraShift = max(0, chromeBinCapsuleHeight - Rail.hit) / 2
        return Group {
            if centers.count == 3 {
                muteButton
                    .position(x: centers[0].x, y: centers[0].y - extraShift)
                FilterMenuView(store: optionsStore, hidesChrome: hidesGlobalChrome)
                    .duoGuideMark("top.filter", color: .teal)
                    .position(x: centers[1].x, y: centers[1].y - extraShift)
                chromeColumnBinCapsule()
                    .position(centers[2])
            }
        }
    }

    // MARK: - Pose 5 top row (build 6)

    /// Pose 5's (open-tall) replacement for `topChrome`'s own Mute,
    /// Filter, and Bin: "one row, y-centre = `statusBlock.midY`;
    /// Mute at `stage.minX + 16` ... counter left of Bin"
    /// (`DUO_POSES.md`'s per-pose table). Counter-left-of-Bin is
    /// already this row's own child order — the same as `topChrome`'s
    /// own `counterCapsule`, `binButton` pair — so nothing extra is
    /// needed for that part.
    ///
    /// Anchored the same way `actionRailColumn`/`chromeColumn`'s own
    /// siblings are: a target rect from the leading edge to the
    /// trailing edge, `.frame(width:height:alignment:.center)` to
    /// give the row a known box, then `.position(x: rect.midX, y:
    /// statusBlock.midY)`. The row's own `Spacer(minLength: 8)`
    /// between Mute/Filter and the counter/Bin pair pushes Bin's own
    /// trailing edge out to fill `rect.width` exactly, the same way
    /// `topChrome`'s identical `Spacer` already fills its own row.
    ///
    /// Owner re-adapt (pose pass, 1V): the trailing edge used to be
    /// `statusBlock.minX − 8` — fine for pose 5, where that point
    /// still falls inside the stage/video, but for pose 1V it does
    /// not: `statusBlock` there is the small `.occlusion` camera
    /// cutout, well inside the BAR column the video excludes, so
    /// `statusBlock.minX − 8` landed past the video's own right edge
    /// — the Bin pill the owner's own screenshot caught straddling
    /// into the black bar column. Both edges now come from the stage
    /// itself — `stage.maxX − 16`, the same 16pt margin `leading`
    /// already gives Mute from `stage.minX` — so the row can never
    /// read past the video it sits on, in either pose.
    ///
    /// Owner re-adapt (pose pass, 1V, second round): `y` used to be
    /// `statusBlock.midY` for both poses — correct for pose 5, where
    /// that is genuinely the real time/connectivity ring's own
    /// vertical centre, but wrong for 1V: there `statusBlock` reads
    /// the small `.occlusion` camera cutout instead (the ring itself
    /// has no reserved-region API of its own there — see
    /// `statusBlock`'s own comment), which the owner's own screenshot
    /// showed centred around y 47pt, visibly below the screen's true
    /// top edge. Pose 1V now pins `y` to `safeAreaTop + 8 + 20`
    /// instead — this row's own fixed 40pt height means its top edge
    /// lands exactly 8pt below the real top safe-area inset (0 in
    /// 1V), "the very top of the video." Pose 5 is unchanged: it
    /// keeps centring on `statusBlock.midY`, the owner's own explicit
    /// "don't change pose 5."
    private func pose5TopRow(duoLayout: DuoLayout, safeAreaTop: CGFloat, containerSize: CGSize) -> some View {
        let statusBlock = duoLayout.statusBlock(containerSize: containerSize, safeAreaTop: safeAreaTop)
        let stageRect = duoLayout.stageRect(containerSize: containerSize, safeAreaTop: safeAreaTop)
        let leading = stageRect.minX + 16
        // Owner re-adapt (Live Activity pass): a Live Activity's own
        // pill grows the status block LEFTWARD on pose 5 (occlusion
        // itself widens — unlike the closed display, this pose DOES
        // see it) and used to cover Bin, since `stage.maxX - 16` alone
        // never read it. Clamped to `occlusion.minX - 8`, whatever
        // width that region reports this frame, so Bin stays clear at
        // any pill width instead of only the un-grown one. `nil`
        // occlusion (no status block at all) leaves the plain
        // stage-edge trailing unchanged.
        //
        // Review fix: this reads `duoLayout.occlusion` directly, not
        // `duoLayout.statusBlock(...)` — so `statusBlock`'s own new
        // containment check against a stale cross-display occlusion
        // frame (see that function's own comment) does not cover this
        // call site. A stale frame here is a separate failure mode
        // from the `nil` case just above — real, non-nil, but
        // wrong — and still reaches `occlusionClamp` unfiltered; this
        // comment used to claim `statusBlock` already covered it,
        // which was never true for a direct read like this one.
        //
        // Review fix (1H): the clamp above only ever makes sense when
        // the occlusion genuinely sits PAST `leading` — a real Live
        // Activity pill grown leftward on the trailing side. In 1H the
        // reported occlusion sits at `x = 29`, well left of `leading`
        // itself, so the old unconditional clamp read `29 - 8 = 21`
        // and collapsed this whole row to zero width. Only applying
        // the clamp when `occlusion.minX > leading` keeps that
        // unrelated, near-leading-edge occlusion from ever touching
        // this row's own trailing edge.
        //
        // NIT: a stale cross-display occlusion reading — same failure
        // mode `DuoLayout.current`'s own `windowBounds.contains(frame)`
        // filter already guards `occlusionFrame`/`divisionFrame`
        // against, but this call site reads `duoLayout.occlusion`
        // directly (the comment above already explains why), so it
        // needs its own containment check. `containerSize` here is
        // `fullWindow` (this function's own caller passes it), the
        // same true window-space rect `occlusion` is itself already
        // reported in, with the same 1pt rounding tolerance.
        let windowOcclusion = duoLayout.occlusion.flatMap { CGRect(origin: .zero, size: containerSize).insetBy(dx: -1, dy: -1).contains($0) ? $0 : nil }
        let occlusionClamp = windowOcclusion.map { $0.minX > leading ? $0.minX - 8 : .infinity } ?? .infinity
        let trailing = min(stageRect.maxX - 16, occlusionClamp)
        let width = max(0, trailing - leading)
        let rowHeight: CGFloat = 40
        let centerY = duoLayout.pose == .closed ? safeAreaTop + 8 + rowHeight / 2 : statusBlock.midY
        // Mirrored-layout round: "Bin top-left, Mute/Filter top-right"
        // — the row's own child order simply reverses. The counter
        // stays the child immediately next to Bin either way (it reads
        // left of Bin unmirrored, right of Bin mirrored), since
        // reversing the whole sequence keeps every pair's own relative
        // order, just read from the other end.
        return HStack(spacing: Rail.spacing) {
            if duoLayout.isMirrored {
                binButton()
                counterCapsule
                Spacer(minLength: 8)
                FilterMenuView(store: optionsStore, hidesChrome: hidesGlobalChrome)
                    .duoGuideMark("top.filter", color: .teal)
                muteButton
            } else {
                muteButton
                FilterMenuView(store: optionsStore, hidesChrome: hidesGlobalChrome)
                    .duoGuideMark("top.filter", color: .teal)
                Spacer(minLength: 8)
                counterCapsule
                binButton()
            }
        }
        .frame(width: width, height: rowHeight, alignment: .center)
        .position(x: leading + width / 2, y: centerY)
    }

    // MARK: - Laptop deck globals (build 8b, re-adapted R4)

    /// Pose 6's (laptop) own two screen-global pieces of the shared
    /// bottom deck — `design/duo/duo_build_spec.md` §2.6: the Mute/
    /// Filter/Bin group, and Previous/Next. Mounted here, not in
    /// `FeedPageContent`, for the same reason `chromeColumn`/
    /// `pose5TopRow` already are: these describe the SCREEN, not the
    /// current page — a shrink's progress capsule, mute state, and
    /// paging the feed are all facts this view already owns, and
    /// hoisting them is the one deliberate exception the audit's own
    /// Decision/§2 calls for in the laptop pose (every other pose's
    /// rail/caption/scrubber stays per-page). The rail row and the
    /// caption, which DO describe the current item, stay in
    /// `FeedPageContent`/`PlayerPageView` instead — see
    /// `FeedPageContent.laptopHorizontalRail`/`duoLaptopCaption`.
    ///
    /// Owner re-adapt (round 4): "put the filters in the top right of
    /// the bottom section, across and aligned from the date and
    /// time." The group now shares band 0 with the caption instead of
    /// owning its own row — `DuoLayout.laptopControlGroupTrailingX`
    /// gives the X axis (band 0's own trailing margin); `y` is
    /// `laptopCaptionDateLineCenterY`, this launch's latest real
    /// measurement of the caption's own date line — see that
    /// property's own comment (round-4 review) for why a nil reading
    /// now hides the group outright instead of guessing a Y. The
    /// `HStack`/`.frame(width: trailingX, alignment: .trailing)`/
    /// `.position(x: trailingX / 2, y:)` trio is the same
    /// "zero-anchored box, aligned content" technique
    /// `duoLaptopCaption`'s own `rect` already uses: the box's right
    /// edge always sits at `trailingX` regardless of the group's own
    /// rendered width, so `binBadgeText` widening the group shifts it
    /// LEFT on its own — "when it appears the group shifts left so it
    /// stays inside" — with no gap arithmetic here at all. The
    /// `background` `GeometryReader` reports that real, just-laid-out
    /// frame back up through `LaptopControlGroupFrameKey`,
    /// attached to the `HStack` itself (before the outer `.frame`
    /// inflates it to the box's own full width), so what bubbles up
    /// is the group's own tight bounds, not the box's.
    private func laptopDeckControls(duoLayout: DuoLayout, safeAreaBottom: CGFloat, containerSize: CGSize) -> some View {
        Group {
            if let nearX = duoLayout.laptopControlGroupTrailingX(containerSize: containerSize, safeAreaBottom: safeAreaBottom) {
                // Owner re-adapt (round-4 review): no more guessed
                // `fallbackY` — hidden instead for the one frame
                // before `laptopCaptionDateLineCenterY` reports its
                // first real value, rather than drawn at a guessed Y
                // and then jumped once the real one lands.
                //
                // Mirrored-layout round: `nearX` is the group's own
                // LEADING edge, not trailing, once mirrored — the box
                // spans `[nearX, containerWidth]` instead of `[0,
                // nearX]`, content leading-aligned, growing rightward.
                //
                // Owner correction (relayed, pose pass): the ORDER
                // inside the `HStack` flips too — "Bin outermost, same
                // as the mirrored top row." Unmirrored reads Mute,
                // Filter, Bin left to right (Bin innermost, next to
                // the group's own trailing edge); mirrored reads Bin,
                // Filter, Mute (Bin now innermost on the LEADING side
                // instead — still the edge closest to the rail, just
                // the other one).
                let width = duoLayout.isMirrored ? containerSize.width - nearX : nearX
                HStack(spacing: 12) {
                    if duoLayout.isMirrored {
                        binButton()
                        FilterMenuView(store: optionsStore, hidesChrome: hidesGlobalChrome)
                            .duoGuideMark("top.filter", color: .teal)
                        muteButton
                    } else {
                        muteButton
                        FilterMenuView(store: optionsStore, hidesChrome: hidesGlobalChrome)
                            .duoGuideMark("top.filter", color: .teal)
                        binButton()
                    }
                    // Owner re-adapt: this used to ALSO repeat the
                    // count/size trailing of Bin, inside the deck's
                    // own margin — the same doubled-badge bug
                    // `chromeColumn`'s identical comment now
                    // documents, "it shows the count and space
                    // twice." Shown once now, the pill's own inline
                    // badge — the `trailingX`-anchored frame below
                    // still keeps the group inside its own margin
                    // when that inline badge alone widens the pill,
                    // the same real-measurement mechanism as before,
                    // just with one fewer thing making it wider.
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: LaptopControlGroupFrameKey.self, value: proxy.frame(in: .global))
                    }
                )
                .frame(width: width, alignment: duoLayout.isMirrored ? .leading : .trailing)
                .position(x: duoLayout.isMirrored ? nearX + width / 2 : width / 2, y: laptopCaptionDateLineCenterY ?? 0)
                .opacity(laptopCaptionDateLineCenterY == nil ? 0 : 1)
            }
            if let pager = duoLayout.laptopPagerCenters(containerSize: containerSize, safeAreaBottom: safeAreaBottom) {
                laptopPagerButton(title: "← Previous", identifier: "duo_prev",
                                   center: pager.previous, width: pager.width, height: pager.height,
                                   isEnabled: laptopPagerIndex.map { $0 > 0 } ?? false,
                                   action: { laptopGoToPreviousPage() })
                laptopPagerButton(title: "Next →", identifier: "duo_next",
                                   center: pager.next, width: pager.width, height: pager.height,
                                   isEnabled: laptopPagerIndex.map { $0 + 1 < viewModel.deck.count } ?? false,
                                   action: { laptopGoToNextPage() })
            }
        }
    }

    /// One pill of the Previous/Next pair — `DuoLayout
    /// .laptopPagerCenters`'s own live width/height, disabled and
    /// dimmed at either end of the deck.
    private func laptopPagerButton(title: String, identifier: String, center: CGPoint, width: CGFloat, height: CGFloat, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: width, height: height)
                .feedGlassButton(in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .position(center)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title == "← Previous" ? "Previous video" : "Next video")
        .accessibilityHint("Pose 6's own paging control — plays the \(title == "← Previous" ? "previous" : "next") video without touching the upright half")
    }

    /// The deck's own index into `viewModel.deck` — `currentPageID`'s
    /// own live lookup, the same one `advanceToNextPage(from:)` already
    /// performs from an `entry`, just entered from the pager's own
    /// cursor instead of a tapped page. `nil` only when the pager has
    /// no current page at all (an empty deck, already excluded upstream
    /// by `content(safeAreaTop:fullscreenSafeArea:duoLayout:)`).
    private var laptopPagerIndex: Int? {
        guard let currentPageID else { return nil }
        return viewModel.deck.firstIndex(where: { $0.id == currentPageID })
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
    /// Island — except when this frame has no top status bar to clear
    /// at all. Owner ask (pose 1V): "can the archive, filter and
    /// volume buttons go all the way to the top of the Duo screen?"
    /// The closed Duo's own outer display has no Dynamic Island or
    /// status bar of its own — its own status lives in the bar column
    /// instead — so it reports a `safeAreaTop` far below a real status
    /// bar's. Below `StageGeometry.chromeTop`'s own `safeAreaTop >= 44`
    /// threshold (reused here, not reinvented, for "is there a real
    /// one to clear"), this row sits flush at `0`:
    /// `.containerCornerOffset(.top)`, already chained after this
    /// padding at the call site, is the only clearance left —
    /// "the corner clearance from `containerCornerOffset(.top)`," the
    /// owner's own words. A regular iPhone's own `safeAreaTop` is
    /// always well above 44, so it never takes this branch — decided
    /// purely by the real inset this frame reports, never a device
    /// check. Scoped to this one row, not `StageGeometry.chromeTop`
    /// itself, which `downShift`/`PhotoTopBar` also read for the
    /// stage's own positioning and Photos' own top bar — neither asked
    /// for by the owner here, so neither changes.
    private func topChromeTopPadding(safeAreaTop: CGFloat, containerSize: CGSize) -> CGFloat {
        // Below the threshold: `StageGeometry.downShift` grows the top
        // band by exactly enough for the video to start
        // `chromeToVideoGap` below `StageGeometry.chromeTop`'s OWN
        // reading, not this row's actual `0` — the two can disagree by
        // design here, since the video's own downward shift still
        // follows the shared, unmodified formula; only this specific
        // row (Mute/Filter/Bin) moves to the true edge.
        safeAreaTop >= 44 ? StageGeometry.chromeTop(safeAreaTop: safeAreaTop) : 0
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
        // Owner re-adapt (Opus wireframe compare): `.controlSize(.small)`
        // draws this glass circle at about 32pt — under Apple's own
        // 44×44pt minimum tap target. One definition, every pose that
        // mounts `muteButton` — topChrome, pose5TopRow, chromeColumn,
        // laptopDeckControls — picks this up without its own fix.
        //
        // Owner re-adapt (18 Pro regression check, round-4 pass): the
        // comment above claimed `.frame(minWidth: 44, minHeight: 44)`
        // "grows the hit area alone" — not true. `minWidth`/`minHeight`
        // are a real layout constraint: they grow this view's own
        // REPORTED size too, which shifted `topChrome`'s own HStack
        // (regular iPhone/tent) ~5pt — the regular iPhone must look
        // pixel-identical to pre-Duo, and did not. The standard
        // "padding, then `.contentShape`, then the same padding
        // negated" trick below instead grows the TAPPABLE area without
        // growing what the parent measures: the inner `.padding(6)`
        // expands the region `.contentShape` then captures, and the
        // matching `.padding(-6)` reports this view's own size back to
        // its parent exactly as before — 2×6 = 12pt added each
        // dimension, landing a 32pt circle at 44pt tappable, the same
        // floor the old `minWidth`/`minHeight` gave a bare circle,
        // while a badge/count still grows the control past 44 on its
        // own, unclipped, same as before.
        .padding(6)
        .contentShape(Rectangle())
        .padding(-6)
        // Identifier gated directly on `hidesGlobalChrome`, the same
        // condition that actually hides this row — the same pattern
        // every other top-chrome control uses.
        .accessibilityIdentifier(hidesGlobalChrome ? "" : "feed_mute_toggle")
        .accessibilityLabel(muteProbeState ? "Sound off" : "Sound on")
        .accessibilityHint("Double tap to turn sound \(muteProbeState ? "on" : "off")")
        // Owner re-adapt (pose pass): marked ONCE here, not at each of
        // the 4 call sites above — this is the one shared `muteButton`
        // every one of them mounts, so its own real frame is correct
        // regardless of which row actually placed it this pose. The
        // guide tool used to read `zigzagCenters` directly instead —
        // `chromeColumn`'s OWN geometry source, wrong for every pose
        // `pose5TopRow`/`topChrome`/`laptopDeckControls` serve instead
        // (1V's own real row reported "mid-screen," the owner's
        // report).
        .duoGuideMark("top.mute", color: .teal)
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

    /// `showsInlineBadge` (owner re-adapt, pose 3/4/4W BLOCKER):
    /// `false` only for `chromeColumn`'s own call — this button's
    /// capsule otherwise WIDENS for "count · size," which ran its own
    /// right half over the rail's Shrink icon once `chromeColumn`
    /// centres this on a fixed point in that narrow column, with no
    /// row to push a neighbour out of the way the way `topChrome`/
    /// `pose5TopRow`/`laptopDeckControls`'s own `HStack` flow does.
    /// `chromeColumn` instead keeps this a plain circle and draws the
    /// same text as its own separate, clamped label under it — see
    /// that function's own comment.
    private func binButton(showsInlineBadge: Bool = true) -> some View {
        Button { Usage.shared.binOpened(); showTrash = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 15, weight: .medium))
                if showsInlineBadge, let binBadgeText {
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
        // Owner re-adapt (Opus wireframe compare): see `muteButton`'s
        // identical comment for why — the icon-only (empty bin) case
        // drew at about 32pt wide, under the 44pt minimum.
        //
        // Owner re-adapt (18 Pro regression check, round-4 pass): see
        // `muteButton`'s identical comment — `.frame(minWidth:
        // minHeight:)` grew this view's own LAYOUT size too, shifting
        // `topChrome`'s own row. Same padding/contentShape/negated-
        // padding trick: a queued count or byte figure still grows the
        // capsule past 44pt on its own, unclipped, same as before.
        .padding(6)
        .contentShape(Rectangle())
        .padding(-6)
        // See `FilterMenuView`'s identical `hidesGlobalChrome`-gated
        // identifier pattern.
        .accessibilityIdentifier(hidesGlobalChrome ? "" : "bin_open")
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
        // See `muteButton`'s identical comment: one shared view, one
        // mark, correct for every one of its 4 call sites.
        .duoGuideMark("top.bin", color: .teal)
    }

    /// Pose 3/4/4W's own Bin button (round-5 wireframe, the "Bin open"
    /// row): replaces `104c599`'s interim fix — a plain circle plus a
    /// separate label drawn underneath it — with the approved design.
    /// An empty bin is the same plain circle `binButton` draws, same
    /// width as Mute/Filter. Once the bin has items, this grows
    /// DOWNWARD into a tall capsule instead of widening sideways the
    /// way `binButton`'s own inline badge does everywhere else: icon,
    /// then the count, then the size, stacked — sideways would run the
    /// capsule straight into the rail's own Shrink/Delete in this
    /// narrow column, the exact collision `104c599` was built to dodge
    /// in the first place (`chromeColumn`'s own history has the
    /// detail). `chromeColumn` reads this view's own real rendered
    /// height back through `ChromeBinCapsuleHeightKey` to shift the
    /// whole Mute/Filter/Bin group up by half of whatever this grows
    /// past `Rail.hit` — see that property's own comment.
    ///
    /// Width pinned to 32pt — `muteButton`'s own measured circle width
    /// (`.controlSize(.small)`'s own glass-circle size for a bare
    /// 20×20 glyph; see that button's own comment) — so the grown
    /// capsule never reads wider than Mute/Filter beside it. The count
    /// and size lines are clamped to that same width minus 2pt on each
    /// side, with `.minimumScaleFactor` to shrink rather than clip a
    /// wide byte figure ("1.2 GB") that does not fit at full size.
    private func chromeColumnBinCapsule() -> some View {
        let capsuleWidth: CGFloat = 32
        return Button { Usage.shared.binOpened(); showTrash = true } label: {
            VStack(spacing: 2) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 15, weight: .medium))
                if trashService.count > 0 {
                    Text("\(trashService.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: capsuleWidth - 4)
                    if let binSizeText {
                        Text(binSizeText)
                            .font(.system(size: 9, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: capsuleWidth - 4)
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(width: capsuleWidth)
            .padding(.vertical, trashService.count > 0 ? 6 : 0)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.white)
        .binShake(count: trashService.count)
        // Same padding/contentShape/negated-padding tap-target trick
        // as `binButton`/`muteButton` — see either one's own comment.
        .padding(6)
        .contentShape(Rectangle())
        .padding(-6)
        .accessibilityIdentifier(hidesGlobalChrome ? "" : "bin_open")
        // Same label/hint pair as `binButton` — see that view's own
        // comment on why the byte figure never joins this string.
        .accessibilityLabel(trashService.count > 0 ? "Bin, \(trashService.count) queued" : "Bin")
        .accessibilityHint("Opens the list of videos queued for deletion")
        .duoGuideMark("top.bin", color: .teal)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ChromeBinCapsuleHeightKey.self, value: proxy.size.height)
            }
        )
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

    /// `binBadgeText`'s own byte figure, split out on its own —
    /// `chromeColumnBinCapsule` stacks count and size as two separate
    /// lines instead of `binBadgeText`'s single "count · size" line.
    /// Same `showPending` rule, so the two never disagree about
    /// whether a figure is showing right now.
    private var binSizeText: String? {
        guard trashService.count > 0, trashService.pendingBytes > 0, activeShrinkJob == nil else { return nil }
        return Fmt.bytes(trashService.pendingBytes)
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

    // MARK: - Duo alignment guides

    /// Owner, direct: "if you have to add a helper box or line to the
    /// UI in dev that's fine, cause you're not nailing the network
    /// status icon alignment at all." DEBUG-only, on only behind
    /// `-cloudfull-duo-guides` — deliberately a bare launch-argument
    /// check, not `DiagnosticsGate`/`DiagnosticsSwitch`: those also
    /// turn on from the in-app diagnostics toggle, which would put
    /// this on screen in an otherwise-normal DEBUG session. This must
    /// never appear by accident, and never in a shipped build.
    ///
    /// Now a plain alias for `DuoGuides.isOn` — the shared flag every
    /// `.duoGuideMark` call site across the app reads too, so there is
    /// one source of truth instead of two bare launch-argument checks
    /// that could drift.
    private static var showsDuoGuides: Bool { DuoGuides.isOn }

    /// `pager`'s own background — plain black outside
    /// `-cloudfull-duo-guides`, unchanged. Owner: "I can't tell if the
    /// laptop video sits flush on the fold." A video is opaque and
    /// exactly fills whatever rect layout actually gave it — the only
    /// way to SEE a gap between that rect and where it was supposed to
    /// reach is to colour the destination differently from its
    /// surroundings and let the video cover whatever it actually
    /// reaches: any colour still showing through once it is on screen
    /// IS the gap.
    ///
    /// `blue` is the whole window — "everything else behind controls."
    /// `red` is this pose's own STRUCTURAL stage area — the box a video
    /// is FIT into, not the aspect-dependent FITted rect itself (that
    /// would always exactly equal the video's own rect, by definition,
    /// and could never show a gap). `.laptop`/`.book` draw their own
    /// `division` as a third, dim grey band on top of both, so the
    /// fold's own edges stay visible against whichever colour is
    /// under them.
    ///
    /// Pose by pose: `.laptop` — red is `[0, W] × [0, division.minY]`,
    /// the SAME box `stageRect`'s own `.laptop` branch FITs into (see
    /// that branch's own comment for why its bottom is `division.minY`
    /// itself now, no separate gap) — the owner's own ask, stated
    /// directly: "the upright half (window top → division.minY) RED,
    /// the flat half (division.maxY → window bottom) BLUE." `.book`
    /// (4/4W) — red is the left page, `[0, division.minX] × [0, H]`,
    /// the same box `stageRect`'s own `.book` tall-video branch FITs
    /// into; the right page (the grid) stays blue, unmarked, matching
    /// the owner's own "left page red, right page blue." Every other
    /// Duo pose (1V, 3, 5) — red is `availableRect`, the structural
    /// box every one of THEIR OWN stage branches FITs into before an
    /// aspect ratio narrows it (pose 3's own wide-video box additionally
    /// excludes the chrome column and the caption band — `availableRect`
    /// alone over-states that one pose's own red area slightly; flagged
    /// here rather than adding a second, pose-3-only box, since the
    /// owner's own ask was for the fold-flush check specifically).
    /// `.tent` falls to the same `availableRect` default — no rail
    /// column there either, so it reduces to the full container and red
    /// sits exactly over blue, harmless, nothing to see either way.
    /// `.regularPhone` draws no red at all (`nil`) — this tool is for
    /// Duo pose work specifically, and a regular iPhone's own stage is
    /// never in question here.
    /// `stageArea`/`division` come from `DuoLayout.debugStageArea` — see
    /// that method's own comment for the red rect's own pose-by-pose
    /// definition and the `availableRect`/pose-3 caveat.
    ///
    /// This is the PAGER's own shared background, behind the whole
    /// `ScrollView` — mostly covered in practice by each page's own
    /// opaque background (`PlayerPageView`'s identical use of this same
    /// pair, which is what actually shows through around a video in
    /// normal use). Kept here too for whatever this layer alone ever
    /// shows (between pages, before the first page lays out) so it
    /// never reads plain black while guides are on.
    @ViewBuilder
    private func pagerBackground(duoLayout: DuoLayout, safeAreaTop: CGFloat, containerSize: CGSize) -> some View {
        #if DEBUG
        if Self.showsDuoGuides && DuoGuideColours.isOn {
            DuoGuideColouredBackground(duoLayout: duoLayout, safeAreaTop: safeAreaTop, containerSize: containerSize)
                .ignoresSafeArea()
        } else {
            Color.black
        }
        #else
        Color.black
        #endif
    }

    /// `body`'s own root touch logger (`-cloudfull-log-touches`) —
    /// see that `simultaneousGesture`'s own comment.
    private static let touchLog = Logger(subsystem: "com.cloudfull.app", category: "Touch")

    /// Geometry sources this file's own Duo math is built from, drawn
    /// directly instead of trusted: `.occlusion` (red), `.division`
    /// (blue), the REAL system bar column — `barEdge`/`barWidth`
    /// construct this directly; there is no reserved-region API for
    /// it, and it does not exist at all on a bar-off pose (green,
    /// closed-bar poses only), `railColumnRect` (orange — every pose
    /// with a column, real bar or computed) — and the one x value
    /// `ringCenteredColumnX` actually hands the rail and chin (yellow,
    /// a 1pt line). Each draws its own live numbers as a small label,
    /// so one screenshot is enough to compare this file's own math
    /// against Apple's, with no second source of truth to keep in
    /// sync by hand.
    ///
    /// Owner, direct: "these lines are useful! can you add more so we
    /// can use them as conversation references?" Extended with: a
    /// faint 50pt reference grid (`duoReferenceGrid`), dashed
    /// safe-area lines (`duoSafeAreaGuides`), every element a pose fix
    /// has ever needed to talk about — the top row and the right
    /// page's grid/deck/pager read straight off the same pure
    /// `DuoLayout` functions the real views use (no per-page state
    /// involved, so no risk of drawing a stale neighbour's copy); the
    /// video stage, its caption, its scrubber, its iCloud ring, the
    /// chin, and each rail item instead report their own REAL
    /// rendered frame through `.duoGuideMark` (`DuoGuideMarksKey`'s
    /// own comment) — a measurement, not a second derivation, the
    /// exact distinction the pose 5 ring-x round needed the hard way —
    /// and a small legend in the corner.
    @ViewBuilder
    private func duoGuidesOverlay(duoLayout: DuoLayout, safeAreaTop: CGFloat, safeAreaInsets: EdgeInsets, containerSize: CGSize) -> some View {
        duoReferenceGrid(containerSize: containerSize)
        duoSafeAreaGuides(containerSize: containerSize, safeAreaInsets: safeAreaInsets)
        if let occlusion = duoLayout.occlusion {
            duoGuideRect(occlusion, color: .red, label: "occlusion \(duoGuideFormat(occlusion))")
        }
        if let division = duoLayout.division {
            duoGuideRect(division, color: .blue, label: "division \(duoGuideFormat(division))")
        }
        if let barRect = duoGuideBarRect(duoLayout: duoLayout, containerSize: containerSize) {
            duoGuideRect(barRect, color: .green, label: "bar \(duoGuideFormat(barRect))")
        }
        if let columnRect = duoLayout.railColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop) {
            duoGuideRect(columnRect, color: .orange, label: "railColumn \(duoGuideFormat(columnRect))")
        }
        if let x = duoLayout.ringCenteredColumnX(containerSize: containerSize, safeAreaTop: safeAreaTop) {
            Rectangle()
                .fill(Color.yellow)
                .frame(width: 1, height: containerSize.height)
                .position(x: x, y: containerSize.height / 2)
                .allowsHitTesting(false)
            Text("ringX \(Int(x))")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.yellow)
                .padding(2)
                .background(Color.black.opacity(0.6))
                .fixedSize()
                .position(x: x, y: 40)
                .allowsHitTesting(false)
        }
        // The Mute/Filter/Bin row — owner bug (pose pass, 1V): this
        // used to read `zigzagCenters` directly, `chromeColumn`'s own
        // geometry source (pose 3/4/4W only) — wrong for every other
        // pose, which mounts the SAME `muteButton`/`FilterMenuView`/
        // `binButton` through `topChrome`, `pose5TopRow`, or
        // `laptopDeckControls` instead. 1V's own report: the guide
        // boxes sat "mid-screen next to the rail" while the real row
        // sits at the top. `top.mute`/`top.filter`/`top.bin` are now
        // marked at the shared views themselves (`muteButton`'s own
        // comment), so they read correctly regardless of which of the
        // four layouts actually placed them this pose.
        // The right page's grid rect — pure `DuoLayout`, drawn
        // directly like `occlusion`/`division` above. Its date line
        // and the grid's own tiles still report through
        // `.duoGuideMark` (`DuoRightPage`), since this rect alone does
        // not know where the real content laid out inside it.
        if let rightPage = duoLayout.rightPage(containerSize: containerSize, safeAreaTop: safeAreaTop) {
            duoGuideRect(rightPage, color: .pink, label: "grid \(duoGuideFormat(rightPage))")
        }
        // The laptop deck's three bands (round 4: down from four — the
        // Mute/Filter/Bin group folded into band 0, see
        // `DuoLayout.laptopControlGroupTrailingX`'s own comment) — same
        // `bottom.height / 3` split `DuoLayout.laptopBand` (private)
        // already uses internally, read back here for the outline
        // alone; every laptop-deck function in `DuoLayout` already
        // reads ITS OWN band straight from `laptopBottomRect`, so this
        // is not a second description of their placement, only of the
        // band lines themselves.
        if let bottom = duoLayout.laptopBottomRect(containerSize: containerSize, safeAreaBottom: safeAreaInsets.bottom) {
            let bandHeight = bottom.height / 3
            let names = ["deck1 (scrubber/caption/group)", "deck2 (rail/chin)", "deck3 (prev/next)"]
            ForEach(0..<3, id: \.self) { index in
                let band = CGRect(x: bottom.minX, y: bottom.minY + CGFloat(index) * bandHeight,
                                   width: bottom.width, height: bandHeight)
                duoGuideRect(band, color: .gray, label: "\(names[index]) \(duoGuideFormat(band))", labelAlignment: .topTrailing)
            }
        }
        // The Mute/Filter/Bin group's own real rendered box (round 4)
        // — unlike `top.mute`/`top.filter`/`top.bin` above, which mark
        // each BUTTON, this marks the GROUP as a whole, so the guide
        // shows whether the group is actually staying inside band 0's
        // own margin (and shifting left for `binBadgeText`) rather
        // than just where its buttons landed.
        //
        // Mirrored-layout round: reads `laptopControlGroupFrame`
        // directly now — the real, measured frame, whichever edge the
        // group grew from — rather than reconstructing a box from a
        // separately-computed `trailingX`, which only ever described
        // the unmirrored (trailing-anchored) case correctly.
        if let frame = laptopControlGroupFrame {
            duoGuideRect(frame, color: .teal, label: "deck.group \(duoGuideFormat(frame))")
        }
        if let pager = duoLayout.laptopPagerCenters(containerSize: containerSize, safeAreaBottom: safeAreaInsets.bottom) {
            let prevRect = CGRect(x: pager.previous.x - pager.width / 2, y: pager.previous.y - pager.height / 2,
                                   width: pager.width, height: pager.height)
            let nextRect = CGRect(x: pager.next.x - pager.width / 2, y: pager.next.y - pager.height / 2,
                                   width: pager.width, height: pager.height)
            duoGuideRect(prevRect, color: .gray, label: "prev \(duoGuideFormat(prevRect))")
            duoGuideRect(nextRect, color: .gray, label: "next \(duoGuideFormat(nextRect))")
        }
        // Every production view's own real rendered frame — the
        // stage, its caption (all four per-pose variants share the
        // one "caption" name), its scrubber, its iCloud ring, the
        // chin, the grid's date line, and each rail item (both the
        // vertical and the laptop's horizontal row share the one
        // "rail.*" name) — reported through `.duoGuideMark` at each
        // real call site. See `DuoGuideMarksKey`'s own comment.
        ForEach(duoGuideMarks, id: \.id) { mark in
            duoGuideRect(mark.rect, color: mark.color, label: "\(mark.id) \(duoGuideFormat(mark.rect))")
        }
        duoGuideLegend(duoLayout: duoLayout, containerSize: containerSize)
    }

    /// One guide's own outline + label, positioned the same way every
    /// other absolute-positioned overlay in this file already is —
    /// `.frame(width:height:)` then `.position(x: rect.midX, y:
    /// rect.midY)` — so these guides sit in exactly the window space
    /// every real caller already reads `occlusion`/`division`/
    /// `railColumnRect` in, with no translation of their own to get
    /// wrong.
    ///
    /// `labelAlignment` (round-4 review): the deck band labels
    /// ("deck1 (scrubber/caption/group)", …) sat on top of the real
    /// caption's own metadata line at the band's own top-leading
    /// corner, the one spot that box always has real content at.
    /// Defaults to `.topLeading`, unchanged for every other caller.
    private func duoGuideRect(_ rect: CGRect, color: Color, label: String, labelAlignment: Alignment = .topLeading) -> some View {
        ZStack(alignment: labelAlignment) {
            Rectangle()
                .stroke(color, lineWidth: 1)
            // Owner re-adapt (pose pass): a small (icon-sized) box's
            // own label used to `.fixedSize()`, the same as every
            // other box here — fine for a wide box with clear room
            // around it, but a tiny 40×40 top-row/rail-item box sits
            // close enough to its neighbours that the UNCLIPPED label
            // ran straight across the next box's own label. Clipping
            // to the box's own width ONLY below this 60pt threshold
            // keeps every other, roomier label exactly as it was.
            duoGuideLabel(label, color: color, maxWidth: rect.width > 0 && rect.width < 60 ? max(rect.width, 20) : nil)
        }
        .frame(width: max(0, rect.width), height: max(0, rect.height), alignment: .topLeading)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func duoGuideLabel(_ label: String, color: Color, maxWidth: CGFloat?) -> some View {
        if let maxWidth {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .padding(2)
                .background(Color.black.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxWidth, alignment: .leading)
        } else {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .padding(2)
                .background(Color.black.opacity(0.6))
                .fixedSize()
        }
    }

    private func duoGuideFormat(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)) midX=\(Int(rect.midX))"
    }

    /// The REAL system bar column's own rect — `barEdge`/`barWidth`
    /// construct this directly, the same way `railColumn`'s own
    /// closed-bar branch does; there is no reserved-region API for a
    /// "bar" kind to read it from instead. `nil` on any bar-off pose
    /// (no real bar to draw), kept as a plain (non-`@ViewBuilder`)
    /// function since the `switch` it needs cannot live inside
    /// `duoGuidesOverlay`'s own view-builder body.
    private func duoGuideBarRect(duoLayout: DuoLayout, containerSize: CGSize) -> CGRect? {
        guard let barEdge = duoLayout.barEdge, duoLayout.barWidth > 0 else { return nil }
        switch barEdge {
        case .leading:
            return CGRect(x: 0, y: 0, width: duoLayout.barWidth, height: containerSize.height)
        case .trailing:
            return CGRect(x: containerSize.width - duoLayout.barWidth, y: 0, width: duoLayout.barWidth, height: containerSize.height)
        }
    }

    /// A faint 50pt reference grid — column letters (A, B, C…) along
    /// the top edge, row numbers (1, 2, 3…) down the leading edge —
    /// owner, direct: "these lines are useful! can you add more so we
    /// can use them as conversation references?" Lets a conversation
    /// say "move Bin to C2" instead of a raw point pair. Deliberately
    /// the faintest marks in this whole overlay, so the real UI stays
    /// readable underneath.
    @ViewBuilder
    private func duoReferenceGrid(containerSize: CGSize) -> some View {
        let step: CGFloat = 50
        let columns = max(0, Int(containerSize.width / step))
        let rows = max(0, Int(containerSize.height / step))
        ForEach(0...columns, id: \.self) { i in
            let x = CGFloat(i) * step
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: containerSize.height)
                .position(x: x, y: containerSize.height / 2)
                .allowsHitTesting(false)
            if i < columns {
                Text(Self.duoGuideColumnLetter(i))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .position(x: x + step / 2, y: 6)
                    .allowsHitTesting(false)
            }
        }
        ForEach(0...rows, id: \.self) { i in
            let y = CGFloat(i) * step
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: containerSize.width, height: 1)
                .position(x: containerSize.width / 2, y: y)
                .allowsHitTesting(false)
            if i < rows {
                Text("\(i + 1)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .position(x: 6, y: y + step / 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A, B, C, … Z, AA, AB, … — spreadsheet-style column naming, for
    /// however wide a window this grid ever needs to label.
    private static func duoGuideColumnLetter(_ index: Int) -> String {
        var n = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(65 + n % 26)!) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters
    }

    /// The four safe-area insets, as dashed lines — "safe-area insets
    /// as dashed lines (label 'safe T/L/B/R = n')," the owner's own
    /// spec. `safeAreaInsets` is `fullscreenSafeArea`, the real
    /// per-frame reading `railAlignedChinCenter` and every other
    /// Duo-aware call in this file already uses — never a flat
    /// constant.
    @ViewBuilder
    private func duoSafeAreaGuides(containerSize: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        if safeAreaInsets.top > 0 {
            duoGuideDashedLine(horizontalAt: safeAreaInsets.top, containerSize: containerSize, label: "safe T=\(Int(safeAreaInsets.top))")
        }
        if safeAreaInsets.bottom > 0 {
            duoGuideDashedLine(horizontalAt: containerSize.height - safeAreaInsets.bottom, containerSize: containerSize, label: "safe B=\(Int(safeAreaInsets.bottom))")
        }
        if safeAreaInsets.leading > 0 {
            duoGuideDashedLine(verticalAt: safeAreaInsets.leading, containerSize: containerSize, label: "safe L=\(Int(safeAreaInsets.leading))")
        }
        if safeAreaInsets.trailing > 0 {
            duoGuideDashedLine(verticalAt: containerSize.width - safeAreaInsets.trailing, containerSize: containerSize, label: "safe R=\(Int(safeAreaInsets.trailing))")
        }
    }

    private func duoGuideDashedLine(horizontalAt y: CGFloat, containerSize: CGSize, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: containerSize.width, y: y))
            }
            .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(2)
                .background(Color.black.opacity(0.6))
                .fixedSize()
                .position(x: 36, y: max(8, y - 8))
        }
        .allowsHitTesting(false)
    }

    private func duoGuideDashedLine(verticalAt x: CGFloat, containerSize: CGSize, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: containerSize.height))
            }
            .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(2)
                .background(Color.black.opacity(0.6))
                .fixedSize()
                .position(x: x, y: 70)
        }
        .allowsHitTesting(false)
    }

    /// A small legend — colours, the current pose, and the window
    /// size (e.g. "pose openTall 669x951"), the owner's own spec.
    ///
    /// Owner (pose pass, round 2): top-leading still wasn't free —
    /// pose 5's own `pose5TopRow` sits top-LEADING there (Mute/Filter
    /// near `stageRect.minX`), the same corner top-leading moved TO
    /// after pose 3's caption bumped it off bottom-leading. No fixed
    /// corner is free in every pose today, and the round-4 agents are
    /// changing the laptop/column layouts as this is written, so a
    /// third hardcoded guess could just as easily collide with
    /// whatever they land on. Collapsible instead: starts as a small
    /// tap target at top-CENTRE (clear of every pose's own leading or
    /// trailing content in every capture so far), expands in place on
    /// tap, never drawn without a deliberate tap asking for it.
    @ViewBuilder
    private func duoGuideLegend(duoLayout: DuoLayout, containerSize: CGSize) -> some View {
        if duoGuideLegendExpanded {
            VStack(alignment: .leading, spacing: 2) {
                Text("pose \(duoLayout.pose.rawValue) \(Int(containerSize.width))×\(Int(containerSize.height)) (tap to hide)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.bottom, 2)
                duoGuideLegendRow(.red, "occlusion")
                duoGuideLegendRow(.blue, "division")
                duoGuideLegendRow(.green, "bar")
                duoGuideLegendRow(.orange, "railColumn")
                duoGuideLegendRow(.yellow, "ringX")
                duoGuideLegendRow(.teal, "top row")
                duoGuideLegendRow(.purple, "stage")
                duoGuideLegendRow(.pink, "caption / grid")
                duoGuideLegendRow(.mint, "chin")
                duoGuideLegendRow(.cyan, "cloud ring")
                duoGuideLegendRow(.indigo, "rail item")
                duoGuideLegendRow(.gray, "deck / prev-next")
                duoGuideLegendRow(.white, "safe area")
            }
            .padding(6)
            .background(Color.black.opacity(0.85))
            .cornerRadius(4)
            .fixedSize()
            .position(x: containerSize.width / 2, y: 110)
            .onTapGesture { duoGuideLegendExpanded = false }
        } else {
            Text("legend")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.85))
                .cornerRadius(4)
                .fixedSize()
                .position(x: containerSize.width / 2, y: 12)
                .onTapGesture { duoGuideLegendExpanded = true }
        }
    }

    private func duoGuideLegendRow(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(color).frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
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

    /// §3d's own mirror of `advanceToNextPage(from:)`: `index − 1`, the
    /// same `advanceNonce` path, disabled at index 0 (the pager button
    /// itself checks that through `laptopPagerIndex`, this is just the
    /// action). Pose 6's own Previous pill is the one caller.
    private func retreatToPreviousPage(from entry: DeckEntry) {
        guard let index = viewModel.deck.firstIndex(where: { $0.id == entry.id }) else { return }
        let previousIndex = index - 1
        guard viewModel.deck.indices.contains(previousIndex) else { return }
        let previousID = viewModel.deck[previousIndex].id
        isAdvancing = true
        advanceTargetID = previousID
        advanceNonce += 1
    }

    /// Pose 6's Previous/Next pills act on the centred page
    /// (`currentPageID`), not a tapped-from page — there is no
    /// per-page `entry` in scope at the pill's own call site, unlike
    /// `advanceToNextPage(from:)`'s other caller (`FeedPageContent
    /// .onAdvanceRequested`, the exhausted card). These two small
    /// wrappers resolve that entry once and hand it to the shared
    /// action, so `laptopDeckControls` stays a plain view builder.
    private func laptopGoToNextPage() {
        guard let currentPageID, let entry = viewModel.deck.first(where: { $0.id == currentPageID }) else { return }
        advanceToNextPage(from: entry)
    }

    private func laptopGoToPreviousPage() {
        guard let currentPageID, let entry = viewModel.deck.first(where: { $0.id == currentPageID }) else { return }
        retreatToPreviousPage(from: entry)
    }

    // MARK: - Step 12: DuoRightPage actions

    /// `FeedPageContent`'s own inline `onRequestShrink` closure,
    /// pulled out so `DuoRightPage`'s Shrink button reaches the exact
    /// same sheet through the exact same path — "the same paths the
    /// rail's shrinkButton … use" (`design/duo/duo_build_spec.md`
    /// §3b).
    private func requestShrink(assetID: String) {
        Usage.shared.shrinkSheetOpened()
        shrinkTarget = ShrinkTarget(id: assetID)
    }

    /// Plays `assetID` next on the left page — §3b: "`DeckViewModel
    /// .insertNext` … F then runs the existing `advanceTargetID`/
    /// `advanceNonce` scroll," the same path a trash tap's own advance
    /// and the laptop pose's Next pill already use.
    /// `insertNext` itself already no-ops (returns the current page's
    /// own id, unchanged) for the current video or a stale/queued tile,
    /// so this needs no guard of its own before scrolling.
    private func playNextFromRightPage(assetID: String) {
        let targetID = viewModel.insertNext(assetID: assetID)
        guard !targetID.isEmpty else { return }
        isAdvancing = true
        advanceTargetID = targetID
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

/// `FeedView.laptopCaptionDateLineCenterY`'s own anchor — see that
/// property's comment, and `DuoRightGridBottomKey`'s identical pattern
/// (`Cloudfull/Feed/DuoRightPage.swift`) this mirrors for the same
/// cross-view geometry problem: a value only a real, laid-out view can
/// report, needed by a sibling that cannot read it any other way.
/// Reported only by the ACTIVE page's own `FeedPageContent
/// .duoLaptopCaption` (gated on `isActive` at that call site, through
/// `captionTexts(measureDateLineCenter:)`); a preloaded neighbor page
/// reports nothing at all, so it can never win the `reduce` below and
/// steal this value mid-swipe.
struct LaptopCaptionDateLineCenterKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

/// `FeedView.laptopControlGroupFrame`'s own anchor — the Mute/
/// Filter/Bin group's real rendered frame, reported by `FeedView
/// .laptopDeckControls` itself. That view mounts once, globally, never
/// per page, so — unlike `LaptopCaptionDateLineCenterKey` above —
/// there is no second contributor this `reduce` ever needs to guard
/// against.
///
/// Mirrored-layout round: carries the whole frame, not only `minX` —
/// renamed from `LaptopControlGroupLeadingXKey`. Unmirrored,
/// `duoLaptopCaption` still only ever needs `.minX` (the group's own
/// leading edge, the caption's own clearance point on its trailing
/// side); mirrored, it needs `.maxX` instead (the group now sits on
/// the LEADING side, and the caption must clear its trailing edge).
struct LaptopControlGroupFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

/// `FeedView.chromeBinCapsuleHeight`'s own anchor — pose 3/4/4W's Bin
/// capsule's real rendered height, reported by `chromeColumnBinCapsule`
/// itself. That view mounts once, globally (inside `chromeColumn`,
/// never per page), so — same as `LaptopControlGroupLeadingXKey` above
/// — there is no second contributor this `reduce` ever needs to guard
/// against. `max`, not "last write wins": a height can only ever grow
/// from real content, never arrive smaller by mistake.
struct ChromeBinCapsuleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = Rail.hit
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
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
    /// The real bottom safe-area inset, threaded the same way
    /// `safeAreaTop` is — build 8b's own addition, read only by
    /// `duoLaptopCaption`/`laptopHorizontalRail` through
    /// `DuoLayout.laptopBottomRect`/`laptopRailRow`. `0` on every
    /// regular-iPhone or non-laptop call site; those functions never
    /// read it there.
    let safeAreaBottom: CGFloat
    /// This frame's iPhone Duo geometry, threaded the same way
    /// `safeAreaTop` is — see `PlayerPageView.duoLayout`'s identical
    /// comment. `DuoLayout.none` on a regular iPhone, which keeps
    /// `body`'s overlay layout exactly what it was before this
    /// parameter existed. See `DuoLayout.railColumnRect` and this
    /// file's `body`/`actionRailColumn` for how it is used.
    let duoLayout: DuoLayout
    /// The book pose's (4/4W) right-page grid's own real bottom edge,
    /// threaded the same way `safeAreaTop` is — see `FeedView
    /// .duoRightGridBottomY`'s own comment. Read only by
    /// `duoBookCaption`. `nil` on every pose but book, and on book
    /// itself until `DuoRightPage`'s own grid has laid out at least
    /// once this launch.
    let duoRightGridBottomY: CGFloat?
    /// Pose 6 (laptop), round 4: the Mute/Filter/Bin group's own real
    /// rendered frame, threaded the same way `duoRightGridBottomY` is
    /// — see `FeedView.laptopControlGroupFrame`'s own comment. Read
    /// only by `duoLaptopCaption`, to keep the caption's own text
    /// clear of the group sharing its row — `.minX` unmirrored,
    /// `.maxX` mirrored. `nil` on every pose but laptop, and on laptop
    /// itself until the group has laid out at least once this launch.
    let laptopControlGroupFrame: CGRect?
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
            // Build 5: the REAL band below the stage, from the real
            // stage height (`duoLayout.stageRect`'s own `.height`),
            // not `bottomBand`'s width-derived assumption above —
            // identical to it on a regular iPhone (width always
            // binds there), but different once a Duo pose's own
            // excluded column makes HEIGHT the binding side instead.
            // `captionZone` compares this against
            // `ScrubberView.minimumSeamBand` (50) to decide whether
            // the on-video scrubber line this pose falls back to
            // (`PlayerPageView.bottomSpace` the same size) needs the
            // caption lifted clear of it — see that function's own
            // comment.
            let realStageHeight = duoLayout.stageRect(containerSize: proxy.size, safeAreaTop: safeAreaTop).height
            // Owner re-adapt (pose pass, 1V): matches
            // `PlayerPageView`'s identical `.closed` term on its own
            // `ScrubberView.bandHeight` — the scrubber line is forced
            // onto the video's own bottom edge for this pose now, so
            // `captionZone`'s own `liftsForScrubber` check (below)
            // must see the same `0`, not the generically-computed real
            // band, to agree about whether the caption needs lifting
            // clear of it.
            let realBottomBand = duoLayout.pose == .closed ? 0 : StageGeometry.bottomBand(
                safeAreaTop: safeAreaTop, stageHeight: realStageHeight, containerHeight: proxy.size.height
            )
            // `nil` on a regular iPhone, and on an open Duo too narrow
            // for one: every call below falls back to the pre-Duo
            // overlay, unchanged. Non-`nil` on the closed Duo (the
            // system's own bar column) and on an open Duo wide enough
            // (a computed column) — see `DuoLayout.railColumn`'s own
            // comment for why those two share this one rectangle.
            let railColumnRect = duoLayout.railColumnRect(containerSize: proxy.size, safeAreaTop: safeAreaTop)
            // Build 4: pose 3 (openWide) and pose 4/4W (book) place the
            // caption at their own fixed point off the stage —
            // `duoOpenWideCaption`/`duoBookCaption`, rendered as their
            // own absolute-positioned siblings below, never through
            // this VStack's flow layout. Both poses already have a
            // non-nil `railColumnRect` (the bar is on for them too —
            // see `DUO_POSES.md`), so without this guard the `if let
            // railColumnRect` branch below would ALSO render a second,
            // flow-positioned caption for them.
            //
            // Build 8b: pose 6 (laptop) joins the same guard —
            // `duoLaptopCaption`'s own fixed point below the fold,
            // never this VStack's flow layout either.
            let usesDuoCaption = duoLayout.pose == .openWide || duoLayout.pose == .book || duoLayout.pose == .laptop
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                // `exhaustedCard` sits directly above the caption and
                // rail row, on whichever page is both the deck's last
                // entry and the one actually centered.
                if isFinalExhausted {
                    exhaustedCard
                        .padding(.bottom, 24)
                }
                if !usesDuoCaption {
                    if let railColumnRect {
                        // The rail lives in its own column
                        // (`actionRailColumn` below), not over the
                        // stage, so the caption only needs to stay
                        // clear of that column, not of a rail that is
                        // no longer on the video.
                        //
                        // Owner re-adapt (pose 5, right-align): a
                        // height-bound video's own leading edge now
                        // sits wherever `stageRect` right-aligned it
                        // to, not always 0 — "caption leading =
                        // stage.minX + 16." 1V reads the same
                        // `railColumnRect` branch but never moves its
                        // own video off the leading edge, so this is a
                        // no-op there (`stageRect.minX` is already 0).
                        //
                        // Mirrored-layout round: `captionZone`'s own
                        // `leadingClearance` is really "the gap on the
                        // side AWAY from the rail" — it lands on the
                        // trailing edge once mirrored (see that
                        // function's own comment), so this must read
                        // whichever side of `stageRect` is now the
                        // away-from-rail one too: `stage.minX` when
                        // the video left-aligns (unmirrored), the gap
                        // past `stage.maxX` to the window's own
                        // trailing edge when it right-aligns
                        // (mirrored) instead.
                        // A plain closure, invoked at once — an
                        // `if/else` with no trailing View expression,
                        // written directly in this `@ViewBuilder`
                        // body, is read as a view branch and fails to
                        // type-check (see `duoLaptopCaption`'s
                        // identical note).
                        let leadingClearance: CGFloat = {
                            guard duoLayout.pose == .openTall else { return 16 }
                            let stage = duoLayout.stageRect(containerSize: proxy.size, safeAreaTop: safeAreaTop)
                            return duoLayout.isMirrored
                                ? proxy.size.width - stage.maxX + 16
                                : stage.minX + 16
                        }()
                        captionZone(leadingClearance: leadingClearance, trailingClearance: railColumnRect.width + 16, hidden: false, bandHeight: realBottomBand)
                    } else {
                        // Mirrored-layout round: this HStack is a true
                        // two-pane layout, caption and rail each their
                        // own side-by-side child — not one row whose
                        // own internal padding/alignment can flip in
                        // place, the way every other mirrored piece in
                        // this file works. Mirrored, the PANES
                        // themselves swap order, and the rail's own
                        // `VStack` alignment swaps with them (leading,
                        // hugging the screen's own true left bezel,
                        // instead of trailing). `captionZone`'s own
                        // call is UNCHANGED either way — its own
                        // internal mirror logic (that function's own
                        // comment) already reads correctly once it is
                        // simply the HStack's other child.
                        let railColumn = VStack(alignment: duoLayout.isMirrored ? .leading : .trailing, spacing: 0) {
                            if isActive, let calloutMessage = shareCoordinator.calloutMessage {
                                railCallout(calloutMessage)
                            }
                            actionRail(bottomBand: bottomBand)
                        }
                        .animation(.easeInOut(duration: 0.2), value: shareCoordinator.calloutMessage)
                        HStack(alignment: .bottom, spacing: 0) {
                            if duoLayout.isMirrored {
                                railColumn
                                captionZone(trailingClearance: 16, hidden: false, bandHeight: realBottomBand)
                            } else {
                                captionZone(trailingClearance: 16, hidden: false, bandHeight: realBottomBand)
                                railColumn
                            }
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Build 8b: pose 6 never uses the vertical rail column —
            // `laptopHorizontalRail` below draws its own five buttons
            // in a row instead, so this must not also render
            // `actionRailColumn` even on a wide enough laptop window
            // where `railColumn`'s own generic (bar/occlusion-based)
            // gate happens to pass.
            if let railColumnRect, duoLayout.pose != .laptop {
                actionRailColumn(rect: railColumnRect, containerSize: proxy.size)
            }
            if duoLayout.pose == .openWide {
                duoOpenWideCaption(containerSize: proxy.size, safeAreaTop: safeAreaTop)
            } else if duoLayout.pose == .book {
                duoBookCaption(containerSize: proxy.size, safeAreaTop: safeAreaTop)
            } else if duoLayout.pose == .laptop {
                duoLaptopCaption(containerSize: proxy.size, safeAreaBottom: safeAreaBottom)
                laptopHorizontalRail(containerSize: proxy.size, safeAreaBottom: safeAreaBottom)
            }
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

    /// The caption's own two lines, with no outer positioning — shared
    /// by `captionZone` (every pose but 3/4/4W) and, as of build 4,
    /// `duoOpenWideCaption`/`duoBookCaption`, which each wrap this in
    /// their own absolute-positioned frame instead of `captionZone`'s
    /// flow-based padding.
    ///
    /// `measureDateLineCenter` (round 4, default `false`, every call
    /// site but `duoLaptopCaption`'s own): reports the date line's
    /// real, just-laid-out vertical centre through
    /// `LaptopCaptionDateLineCenterKey` — see that key's own comment,
    /// and `FeedView.laptopCaptionDateLineCenterY`'s. `duoLaptopCaption`
    /// passes `isActive` here, so only the one page genuinely on
    /// screen (not a preloaded neighbor) ever reports a position.
    ///
    /// Review fix: the `VStack`'s own `alignment` used to stay
    /// `.leading` regardless of `duoLayout.isMirrored` — every call
    /// site already flips its OWN outer `.frame(alignment:)` to put
    /// the box on the trailing side when mirrored (see
    /// `duoOpenWideCaption`/`duoLaptopCaption`'s own bodies), but the
    /// text's own reading edge inside that box stayed leading either
    /// way — wrong once the two lines genuinely differ in width (a
    /// long place name on the date line, say): the shorter line should
    /// hug the TRAILING edge when mirrored, matching the comment near
    /// `duoLaptopCaption`'s own mirrored branch ("the TEXT's own
    /// reading edge within it" flips too, not only the block's
    /// position).
    private func captionTexts(measureDateLineCenter: Bool = false) -> some View {
        VStack(alignment: duoLayout.isMirrored ? .trailing : .leading, spacing: 3) {
            Text(dateLine)                           // "<date> · <time> · <place>"
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                // Always one line. A long city name pushes this past the
                // chin's width, so it shrinks to 75% before it truncates.
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
                .background(alignment: .center) {
                    if measureDateLineCenter {
                        GeometryReader { proxy in
                            Color.clear.preference(key: LaptopCaptionDateLineCenterKey.self, value: proxy.frame(in: .named("duoPage")).midY)
                        }
                    }
                }
            Text(meta.detailText)                    // "4K · 1:12 · 428 MB"
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    /// `trailingClearance` is how far the caption must stay off the
    /// trailing edge: the overlay rail's own 16pt margin when the rail
    /// is on the video (a regular iPhone, or an open Duo too narrow
    /// for a column), or the rail COLUMN's full width plus that same
    /// 16pt when the rail has moved there instead. See
    /// `FeedPageContent.body` for which case applies, and
    /// `DuoLayout.railColumnRect` for where the column's width comes
    /// from.
    /// `hidden` is always `false` from both call sites below, as of
    /// step 2's build 1 fix: the old round's `isLandscapeFit` used to
    /// pass `true` here for a real-rotation horizontal video on an
    /// open Duo, but the round-3 wireframes (`DUO_POSES.md`) keep the
    /// caption visible for pose 3's wide video too. Kept as its own
    /// parameter, rather than deleted outright, since the caption
    /// hiding the same way `isScrubbing` already does — opacity, plus
    /// its own accessibility bits below, independent of the outer
    /// `hideForFullscreen` path — is a real, reusable shape a later
    /// pose could still need.
    ///
    /// `bandHeight` is build 5's own addition: the REAL band below
    /// the stage (`FeedPageContent.body`'s own `realBottomBand`),
    /// compared against `ScrubberView.minimumSeamBand` the same way
    /// that view compares it, to decide the bottom padding. Below 50,
    /// `ScrubberView` itself falls back from the seam to the on-video
    /// placement — the hairline sits inside its own 28pt track box,
    /// drawn over the video's own bottom pixels rather than below
    /// them. The plain 20pt padding below is exactly what
    /// `StageGeometry.captionCenterFromBottom`'s own header comment
    /// derives from, with no such line to clear; once that line is on
    /// the video instead, this adds the track box's own height (28)
    /// on top of it — 48pt total — so the caption lifts clear of it.
    /// Pose 1V (closed) and pose 5 (open-tall) are the two poses
    /// where the real band can fall under 50 today — the build-list's
    /// own check for this step, "Duo 1V + 5: no scrubber line crosses
    /// the text."
    ///
    /// Re-adapted (`design/duo/duo_audit_apple_checklist.md` §5): this
    /// used to be described as "(Duo only)," which reads like a device
    /// check. It is not one — `duoLayout.pose != .regularPhone` is
    /// `DuoLayout.classify`'s own SPACE-derived result (R1, Decision
    /// B), the same hard-rule gate every new Duo branch in this app
    /// already follows, never a device name or model check. Without
    /// it, a regular iPhone whose own band happens to fall under 50
    /// (an iPhone SE, close to 16:9) would also read 48pt here instead
    /// of its today's flat 20pt — a real behaviour change on a device
    /// this branch must leave untouched. The gate stays for that
    /// reason; only the "(Duo only)" framing was ever imprecise.
    ///
    /// Owner re-adapt (pose pass, pose 1V): "the line's slightly above
    /// the bottom — it should be on the bezel... [caption] lower it
    /// the same amount, keep its gap." Pose 1V's own `ScrubberView`
    /// now pins its line flush to the true bottom edge
    /// (`PlayerPageView`'s own `pinsToBottomEdge`), not `trackBoxHeight`
    /// above it, so the `+ 28` term — which existed only to clear that
    /// 28pt box's own height — no longer applies there: a plain 20pt
    /// gap from the page's own bottom edge already measures "20pt
    /// above the line" directly, once the line IS the bottom edge.
    /// Pose 5 is untouched — its own scrubber still rests at the top
    /// of its 28pt box, so it keeps the `20 + 28` sum unchanged.
    private func captionZone(leadingClearance: CGFloat = 16, trailingClearance: CGFloat, hidden: Bool, bandHeight: CGFloat) -> some View {
        let liftsForScrubber = duoLayout.pose != .regularPhone && bandHeight < 50
        let bottomPadding: CGFloat = duoLayout.pose == .closed ? 20 : (liftsForScrubber ? 20 + 28 : 20)
        // Mirrored-layout round: "caption bottom-trailing" — the
        // caption reads from the TRAILING edge instead, the SAME two
        // clearance values just reflected: `leadingClearance` (the
        // plain, small default every unmirrored caller leaves at 16)
        // becomes the TRAILING padding, and `trailingClearance` (the
        // caller's own rail/chrome-clearance amount) becomes the
        // LEADING padding, clearing the rail/chrome now sitting there
        // instead. Callers do not need their own mirrored branch —
        // they already compute "the small gap" and "the gap that
        // clears the rail" as two numbers; this is the one place that
        // decides which edge each lands on.
        let mirrored = duoLayout.isMirrored
        return captionTexts()
            .feedShadow()
            // Marked HERE, before `.frame(maxWidth: .infinity,
            // alignment: .leading)` just below — marking after that
            // frame reported the whole page (951×669 for pose 3, the
            // SAME chin/cloud mistake: an unconstrained expanding
            // frame with nothing downstream to size it back down).
            // Seen live only for a neighbour page caught mid pose
            // transition (this function does not even mount for the
            // active page once `usesDuoCaption` picks a different
            // caption), but the same structural bug regardless of
            // when it shows.
            .duoGuideMark("caption", color: .pink, active: isActive)
            .frame(maxWidth: .infinity, alignment: mirrored ? .trailing : .leading)
            .padding(mirrored ? .trailing : .leading, leadingClearance)
            .padding(.bottom, bottomPadding)
            .padding(mirrored ? .leading : .trailing, trailingClearance)
        // Keeps this block clear of the display's own rounded bottom
        // corner — reported on the open-wide (landscape, bar-on) pose,
        // where this caption sits flush at the window's leading edge
        // and the corner there is big enough to actually clip it. See
        // `FeedView.topChrome`'s identical `.containerCornerOffset`
        // for the API itself; a no-op everywhere the existing padding
        // and safe area already clear the corner on their own.
        .containerCornerOffset(.bottom)
        .opacity((isScrubbing || hidden) ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: isScrubbing)
        .animation(.easeOut(duration: 0.15), value: hidden)
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
        //
        // `hidden` folds in here too, for whichever future caller
        // passes `true` — see this function's own comment on `hidden`.
        .accessibilityHidden(hideForFullscreen || hidden)
        .accessibilityIdentifier(isActive && !hideForFullscreen && !hidden ? "feed_caption" : "")
        .accessibilityLabel(meta.placeText.map { "\($0). " + meta.voiceOverLabel } ?? meta.voiceOverLabel)
    }

    // MARK: - Pose 3/4/4W caption (build 4)

    /// Pose 3's own caption: off the video, bottom-leading at the
    /// PAGE's own edges — "leading 24, bottom 30" (`DUO_POSES.md`'s
    /// per-pose table) — rather than `captionZone`'s flow-based
    /// leading 16/bottom 20 inside the VStack every other pose
    /// shares. `maxWidth` clears the video's own leading edge by
    /// 40pt, computed from the TALL-video stage box
    /// (`duoLayout.stageRect`'s default aspect ratio) regardless of
    /// which video shape is actually loaded: this view has no way to
    /// read `PlayerPageView.videoIsLandscape` (a sibling view's own
    /// `@State`), and the per-pose table's own clamp is spelled out
    /// for the tall-video sub-case only. For the wide-video sub-case
    /// this is a deliberate approximation — a narrower caption than
    /// the table's own "under the video" row strictly needs, since
    /// that row names no clamp at all — accepted rather than plumbing
    /// the loaded video's shape across two views for one number;
    /// flagged for the owner's own look at the sim.
    ///
    /// Positioned the same way `actionRailColumn` already is: a
    /// target rect, `.frame(width:height:alignment:)` to give the
    /// text a well-defined box, then `.position(x: rect.midX, y:
    /// rect.midY)` — `.bottomLeading` alignment inside a box reaching
    /// from the page's own top to `H − 30` is what lands the text's
    /// OWN bottom-leading corner at `(24, H − 30)` regardless of its
    /// rendered height, with no need to measure that height first.
    private func duoOpenWideCaption(containerSize: CGSize, safeAreaTop: CGFloat) -> some View {
        // Mirrored-layout round: this caption sits off the video, on
        // the SAME bezel the stage itself touches — `openWideWideVideoBox`
        // already moves that bezel to the trailing edge when mirrored,
        // so this reads `stageMaxX` and the window's own trailing
        // margin instead of `stageMinX`/leading.
        let stage = duoLayout.stageRect(containerSize: containerSize, safeAreaTop: safeAreaTop)
        let mirrored = duoLayout.isMirrored
        let near: CGFloat = 24
        let width = max(0, mirrored ? (containerSize.width - stage.maxX - 40 - near) : (stage.minX - 40 - near))
        let rect = CGRect(x: mirrored ? containerSize.width - near - width : near, y: 0,
                           width: width, height: max(0, containerSize.height - 30))
        return captionTexts()
            .feedShadow()
            .frame(width: rect.width, alignment: mirrored ? .trailing : .leading)
            .opacity(isScrubbing ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: isScrubbing)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityHidden(hideForFullscreen)
            .accessibilityIdentifier(isActive && !hideForFullscreen ? "feed_caption" : "")
            .accessibilityLabel(meta.placeText.map { "\($0). " + meta.voiceOverLabel } ?? meta.voiceOverLabel)
            .frame(width: rect.width, height: rect.height, alignment: mirrored ? .bottomTrailing : .bottomLeading)
            .position(x: rect.midX, y: rect.midY)
            .duoGuideMark("caption", color: .pink, active: isActive)
    }

    /// Pose 4/4W's own caption: the right page, "leading
    /// `rightPage.minX + 20`" (`DUO_POSES.md`). Renders nothing when
    /// `DuoLayout.rightPage` itself is `nil` (no active division this
    /// frame). No `maxWidth` clamp in the per-pose table here: the
    /// right page's own trailing edge (the rail/bar or chrome column
    /// beyond it) already bounds the available width the same way
    /// `captionZone`'s `trailingClearance` bounds every other pose's
    /// caption, so `rightPage.maxX` is the clamp.
    ///
    /// Owner re-adapt (pose pass): was bottom-anchored at the screen's
    /// own bottom edge ("bottom 30"); the wireframe puts it directly
    /// UNDER the grid instead, a small gap below the last tile row.
    ///
    /// Owner re-adapt (pose pass, second round): `duoRightGridBottomY`
    /// — see `FeedView`'s own property of that name — replaces an
    /// earlier version that read an async singleton `DuoRightPage
    /// .reload()` published by hand; that value could lag or race a
    /// page change and leave this reading stale data, the owner's own
    /// "sits at the bottom, not under the grid" report. This one comes
    /// from a `GeometryReader`/`PreferenceKey` pair instead — always
    /// whatever `DuoRightPage`'s own grid is actually showing, this
    /// frame, never stale. Falls back to the old screen-bottom anchor
    /// only when nothing has ever laid out yet (this launch's first
    /// frame), or the grid came back empty.
    @ViewBuilder
    private func duoBookCaption(containerSize: CGSize, safeAreaTop: CGFloat) -> some View {
        if let rightPage = duoLayout.rightPage(containerSize: containerSize, safeAreaTop: safeAreaTop) {
            // Review fix (finding 4): `rightPage` itself already flips
            // which physical side it occupies when mirrored (grid on
            // the LEFT instead of the right — see that function's own
            // comment), so `rightPage.minX`/`.maxX` swap which edge is
            // "near the fold" and which is "the window's own outer
            // edge" too. Unmirrored, `rightPage.minX` is the fold-
            // adjacent edge (the wireframe's own `rightPage.minX + 20`)
            // and `rightPage.maxX` is the outer edge, bare, no inset.
            // Mirrored, that is reversed: `rightPage.maxX` is now the
            // fold-adjacent edge (gets the 20pt inset instead) and
            // `rightPage.minX` is the outer edge (stays bare) — using
            // the unmirrored formula's bare `rightPage.minX + 20` here
            // would have inset the wrong (outer) edge by 20pt and left
            // the fold-adjacent edge at the bare `rightPage.maxX`,
            // the exact opposite of "sits near the fold." A plain
            // value closure, like `duoLaptopCaption`'s own
            // `(leading, trailing)` — not an `if/else` written directly
            // in this `@ViewBuilder` body, which the builder would try
            // to read as a view branch (`duoLaptopCaption`'s own
            // comment on this exact pattern).
            let (leading, width): (CGFloat, CGFloat) = {
                if duoLayout.isMirrored {
                    let trailing = rightPage.maxX - 20
                    return (rightPage.minX, max(0, trailing - rightPage.minX))
                }
                let leading = rightPage.minX + 20
                return (leading, max(0, rightPage.maxX - leading))
            }()
            let captionHeight: CGFloat = 40
            let top = duoRightGridBottomY.map { $0 + 16 } ?? max(0, containerSize.height - 30 - captionHeight)
            let rect = CGRect(x: leading, y: top, width: width, height: captionHeight)
            captionTexts()
                .feedShadow()
                .frame(width: rect.width, alignment: duoLayout.isMirrored ? .trailing : .leading)
                .opacity(isScrubbing ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: isScrubbing)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityHidden(hideForFullscreen)
                .accessibilityIdentifier(isActive && !hideForFullscreen ? "feed_caption" : "")
                .accessibilityLabel(meta.placeText.map { "\($0). " + meta.voiceOverLabel } ?? meta.voiceOverLabel)
                .frame(width: rect.width, height: rect.height, alignment: duoLayout.isMirrored ? .topTrailing : .topLeading)
                .position(x: rect.midX, y: rect.midY)
                .duoGuideMark("caption", color: .pink, active: isActive)
        }
    }

    // MARK: - Pose 6 (laptop) caption + rail (build 8b)

    /// Pose 6's own caption, in the shared bottom deck's own band 0
    /// (`design/duo/duo_build_spec.md` §2.6) — the same
    /// `.bottomLeading`-positioned-rect technique `duoOpenWideCaption`/
    /// `duoBookCaption` already use, so the text's own natural height
    /// never has to be hand-measured. Renders nothing when
    /// `DuoLayout.laptopCaptionBottomY` is `nil` (no active division
    /// this frame).
    ///
    /// Owner re-adapt (round 4): "put the filters in the top right of
    /// the bottom section, across and aligned from the date and
    /// time." This row now has a second occupant — the Mute/Filter/
    /// Bin group (`FeedView.laptopDeckControls`) — so it can no
    /// longer claim the row's whole width. Unmirrored, `trailing` stops
    /// short of the group's own real left edge
    /// (`laptopControlGroupFrame.minX`, a live measurement — see that
    /// property's own comment), with `DuoLayout.pagePad` clear between
    /// them; mirrored, the caption reads from the TRAILING side
    /// instead, `leading` stopping short of the group's own real right
    /// edge (`.maxX`) the same way — see this function's own body.
    ///
    /// Owner re-adapt (round-4 review): the fallback for the one
    /// frame before the group has ever reported was the OLD
    /// near-full-width edge — wrong once the group actually has a
    /// trailing margin to fit inside. It is now that same trailing
    /// margin (`DuoLayout.laptopControlGroupTrailingX`) minus the
    /// group's own three-button width at rest (`3 * 44 + 2 * 12`,
    /// `Rail`'s own 44pt minimum tap target and the group's own 12pt
    /// `HStack` spacing) minus one more `pagePad` of clearance — the
    /// same number the real, measured edge converges to once it
    /// lands, so there is no visible jump between the guess and the
    /// real value. The date line's own `lineLimit(1)`/
    /// `minimumScaleFactor` (`captionTexts`) already does the actual
    /// truncating when it loses this race — "the group wins its
    /// space and the caption truncates," the owner's own call.
    ///
    /// Owner re-adapt (round-4 review): leading is `DuoLayout.pagePad`
    /// (16), not a locally hand-picked 24 — the wireframe's own "line
    /// up with the scrubber's left edge," which `laptopScrubberRect`
    /// already insets by `pagePad`. Top is `laptopScrubberRect.maxY +
    /// 8` — directly under the scrubber, the wireframe's own
    /// placement — not `laptopCaptionBottomY` (band 0's own bottom
    /// edge), which left a roughly 60pt dead gap between the scrubber
    /// and a bottom-anchored date line. The box still ends at
    /// `laptopCaptionBottomY`, now as its own bottom edge rather than
    /// the text's own anchor, so `.topLeading` places the text right
    /// under the scrubber instead of `.bottomLeading` pinning it to
    /// band 0's own far edge.
    @ViewBuilder
    private func duoLaptopCaption(containerSize: CGSize, safeAreaBottom: CGFloat) -> some View {
        if let scrubberRect = duoLayout.laptopScrubberRect(containerSize: containerSize, safeAreaBottom: safeAreaBottom),
           let bottomY = duoLayout.laptopCaptionBottomY(containerSize: containerSize, safeAreaBottom: safeAreaBottom) {
            // Mirrored-layout round: the group moved to the LEADING
            // side, so the caption now reads from the TRAILING side
            // instead — "caption + iCloud ring bottom-trailing," the
            // same opposite-the-rail principle as everywhere else.
            // `nearX` is `laptopControlGroupTrailingX`'s own value,
            // whichever edge it now measures from (see that
            // function's own comment); the `3 * 44 + 2 * 12` estimate
            // (`Rail`'s own 44pt tap target × 3 buttons, the group's
            // own 12pt `HStack` spacing × 2 gaps) is unchanged, only
            // which edge it is subtracted from or added to flips.
            let nearX = duoLayout.laptopControlGroupTrailingX(containerSize: containerSize, safeAreaBottom: safeAreaBottom)
            let groupWidthEstimate: CGFloat = 3 * 44 + 2 * 12
            // A plain closure, invoked at once: an `if/else` with no
            // trailing View expression, written directly in this
            // `@ViewBuilder` function's body, is read as a VIEW branch
            // by the builder and fails to type-check (`()` is not a
            // `View`) — this keeps the branch a plain value
            // computation, outside the builder's own transform.
            let (leading, trailing): (CGFloat, CGFloat) = {
                if duoLayout.isMirrored {
                    let fallbackLeading = (nearX ?? 0) + groupWidthEstimate + DuoLayout.pagePad
                    let leading = laptopControlGroupFrame.map { $0.maxX + DuoLayout.pagePad } ?? fallbackLeading
                    return (leading, containerSize.width - DuoLayout.pagePad)
                }
                let fallbackTrailing = (nearX ?? containerSize.width) - groupWidthEstimate - DuoLayout.pagePad
                let trailing = laptopControlGroupFrame.map { $0.minX - DuoLayout.pagePad } ?? fallbackTrailing
                return (DuoLayout.pagePad, trailing)
            }()
            let width = max(0, trailing - leading)
            let top = scrubberRect.maxY + 8
            let rect = CGRect(x: leading, y: top, width: width, height: max(0, bottomY - top))
            // Owner call (relayed, item 3): "caption right-aligned on
            // that line" once mirrored — the group sits on the LEFT of
            // band 0's own date line, so the caption now reads from
            // the RIGHT instead of the left, both the block's own
            // position (handled above, by `leading`/`trailing`) and
            // the TEXT's own reading edge within it.
            captionTexts(measureDateLineCenter: isActive)
                .feedShadow()
                .frame(width: rect.width, alignment: duoLayout.isMirrored ? .trailing : .leading)
                .opacity(isScrubbing ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: isScrubbing)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityHidden(hideForFullscreen)
                .accessibilityIdentifier(isActive && !hideForFullscreen ? "feed_caption" : "")
                .accessibilityLabel(meta.placeText.map { "\($0). " + meta.voiceOverLabel } ?? meta.voiceOverLabel)
                .frame(width: rect.width, height: rect.height, alignment: duoLayout.isMirrored ? .topTrailing : .topLeading)
                .position(x: rect.midX, y: rect.midY)
                .duoGuideMark("caption", color: .pink, active: isActive)
        }
    }

    /// Pose 6's own horizontal action rail, centred in
    /// `DuoLayout.laptopRailRow`'s own band — the same five buttons
    /// `actionRail`/`actionRailColumn` draw everywhere else, this time
    /// at that row's own points — per-page, like every other pose's
    /// rail, since it describes the current item, not the screen (see
    /// `FeedView.laptopDeckControls`'s own comment on which pieces of
    /// §2.6 are global instead). The vertical hairline at
    /// `hairlineX`/`hairlineY` is this row's own divider, between
    /// Delete and the chin, clamped to `Rail.itemHeight` tall — owner
    /// re-adapt: "a SHORT divider only as tall as the rail row," not
    /// the whole deck (the first build's own bug, spanning
    /// `bottom.height` and cutting through the Next pill below it).
    @ViewBuilder
    private func laptopHorizontalRail(containerSize: CGSize, safeAreaBottom: CGFloat) -> some View {
        if let row = duoLayout.laptopRailRow(containerSize: containerSize, safeAreaBottom: safeAreaBottom),
           row.centers.count == 5 {
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: Rail.itemHeight)
                .position(x: row.hairlineX, y: row.hairlineY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            likeButton(rail).position(row.centers[0])
                .duoGuideMark("rail.keep", color: .indigo, active: isActive)
            shareButton.position(row.centers[1])
                .duoGuideMark("rail.share", color: .indigo, active: isActive)
            albumButton.position(row.centers[2])
                .duoGuideMark("rail.album", color: .indigo, active: isActive)
            shrinkButton(rail).position(row.centers[3])
                .duoGuideMark("rail.shrink", color: .indigo, active: isActive)
            deleteButton(rail).position(row.centers[4])
                .duoGuideMark("rail.delete", color: .indigo, active: isActive)
        }
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
        // Mirrored-layout round (item D, left-handed regular iPhone):
        // the whole point of the setting — the rail itself moves to
        // the LEADING edge. No rail COLUMN exists here (this is the
        // pre-Duo overlay, `railColumnRect == nil`), so this is the
        // one place that reads `isMirrored` directly rather than
        // through `DuoLayout.railColumn`'s own edge.
        VStack(spacing: Rail.spacing) {
            likeButton(rail)
            shareButton
            albumButton
            shrinkButton(rail)
            deleteButton(rail)
        }
        .padding(duoLayout.isMirrored ? .leading : .trailing, 10)
        .padding(.bottom, bottomBand + Rail.seamClearance)
    }

    /// `actionRail`'s column layout (steps 3/5): the same five
    /// buttons, the same `Rail.spacing`, placed inside the rail
    /// column instead of over the stage.
    ///
    /// X-centred on `DuoLayout.ringCenteredColumnX` — on the closed
    /// bar, the ring's own real `.occlusion` midX (owner re-adapt,
    /// pose pass: the bar rect's own naive midpoint sat measurably off
    /// the real ring — see that function's own comment for the
    /// measured numbers); on the open-tall column,
    /// `DuoLayout.railColumn`'s own open-branch already centres the
    /// column on the same `.occlusion` midX by construction (F6), so
    /// this reads the same value there too, just by a different route.
    ///
    /// Anchored top or bottom per `DuoLayout.railVerticalExtent`, not
    /// decided here: bar ON anchors from the bottom (the ring sits
    /// above the rail there, with no SDK API to say by how much, but
    /// the chin's own position below is exactly known); bar OFF
    /// (open-tall) anchors from the top, flush with the stage's own
    /// top edge, since in THAT pose the ring sits above the whole
    /// stage rather than above the rail specifically — an earlier
    /// version bottom-anchored this pose too and left a dead gap above
    /// the rail, which was the owner's own report.
    ///
    /// `rect` is in `FeedPageContent.body`'s own `GeometryReader`
    /// coordinate space — the same space `captionZone` and
    /// `pageFactsProbe` already render in — so `.position(x:y:)`
    /// below lands this exactly on `rect` without needing its own
    /// `GeometryReader`. `containerSize` is that same reader's
    /// `proxy.size`, needed separately because `railVerticalExtent`
    /// measures from the page's own top and bottom, not from `rect`.
    private func actionRailColumn(rect: CGRect, containerSize: CGSize) -> some View {
        let extent = duoLayout.railVerticalExtent(containerSize: containerSize, safeAreaTop: safeAreaTop, safeAreaBottom: safeAreaBottom)
        let top = extent?.top ?? 0
        let centerX = duoLayout.ringCenteredColumnX(containerSize: containerSize, safeAreaTop: safeAreaTop) ?? rect.midX
        return VStack(spacing: extent?.spacing ?? Rail.spacing) {
            if isActive, let calloutMessage = shareCoordinator.calloutMessage {
                railCallout(calloutMessage)
            }
            likeButton(rail)
                .duoGuideMark("rail.keep", color: .indigo, active: isActive)
            shareButton
                .duoGuideMark("rail.share", color: .indigo, active: isActive)
            albumButton
                .duoGuideMark("rail.album", color: .indigo, active: isActive)
            shrinkButton(rail)
                .duoGuideMark("rail.shrink", color: .indigo, active: isActive)
            deleteButton(rail)
                .duoGuideMark("rail.delete", color: .indigo, active: isActive)
        }
        .animation(.easeInOut(duration: 0.2), value: shareCoordinator.calloutMessage)
        .padding(.top, top)
        .frame(width: rect.width, height: rect.height, alignment: .top)
        .position(x: centerX, y: rect.midY)
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
