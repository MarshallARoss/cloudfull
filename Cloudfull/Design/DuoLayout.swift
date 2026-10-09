//
//  DuoLayout.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

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

    /// `barEdge != nil`. The spelling most call sites reach for when all
    /// they need is the yes/no, not which edge.
    var isClosedBar: Bool { barEdge != nil }

    /// The "no Duo furniture" value: every field at its plain default.
    /// A regular iPhone's `FeedView`/`PhotoFeedView` can hand this
    /// straight to a child that expects a `DuoLayout` without ever
    /// calling `current(proxy:toolbarVerticalEdge:)`.
    static let none = DuoLayout(barEdge: nil, barWidth: 0, occlusion: nil, division: nil)

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
    @available(iOS 27.1, *)
    static func current(proxy: GeometryProxy, toolbarVerticalEdge: HorizontalEdge?) -> DuoLayout {
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
        let divisionFrame = proxy.reservedRegions(kind: .division).first(where: \.isActive)?.frame
        return DuoLayout(
            barEdge: toolbarVerticalEdge,
            barWidth: toolbarVerticalEdge == nil ? 0 : width,
            occlusion: occlusionFrame,
            division: divisionFrame
        )
    }

    /// The rectangle, inside a container of `containerSize`, that
    /// excludes the rail column — see `railColumn(containerSize:safeAreaTop:)`
    /// for what that is in each case — and, when the column is the
    /// OPEN kind (bar off), also excludes the top chrome's own band
    /// from the top. Anything that must stay clear of either —
    /// `stageRect` below, which is also where the top chrome itself
    /// measures from — uses this instead of the full container.
    ///
    /// The open column used to reserve that top band as a side effect
    /// of its own width: it was sized to exactly "whatever a 9:16
    /// stage leaves over, after first reserving the top band from the
    /// height it is fit against," so the leftover-sized column and
    /// the height reservation were really the same number wearing two
    /// hats. `openColumnWidth` is now a fixed width instead — see that
    /// constant's own comment for why — which means nothing else
    /// reserves the top band as a side effect any more, so this
    /// function reserves it directly: `requiredTopBand`, insetting
    /// both `y` and `height`. `PlayerPageView` reads this back through
    /// `stageRect.minY`/`.maxY` for this one pose, instead of its own
    /// `StageGeometry.downShift`/`bottomBand` — see that file's own
    /// `hasOpenColumn` comment.
    ///
    /// The closed bar column, and an open landscape window's bar
    /// column, are both untouched: `isClosedBar` is true for either,
    /// and the system's own column already leaves `stageRect` a
    /// natural vertical band (from its own aspect ratio) that
    /// `StageGeometry.downShift` already uses correctly today —
    /// reserving the band twice would double-shift the stage.
    ///
    /// Returns the full container unchanged when no column applies, so
    /// a regular iPhone's math is untouched.
    func availableRect(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect {
        guard let column = railColumn(containerSize: containerSize, safeAreaTop: safeAreaTop) else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let topInset = isClosedBar ? 0 : Self.requiredTopBand(safeAreaTop: safeAreaTop)
        let height = max(0, containerSize.height - topInset)
        switch column.edge {
        case .leading:
            return CGRect(x: column.width, y: topInset,
                          width: max(0, containerSize.width - column.width),
                          height: height)
        case .trailing:
            return CGRect(x: 0, y: topInset,
                          width: max(0, containerSize.width - column.width),
                          height: height)
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

    /// `StageGeometry.chromeTop(safeAreaTop:) + chromeHeight + chromeToVideoGap`
    /// — the same band `StageGeometry.downShift` reserves for a
    /// regular iPhone's own top chrome. Named here because the open
    /// (bar-off) column needs it twice, in exact agreement: once to
    /// size itself (`fullHeightStageWidth` below), and again to
    /// reserve the same band directly in `availableRect`, since the
    /// open column no longer does that reservation as a side effect
    /// of its own width the way an earlier version did — see
    /// `openColumnWidth`'s own comment.
    private static func requiredTopBand(safeAreaTop: CGFloat) -> CGFloat {
        StageGeometry.chromeTop(safeAreaTop: safeAreaTop) + StageGeometry.chromeHeight + StageGeometry.chromeToVideoGap
    }

    /// The width a 9:16 stage would need to claim this container's
    /// full height, after reserving `requiredTopBand` at the top. The
    /// one formula `railColumn`'s own gate (below) is built on.
    private static func fullHeightStageWidth(containerSize: CGSize, safeAreaTop: CGFloat) -> CGFloat {
        let effectiveHeight = max(0, containerSize.height - requiredTopBand(safeAreaTop: safeAreaTop))
        return effectiveHeight * 9 / 16
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
    func railColumn(containerSize: CGSize, safeAreaTop: CGFloat) -> (edge: HorizontalEdge, width: CGFloat)? {
        if let barEdge, barWidth > 0 {
            return (barEdge, barWidth)
        }
        let openWidth = containerSize.width - Self.fullHeightStageWidth(containerSize: containerSize, safeAreaTop: safeAreaTop)
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
    ///
    /// Bar OFF (the open-tall pose): anchored from the TOP instead,
    /// flush with the stage's own top edge, `stageRect.minY` — now
    /// correctly below the top chrome, since `availableRect` reserves
    /// that band directly for this one case. Bottom-anchoring this
    /// pose the way the bar-ON case is, as an earlier version did,
    /// left a dead gap above the rail: in THIS pose the ring sits
    /// ABOVE the whole stage, not above the rail specifically, so
    /// hanging the rail from the stage's own top edge is what the
    /// owner saw look right in an earlier build, and what "the ring
    /// sits above the rail, not below it, here" actually means in
    /// practice: follow the stage, not the chin.
    func railVerticalExtent(containerSize: CGSize, safeAreaTop: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
        guard railColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop) != nil else { return nil }
        if isClosedBar {
            let bottom = containerSize.height - Self.railColumnBottomPadding
            return (bottom - Rail.columnHeight, bottom)
        }
        let top = stageRect(containerSize: containerSize, safeAreaTop: safeAreaTop).minY
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
