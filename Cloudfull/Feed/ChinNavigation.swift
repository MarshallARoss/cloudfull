//
//  ChinNavigation.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The round glass icon button under `rail_trash` that expands into
/// Videos, Photos, and Settings, in the style of Apple Music.
///
/// Every mode mounts exactly one instance: `FeedView`, `SettingsView`,
/// and `PhotoFeedView` each mount their own. Each instance owns its
/// expand and collapse state and switches `AppModeStore.shared`
/// directly. It has no callback out, so every host wires it
/// identically.
///
/// Layering rule: the control is three stacked layers, and the order
/// matters.
///
/// 1. `shellGlass`: a `GlassEffectContainer` holding one shape, the
///    shell. It is a circle when collapsed and a capsule when
///    expanded, with one `glassEffectID` so iOS morphs one into the
///    other. It holds no text and no glyphs.
/// 2. `content`: the glyphs and words, drawn on top of the glass. Text
///    drawn inside the glass would pass through the lensing effect on
///    every frame of every transition and read as a blur.
/// 3. Two 1×1 accessibility markers, with frozen identifiers.
///
/// The bubble: the selection bubble is not drawn by this file.
/// `ChinTabSegmentedControl` mounts an iOS 26 `UISegmentedControl`,
/// which carries Apple's own draggable Liquid Glass lens. UIKit strips
/// every other piece of that control's chrome, so only the lens shows.
/// See that file for the technique and its origin (adapted from
/// FabBar, MIT). This file holds no bubble geometry, no bubble
/// animation, and no drag gesture. The control owns all three.
struct ChinNavigation: View {
    /// `StageGeometry.bottomBand(safeAreaTop:containerSize:)` for this
    /// screen. The button's vertical position does not branch on this
    /// value. It always centers on `StageGeometry.captionCenterFromBottom`,
    /// in both Videos and Photos, because Photos has no chin to differ by.
    /// The value is not used for layout. `FeedView` passes the computed
    /// band; other hosts pass `0`.
    let bottomBand: CGFloat

    /// The rail's own lowest reach this frame, in this view's own
    /// coordinate space (0 at the top) — see `DuoLayout.railBottom`.
    ///
    /// `0`, the default: no rail shares this screen (`SettingsView`,
    /// `PhotoFeedView`, and every build below iOS 27.1 or on a regular
    /// iPhone). The chin keeps its plain, fixed anchor unconditionally,
    /// with no dependence on this view's own geometry at all — see
    /// `resolvedBottomPadding`'s guard.
    ///
    /// A positive value: `FeedView`'s Videos mode, the one place a
    /// rail actually exists. The chin derives a minimum gap below it
    /// instead, only pulling its own anchor closer to the page bottom
    /// when the plain fixed anchor would not already clear the rail —
    /// see `resolvedBottomPadding`. On every device this has been
    /// measured against so far, the plain anchor already clears it, so
    /// this is a safety net for a short or unusually shaped screen,
    /// not an observed change on today's iPhones.
    let railBottom: CGFloat

