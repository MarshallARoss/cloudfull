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
    /// excludes the vertical bar column. Anything that must stay clear
    /// of the bar — today, the video stage — measures against this
    /// instead of the full container while `isClosedBar` is true.
    ///
    /// Returns the full container unchanged when the bar is off, so a
    /// regular iPhone's math is untouched.
    func availableRect(containerSize: CGSize) -> CGRect {
        guard let barEdge, barWidth > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        switch barEdge {
        case .leading:
            return CGRect(x: barWidth, y: 0,
                          width: max(0, containerSize.width - barWidth),
                          height: containerSize.height)
        case .trailing:
            return CGRect(x: 0, y: 0,
                          width: max(0, containerSize.width - barWidth),
                          height: containerSize.height)
        }
    }

    /// The largest 9:16 box that fits inside
    /// `availableRect(containerSize:)`, centred there.
    ///
    /// On a regular iPhone `availableRect` is the full container, which
    /// is always taller (relative to its width) than 16:9, so this
    /// reduces to the old width-derived box exactly: `width` is the
    /// binding side there, matching `PlayerPageView`'s pre-Duo stage.
    /// On the Duo's closed screen, once the bar column is excluded,
    /// height can become the binding side instead, which is what keeps
    /// the stage from overflowing the squat screen. See
    /// `PlayerPageView.body` for the caller.
    func stageRect(containerSize: CGSize) -> CGRect {
        let avail = availableRect(containerSize: containerSize)
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
