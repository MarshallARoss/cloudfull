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

    /// A copy of this value with only `pose` replaced — every other
    /// field (`barEdge`, `occlusion`, `division`, `hinge`, …) stays
    /// this frame's own live reading.
    ///
    /// Step 1's own measured fix: `FeedView`/`PhotoFeedView` debounce
    /// `pose` before threading a `DuoLayout` further down (see
    /// `FeedView.settledDuoLayout`'s own comment for why), but every
    /// OTHER field keeps updating live, every frame — the owner's sim
    /// readings showed the raw geometry itself (window size, the
    /// division frame, the hinge) settling quickly; it was only the
    /// discrete, named `pose` that visibly flickered between two
    /// labels for a few frames mid-fold. This is the one place that
    /// substitutes a debounced pose into an otherwise-live reading,
    /// so no caller needs its own copy of this struct's field list.
    func withPose(_ pose: DuoPose) -> DuoLayout {
        DuoLayout(barEdge: barEdge, barWidth: barWidth, occlusion: occlusion, division: division,
                  pose: pose, hinge: hinge, hingeDegrees: hingeDegrees)
    }

    /// The "no Duo furniture" value: every field at its plain default.
    /// A regular iPhone's `FeedView`/`PhotoFeedView` can hand this
    /// straight to a child that expects a `DuoLayout` without ever
    /// calling `current(proxy:toolbarVerticalEdge:horizontalSizeClass:hinge:hingeDegrees:stanceIsLandscape:)`.
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
    /// `horizontalSizeClass`, `hinge`, and `stanceIsLandscape` are the
    /// classifier's three extra inputs — see `classify(...)` below for
    /// what each decides. The caller reads all three itself
    /// (`@Environment(\.horizontalSizeClass)`, `HingeReader`'s stored
    /// state, and `OrientationMonitor`'s `Stance.isLandscape`) for the
    /// same reason it already reads `toolbarVerticalEdge` itself: only a
    /// View's own environment/state context can read them.
    @available(iOS 27.1, *)
    static func current(
        proxy: GeometryProxy,
        toolbarVerticalEdge: HorizontalEdge?,
        horizontalSizeClass: UserInterfaceSizeClass?,
        hinge: DuoHingeStatus?,
        hingeDegrees: Double?,
        stanceIsLandscape: Bool
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
            sizeClass: horizontalSizeClass,
            containerSize: proxy.size,
            division: divisionFrame,
            barEdge: toolbarVerticalEdge,
            hinge: hinge,
            stanceIsLandscape: stanceIsLandscape
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

    /// The pose classifier. Pure geometry/trait math, no device check —
    /// see this file's header comment on why that is what keeps a
    /// regular iPhone's result (`.regularPhone`) decided purely by its
    /// own proportions and traits, never by a name.
    ///
    /// `sizeClass == .regular` only on the Duo's INNER display (the
    /// same fact `PlayerPageView.isFullscreen` already leans on — see
    /// that property's own comment). There, an active `division` means
    /// the device is partially open: a division taller than it is wide
    /// is the fold read top-to-bottom (a book spine down the middle),
    /// a division wider than tall is the fold read left-to-right (a
    /// laptop hinge along the bottom) — see this file's "Fold-orientation
    /// check" in the build spec for the 951×669 / 669×951 arithmetic
    /// this falls out of. No division at all means fully open: the
    /// window's own shape (landscape or portrait) is `.openWide` or
    /// `.openTall`.
    ///
    /// `sizeClass != .regular` is every compact-width case: a regular
    /// iPhone in any orientation, or the Duo's OUTER display. A
    /// `.partial` hinge together with a landscape device stance is the
    /// tent (pose 2) — the hinge alone cannot tell tent from laptop
    /// (both report `.partiallyOpen`; see `isFullscreen`'s own comment
    /// on why `horizontalSizeClass` is what actually separates them),
    /// but the OUTER display never goes `.regular`, so reaching this
    /// branch at all already rules laptop out. Otherwise, any sign of
    /// Duo furniture at all (`barEdge` or a non-nil `hinge`) is the
    /// closed pose; with neither, this is a plain regular iPhone.
    private static func classify(
        sizeClass: UserInterfaceSizeClass?,
        containerSize: CGSize,
        division: CGRect?,
        barEdge: HorizontalEdge?,
        hinge: DuoHingeStatus?,
        stanceIsLandscape: Bool
    ) -> DuoPose {
        if sizeClass == .regular {
            if let division {
                return division.height > division.width ? .book : .laptop
            }
            return containerSize.width > containerSize.height ? .openWide : .openTall
        }
        if hinge == .partial, stanceIsLandscape {
            return .tent
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
    /// 9:16 stage leaves over" (see `openColumnWidth`'s own comment on
    /// why that sizing changed); this undoes that reservation, so the
    /// open column now behaves exactly like the closed bar column
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
    /// `openColumnWidth`'s fixed column is removed from it, into even
    /// margins on both sides of the stage — see that constant's own
    /// comment for why that is the goal, not a flush-left stage.
    ///
    /// The non-default `aspectRatio` is step 6's own addition: an open
    /// Duo turned sideways really rotates its window (see
    /// `PlayerPageView.windowIsLandscape`), and a horizontal video
    /// shown there must FIT its own shape, not the portrait stage every
    /// other screen wants. `PlayerPageView.body` passes the loaded
    /// video's real aspect ratio exactly when that applies, and the
    /// default everywhere else.
    func stageRect(containerSize: CGSize, safeAreaTop: CGFloat, aspectRatio: CGFloat = 9.0 / 16.0) -> CGRect {
        let avail = availableRect(containerSize: containerSize, safeAreaTop: safeAreaTop)
        guard avail.width > 0, avail.height > 0 else { return avail }
        let height = min(avail.height, avail.width / aspectRatio)
        let width = height * aspectRatio
        return CGRect(
            x: avail.minX + (avail.width - width) / 2,
            y: avail.minY + (avail.height - height) / 2,
            width: width,
            height: height
        )
    }

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

    /// Measured, no API: half the open (bar-off) column's own width,
    /// and the distance from the trailing edge to the system
    /// connectivity ring's own x-centre on the inner display's
    /// portrait pose ("open-tall"). `openColumnWidth` below is
    /// `2 × ringInset`, which is what makes a column that wide,
    /// centred on itself, land its own centre exactly `ringInset` from
    /// the trailing edge — the ring's own centre, fixing the owner's
    /// report that the rail sat "pushed in" from it.
    ///
    /// There is no SDK API for the ring's own position on this pose —
    /// see `railVerticalExtent`'s own comment on the equivalent gap for
    /// its height. This number came from a screenshot instead: on a
    /// 2007px-wide (3×, 669pt) inner portrait frame, the ring's own
    /// centre measured at ≈ 1857px, ≈ 619pt, ≈ 50pt from the trailing
    /// edge.
    static let ringInset: CGFloat = 50

    /// The open (bar-off) column's own fixed width — `2 × ringInset` —
    /// unlike the CLOSED bar column, which is whatever width the
    /// system gives it.
    ///
    /// An earlier version sized this column to "whatever is left
    /// over," the same width `fullHeightStageWidth` subtracts from the
    /// container — correct by coincidence on a narrow leftover, wrong
    /// on a wide one: the owner found the rail centred far from the
    /// ring, with a large unused gap on the video's own leading edge,
    /// because "the column's centre" and "the ring's own position"
    /// have no reason to agree once the leftover is wide. A column
    /// this width, always, keeps the rail's own centre at a fixed,
    /// known distance from the trailing edge (`ringInset`) regardless
    /// of how wide the window's own leftover is. `railColumn`'s own
    /// gate below still only forms a column at all when that leftover
    /// comfortably fits one — see its own comment — so `stageRect`'s
    /// unchanged horizontal centring turns whatever leftover remains,
    /// after this fixed column, into even margins on both sides of
    /// the video instead of a flush-left stage. That symmetry, not a
    /// new centring rule, is what fixes the owner's other report (the
    /// video touching the leading edge).
    static let openColumnWidth: CGFloat = ringInset * 2

    /// Minimum leading margin `railColumn`'s open-branch gate
    /// guarantees the stage, on each side, once `openColumnWidth` is
    /// removed from the natural leftover. See that function's own
    /// gate for the arithmetic.
    static let minStageMargin: CGFloat = 16

    /// Minimum gap kept between the rail's own last button and the
    /// chin's own top edge, when the rail is bottom-anchored in a
    /// column. Mirrors `ChinNavigation`'s own `railGap` (the same gap,
    /// read from the opposite side): both are 8pt, declared
    /// independently, since `ChinNavigation` is a Feed-level view and
    /// this is a Design-level type — neither should import the other
    /// just to read one number.
    static let railBottomGap: CGFloat = 8

    /// The chin's own top edge, from the page's bottom, at the chin's
    /// tallest (expanded) state: `StageGeometry.captionCenterFromBottom`
    /// plus half of `ChinNavigation`'s own expanded height. The `56`
    /// here is hand-mirrored from `ChinNavigation.expandedHeight`, the
    /// same way `captionCenterFromBottom` itself hand-mirrors
    /// `captionZone`'s real layout elsewhere in this file, rather than
    /// reading live state. Using the expanded height, not whichever
    /// height the chin currently is, guarantees clearance in both of
    /// its states.
    private static let chinTopFromPageBottom: CGFloat = StageGeometry.captionCenterFromBottom + 56 / 2

    /// The rail's own bottom edge, from the page's bottom, when it is
    /// bottom-anchored in a column: `railBottomGap` above the chin's
    /// own top edge, at its tallest.
    ///
    /// This replaces an earlier top-anchored version (since removed,
    /// then reintroduced in a different shape below — see
    /// `railVerticalExtent`) that placed the rail's first button below
    /// whatever `.occlusion`/`safeAreaTop` reported. On a real closed
    /// Duo screen that undershot the system's own time + connectivity
    /// ring: there is no SDK API for that cluster's own extent —
    /// `UIViewReservedRegion`'s only kinds are `.occlusion` (the
    /// camera) and `.division` (the fold); see this type's own header
    /// comment — so the rail's first button (Keep) rendered partly
    /// under the ring. The chin's own position, by contrast, is
    /// exactly known, with comfortably more room between the ring and
    /// the chin than the rail's own height needs, so anchoring from
    /// there instead is both correct and already the one number
    /// `ChinNavigation` itself reads back (as `railBottom`, below).
    ///
    /// Bottom-anchoring like this is right only when the ring sits
    /// ABOVE the rail (the closed bar column, and an open landscape
    /// window's bar column) — see `railVerticalExtent`'s own comment
    /// for the open-tall pose, where the ring sits above the STAGE
    /// instead, and bottom-anchoring the rail there left a dead gap
    /// above it.
    static let railColumnBottomPadding: CGFloat = chinTopFromPageBottom + railBottomGap

    /// Where the rail column sits, and how wide it is, this frame — or
    /// `nil` when no column applies.
    ///
    /// Closed (`isClosedBar`): the column IS the system vertical bar —
    /// same edge, same width as `barEdge`/`barWidth`. The rail moves
    /// into furniture the system already reserved; nothing new is
    /// carved out of the stage.
    ///
    /// Open (`barEdge == nil`): there is no system column to reuse, so
    /// one is computed instead: `openColumnWidth`, fixed, on the
    /// trailing edge — see that constant's own comment for why fixed,
    /// rather than "whatever is left over," is now the rule. The gate
    /// below is still geometry-only, never a device check: it asks
    /// whether the natural leftover — `fullHeightStageWidth`'s own
    /// subtraction, the same test the earlier version used end to end
    /// — is big enough to carve out `openColumnWidth` AND still leave
    /// the stage `minStageMargin` on each side. Below that, there is
    /// no column: `nil`, and every caller keeps the pre-Duo overlay
    /// layout. A regular iPhone's own leftover here is always
    /// negative — a phone screen is always narrower than the width a
    /// 9:16 box needs to reach its own full height — so it never
    /// clears this, decided purely by the screen's own proportions.
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
        guard openWidth >= Self.openColumnWidth + Self.minStageMargin * 2 else { return nil }
        return (.trailing, Self.openColumnWidth)
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
    /// Bar ON (closed, or an open landscape window): anchored from the
    /// BOTTOM — `railColumnBottomPadding` above the page's own bottom
    /// edge — because the ring sits ABOVE the rail in that pose, with
    /// no SDK API to say by how much, but the chin's own position
    /// below is exactly known; see that constant's own comment.
    /// Unchanged from the owner's own review of this pose ("pose 1 ...
    /// looks generally pretty good" — "leave pose 1's rail position as
    /// it is").
    ///
    /// Bar OFF (the open-tall pose): centred in the column instead —
    /// `(containerSize.height - Rail.columnHeight) / 2` — not anchored
    /// to either edge. An earlier version anchored from the top, flush
    /// with the stage's own top edge, which put it right under the
    /// system's own time + connectivity ring; the owner's own review
    /// called the result "too high," asking for the rail "centred
    /// vertically and accessible if I'm holding with one hand
    /// unfolded" instead.
    func railVerticalExtent(containerSize: CGSize, safeAreaTop: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
        guard railColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop) != nil else { return nil }
        if isClosedBar {
            let bottom = containerSize.height - Self.railColumnBottomPadding
            return (bottom - Rail.columnHeight, bottom)
        }
        let top = (containerSize.height - Rail.columnHeight) / 2
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