    /// When non-nil, the collapsed resting position: `resolvedTrailingPadding`/
    /// `resolvedBottomPadding` solve for the `.padding(.trailing:)` +
    /// `.padding(.bottom:)` pair that puts this view's own center on
    /// this point, instead of the usual bottom-trailing anchor
    /// (plain 12pt trailing + `resolvedBottomPadding`'s fixed anchor),
    /// and `collapsedHeight` becomes `Rail.hit` instead of the plain
    /// default, to match a rail button's own size.
    ///
    /// Solved as padding on the ordinary view, not a separate
    /// `.position()` on a separate branch: a `.position()` branch that
    /// only applied while collapsed, falling through to the padding
    /// branch the instant `isExpanded` turned true, swapped the view's
    /// own identity mid-tap. SwiftUI had nothing to interpolate across
    /// that swap, so the capsule jumped to its expanded spot instead of
    /// growing out of the rail-aligned circle — main's morph lost.
    /// Padding on one unconditional view keeps the identity stable
    /// across the whole gesture, so the same `expand()`/`collapse()`
    /// springs that animate every other host's trailing/bottom padding
    /// now animate this one's too.
    ///
    /// `nil` everywhere but two `FeedView` poses: the open-tall rail
    /// column (bar off) — the owner's own review there, "the buttons
    /// are too high," and separately, "[the chin] should at least be
    /// bigger and align with the other rail items" — and, since build
    /// 8b, the laptop pose's own horizontal rail row (§2.6, "chin
    /// collapsed centre (600, v 236)"). Both ask for this control to
    /// sit beside the rail's own last item, the same size as a rail
    /// button, rather than at the fixed bottom-trailing spot every
    /// other host still uses unconditionally; see
    /// `FeedView.railAlignedChinCenter` for which point each pose
    /// supplies.
    ///
    /// Read only while collapsed (see `resolvedTrailingPadding`/
    /// `resolvedBottomPadding`): an EXPANDED capsule centred this close
    /// to the trailing edge would grow mostly off-screen. A tap in this
    /// pose morphs back to the ordinary bottom-trailing anchor the
    /// moment `isExpanded` turns true, the same anchor the capsule has
    /// always expanded from — no new expanded layout was built for this
    /// pose, only how the collapsed spot gets there.
    let railAlignedCenter: CGPoint?

    /// Step 7 (`design/duo/duo_build_spec.md` §3c, `design/duo/duo_audit_apple_checklist.md`
    /// §5): pose 5's (open-tall, Videos host only) own replacement for
    /// the collapsed round button — a vertical stack of the three mode
    /// buttons, always open, each switching mode directly on tap. Both
    /// non-nil together, or both `nil`; `FeedView` is the one caller
    /// that ever sets them, computed from `DuoLayout.railVerticalExtent`/
    /// `railColumnRect` so this view needs no `DuoLayout` import of its
    /// own. `columnTabsTop` is the stack's own TOP edge ("Delete bottom
    /// + 40," the per-pose table's own words) in this view's coordinate
    /// space; `columnX` is the column's own horizontal centre (the same
    /// one the rail itself is centred on).
    let columnTabsTop: CGFloat?
    let columnX: CGFloat?

    @State private var isExpanded = false
    @ObservedObject private var modeStore = AppModeStore.shared
    // Collapses the switcher when either pager starts to scroll.
    // `FeedView` and `PhotoFeedView` set `ScrollPhaseGate.isScrolling` in
    // their own `.onScrollPhaseChange`.
    @ObservedObject private var scrollGate = ScrollPhaseGate.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace

    // Opacity of the two content states, held as state and driven only by
    // `expand()`'s and `collapse()`'s own `withAnimation` calls.
    //
    // Do not add `.animation(_:value: isExpanded)`. That modifier cancels
    // the parent frame's spring, even with a `nil` animation. The glyph
    // then jumps to the right edge before the glass arrives. Separate
    // state keeps the fades and the morph in two independent
    // transactions.
    @State private var wordsOpacity: Double = 0
    @State private var glyphOpacity: Double = 1

    // Bumped by every `selectAnimated(_:)` call and captured by its
    // delayed steps. A stale timer is one superseded by a newer tap or
    // drag before it fires. It checks this value and does nothing,
    // instead of acting on a selection the user has already moved past.
    @State private var selectionToken = 0

    // The tab the user just picked, held here from the moment of the tap
    // until `AppModeStore` is finally told about it.
    //
    // `RootView` replaces this instance when `modeStore.select` changes
    // the mode. A removed view cannot animate. So this instance holds the
    // pick and commits it after the capsule shrinks. The visible parts
    // read `displayMode`, not the store.
    @State private var pendingMode: AppMode?

    /// The shell's identity inside `glassNamespace`, deliberately the same
    /// value in both states. That identity is what makes the collapsed
    /// circle grow into the expanded capsule, and shrink back, as one
    /// piece of glass instead of cross-fading.
    private enum GlassPart: Hashable {
        case shell
    }

