//
//  ChinTabSegmentedControl.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Portions adapted from FabBar by Ryan Ashcraft (MIT).
//  See THIRD_PARTY_NOTICES.md.
//

import SwiftUI
import UIKit

// MARK: - Provenance
//
// The technique: subclass `UISegmentedControl`. Hide its labels and
// background images. Add custom content views to each `UISegment`. Move
// `selectedSegmentIndex` on touch-down and touch-move, so the system's
// Liquid Glass selection lens follows the finger. Defer the
// value-changed action to touch-up. Mask an accent-colored duplicate of
// each item to the lens's presentation rect.
//
// This technique is adapted from FabBar by Ryan Ashcraft (MIT licensed),
// https://github.com/ryanashcraft/FabBar, files
// `Sources/FabBar/Internal/TabBarSegmentedControl.swift`,
// `TabItemContentView.swift` and `FabBarRepresentable.swift`.
//
// On iOS 26, `UISegmentedControl` draws a draggable Liquid Glass
// selection lens. This file puts that control inside the app's chin
// capsule, instead of recreating the lens's look in SwiftUI.
//
// Differences from FabBar: three fixed tabs, no floating action button,
// and no rebuild path. For the accessibility popover, the content views
// hide themselves when unarchived, so the popover shows the native
// segment titles.

// MARK: - Item content view

/// One tab's glyph over its word, drawn at the current graphics-context scale
/// rather than composed from subviews. `draw(_:)` rendering keeps the words
/// crisp inside the glass. The lens would resample a rasterized `UIImageView`
/// every frame, which would blur the words.
///
/// `NSCoding` support matters for one case: at accessibility content sizes,
/// the system archives a segment's content into a popover. The unarchived
/// copy hides itself, in `init(coder:)`, so the popover shows the native
/// segment title instead of a half-configured duplicate.
@objc(CloudfullChinTabItemContentView)
final class ChinTabItemContentView: UIView {
    private var symbolName: String = ""
    private var title: String = ""

    /// An 11pt semibold word under a 17pt medium glyph, for the expanded
    /// capsule.
    private static let titleFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
    private static let glyphPointSize: CGFloat = 17
    /// Fixed height reserved for the glyph. All three words sit on one
    /// baseline, regardless of each symbol's own bounding box.
    private static let glyphAreaHeight: CGFloat = 22

    init(title: String, symbolName: String) {
        self.title = title
        self.symbolName = symbolName
        super.init(frame: .zero)
        isOpaque = false
        // The control underneath must receive every touch. These views
        // are pure decoration injected into its segments.
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        self.symbolName = coder.decodeObject(forKey: "symbolName") as? String ?? ""
        self.title = coder.decodeObject(forKey: "title") as? String ?? ""
        super.init(coder: coder)
        isHidden = true
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(symbolName, forKey: "symbolName")
        coder.encode(title, forKey: "title")
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsDisplay()
    }

    override var intrinsicContentSize: CGSize {
        let textSize = (title as NSString).size(withAttributes: [.font: Self.titleFont])
        let glyphWidth = glyphImage()?.size.width ?? 0
        return CGSize(width: max(glyphWidth, textSize.width).rounded(.up),
                      height: (Self.glyphAreaHeight + textSize.height).rounded(.up))
    }

    override func draw(_ rect: CGRect) {
        let color = tintColor ?? .white
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont,
            .foregroundColor: color,
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)

        if let glyph = glyphImage() {
            let originX = (bounds.width - glyph.size.width) / 2
            let originY = (Self.glyphAreaHeight - glyph.size.height) / 2
            color.setFill()
            glyph.withRenderingMode(.alwaysTemplate)
                .draw(in: CGRect(origin: CGPoint(x: originX, y: originY), size: glyph.size))
        }

        (title as NSString).draw(
            at: CGPoint(x: (bounds.width - textSize.width) / 2, y: Self.glyphAreaHeight),
            withAttributes: attributes
        )
    }

    private func glyphImage() -> UIImage? {
        guard !symbolName.isEmpty else { return nil }
        let configuration = UIImage.SymbolConfiguration(pointSize: Self.glyphPointSize, weight: .medium)
        return UIImage(systemName: symbolName, withConfiguration: configuration)
    }
}

// MARK: - The control

