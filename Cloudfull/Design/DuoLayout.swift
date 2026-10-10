//
//  DuoLayout.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Which of the iPhone Duo's physical poses this frame is in — see
/// `design/DUO_POSES.md` for the pictures and names this mirrors.
/// `classify(...)` (below `DuoLayout.current`) is the one place that
/// derives this from the SDK's own geometry; nothing else in the app
/// re-derives a pose from raw hinge/size-class/window values, so every
/// pose fix lands in one function.
///
/// `.regularPhone` is also the value a regular iPhone — and any OS
/// below iOS 27.1 — always reports (`DuoLayout.none.pose`), which is
/// what keeps every `pose != .regularPhone` gate a true no-op there.
enum DuoPose: String {
    case regularPhone, closed, tent, openWide, book, openTall, laptop
}

/// A plain mirror of `DeviceHinge.Status` (`.closed`/`.partiallyOpen`/
/// `.fullyOpen`), kept as its own stored-property-friendly enum because
/// `DeviceHinge.Status` itself is `@available(iOS 27.1, *)` — see
/// `ToolbarVerticalEdgeReader`'s own comment on why an `@available` type
/// cannot back a stored property on a type whose deployment target is
/// lower. `HingeReader` below is the one place that converts between the
/// two.
enum DuoHingeStatus: String {
    case closed, partial, full
}

/// One frame's worth of iPhone Duo geometry, read once per feed from the
/// root `GeometryProxy` and the environment, then threaded down through
/// parameters exactly the way `safeAreaTop` already is (see
/// `FeedView.body`'s own `GeometryReader`). Every consumer in that frame
/// gets the same numbers; nothing downstream re-measures on its own.
///
/// On a regular iPhone — and on any OS below iOS 27.1, where the iPhone
/// Duo APIs this type reads do not exist — every field is the plain
/// "no Duo furniture" value: `barEdge` is `nil`, `barWidth` is 0, both
/// reserved-region frames are `nil`. `isClosedBar` is then `false` and
/// `availableRect`/`stageRect` return the full container, so a caller
/// that plugs this struct's numbers into its own geometry gets back
/// exactly what it would have computed without this type existing. That
/// is what keeps regular iPhones pixel-identical to `main`: only
/// `current(proxy:toolbarVerticalEdge:)`, the one spot that calls the
/// new SDK, needs `#available`.
struct DuoLayout {
    /// Which edge the system vertical bar (the closed Duo's time +
    /// connectivity column) sits on, from
    /// `EnvironmentValues.toolbarVerticalEdge`. Non-nil means the bar is
    /// showing — the iPhone Duo's closed screen today, nothing else.
    /// `nil` on a regular iPhone and on an open Duo.
    let barEdge: HorizontalEdge?

    /// The bar's own width: the matching leading/trailing safe-area
    /// inset on `barEdge`'s side. Zero whenever `barEdge` is `nil`.
    let barWidth: CGFloat

    /// The first active `.occlusion` reserved region this frame reports
    /// (the inner camera), or `nil` when none is active.
    let occlusion: CGRect?

    /// The first active `.division` reserved region this frame reports
    /// (the fold), or `nil` when the device is not partially open.
    let division: CGRect?

    /// This frame's classified pose — see `DuoPose` and `classify(...)`
    /// below. Every new Duo branch gates on `pose != .regularPhone`
    /// (spec hard rule), never on `barEdge`/`division`/`hinge`
    /// directly, so a regular iPhone's path is decided by this one
    /// field.
    let pose: DuoPose

    /// A plain mirror of `DeviceHingeContext.hinge?.status`, read by
    /// `HingeReader` and threaded down the same way `barEdge` already
    /// is. `nil` until the first `onHingeChange` delivery, which has no
    /// `initial:` parameter — see `HingeReader`'s own comment — or on a
    /// device/OS with no hinge at all.
    let hinge: DuoHingeStatus?

    /// `DeviceHinge.angle.degrees` alongside `hinge`, for the
    /// `-cloudfull-log-rotation` probe only; nothing in `classify(...)`
    /// reads this, only `hinge` itself.
    let hingeDegrees: Double?

    /// `barEdge != nil`. The spelling most call sites reach for when all
    /// they need is the yes/no, not which edge.
    var isClosedBar: Bool { barEdge != nil }

    /// The "no Duo furniture" value: every field at its plain default.
    /// A regular iPhone's `FeedView`/`PhotoFeedView` can hand this
    /// straight to a child that expects a `DuoLayout` without ever
    /// calling `current(proxy:toolbarVerticalEdge:horizontalSizeClass:verticalSizeClass:hinge:hingeDegrees:)`.
    /// `pose` is `.regularPhone` here — the hard rule every new branch
    /// gates on.
    static let none = DuoLayout(barEdge: nil, barWidth: 0, occlusion: nil, division: nil,
                                pose: .regularPhone, hinge: nil, hingeDegrees: nil)