    init(
        bottomBand: CGFloat, railBottom: CGFloat = 0, railAlignedCenter: CGPoint? = nil,
        columnTabsTop: CGFloat? = nil, columnX: CGFloat? = nil
    ) {
        self.bottomBand = bottomBand
        self.railBottom = railBottom
        self.railAlignedCenter = railAlignedCenter
        self.columnTabsTop = columnTabsTop
        self.columnX = columnX
    }

    var body: some View {
        // Uses its own `GeometryReader`, the same pattern as
        // `FeedView.body`'s root reader. The expanded capsule's width
        // formula (`min(containerWidth - 32, 252)`) needs the real screen
        // width. This view mounts as a leaf overlay, with no proxy of its
        // own to borrow.
        //
        // `.ignoresSafeArea()` below: `FeedView`'s `rootProxy` does not
        // ignore the safe area. Without `.ignoresSafeArea()`, `proxy.size`
        // stops at the safe-area bottom. `FeedPageContent`'s reader
        // ignores the safe area. This reader does the same, so
        // `captionCenterFromBottom` is the same distance in both places.
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                // A clear full-screen catcher mounts only while the
                // switcher is expanded. A tap or a short drag on it
                // collapses the switcher. Declared first, so the capsule
                // and button drawn after it win hit-testing over their
                // own bounds. The catcher only ever sees taps that land
                // outside them.
                //
                // The catcher excludes the Settings screen from its
                // mount condition. `syncExpansionWithMode` forces
                // `isExpanded` true for the whole time the Settings
                // screen shows. A full-screen `Color.clear` with a tap
                // gesture consumes the touch before it reaches the
                // `List` underneath, even when its closure does nothing
                // on Settings. A recognized `TapGesture` always consumes
                // the touch. Excluding Settings from the mount condition
                // leaves the `List` as the only view under the user's
                // finger. There is nothing for the catcher to intercept
                // on Settings anyway. Tap-outside never collapses that
                // screen.
                if isExpanded && displayMode != .settings {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture { collapse() }
                        // Because the catcher fully covers the screen, a
                        // swipe over the feed while the switcher is
                        // expanded lands entirely inside it. The pager
                        // underneath never sees the touch, so
                        // `scrollGate.isScrolling`, read below, never
                        // flips, and the capsule stays open through the
                        // whole gesture. A short drag here gives the
                        // swipe a second, direct way to collapse it.
                        // Apple Music does the same: the swipe that
                        // dismisses its mini player does not also scroll
                        // the list behind it.
                        .gesture(
                            DragGesture(minimumDistance: 6)
                                .onChanged { _ in
                                    guard isExpanded else { return }
                                    collapse()
                                }
                        )
                        .accessibilityHidden(true)
                }

                if let columnTabsTop, let columnX {
                    // Step 7: pose 5's own column tabs replace the
                    // collapsed chin outright — see `columnTabsTop`'s
                    // own comment. No capsule, no expand/collapse: three
                    // always-visible buttons, each a direct mode switch.
                    columnTabs(top: columnTabsTop, x: columnX)
                } else {
                    // One modifier chain for every other host and pose —
                    // `railAlignedCenter`'s collapsed resting spot (the
                    // open-tall rail column, the laptop rail row) and the
                    // ordinary bottom-trailing anchor both resolve down
                    // to trailing/bottom padding on the SAME view, never
                    // a `.position()` on a separate branch.
                    //
                    // That used to be two mutually exclusive branches: a
                    // `.position()` one while collapsed-and-rail-aligned,
                    // and this padding one everywhere else, including the
                    // moment that same control expands. Switching branches
                    // mid-animation swaps the view's identity, so SwiftUI
                    // had nothing to interpolate — the capsule jumped
                    // straight to its expanded spot instead of growing out
                    // of the rail-aligned circle, breaking main's morph.
                    // Resolving both cases to padding on one unconditional
                    // view keeps the identity stable, so `expand()`'s and
                    // `collapse()`'s own springs (unchanged below) morph it
                    // exactly as they do on a regular iPhone, from
                    // whichever collapsed spot this pose uses.
                    switcher(containerWidth: proxy.size.width)
                        // 12pt from the right edge on every host that has
                        // no rail-aligned spot, or once expanded — the
                        // control does not sit under the trash can. A
                        // rail-aligned pose pulls this in instead while
                        // collapsed, to its own measured spot — see
                        // `resolvedTrailingPadding`.
                        .padding(.trailing, resolvedTrailingPadding(containerWidth: proxy.size.width))
                        // The bottom padding centers the shape on
                        // `captionCenterFromBottom` by default — pulled
                        // closer to the page bottom only if the rail's own
                        // reach this frame would otherwise sit under it,
                        // or replaced outright by a rail-aligned pose's
                        // own spot while collapsed — see
                        // `resolvedBottomPadding`. The control's center
                        // then aligns with the caption text in Videos and
                        // Photos, exactly as before, on every screen that
                        // does not need either adjustment.
                        .padding(.bottom, resolvedBottomPadding(containerHeight: proxy.size.height))
                        .duoGuideMark("chin", color: .mint)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
        }
        .ignoresSafeArea()
        // The switcher is always expanded on the Settings screen. Seeding
        // `isExpanded` from `AppModeStore.shared.mode` in `init` is
        // unreliable: the collapsed button can still show on a fresh
        // Settings mount. This view sets `isExpanded` at mount and on
        // each mode change. This is correct whatever `isExpanded` held
        // before the first render.
        .onAppear { syncExpansionWithMode() }
        .onChange(of: modeStore.mode) { _, _ in syncExpansionWithMode() }
        // Collapses when the feed starts to scroll. Guarded on
        // `isExpanded`, since there is nothing to collapse otherwise.
        // It never runs on Settings, which has no pager to scroll and
        // stays expanded by design. See `syncExpansionWithMode`.
        .onChange(of: scrollGate.isScrolling) { _, isScrolling in
            guard isScrolling, isExpanded, displayMode != .settings else { return }
            collapse()
        }
    }