/// A `UISegmentedControl` with its own chrome stripped away, leaving only
/// the Liquid Glass selection lens from the system's own rendering.
final class ChinSegmentedControl: UISegmentedControl {
    /// Identifies the injected views inside segment subtrees, which the
    /// system is free to rebuild at any time.
    private static let baseViewTag = 9_101
    private static let accentViewTag = 9_102
    /// Three consecutive identical indicator rects mean the lens is
    /// stable. The display link then pauses until the next touch or
    /// layout.
    private static let stableFrameThreshold = 3

    private var baseViews: [ChinTabItemContentView] = []
    private var accentViews: [ChinTabItemContentView] = []

    /// One accessibility identifier per segment, applied to the internal
    /// `UISegment` views in `layoutSubviews`. These are the frozen
    /// `chin_nav_videos`, `chin_nav_photos`, and `chin_nav_settings`
    /// handles that XCUITest taps. The segment view is the real, hittable
    /// accessibility element for a segment, so the identifier goes there,
    /// not on a decorative overlay.
    var segmentIdentifiers: [String] = []

    /// The selected item's color, and the color every other item uses.
    var activeTintColor: UIColor = .white { didSet { applyContentColors() } }
    var inactiveTintColor: UIColor = UIColor.white.withAlphaComponent(0.7) { didSet { applyContentColors() } }

    /// Fires on touch-up when the finger lifts over the segment that was
    /// selected when the touch began. `.valueChanged` covers a different
    /// segment.
    var onReselect: ((Int) -> Void)?

    private var originalIndex: Int?
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    private var lastIndicatorRect: CGRect = .zero
    private var stableFrameCount = 0
    private weak var cachedIndicatorView: UIView?