    /// Reads this frame's Duo geometry from `proxy` and the
    /// already-resolved `toolbarVerticalEdge` environment value.
    ///
    /// Call this once, at the same root `GeometryReader` that already
    /// measures `safeAreaTop`, and thread the result down as a
    /// parameter. The caller reads `toolbarVerticalEdge` itself (an
    /// `@Environment(\.toolbarVerticalEdge)` property gated the same
    /// way), because that key only exists from iOS 27.1 and an
    /// `EnvironmentValues` extension cannot be read from inside a
    /// plain, unavailable-gated function — only from a View's own
    /// environment-reading context.
    /// `horizontalSizeClass`, `verticalSizeClass`, and `hinge` are the
    /// classifier's three extra inputs — see `classify(...)` below for
    /// what each decides. The caller reads all three itself
    /// (`@Environment(\.horizontalSizeClass)`, `@Environment(\.verticalSizeClass)`,
    /// and `HingeReader`'s stored state) for the same reason it already
    /// reads `toolbarVerticalEdge` itself: only a View's own
    /// environment/state context can read them.
    ///
    /// There is no `stanceIsLandscape`/device-orientation input here —
    /// the owner's Apple-checklist audit (`design/duo/duo_audit_apple_checklist.md`,
    /// Decision B) replaced it with the window's own shape
    /// (`proxy.size`), which `classify(...)` already has from
    /// `containerSize`. No layout in this app reads device orientation.
    @available(iOS 27.1, *)
    static func current(
        proxy: GeometryProxy,
        toolbarVerticalEdge: HorizontalEdge?,
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        hinge: DuoHingeStatus?,
        hingeDegrees: Double?
    ) -> DuoLayout {
        let insets = proxy.safeAreaInsets
        let width: CGFloat
        switch toolbarVerticalEdge {
        case .leading: width = insets.leading
        case .trailing: width = insets.trailing
        case nil: width = 0
        }
        // The default query (no `.includeInactive`) already reports only
        // active regions, but the explicit filter documents that intent
        // at the call site and costs nothing if the SDK's default ever
        // changes.
        let occlusionFrame = proxy.reservedRegions(kind: .occlusion).first(where: \.isActive)?.frame
        // Build 1 fix: the owner's own sim readings caught a division
        // frame from the INNER display's own coordinate space (669 pt
        // wide) reported once while this frame's own window was still
        // the OUTER display's compact 466-pt one — a stale cross-display
        // reading, one layout pass behind the window size that already
        // changed. Such a frame does not fit inside this frame's own
        // window at all (its far edge lands past this window's own
        // edge), so `book`/`laptop`'s `division.height > division.width`
        // test must never see it: a plain `nil` here, same as "no fold
        // active," is what every other `division` reader downstream
        // (`DuoLayout.division` itself, and anything that reads it off
        // this frame's `DuoLayout`) already expects. `CGRect.contains`
        // is the containment test — not `intersects`, which the bad
        // frame above would still pass, since its leading edge does
        // overlap this window's own leading edge even though its
        // trailing edge does not.
        let windowBounds = CGRect(origin: .zero, size: proxy.size)
        let rawDivisionFrame = proxy.reservedRegions(kind: .division).first(where: \.isActive)?.frame
        let divisionFrame = rawDivisionFrame.flatMap { (frame: CGRect) -> CGRect? in
            windowBounds.contains(frame) ? frame : nil
        }
        let pose = classify(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            containerSize: proxy.size,
            division: divisionFrame,
            barEdge: toolbarVerticalEdge,
            hinge: hinge
        )
        return DuoLayout(
            barEdge: toolbarVerticalEdge,
            barWidth: toolbarVerticalEdge == nil ? 0 : width,
            occlusion: occlusionFrame,
            division: divisionFrame,
            pose: pose,
            hinge: hinge,
            hingeDegrees: hingeDegrees
        )
    }

    /// The pose classifier — "classify from the space we have" (Decision
    /// B, `design/duo/duo_audit_apple_checklist.md` §4), replacing an
    /// earlier version that read `horizontalSizeClass == .regular` alone
    /// as "this is the Duo's inner display." The owner's Apple-checklist
    /// audit flagged that as its own rule violation (F2: "size class does
    /// not identify the device") — a 17 Pro resized large enough in
    /// iPhone Mirroring also reads `.regular` width, so a single-axis
    /// test alone can misclassify a resizable window as an open Duo. This
    /// function reads geometry and traits only, never a device name or
    /// which physical display is active, in a fixed order where each
    /// rule decides only what the signal in front of it can actually
    /// prove:
    ///
    /// 1. An active `division` means the device is partially open —
    ///    checked ahead of any size-class test, since the division
    ///    reserved region only ever appears there, on either display, at
    ///    any size class. A division taller than it is wide is the fold
    ///    read top-to-bottom (a book spine down the middle): `.book`. A
    ///    division wider than tall is the fold read left-to-right (a
    ///    laptop hinge along the bottom): `.laptop`. See this file's
    ///    "Fold-orientation check" in the build spec for the 951×669 /
    ///    669×951 arithmetic this falls out of.
    /// 2. No division, a `.partial` hinge, and a window wider than it is
    ///    tall is the tent (pose 2) — a nightstand candidate; until the
    ///    nightstand actually engages, it still lays out like rule 4
    ///    below. The window's own shape (`containerSize`) is what
    ///    decides this, not a device stance: Apple's own rule (F1, this
    ///    file's header comment) is no layout from device orientation,
    ///    and real interface rotation (the audit's Decision A) already
    ///    makes `containerSize.width > containerSize.height` the
    ///    correct, geometry-only reading of "this window is sideways" —
    ///    nothing here reads `UIDevice.current.orientation` or a
    ///    `Stance`.
    /// 3. No division, no tent: BOTH size classes regular at once is the
    ///    fully-open case — `.openWide` if the window is wider than
    ///    tall, else `.openTall`. Both axes together, not
    ///    `horizontalSizeClass` alone (F2's own fix): a landscape window
    ///    that is wide but not also tall enough to read `.regular` in
    ///    height (a short Mirroring window, or the Duo's own OUTER
    ///    display, which never goes `.regular` in either axis) falls
    ///    through to rule 4 instead, same as a regular iPhone would.
    /// 4. Anything else — any compact axis, on either size class — is
    ///    the phone family: `.closed` when there is Duo furniture to say
    ///    so (`barEdge` or a non-nil `hinge`), else a plain
    ///    `.regularPhone`. A regular iPhone's own window reads compact
    ///    in at least one axis in every orientation, so it can never
    ///    reach rules 1–3 at all — decided purely by its own proportions
    ///    and traits, never by a name.
    private static func classify(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        containerSize: CGSize,
        division: CGRect?,
        barEdge: HorizontalEdge?,
        hinge: DuoHingeStatus?
    ) -> DuoPose {
        if let division {
            return division.height > division.width ? .book : .laptop
        }
        if hinge == .partial, containerSize.width > containerSize.height {
            return .tent
        }
        if horizontalSizeClass == .regular, verticalSizeClass == .regular {
            return containerSize.width > containerSize.height ? .openWide : .openTall
        }
        if barEdge != nil || hinge != nil {
            return .closed
        }
        return .regularPhone
    }