    /// The tab this control draws: the pick in flight if there is one, and
    /// the committed mode otherwise. Everything the user can see reads
    /// from here. Only `syncExpansionWithMode` still reads the store
    /// directly. "Is this the Settings screen's instance" is a fact about
    /// which view is mounted, not about which tab is selected.
    private var displayMode: AppMode { pendingMode ?? modeStore.mode }

    /// Forces the capsule open whenever the live mode is Settings. This
    /// function never collapses the capsule. The next mounted instance
    /// collapses it through `selectAnimated` or a tap outside.
    private func syncExpansionWithMode() {
        guard modeStore.mode == .settings, !isExpanded else { return }
        isExpanded = true
        // This path is a mount-time force, not a user gesture. There is
        // no morph to stage the fades against, so both values change at
        // once.
        wordsOpacity = 1
        glyphOpacity = 0
    }

    // 36pt collapsed, 56pt expanded: the two states the vertical-centering
    // math in `body` needs to agree on. `collapsedTapTarget` below widens
    // what the finger actually has to hit to 44pt, Apple's own minimum.
    // The glass circle stays the size it looks, so the wider tap target
    // costs nothing visually.
    //
    // `collapsedHeight` is an instance property, not `static`, only
    // because `railAlignedCenter` (pose 5, the open-tall rail column)
    // needs a different collapsed size — see that property's own
    // comment. Every other host keeps the plain 36pt default, since
    // `railAlignedCenter` is `nil` there.
    private var collapsedHeight: CGFloat { railAlignedCenter != nil ? Rail.hit : 36 }
    /// The invisible square the collapsed button answers to. Apple's
    /// Human Interface Guidelines set the minimum tap target at 44pt —
    /// `collapsedHeight` can grow past that (pose 5's `Rail.hit`, 40pt,
    /// still does not) but this never shrinks below it.
    private var collapsedTapTarget: CGFloat { max(44, collapsedHeight) }
    private static let expandedHeight: CGFloat = 56
    private var currentHeight: CGFloat { isExpanded ? Self.expandedHeight : collapsedHeight }