    override init(items: [Any]?) {
        super.init(items: items)
        backgroundColor = .clear
        accessibilityTraits = .tabBar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLink?.isPaused = false
        stableFrameCount = 0
        hideSegmentBackgrounds()
        hideDefaultLabels(in: self)
        injectContentViewsIfNeeded()
        applyContentColors()
        applySegmentIdentifiers()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startDisplayLink() } else { stopDisplayLink() }
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        // The control recreates its labels on some layout passes. This
        // hides each new label at once, so the default text does not show
        // for one frame.
        hideDefaultLabels(in: subview)
    }

    // MARK: Content

    /// Installs the per-segment content. Each segment gets two views: a
    /// base view in the inactive color, and an accent view in the active
    /// color stacked on top of it, masked to the lens. Color never changes
    /// as the selection moves. The mask is what makes the item under the
    /// lens read as highlighted, so the highlight tracks the glass
    /// mid-slide instead of snapping at the end.
    func configureContent(_ items: [(title: String, symbolName: String)]) {
        cachedIndicatorView = nil
        for segment in segmentViews() {
            segment.viewWithTag(Self.baseViewTag)?.removeFromSuperview()
            segment.viewWithTag(Self.accentViewTag)?.removeFromSuperview()
        }
        baseViews = items.map { ChinTabItemContentView(title: $0.title, symbolName: $0.symbolName) }
        accentViews = items.map { ChinTabItemContentView(title: $0.title, symbolName: $0.symbolName) }
        setNeedsLayout()
    }

    private func injectContentViewsIfNeeded() {
        let segments = segmentViews()
        guard segments.count == baseViews.count, segments.count == accentViews.count else { return }

        for (index, segment) in segments.enumerated() {
            if segment.viewWithTag(Self.baseViewTag) == nil {
                pin(baseViews[index], tag: Self.baseViewTag, into: segment)
            }
            if segment.viewWithTag(Self.accentViewTag) == nil {
                let accent = accentViews[index]
                pin(accent, tag: Self.accentViewTag, into: segment)
                // Starts fully clipped away. The display link opens the
                // mask to whatever the lens currently covers.
                let mask = CAShapeLayer()
                mask.path = UIBezierPath(rect: .zero).cgPath
                accent.layer.mask = mask
            }
        }
    }

    private func pin(_ view: ChinTabItemContentView, tag: Int, into segment: UIView) {
        view.tag = tag
        view.translatesAutoresizingMaskIntoConstraints = false
        segment.addSubview(view)
        let size = view.intrinsicContentSize
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: segment.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: segment.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: size.width),
            view.heightAnchor.constraint(equalToConstant: size.height),
        ])
    }

    private func applyContentColors() {
        baseViews.forEach { $0.tintColor = inactiveTintColor }
        accentViews.forEach { $0.tintColor = activeTintColor }
    }

    private func applySegmentIdentifiers() {
        let segments = segmentViews()
        guard segments.count == segmentIdentifiers.count else { return }
        for (index, segment) in segments.enumerated() where segment.accessibilityIdentifier != segmentIdentifiers[index] {
            segment.accessibilityIdentifier = segmentIdentifiers[index]
        }
    }

    // MARK: Private hierarchy walking

    /// The internal `UISegment` views, left to right. On iOS 26 they sit
    /// several container levels down, so this recurses rather than reading
    /// `subviews` directly.
    private func segmentViews() -> [UIView] {
        var found: [UIView] = []
        collectSegments(in: self, into: &found)
        return found.sorted { $0.frame.origin.x < $1.frame.origin.x }
    }

    private func collectSegments(in view: UIView, into results: inout [UIView]) {
        for subview in view.subviews {
            if String(describing: type(of: subview)) == "UISegment" {
                results.append(subview)
            } else {
                collectSegments(in: subview, into: &results)
            }
        }
    }

    private func hideDefaultLabels(in view: UIView) {
        if let label = view as? UILabel,
           label.superview?.tag != Self.baseViewTag,
           label.superview?.tag != Self.accentViewTag {
            label.isHidden = true
        }
        view.subviews.forEach { hideDefaultLabels(in: $0) }
    }

    /// The control's default backgrounds, separators, and legacy selection
    /// images are all `UIImageView`s. This hides all of them: the app's
    /// own capsule is the background, and the lens is the selection.
    private func hideSegmentBackgrounds() {
        for subview in subviews where subview is UIImageView {
            subview.alpha = 0
        }
    }

    // MARK: Lens tracking

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy(control: self)
        displayLinkProxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
    }

    /// The Liquid Glass lens view. Found by its private class name first.
    /// The fallback picks the sibling of the segments container that has
    /// subviews. The lens has subviews. The other sibling has none.
    private func findIndicatorView() -> UIView? {
        if let named = descendant(named: "_UILiquidLensView") { return named }
        let segments = segmentViews()
        guard let container = segments.first?.superview,
              let wrapper = container.superview else { return nil }
        return wrapper.subviews.first { $0 !== container && !$0.subviews.isEmpty }
    }

    private func descendant(named className: String) -> UIView? {
        func search(_ view: UIView) -> UIView? {
            for subview in view.subviews {
                if String(describing: type(of: subview)) == className { return subview }
                if let found = search(subview) { return found }
            }
            return nil
        }
        return search(self)
    }

    /// Where the lens is right now, read off the presentation layer so the
    /// mask tracks the in-flight animation rather than its destination.
    /// Falls back to the selected segment's frame if Apple renames the
    /// lens class.
    private func currentIndicatorRect() -> CGRect {
        if cachedIndicatorView == nil { cachedIndicatorView = findIndicatorView() }
        if let indicator = cachedIndicatorView {
            let indicatorLayer = indicator.layer.presentation() ?? indicator.layer
            let selfLayer = layer.presentation() ?? layer
            return selfLayer.convert(indicatorLayer.bounds, from: indicatorLayer)
        }
        let segments = segmentViews()
        if selectedSegmentIndex >= 0, selectedSegmentIndex < segments.count {
            return segments[selectedSegmentIndex].frame
        }
        return .zero
    }

    fileprivate func updateAccentMasks() {
        let indicatorRect = currentIndicatorRect()

        if indicatorRect == lastIndicatorRect {
            stableFrameCount += 1
            if stableFrameCount >= Self.stableFrameThreshold {
                displayLink?.isPaused = true
                return
            }
        } else {
            stableFrameCount = 0
            lastIndicatorRect = indicatorRect
        }

        guard baseViews.count == accentViews.count else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in accentViews.indices {
            updateMask(base: baseViews[index], accent: accentViews[index], indicatorRect: indicatorRect)
        }
        CATransaction.commit()
    }

    private func updateMask(base: ChinTabItemContentView, accent: ChinTabItemContentView, indicatorRect: CGRect) {
        let accentLayer = accent.layer.presentation() ?? accent.layer
        let selfLayer = layer.presentation() ?? layer
        let accentRectInControl = selfLayer.convert(accentLayer.bounds, from: accentLayer)

        // The lens, expressed in the accent view's own coordinates. Masking
        // with the full capsule path, not a rectangle intersection, keeps
        // the rounded ends of the lens reading as rounded where a word
        // crosses them.
        let local = CGRect(
            x: indicatorRect.origin.x - accentRectInControl.origin.x,
            y: indicatorRect.origin.y - accentRectInControl.origin.y,
            width: indicatorRect.width,
            height: indicatorRect.height
        )
        let capsule = UIBezierPath(roundedRect: local, cornerRadius: indicatorRect.height / 2)

        let accentMask = accent.layer.mask as? CAShapeLayer ?? {
            let created = CAShapeLayer()
            accent.layer.mask = created
            return created
        }()
        accentMask.path = capsule.cgPath

        if indicatorRect.intersects(accentRectInControl) {
            let baseMask = base.layer.mask as? CAShapeLayer ?? {
                let created = CAShapeLayer()
                base.layer.mask = created
                return created
            }()
            let path = UIBezierPath(rect: base.bounds)
            path.append(capsule)
            baseMask.fillRule = .evenOdd
            baseMask.path = path.cgPath
        } else {
            base.layer.mask = nil
        }
    }

    // MARK: Touch

    private func segmentIndex(at point: CGPoint) -> Int {
        guard numberOfSegments > 0, bounds.width > 0 else { return 0 }
        let segmentWidth = bounds.width / CGFloat(numberOfSegments)
        return min(max(Int(point.x / segmentWidth), 0), numberOfSegments - 1)
    }

    /// False at accessibility content sizes. At those sizes the control
    /// shows a popover, and an index change on touch-down gives incorrect
    /// results.
    private var movesIndicatorOnTouchDown: Bool {
        !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else {
            super.touchesBegan(touches, with: event)
            return
        }
        displayLink?.isPaused = false
        stableFrameCount = 0
        if movesIndicatorOnTouchDown {
            // Moving the index on touch-down is what animates the lens.
            // An unmodified `UISegmentedControl` only animates its lens when
            // the drag starts outside the already-selected segment, so a
            // tap on a far segment would otherwise move the lens with no
            // animation. Selection itself waits for touch-up, so nothing
            // commits while the finger is down.
            originalIndex = selectedSegmentIndex
            selectedSegmentIndex = segmentIndex(at: touch.location(in: self))
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else {
            super.touchesMoved(touches, with: event)
            return
        }
        displayLink?.isPaused = false
        stableFrameCount = 0
        let index = segmentIndex(at: touch.location(in: self))
        if movesIndicatorOnTouchDown, selectedSegmentIndex != index {
            selectedSegmentIndex = index
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        displayLink?.isPaused = false
        stableFrameCount = 0
        if movesIndicatorOnTouchDown, let originalIndex {
            if selectedSegmentIndex != originalIndex {
                sendActions(for: .valueChanged)
            } else {
                onReselect?(selectedSegmentIndex)
            }
        }
        originalIndex = nil
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        displayLink?.isPaused = false
        stableFrameCount = 0
        if movesIndicatorOnTouchDown, let originalIndex {
            selectedSegmentIndex = originalIndex
        }
        originalIndex = nil
        super.touchesCancelled(touches, with: event)
    }
}

/// A plain `UIView` that pins the control to its own four edges.
///
/// `UISegmentedControl` has a fixed intrinsic height of 32pt. A SwiftUI
/// frame alone does not change its bounds, so the lens stays small. Auto
/// Layout constraints to a sized container change the bounds, and the
/// lens grows with them. FabBar uses the same container method.
final class ChinSegmentedControlContainer: UIView {
    let control: ChinSegmentedControl

    init(control: ChinSegmentedControl) {
        self.control = control
        super.init(frame: .zero)
        addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Keeps `CADisplayLink` from retaining the control forever.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var control: ChinSegmentedControl?

    init(control: ChinSegmentedControl) {
        self.control = control
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let control else {
            link.invalidate()
            return
        }
        control.updateAccentMasks()
    }
}

// MARK: - SwiftUI wrapper (generic)

/// A `UISegmentedControl`-backed Liquid Glass switcher, generalized over any
/// `Hashable` selection. `ChinTabSegmentedControl` below is the three-mode
/// specialization `ChinNavigation` mounts. The photo Share picker
/// (`PhotoPostView.sharePickerContent`) mounts a second instance over
/// `ShareKind`. Both get the system's draggable lens, using the same
/// mechanics described in the provenance note at the top of this file.
///
/// A change to `selection` moves the lens and does not call `onSelect`,
/// because a programmatic write to `selectedSegmentIndex` never sends
/// `.valueChanged`. `nil` selects no segment
/// (`UISegmentedControl.noSegment`). The Share picker uses `nil` to keep
/// the lens hidden until the first touch. `onSelect` fires only on
/// touch-up over a different segment. `onReselect` fires on touch-up
/// over the segment that was already selected. Both callers treat
/// `onReselect` as a pick that collapses the capsule.
struct LiquidSegmentedControl<Selection: Hashable>: UIViewRepresentable {
    /// One segment's value, title, SF Symbol name, and frozen accessibility
    /// identifier, in display order — the order the segments are built in.
    struct Item {
        let value: Selection
        let title: String
        let symbolName: String
        let identifier: String
    }

    let items: [Item]
    let selection: Selection?
    let onSelect: (Selection) -> Void
    let onReselect: (Selection) -> Void

    private func index(of selection: Selection?) -> Int {
        guard let selection, let found = items.firstIndex(where: { $0.value == selection }) else {
            return UISegmentedControl.noSegment
        }
        return found
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ChinSegmentedControlContainer {
        let control = ChinSegmentedControl(items: items.map(\.title))
        control.selectedSegmentIndex = index(of: selection)
        control.segmentIdentifiers = items.map(\.identifier)
        control.configureContent(items.map { ($0.title, $0.symbolName) })

        // The lens's own tint. The capsule uses `FeedGlass.style`,
        // black-tinted glass chosen so white glyphs stay legible over a
        // bright video frame. A black lens is not visible on that glass,
        // so the lens uses a light tint.
        control.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.20)
        control.activeTintColor = .white
        control.inactiveTintColor = UIColor.white.withAlphaComponent(0.7)
        // Keeps the control from dimming itself when the app presents a
        // sheet over the feed. Its colors are already fixed white, not a
        // dynamic tint.
        control.tintAdjustmentMode = .normal
        // Disable the large-content viewer. It is a long-press HUD for
        // tab bars, and this small capsule shows over video.
        control.showsLargeContentViewer = false

        control.addTarget(context.coordinator,
                          action: #selector(Coordinator.valueChanged(_:)),
                          for: .valueChanged)
        control.onReselect = { [weak coordinator = context.coordinator] index in
            coordinator?.reselected(index)
        }
        return ChinSegmentedControlContainer(control: control)
    }

    /// Returns SwiftUI's proposal unchanged, so the container takes the
    /// frame the caller asks for, instead of collapsing onto the segmented
    /// control's 32pt intrinsic height. See `ChinSegmentedControlContainer`.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: ChinSegmentedControlContainer,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width,
               height: proposal.height ?? uiView.intrinsicContentSize.height)
    }

    func updateUIView(_ container: ChinSegmentedControlContainer, context: Context) {
        let control = container.control
        context.coordinator.parent = self
        let idx = index(of: selection)
        if control.selectedSegmentIndex != idx {
            control.selectedSegmentIndex = idx
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: LiquidSegmentedControl

        init(parent: LiquidSegmentedControl) {
            self.parent = parent
        }

        @objc func valueChanged(_ control: UISegmentedControl) {
            let index = control.selectedSegmentIndex
            guard parent.items.indices.contains(index) else { return }
            parent.onSelect(parent.items[index].value)
        }

        func reselected(_ index: Int) {
            guard parent.items.indices.contains(index) else { return }
            parent.onReselect(parent.items[index].value)
        }
    }
}

/// The three chin-nav destinations. This named type keeps the item list
/// and the `chin_nav_*` identifiers in one place for `ChinNavigation`,
/// rather than spelling out `LiquidSegmentedControl<AppMode>` at every
/// call site.
struct ChinTabSegmentedControl: View {
    let selection: AppMode
    let onSelect: (AppMode) -> Void
    let onReselect: (AppMode) -> Void

    /// Title, glyph and frozen accessibility identifier per tab, in
    /// `AppMode.allCases` order.
    private static let items: [LiquidSegmentedControl<AppMode>.Item] = [
        .init(value: .videos, title: "Videos", symbolName: "video", identifier: "chin_nav_videos"),
        .init(value: .photos, title: "Photos", symbolName: "photo.on.rectangle", identifier: "chin_nav_photos"),
        .init(value: .settings, title: "Settings", symbolName: "gearshape", identifier: "chin_nav_settings"),
    ]

    var body: some View {
        LiquidSegmentedControl(items: Self.items, selection: selection, onSelect: onSelect, onReselect: onReselect)
    }
}
