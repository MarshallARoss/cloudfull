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
    /// for what that is in each case. Anything that must stay clear of
    /// it — the video stage, the top chrome — measures against this
    /// instead of the full container.
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

    /// The largest 9:16 box that fits inside
    /// `availableRect(containerSize:safeAreaTop:)`, centred there.
    ///
    /// On a regular iPhone `availableRect` is the full container, which
    /// is always taller (relative to its width) than 16:9, so this
    /// reduces to the old width-derived box exactly: `width` is the
    /// binding side there, matching `PlayerPageView`'s pre-Duo stage.
    /// On the Duo's closed screen, once the bar column is excluded,
    /// height can become the binding side instead, which is what keeps
    /// the stage from overflowing the squat screen. On an open Duo wide
    /// enough for a computed column (same function), the box lands
    /// flush against that column with no pillarbox between them — see
    /// `railColumn`'s own comment for why that falls out of the same
    /// formula rather than needing a separate "flush left" rule. See
    /// `PlayerPageView.body` for the caller.
    func stageRect(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect {
        let avail = availableRect(containerSize: containerSize, safeAreaTop: safeAreaTop)
        guard avail.width > 0, avail.height > 0 else { return avail }
        let height = min(avail.height, avail.width * 16 / 9)
        let width = height * 9 / 16
        return CGRect(
            x: avail.minX + (avail.width - width) / 2,
            y: avail.minY + (avail.height - height) / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Rail column (step 3; extended by steps 4 and 5)
    //
    // The action rail (Keep, Share, Album, Shrink, Delete) moves off
    // the stage and into its own column when `isClosedBar`: the
    // column IS the system vertical bar — same edge, same width as
    // `barEdge`/`barWidth`. The rail moves into furniture the system
    // already reserved; nothing new is carved out of the stage.
    //
    // `railColumn(containerSize:safeAreaTop:)` is the one function
    // every caller below reads — never `barEdge`/`barWidth` directly.
    // `safeAreaTop` is unused here for now; an open Duo wide enough
    // for a column of its own computed from the stage's own geometry,
    // rather than reused from the system, is step 5's own addition to
    // this same function, and that is the case that needs it.

    /// Minimum width a rail column must have to hold the action rail
    /// comfortably: `Rail.hit` (40pt, each glyph's own hit box) plus
    /// 12pt clear on either side. Below this, `railColumn` reports no
    /// column, and every caller keeps the pre-Duo overlay layout.
    static let minRailColumnWidth: CGFloat = 64

    /// Gap kept below whatever the rail column's top already holds —
    /// the system's own time/connectivity ring when closed — before
    /// the rail's own first button. A visual gap, not a safety margin
    /// that top already guarantees on its own.
    static let railTopClearance: CGFloat = 12

    /// Where the rail column sits, and how wide it is, this frame — or
    /// `nil` when no column applies.
    ///
    /// Closed (`isClosedBar`): the column IS the system vertical bar —
    /// same edge, same width as `barEdge`/`barWidth`.
    ///
    /// Not closed (a regular iPhone, or an open Duo): no column yet.
    /// `nil`.
    func railColumn(containerSize: CGSize, safeAreaTop: CGFloat) -> (edge: HorizontalEdge, width: CGFloat)? {
        guard let barEdge, barWidth > 0 else { return nil }
        return (barEdge, barWidth)
    }

    /// The rail column's own rectangle this frame — the complement of
    /// `availableRect(containerSize:safeAreaTop:)` — or `nil` when
    /// `railColumn(containerSize:safeAreaTop:)` found none.
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

    /// The Y position, in this page's own coordinate space (0 at the
    /// top), where the rail's first button starts inside its column.
    ///
    /// The system draws its own time + connectivity ring at the top of
    /// the bar column. There is no SDK API that reports that cluster's
    /// own height (only its width, via `barWidth`'s matching safe-area
    /// inset), so this reads the frame's active `.occlusion` region
    /// instead, the inner camera cutout the same column must also
    /// clear, and falls back to `safeAreaTop` when no such region is
    /// active. Either number is a lower bound on where the system's
    /// own furniture ends; `railTopClearance` below it is the visual
    /// gap.
    func railContentTop(safeAreaTop: CGFloat) -> CGFloat {
        let systemBottom = isClosedBar ? max(occlusion?.maxY ?? 0, safeAreaTop) : safeAreaTop
        return systemBottom + Self.railTopClearance
    }

    /// The actual bottom edge of the rail's last button (Delete) this
    /// frame, in the page's own coordinate space (0 at the top) —
    /// whichever layout the rail is using.
    ///
    /// No rail column (a regular iPhone, or an open Duo — see
    /// `railColumn`'s own comment on that case): the rail is the
    /// pre-Duo overlay, bottom-anchored against the video's own seam —
    /// see `FeedPageContent.actionRail`'s identical
    /// `bottomBand + Rail.seamClearance` padding, which this mirrors
    /// so the two can never disagree.
    ///
    /// A rail column (the closed bar, today): the rail is anchored
    /// from the column's own top instead — see
    /// `railContentTop(safeAreaTop:)` — so its bottom is that anchor
    /// plus the rail's own fixed height, `Rail.columnHeight`.
    ///
    /// `ChinNavigation` reads this (as `railBottom`) to keep its own
    /// top edge below the rail's, with a minimum gap, instead of
    /// relying on a fixed offset that only happens to clear it on
    /// whichever screen it was tuned against.
    func railBottom(safeAreaTop: CGFloat, containerSize: CGSize) -> CGFloat {
        if railColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop) != nil {
            return railContentTop(safeAreaTop: safeAreaTop) + Rail.columnHeight
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