    /// Minimum gap kept between this control's own top edge and the
    /// rail's last button (`railBottom`), when one exists on this
    /// screen. A visual gap, 8pt, declared independently of
    /// `DuoLayout` — this is a Feed-level view and that is a
    /// Design-level type, so neither should import the other just to
    /// read one number — not a safety margin the rail's own geometry
    /// does not already guarantee.
    private static let railGap: CGFloat = 8

    /// This control's own trailing padding — the distance between its
    /// own trailing edge and the page's.
    ///
    /// `railAlignedCenter == nil`, or expanded: the plain 12pt every
    /// host has always used, unconditionally — pixel-identical to what
    /// this control has always done.
    ///
    /// `railAlignedCenter != nil` and collapsed: solved for the
    /// trailing padding that puts this view's own center — the ZStack
    /// aligns it `.bottomTrailing`, `collapsedTapTarget` wide — exactly
    /// on `railAlignedCenter.x`, the same point `.position(x:,y:)` used
    /// to be handed directly. Expressing the pose's own spot as padding
    /// on the ordinary view, instead of a separate `.position()` on a
    /// separate branch, is what lets `expand()`/`collapse()`'s springs
    /// (unchanged) animate the move — see `body`'s own comment.
    private func resolvedTrailingPadding(containerWidth: CGFloat) -> CGFloat {
        guard let railAlignedCenter, !isExpanded else { return 12 }
        return containerWidth - railAlignedCenter.x - collapsedTapTarget / 2
    }

    /// This control's own bottom padding — the distance between its
    /// own bottom edge and the page's.
    ///
    /// `railAlignedCenter != nil` and collapsed: solved the same way
    /// `resolvedTrailingPadding` solves for `x`, this time for
    /// `railAlignedCenter.y` — see that function's own comment.
    ///
    /// Otherwise, `railBottom <= 0` (the default, every host but
    /// `FeedView`'s Videos mode): returns the plain, fixed anchor
    /// unconditionally, with no dependence on `containerHeight` at all
    /// — pixel-identical to what this control has always done.
    ///
    /// `railBottom > 0`: that plain anchor still wins whenever it
    /// already clears the rail's own reach by `railGap` or more — the
    /// case on every iPhone and iPhone Duo screen this has been
    /// measured against, since the rail (overlaid on the stage, or in
    /// its own column; see `DuoLayout.railBottom`) does not reach as
    /// far down as the chin's own fixed spot. Only a screen shaped
    /// such that the rail's reach comes closer than that pulls this
    /// control's own anchor down toward the page bottom instead,
    /// capped at 0 (flush with the bottom edge, never past it).
    private func resolvedBottomPadding(containerHeight: CGFloat) -> CGFloat {
        if let railAlignedCenter, !isExpanded {
            return containerHeight - railAlignedCenter.y - collapsedTapTarget / 2
        }
        let fixedAnchor = StageGeometry.captionCenterFromBottom - currentHeight / 2
        guard railBottom > 0 else { return fixedAnchor }
        let railClearFromBottom = containerHeight - railBottom
        let maxAnchor = railClearFromBottom - Self.railGap - currentHeight
        return min(fixedAnchor, max(0, maxAnchor))
    }

    /// Inset between the expanded capsule's edge and the segmented control
    /// inside it, per side. FabBar uses the same 2pt around its own
    /// control. It leaves a rim of the capsule showing around Apple's
    /// lens, instead of the lens running flush to the glass edge. It must
    /// stay positive horizontally. The control's three segments divide its
    /// own width, so a control wider than the capsule would put the lens
    /// past the glass at either end.
    ///
    /// Do not try to set the lens height here. `UISegmentedControl` sizes
    /// its lens from the segment content, not its bounds. The lens is
    /// about 40pt tall in the 56pt capsule.
    private static let controlInset: CGFloat = 2