    /// The rectangle, inside a container of `containerSize`, that
    /// excludes the rail column — see `railColumn(containerSize:safeAreaTop:)`
    /// for what that is in each case. Anything that must stay clear of
    /// it — `stageRect` below — uses this instead of the full
    /// container.
    ///
    /// Deliberately does NOT also reserve the top chrome's own band
    /// out of the height, for either column source: the owner's own
    /// review of the open-tall pose asked for exactly the opposite —
    /// "pose 5 should pretty much look like pose 1" — where the top
    /// chrome OVERLAYS the video's own top edge, the same as every
    /// other pose, rather than pushing the video down into its own
    /// band below a separate chrome row. An earlier version reserved
    /// that band here specifically for the open column, once its width
    /// stopped doing so as a side effect of being sized to "whatever a
    /// 9:16 stage leaves over" (see `railColumn`'s own comment on its
    /// open branch for why that sizing changed); this undoes that
    /// reservation, so the open column now behaves exactly like the
    /// closed bar column
    /// already did — no height carve-out, chrome overlaid on the
    /// stage, `StageGeometry.downShift`'s own small natural band (from
    /// the stage's own aspect ratio) the only clearance either case
    /// ever gets.
    ///
    /// Returns the full container unchanged when no column applies, so
    /// a regular iPhone's math is untouched.
    func availableRect(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect {
        guard let column = railColumn(containerSize: containerSize, safeAreaTop: safeAreaTop) else {
            return CGRect(origin: .zero, size: containerSize)
        }
        switch column.edge {
        case .leading:
            return CGRect(x: column.width, y: 0,
                          width: max(0, containerSize.width - column.width),
                          height: containerSize.height)
        case .trailing:
            return CGRect(x: 0, y: 0,
                          width: max(0, containerSize.width - column.width),
                          height: containerSize.height)
        }
    }

    /// The largest `aspectRatio` (width ÷ height) box that fits inside
    /// `availableRect(containerSize:safeAreaTop:)`, centred there.
    /// Defaults to 9:16 (`9.0 / 16.0`), the fixed portrait video stage
    /// every call site but one still wants.
    ///
    /// On a regular iPhone `availableRect` is the full container, which
    /// is always taller (relative to its width) than the default 16:9,
    /// so this reduces to the old width-derived box exactly: `width` is
    /// the binding side there, matching `PlayerPageView`'s pre-Duo
    /// stage. On the Duo's closed screen, once the bar column is
    /// excluded, height can become the binding side instead, which is
    /// what keeps the stage from overflowing the squat screen. On an
    /// open Duo wide enough for a computed column (same function), this
    /// same centring is what turns the leftover width, once
    /// `railColumn`'s own computed column is removed from it, into even
    /// margins on both sides of the stage — see that function's own
    /// open-branch comment for why that is the goal, not a flush-left
    /// stage.
    ///
    /// The non-default `aspectRatio` is step 6's own addition: an open
    /// Duo turned sideways really rotates its window (see
    /// `PlayerPageView.windowIsLandscape`), and a horizontal video
    /// shown there must FIT its own shape, not the portrait stage every
    /// other screen wants. `PlayerPageView.body` passes the loaded
    /// video's real aspect ratio exactly when that applies, and the
    /// default everywhere else.
    ///
    /// Build 3 addition: `.openWide` and `.book` get their own stage
    /// box once `aspectRatio >= 1` — a landscape video, the only case
    /// `PlayerPageView.useVideoAspect` ever passes a non-default
    /// `aspectRatio` for — matching the round-3 wireframes
    /// (`DUO_POSES.md`, pose 3/4W rows): the chrome column and (for
    /// `.book`) the fold both carve space this function's generic
    /// `availableRect` path has no way to know about, since that path
    /// only ever excludes the rail/bar column. `aspectRatio >= 1`
    /// (never read outside this function) is the one signal available
    /// here for "this is the landscape-video sub-case," so the
    /// function stays a drop-in replacement at its one call site
    /// rather than growing a second parameter every caller would need
    /// to pass. `.openWide`'s own TALL-video case (the default
    /// `aspectRatio`) falls through to the generic `availableRect`
    /// path unchanged — see `openWideWideVideoRect`'s own comment for
    /// why that case already reads correctly from the generic math,
    /// with nothing special to do. `.book`'s own TALL-video case
    /// does need its own box, just not its own named function: "FIT
    /// 9:16 full height, centred in `[0, division.minX]`" below —
    /// `division.minX`, not the bar column, is what bounds the left
    /// page, since the fold sits well inside where the bar column
    /// would start to matter.
    func stageRect(containerSize: CGSize, safeAreaTop: CGFloat, aspectRatio: CGFloat = 9.0 / 16.0) -> CGRect {
        if pose == .openWide, aspectRatio >= 1 {
            return openWideWideVideoRect(containerSize: containerSize, safeAreaTop: safeAreaTop, aspectRatio: aspectRatio)
        }
        if pose == .book, let division {
            return aspectRatio >= 1
                ? bookWideVideoRect(division: division, containerSize: containerSize, aspectRatio: aspectRatio)
                : fitRect(in: CGRect(x: 0, y: 0, width: max(0, division.minX), height: containerSize.height),
                          aspectRatio: aspectRatio)
        }
        let avail = availableRect(containerSize: containerSize, safeAreaTop: safeAreaTop)
        return fitRect(in: avail, aspectRatio: aspectRatio)
    }

    /// The largest `aspectRatio` box that fits inside `box`, centred
    /// there — the one FIT formula every stage-rect case in this file
    /// shares, pulled out once `stageRect` grew pose-specific boxes of
    /// its own to fit (build 3) rather than only ever `availableRect`'s.
    private func fitRect(in box: CGRect, aspectRatio: CGFloat) -> CGRect {
        guard box.width > 0, box.height > 0 else { return box }
        let height = min(box.height, box.width / aspectRatio)
        let width = height * aspectRatio
        return CGRect(
            x: box.minX + (box.width - width) / 2,
            y: box.minY + (box.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// Pose 3's wide-video stage box (build 3): "FIT video aspect in
    /// `[16, W − bar − 80 − 16] × [0, H − captionBand]`, centred" —
    /// the wireframe's own words for excluding BOTH the rail/bar
    /// column and the new chrome column (`chromeColumnWidth`, the
    /// Mute/Filter/Bin column `zigzagCenters` places buttons in),
    /// `pagePad` clear on each side, with `captionBand` reserved at
    /// the bottom for the caption now sitting under the video instead
    /// of on it (see the per-pose table's pose-3-wide-video row).
    ///
    /// Pose 3's TALL-video case (the default `aspectRatio`, handled by
    /// `stageRect`'s own fallthrough to `availableRect`) needs none of
    /// this: `availableRect` already excludes only the bar column, and
    /// `fitRect`'s height-first binding on that wider box already
    /// reduces to "FIT 9:16, full height" — the chrome column and
    /// caption band never come into it, because a tall video's own
    /// FIT box is already narrower than the leftover before either
    /// would ever bind. Confirmed algebraically: at this window's own
    /// proportions, `avail.width / (9/16)` is always well over
    /// `avail.height`, so height is always the binding side there.
    private func openWideWideVideoRect(containerSize: CGSize, safeAreaTop: CGFloat, aspectRatio: CGFloat) -> CGRect {
        let column = railColumn(containerSize: containerSize, safeAreaTop: safeAreaTop)
        let barWidth = column?.width ?? 0
        let edge = column?.edge ?? .trailing
        let pad = Self.pagePad
        let excluded = barWidth + Self.chromeColumnWidth
        let availableWidth = max(0, containerSize.width - excluded - pad * 2)
        let minX: CGFloat
        switch edge {
        case .trailing: minX = pad
        case .leading: minX = excluded + pad
        }
        let box = CGRect(x: minX, y: 0, width: availableWidth,
                          height: max(0, containerSize.height - Self.captionBand))
        return fitRect(in: box, aspectRatio: aspectRatio)
    }

    /// Pose 4W's stage box (build 3): "width `division.minX − 32`, x
    /// = 16, centred on H" — a WIDTH-first box, not a FIT-into-box
    /// one like every other case in this file: the left page's own
    /// width is fixed first (`division.minX`, `pagePad` clear on each
    /// side of that span), then the height follows from `aspectRatio`
    /// alone, centred vertically in the full window height. This
    /// differs from `fitRect` deliberately — a FIT box here could
    /// bind on height first for a near-square `division.minX`, which
    /// would narrow the video below the wireframe's own fixed width.
    private func bookWideVideoRect(division: CGRect, containerSize: CGSize, aspectRatio: CGFloat) -> CGRect {
        let width = max(0, division.minX - Self.pagePad * 2)
        let height = width / aspectRatio
        return CGRect(x: Self.pagePad, y: (containerSize.height - height) / 2, width: width, height: height)
    }

    // MARK: - Pose-table constants (build 3)
    //
    // Every number below is "measured/wireframe, no API" — read off
    // `DUO_VIDEO_WIREFRAMES.png`/`DUO_POSES.md`, not any SDK property.
    // There is no reserved-region kind, margin, or trait for a chrome
    // column, a caption band, a page margin, or a chin's own size;
    // Apple's hinge/division/occlusion API (this file's header comment)
    // says nothing about any of them. These are plain design constants,
    // the same category `Rail.hit`/`Rail.spacing` already are —
    // unlike the ring's own position, which `railColumn`'s open branch
    // now reads from `.occlusion` instead of a fixed number (F6, §5 of
    // the audit).

    /// Width of the Mute/Filter/Bin column pose 3/4/4W put beside the
    /// rail/bar column — `chromeColumnRect`'s own width, and
    /// `zigzagCenters`'s own x.
    static let chromeColumnWidth: CGFloat = 80
    /// Height reserved at a wide video's own bottom edge for its
    /// caption, pose 3's wide-video case only (`openWideWideVideoRect`).
    static let captionBand: CGFloat = 100
    /// A page margin, used wherever the wireframe leaves a plain 16pt
    /// clearance rather than reusing an existing gap constant — pose
    /// 3's wide-video box, pose 4W's box, and (elsewhere) the caption
    /// and right-page placements build 4 and later add.
    static let pagePad: CGFloat = 16
    /// Pose 6's (laptop) horizontal rail row: the x-spacing between
    /// consecutive buttons — build 8.
    static let laptopRailPitch: CGFloat = 100
    /// Pose 6's horizontal rail row: the x of its first button — build 8.
    static let laptopRailLead: CGFloat = 70
    /// Pose 5's chin: the gap above its own top edge, clear of the
    /// rail's last button — build 7.
    static let chinColumnGap: CGFloat = 40
    /// Pose 5's chin: its own size once expanded in its column —
    /// build 7.
    static let columnChinSize: CGFloat = 56

    // MARK: - Rail column (step 3; extended by steps 4, 5, and the pose fixes)
    //
    // The action rail (Keep, Share, Album, Shrink, Delete) moves off
    // the stage and into its own column whenever one exists. The
    // column itself comes from one of two sources, and every function
    // below reads only `railColumn(containerSize:safeAreaTop:)` — never
    // `barEdge`/`barWidth` directly — so the closed-bar case (step 3)
    // and the open, computed case (step 5) share this one definition
    // end to end (`availableRect`, the stage, the rail, the chin).

    /// The width a 9:16 stage would need to claim this container's
    /// bare full height — no top-chrome reservation; see
    /// `availableRect`'s own comment on why the open column does not
    /// carve one out. The one formula `railColumn`'s own gate (below)
    /// is built on.
    private static func fullHeightStageWidth(containerSize: CGSize) -> CGFloat {
        containerSize.height * 9 / 16
    }

    /// Re-adapted (`design/duo/duo_audit_apple_checklist.md` §5/F6):
    /// replaces the old `ringInset`/`openColumnWidth` pair — a fixed
    /// 50pt/100pt read off one Duo-sim screenshot, which drifts off the
    /// real ring in a Mirroring window, another display, or a larger
    /// Dynamic Type size (F6's own finding). The open (bar-off)
    /// column's own width is now derived live, in `railColumn` below:
    /// from the active `.occlusion` region's own `midX` when one is on
    /// the trailing half (the ring/status cluster's real measured
    /// position, the same field `statusBlock` already reads for pose
    /// 5), or from `Rail.hit` (the button's own hit target, a design
    /// constant, not a device size) plus this margin when there is
    /// none to read.
    ///
    /// Also the minimum leading margin `railColumn`'s open-branch gate
    /// guarantees the stage, on each side, once the computed column is
    /// removed from the natural leftover. See that function's own gate
    /// for the arithmetic.
    static let minStageMargin: CGFloat = 16

    /// Pose 1V's own status-cluster lower bound — owner ask: "can the
    /// rail be higher? Shift Delete through Keep up as a whole,"
    /// answered by centring the rail in the column's own full height,
    /// clamped so its own top edge never rises above this + 16pt (see
    /// `railVerticalExtent`'s own `isClosedBar` branch).
    ///
    /// Reads the active `.occlusion` region directly when this frame
    /// reports one, filtered to frames genuinely inside this window
    /// (`windowBounds.contains`, the same cross-display staleness
    /// guard `DuoLayout.current` already applies to `division` — only
    /// one display is ever active in pose 1V, so no `minX`-based side
    /// check like `statusBlock`'s own is needed here). Falls back to
    /// `safeAreaTop` alone, no added constant, when there is none to
    /// read: a documented, deliberately conservative choice — the one
    /// real, API-reported value this frame has for "how much the
    /// system reserves at this display's own top edge" — rather than
    /// an invented pixel number.
    ///
    /// Unverified against real hardware: an EARLIER version of this
    /// rail's own anchor (since replaced, then replaced again here)
    /// was top-anchored from exactly this pair of signals
    /// (`.occlusion`/`safeAreaTop`), and on a real closed Duo screen it
    /// undershot the system's own time + connectivity ring — there is
    /// no SDK API for that cluster's own extent — so the rail's first
    /// button (Keep) rendered partly under it. This change carries the
    /// same risk if the signal undershoots again; the owner's own ask
    /// to confirm this via `-cloudfull-log-rotation`'s `occ-`/`hSC`/
    /// `vSC` fields on a REAL closed Duo screen, not just the
    /// simulator, is exactly the right check before trusting this.
    private func closedStatusBottom(containerSize: CGSize, safeAreaTop: CGFloat) -> CGFloat {
        guard let occlusion, CGRect(origin: .zero, size: containerSize).contains(occlusion) else {
            return safeAreaTop
        }
        return occlusion.maxY
    }

    /// Where the rail column sits, and how wide it is, this frame — or
    /// `nil` when no column applies.
    ///
    /// Closed (`isClosedBar`): the column IS the system vertical bar —
    /// same edge, same width as `barEdge`/`barWidth`. The rail moves
    /// into furniture the system already reserved; nothing new is
    /// carved out of the stage.
    ///
    /// Open (`barEdge == nil`): there is no system column to reuse, so
    /// one is computed instead, on the trailing edge, sized so its own
    /// CENTRE lands on the active `.occlusion` region's own `midX` when
    /// one is on the trailing half (F6: "the safe-area inset already
    /// read in `DuoLayout.current`" for the bar case; the occlusion's
    /// own real position for the open case) — never a fixed,
    /// screenshot-measured width. With no occlusion to read, the
    /// column falls back to `Rail.hit + minStageMargin × 2`, a size
    /// built from the rail button's own design constant, not a device
    /// number. The gate below is still geometry-only, never a device
    /// check: it asks whether the natural leftover —
    /// `fullHeightStageWidth`'s own subtraction, the same test the
    /// earlier version used end to end — is big enough to carve out
    /// the computed column AND still leave the stage `minStageMargin`
    /// on each side. Below that, there is no column: `nil`, and every
    /// caller keeps the pre-Duo overlay layout. A regular iPhone's own
    /// leftover here is always negative — a phone screen is always
    /// narrower than the width a 9:16 box needs to reach its own full
    /// height — so it never clears this, decided purely by the
    /// screen's own proportions.
    ///
    /// `safeAreaTop` is unused in this branch — `fullHeightStageWidth`
    /// no longer reserves a top-chrome band (see `availableRect`'s own
    /// comment on why) — and kept only so this function's own
    /// signature still matches every sibling in this file that does
    /// still need it.
    func railColumn(containerSize: CGSize, safeAreaTop: CGFloat) -> (edge: HorizontalEdge, width: CGFloat)? {
        if let barEdge, barWidth > 0 {
            return (barEdge, barWidth)
        }
        let openWidth = containerSize.width - Self.fullHeightStageWidth(containerSize: containerSize)
        let computedWidth: CGFloat
        if let occlusion, occlusion.minX > containerSize.width / 2 {
            // A column centred on `occlusion.midX`, so its own centre
            // lands exactly on the ring's real position regardless of
            // how wide the window is — the same goal `openColumnWidth`
            // used to reach with a fixed, sim-measured number.
            computedWidth = max(Rail.hit, (containerSize.width - occlusion.midX) * 2)
        } else {
            computedWidth = Rail.hit + Self.minStageMargin * 2
        }
        guard openWidth >= computedWidth + Self.minStageMargin * 2 else { return nil }
        return (.trailing, computedWidth)
    }

    /// The rail column's own rectangle this frame, full height — the
    /// complement of `availableRect(containerSize:safeAreaTop:)`'s
    /// WIDTH only, deliberately not its top-inset height too, since
    /// this rectangle is the column's own hit area and background, not
    /// the stage's — or `nil` when `railColumn(containerSize:safeAreaTop:)`
    /// found none.
    ///
    /// `FeedPageContent.actionRailColumn` renders inside this instead
    /// of over the stage.
    func railColumnRect(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect? {
        guard let column = railColumn(containerSize: containerSize, safeAreaTop: safeAreaTop) else { return nil }
        switch column.edge {
        case .leading:
            return CGRect(x: 0, y: 0, width: column.width, height: containerSize.height)
        case .trailing:
            return CGRect(x: containerSize.width - column.width, y: 0,
                          width: column.width, height: containerSize.height)
        }
    }

    /// The rail's own top and bottom edge, in the page's own
    /// coordinate space (0 at the top), for whichever anchor this
    /// frame's column uses — or `nil` when no column applies.
    ///
    /// Both bar ON (closed, pose 1V/1H) and bar OFF (the open-tall
    /// pose) now centre the rail in the column's own full height —
    /// `(containerSize.height - Rail.columnHeight) / 2`. Bar OFF has
    /// read this way since an earlier top-anchored version put the
    /// rail right under the system's own time + connectivity ring; the
    /// owner's own review called that "too high," asking for the rail
    /// "centred vertically and accessible if I'm holding with one hand
    /// unfolded" instead.
    ///
    /// Bar ON picked up the same centring in a LATER review, replacing
    /// a bottom-anchored version this file's own history shows was
    /// itself a deliberate choice at the time ("leave pose 1's rail
    /// position as it is") — the owner later asked to "shift Delete
    /// through Keep up as a whole." Centring alone is not safe there,
    /// though: the ring sits ABOVE the bar column in this pose, with no
    /// SDK API for its own extent, so this clamps the centred top down
    /// to `closedStatusBottom(containerSize:safeAreaTop:) + 16`pt
    /// whenever straight centring would rise above it — seeing the
    /// clamp bind at all, on a real closed Duo screen, is the one
    /// thing to check (see that function's own comment on why this
    /// specific signal undershot once before).
    func railVerticalExtent(containerSize: CGSize, safeAreaTop: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
        guard railColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop) != nil else { return nil }
        let centeredTop = (containerSize.height - Rail.columnHeight) / 2
        guard isClosedBar else {
            return (centeredTop, centeredTop + Rail.columnHeight)
        }
        let minTop = closedStatusBottom(containerSize: containerSize, safeAreaTop: safeAreaTop) + 16
        let top = max(minTop, centeredTop)
        return (top, top + Rail.columnHeight)
    }

    /// The actual bottom edge of the rail's last button (Delete) this
    /// frame, in the page's own coordinate space (0 at the top) —
    /// whichever anchor `railVerticalExtent` reports for this frame.
    ///
    /// No rail column (a regular iPhone, or an open Duo too narrow for
    /// one): the rail is the pre-Duo overlay, bottom-anchored against
    /// the video's own seam — see `FeedPageContent.actionRail`'s
    /// identical `bottomBand + Rail.seamClearance` padding, which this
    /// mirrors so the two can never disagree.
    ///
    /// `ChinNavigation` reads this (as `railBottom`) to keep its own
    /// top edge below the rail's, with a minimum gap, instead of
    /// relying on a fixed offset that only happens to clear it on
    /// whichever screen it was tuned against. Bar ON, this is a no-op
    /// in practice: both this and the chin's own fixed anchor derive
    /// from the same chin position, so they can never disagree by more
    /// than rounding. Bar OFF, the rail's bottom now sits well above
    /// the chin (it hangs from the stage's own top, not the page's
    /// own bottom), so the clamp stays a no-op there too — just no
    /// longer for the same algebraic reason.
    func railBottom(safeAreaTop: CGFloat, containerSize: CGSize) -> CGFloat {
        if let extent = railVerticalExtent(containerSize: containerSize, safeAreaTop: safeAreaTop) {
            return extent.bottom
        }
        let bottomBand = StageGeometry.bottomBand(safeAreaTop: safeAreaTop, containerSize: containerSize)
        return containerSize.height - (bottomBand + Rail.seamClearance)
    }

    // MARK: - Chrome column + right page (build 3)
    //
    // Pose 3/4/4W put Mute, Filter, and Bin in their own column,
    // `chromeColumnWidth` wide, immediately leading of wherever
    // `railColumn` already put the rail/bar column — never computed
    // independently of it, so the two columns can never drift apart
    // or overlap. `FeedView.chromeColumn` is the one caller.

    /// This frame's chrome column, or `nil` when `railColumn` found no
    /// rail/bar column to sit beside (a regular iPhone, or any pose
    /// without one). Full height, like `railColumnRect` — this is the
    /// column's own hit area and background, not the stage's.
    func chromeColumnRect(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect? {
        guard let column = railColumn(containerSize: containerSize, safeAreaTop: safeAreaTop) else { return nil }
        switch column.edge {
        case .trailing:
            return CGRect(x: containerSize.width - column.width - Self.chromeColumnWidth, y: 0,
                          width: Self.chromeColumnWidth, height: containerSize.height)
        case .leading:
            return CGRect(x: column.width, y: 0, width: Self.chromeColumnWidth, height: containerSize.height)
        }
    }

    /// Three points, x = the chrome column's own centre, each level
    /// with a gap between two of the rail's five buttons — "each
    /// button is level with a gap between two rail buttons"
    /// (`DUO_POSES.md`'s own wording for the pose-3 wireframe).
    /// `[]` when `chromeColumnRect`/`railVerticalExtent` found nothing
    /// to anchor against.
    ///
    /// `pitch` is `Rail.itemHeight + Rail.spacing` (76 — the spec's
    /// own annotation). Point `j` (0...2) sits at
    /// `railTop + Rail.hit/2 + (j + 0.5) · pitch`: the rail's own
    /// first button centres at `railTop + Rail.hit/2`, so adding a
    /// half-pitch lands exactly on the gap after it, and each further
    /// whole pitch moves down one more gap. Only 3 of the rail's 4
    /// gaps are used — Mute, Filter, and Bin, not a fourth button.
    func zigzagCenters(containerSize: CGSize, safeAreaTop: CGFloat) -> [CGPoint] {
        guard let columnRect = chromeColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop),
              let extent = railVerticalExtent(containerSize: containerSize, safeAreaTop: safeAreaTop)
        else { return [] }
        let pitch = Rail.itemHeight + Rail.spacing
        return (0..<3).map { j in
            let y = extent.top + Rail.hit / 2 + (CGFloat(j) + 0.5) * pitch
            return CGPoint(x: columnRect.midX, y: y)
        }
    }

    /// The book pose's right page (pose 4/4W only; `nil` otherwise, or
    /// with no active division to anchor against): "`x ∈
    /// [division.maxX, W − bar − 80]`, full height" — the fold's own
    /// trailing edge to the leading edge of whichever column
    /// (rail/bar, then chrome) sits on the window's own far side.
    /// `DuoRightPage` (build 12) mounts here; nothing reads this
    /// rect before then.
    func rightPage(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect? {
        guard pose == .book, let division else { return nil }
        let column = railColumn(containerSize: containerSize, safeAreaTop: safeAreaTop)
        let barWidth = column?.width ?? 0
        switch column?.edge ?? .trailing {
        case .trailing:
            let minX = division.maxX
            let maxX = max(minX, containerSize.width - barWidth - Self.chromeColumnWidth)
            return CGRect(x: minX, y: 0, width: maxX - minX, height: containerSize.height)
        case .leading:
            // Not a configuration this pose has ever measured (the
            // bar is always trailing on the book pose) — mirrored for
            // the same reason `availableRect`/`railColumn` handle
            // both edges generically.
            let minX = division.maxX
            return CGRect(x: minX, y: 0, width: max(0, containerSize.width - minX), height: containerSize.height)
        }
    }

    /// Pose 5's own top-chrome anchor (build 6): "the active
    /// `.occlusion` region whose `minX > W/2`" — the spike that
    /// measured this proved it is the time + connectivity ring block
    /// on pose 5. Re-adapted (`design/duo/duo_audit_apple_checklist.md`
    /// §5): the old fallback was a fixed, screenshot-measured 134×82
    /// box at the window's own top-trailing corner — a device size
    /// (F6's own category of finding, even though this particular
    /// constant post-dates F6's own list). With no `.occlusion` to read
    /// — absent, or sitting on the wrong half, a frame the owner's own
    /// sim readings already caught transiently reporting a stale
    /// cross-display rect; see `current(...)`'s own division filter for
    /// the equivalent fix on that field, since `occlusion` has no such
    /// filter yet, so this check doubles as one for this one caller —
    /// this now returns a zero-width rect pinned to the true trailing
    /// edge, `safeAreaTop` tall: `pose5TopRow`'s own `trailing =
    /// statusBlock.minX − 8` lands the row 8pt from the real trailing
    /// edge, and `statusBlock.midY` centres it in the real safe-area
    /// top inset instead of a guessed height.
    ///
    /// No separate log call here: this type stays a pure value with
    /// no side effects, by design (this file's own header comment);
    /// `PlayerPageView`'s `-cloudfull-log-rotation` probe already
    /// prints the raw `occlusion` field on every pose/hinge change,
    /// which already shows whether this fell back — `occ-none`, or an
    /// `occ-` rect whose own `x` sits left of half the printed `W`.
    func statusBlock(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect {
        if let occlusion, occlusion.minX > containerSize.width / 2 {
            return occlusion
        }
        return CGRect(x: containerSize.width, y: 0, width: 0, height: safeAreaTop)
    }
}

/// Reads `EnvironmentValues.toolbarVerticalEdge` and reports it through
/// `onChange`, instead of exposing it as an `@Environment` property on
/// the host view directly.
///
/// Swift refuses `@available` on a stored property, and
/// `toolbarVerticalEdge` only exists from iOS 27.1 — so a host view
/// whose own deployment target is lower (every view in this app) cannot
/// declare `@Environment(\.toolbarVerticalEdge)` as one of its own
/// properties. Confining the read to this small view, which is itself
/// `@available`-marked, sidesteps that: mount it only inside an
/// `if #available(iOS 27.1, *)` branch, and it is simply never
/// instantiated — hence never type-checked against the environment key
/// it reads — on an older OS.
///
/// Zero-size and non-interactive, the same shape every DEBUG probe
/// elsewhere in this app already uses for an invisible reader.
@available(iOS 27.1, *)
struct ToolbarVerticalEdgeReader: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    let onChange: (HorizontalEdge?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: edge, initial: true) { _, newValue in onChange(newValue) }
    }
}

/// The hinge's own equivalent of `ToolbarVerticalEdgeReader`: a
/// zero-size, non-interactive view whose only job is converting
/// `onHingeChange`'s SDK types into this file's plain, always-available
/// `DuoHingeStatus`/`Double` pair, and reporting them up to a host
/// view's own `@State`.
///
/// `onHingeChange(isEnabled:_:)` has no `initial:` parameter (confirmed
/// against `SwiftUICore.swiftinterface`), unlike `.onChange(of:initial:)`
/// above — so, unlike `toolbarVerticalEdge`, the first real value may
/// arrive late, after the view mounts, rather than on the first frame.
/// The classifier (`DuoLayout.classify`) only ever needs the hinge for
/// the tent pose, which requires a `.partial` hinge AND a landscape
/// device stance together — never true at launch — so a hinge reading
/// that is still `nil` for the first frame or two costs nothing there;
/// every other pose decides without it. Step 1's own build-list check
/// is exactly this: note on the sim whether `onHingeChange` fires at
/// mount at all.
@available(iOS 27.1, *)
struct HingeReader: View {
    let onChange: (DuoHingeStatus?, Double?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onHingeChange { _, new in
                onChange(new.hinge.map { Self.mirror($0.status) }, new.hinge?.angle.degrees)
            }
    }

    /// `DeviceHinge.Status` is a struct, not a Swift enum (three static
    /// members, `.closed`/`.partiallyOpen`/`.fullyOpen`) — so a `switch`
    /// over it cannot be exhaustive from the compiler's own point of
    /// view. This reads the two cases `DuoLayout.classify` actually
    /// distinguishes (`.closed`, `.full`) and folds anything else,
    /// including `.partiallyOpen`, into `.partial` — the correct
    /// default, since partial is the only status with more than one
    /// member in practice.
    private static func mirror(_ status: DeviceHinge.Status) -> DuoHingeStatus {
        if status == .closed { return .closed }
        if status == .fullyOpen { return .full }
        return .partial
    }
}