    /// `GlassEffectContainer`'s merge distance. Only one shape lives in
    /// the container: the bubble is the segmented control's own lens,
    /// drawn by UIKit above this glass. The container is still required,
    /// because `glassEffectID`, which morphs the circle into the capsule,
    /// only works inside one.
    private static let glassSpacing: CGFloat = 0

    // MARK: - Glyphs

    /// The Videos tab carries a camera glyph. The minimized round button
    /// shows the current tab's glyph rather than a neutral grid, the same
    /// way Apple Music's minimized bar shows where you are. Unfilled
    /// outline variants match that bar's own tabs.
    private static func glyph(for mode: AppMode) -> String {
        switch mode {
        case .videos: return "video"
        case .photos: return "photo.on.rectangle"
        case .settings: return "gearshape"
        }
    }

    // MARK: - Step 7: pose 5's own column tabs (§3c)

    /// Pitch (centre-to-centre distance) between consecutive tabs: the
    /// per-pose table's own "Rail.itemHeight + 12" — a smaller gap than
    /// the rail's own `Rail.spacing` (20pt, used by `zigzagCenters`'
    /// identical pitch formula), since this stack of three buttons is
    /// its own, denser group, not a continuation of the rail.
    private static let columnTabPitch: CGFloat = Rail.itemHeight + 12

    /// Half the gap between the rail's own last button and this
    /// column's own first tab — the per-pose table's own "halfway
    /// between": `columnTabsTop` is already "Delete bottom + 40," so a
    /// hairline at `columnTabsTop - hairlineGap` sits equidistant from
    /// both Delete's own bottom edge and the first tab's own top edge.
    private static let hairlineGap: CGFloat = 20

    /// Pose 5's own replacement for the collapsed round button — see
    /// `columnTabsTop`'s own comment. Three `RailItem`-styled buttons,
    /// always visible, each a direct `selectAnimated` call; no capsule,
    /// no expand/collapse.
    private func columnTabs(top: CGFloat, x: CGFloat) -> some View {
        let modes: [AppMode] = [.videos, .photos, .settings]
        let spacing = Self.columnTabPitch - Rail.itemHeight
        let totalHeight = Rail.itemHeight * CGFloat(modes.count) + spacing * CGFloat(modes.count - 1)
        return ZStack {
            // The per-pose table's own "hairline (44×1, white 30%)
            // halfway between" — a plain divider between the rail's
            // own actions and this column's mode switcher, the same
            // `Capsule`-as-hairline shape `FullscreenPlayerChrome`'s
            // own progress hairline already uses.
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 44, height: 1)
                .position(x: x, y: top - Self.hairlineGap)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: spacing) {
                ForEach(modes, id: \.self) { mode in
                    Button(action: { selectAnimated(mode) }) {
                        RailItem(
                            systemName: Self.glyph(for: mode),
                            label: Self.label(for: mode),
                            tint: mode == displayMode ? .white : .white.opacity(0.4)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chin_nav_column_\(mode.rawValue)")
                    .accessibilityLabel(Self.label(for: mode))
                    .accessibilityAddTraits(mode == displayMode ? .isSelected : [])
                }
            }
            .position(x: x, y: top + totalHeight / 2)
        }
    }

    /// The same three words `ChinTabSegmentedControl`'s own tab titles
    /// use (`chin_nav_videos`/`_photos`/`_settings`'s own labels) —
    /// kept as its own small switch, not a shared helper, since that
    /// control's own titles live behind a UIKit segment, not a plain
    /// Swift function this view could call.
    private static func label(for mode: AppMode) -> String {
        switch mode {
        case .videos: return "Videos"
        case .photos: return "Photos"
        case .settings: return "Settings"
        }
    }

    // MARK: - The control

    private func switcher(containerWidth: CGFloat) -> some View {
        let width = min(containerWidth - 32, 252)

        return ZStack {
            shellGlass(width: width)
            content(width: width)

            // Leaf markers with an identifier and no label, like
            // `poolCountProbe`. Not `accessibilityHidden`, which would
            // remove them from the accessibility tree XCUITest reads
            // identifiers from. Expanded only: a UI test
            // (`testChinNavExpandsAndSwitchesToPhotos`) checks that
            // `chin_nav_expanded` does not exist before the first
            // expand. `chin_nav_button` is a real tappable Button while
            // collapsed.
            if isExpanded {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("chin_nav_button")
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("chin_nav_expanded")
            }
        }
        // Collapsed, the container is the 44pt tap target rather than
        // the 36pt circle. The glass shape inside is still drawn at
        // `collapsedHeight`, so this only adds a finger-friendly margin
        // around it and stays invisible. `.contentShape` is what makes
        // that margin actually answer touches, instead of being empty
        // space.
        .frame(
            width: isExpanded ? width : collapsedTapTarget,
            height: isExpanded ? Self.expandedHeight : collapsedTapTarget
        )
        .contentShape(Rectangle())
    }

    // MARK: - Layer 1: the shell, and nothing else

    /// The only SwiftUI glass in this control. The selection bubble is not
    /// here: it is Apple's own lens inside the segmented control mounted
    /// in `content`, drawn above this shell by UIKit.
    private func shellGlass(width: CGFloat) -> some View {
        GlassEffectContainer(spacing: Self.glassSpacing) {
            // One view for the shell, never an `if isExpanded` pair. A
            // `Capsule` whose width equals its height is the collapsed
            // circle. This lets the shape animate its frame from 36×36 to
            // as much as 252×56 and back. Two branches sharing a
            // `glassEffectID` would cross-dissolve instead of travel. A
            // wide capsule would sit over the caption while a separate
            // circle grew in at the right edge. The result would read as
            // two objects with a gap between them. One animated frame
            // gives a continuous shrink.
            Color.clear
                .frame(width: isExpanded ? width : collapsedHeight, height: currentHeight)
                .feedGlass(in: Capsule())
                .glassEffectID(GlassPart.shell, in: glassNamespace)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Layer 2: glyphs and words, above the glass

    /// Both states are always mounted and swapped by opacity, never by
    /// `if` or `.transition`. With a `.transition(.opacity)`, the outgoing
    /// tab row would still be on screen while the capsule morphs back
    /// into the circle. The morph would draw over it. The word "Photos"
    /// would come out warped and doubled inside the shrinking glass. A
    /// view that only changes opacity does not enter a transition layer.
    /// So `wordsOpacity` can drop to 0 in one frame on collapse. It
    /// returns to 1 after the capsule finishes expanding.
    private func content(width: CGFloat) -> some View {
        ZStack {
            // Styled like Apple Music's tab bar: glyph over word, with
            // unfilled outline glyphs like that bar's own tabs. All
            // three tabs, and the bubble that highlights one of them,
            // come from `ChinTabSegmentedControl`. The frozen
            // `chin_nav_videos`, `chin_nav_photos`, and
            // `chin_nav_settings` identifiers are on the control's
            // segment views, which are the real hittable accessibility
            // elements XCUITest taps.
            ChinTabSegmentedControl(
                selection: displayMode,
                onSelect: { selectAnimated($0) },
                // A lift on the tab that is already current still
                // counts as a selection here: the capsule closes.
                onReselect: { selectAnimated($0) }
            )
            .frame(width: width - Self.controlInset * 2,
                   height: Self.expandedHeight - Self.controlInset * 2)
            .opacity(wordsOpacity)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)

            collapsedGlyphButton
                .opacity(glyphOpacity)
                .allowsHitTesting(!isExpanded)
                .accessibilityHidden(isExpanded)
        }
    }

    private var collapsedGlyphButton: some View {
        Button(action: expand) {
            Image(systemName: Self.glyph(for: displayMode))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                // Only the circle's own size here. The extra tap ring
                // goes on the container in `switcher(containerWidth:)`
                // instead. A 44pt button inside a 36pt container would
                // overflow it. The hit test, with the accessibility
                // element attached to it, would stay clipped to 36pt.
                // The button would then be missing from the
                // accessibility tree.
                .frame(width: collapsedHeight, height: collapsedHeight)
                .contentShape(Circle())
        }
        // `.plain`, not `.glass`: the circle's glass is drawn by
        // `shellGlass` above, so it can morph into the capsule. A
        // `.buttonStyle(.glass)` here would paint a second, non-morphing
        // circle of glass on top of it.
        .buttonStyle(.plain)
        .accessibilityIdentifier("chin_nav_button")
        .accessibilityLabel("Navigation")
        .accessibilityHint("Double tap to open Videos, Photos, and Settings")
    }

    // MARK: - Actions

    /// Hides the glyph in one frame, grows the capsule, then fades in the
    /// tab control. The lens is already on the current tab.
    private func expand() {
        Usage.shared.switcherOpened()
        glyphOpacity = 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.86)) {
            isExpanded = true
        }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.18).delay(0.12)) {
            wordsOpacity = 1
        }
    }

    /// Reverses `expand()`. The tab control hides before the morph
    /// starts, so the shrinking glass does not blur the text under it.
    private func collapse() {
        wordsOpacity = 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.88)) {
            isExpanded = false
        }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeIn(duration: 0.16).delay(0.12)) {
            glyphOpacity = 1
        }
    }

    /// How long the lens is given to finish sliding to the picked tab
    /// before anything else moves. The segmented control starts that
    /// slide on touch-down, so the finger has usually already lifted by
    /// the time this runs. The pause lets the user see the bubble arrive,
    /// instead of the capsule leaving underneath it.
    private static let lensSlide: TimeInterval = 0.25

    /// How long the collapse morph is given to land before the mode is
    /// committed. Matches `collapse()`'s own spring (response 0.32)
    /// closely enough that the store flips on the frame the glass
    /// finishes settling into the 36pt circle. The new mode's instance
    /// then mounts already collapsed on the new tab, so the swap is
    /// invisible.
    private static let collapseSettle: TimeInterval = 0.28

    /// A lift on a tab, whether the finger arrived there by tapping or by
    /// dragging the bubble across.
    ///
    /// The order is:
    /// 1. The bubble lands.
    /// 2. The capsule shrinks into the round button, already showing the
    ///    new tab's glyph.
    /// 3. Only then does the store learn about the pick.
    ///
    /// If the store changes first, `RootView` replaces this view at once
    /// and the collapse animation stops. See `pendingMode`.
    private func selectAnimated(_ mode: AppMode) {
        selectionToken += 1
        let token = selectionToken

        // Re-picking the tab already selected is not a mode change. There
        // is nothing to commit, so this only puts the capsule away. On
        // Settings it stays open, which is that screen's rule.
        guard mode != displayMode else {
            guard mode != .settings else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lensSlide) {
                guard token == self.selectionToken, self.isExpanded else { return }
                self.collapse()
            }
            return
        }

        pendingMode = mode

        // Picking Settings keeps the capsule open, since the switcher is
        // always expanded on the Settings screen. There is no collapse to
        // wait behind, so the store flips as soon as the bubble has
        // landed.
        guard mode != .settings else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lensSlide) {
                guard token == self.selectionToken else { return }
                self.modeStore.select(mode)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lensSlide) {
            // A newer tap or drag bumped the token. That pick superseded
            // this one, and its own timers now own the capsule.
            guard token == self.selectionToken else { return }
            if self.isExpanded { self.collapse() }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseSettle) {
                guard token == self.selectionToken else { return }
                // This code leaves `pendingMode` set on purpose. The
                // instance is about to be replaced. Clearing it would
                // repaint the old glyph for the frame or two before that
                // happens.
                if let usageMode = Usage.Mode(rawValue: mode.rawValue), usageMode != Usage.currentMode {
                    Usage.shared.modeSwitch(to: usageMode, via: .chin)   // a return to the same feed is not a switch
                }
                self.modeStore.select(mode)
            }
        }
    }
}
