//
//  DesignSystem.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

// MARK: - Feed chrome

extension View {
    /// The only shadow in Cloudfull. It keeps white glyphs and white text
    /// legible on a bright video frame. Use it only in the feed.
    func feedShadow() -> some View {
        shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
    }
}

// MARK: - Feed glass

/// The single Liquid Glass recipe for chrome that sits over, or just above,
/// the video.
///
/// One constant gives all of these the same glass. The list: the top
/// pills, the shrink toast, the rail callout, the exhausted card, the 2x
/// pill, the scrubber readout, and the fullscreen chrome. A legibility
/// fallback becomes a one-line change here instead of a change at each
/// call site.
enum FeedGlass {
    /// The glass for the Cloudfull pills (bin, mute, filter, the
    /// `ChinNavigation` shell, pending, shrink). It uses untinted
    /// `.regular`, the same as the glass in `ChinTabSegmentedControl`.
    ///
    /// Plain `.regular` gives a contrast of about 1.03:1 on a pure white
    /// frame, so a white glyph can disappear. A dark tint fixes this but
    /// makes the pill look dark and opaque next to the Apple lens.
    ///
    /// `Glass.clear` also exists on this SDK. Try it if `.regular` looks
    /// too frosted next to the lens.
    ///
    /// If a white glyph disappears on a bright frame, add a light shadow
    /// to that glyph, not to this glass. Do not reuse `feedShadow()` for
    /// this. That shadow is tuned for text on video, a stronger effect
    /// than a pill glyph needs. Use a lighter shadow on the glyph that
    /// fails. For example: `.shadow(color: .black.opacity(0.35), radius:
    /// 1.5, x: 0, y: 0.5)`.
    ///
    /// Confirm the need for a shadow on the simulator or a device. Use a
    /// real bright frame under a real pill before you add it.
    static let style: Glass = .regular
}

extension View {
    /// Liquid Glass backing for a pill that sits over video. Use the same
    /// shape and position in the view chain as a plain background call.
    /// Do not change the padding or the frame.
    func feedGlass(in shape: some Shape) -> some View {
        glassEffect(FeedGlass.style, in: shape)
    }

    /// The same glass recipe for use inside a `Button` label.
    ///
    /// A `Menu` handles its own touches, but a plain `Button` whose label
    /// carries non-interactive glass can lose taps to the glass layer
    /// itself. `.interactive()` marks glass that sits on a control, so the
    /// button receives the tap correctly.
    func feedGlassButton(in shape: some Shape) -> some View {
        glassEffect(FeedGlass.style.interactive(), in: shape)
    }
}

/// Fixed optical metrics for the vertical action rail. These are point
/// sizes, not text styles, so the rail does not reflow into the video
/// frame under large Dynamic Type.
///
/// The 40pt hit box is smaller than Apple's 44pt guideline on purpose. The
/// label under each glyph shares the same `contentShape`, so the real
/// tappable area of each item is still about 55pt tall.
enum Rail {
    static let glyph: CGFloat = 30
    // Three rail symbols do not render at the same size as the others at
    // one point size. Each below gets its own optical correction.
    //
    // Measured off a 3x screenshot of the rail. SF Symbols draw to their
    // own ink, not to a shared box. So `heart`, `share`, `album`, and
    // `shrink` render at different heights at the same point size.
    // `heart` is the reference.
    //
    // Each constant makes the glyph ink the same height as the heart.
    // `album` uses a smaller value than an exact height match. A boxy
    // glyph carries more ink than an open curve, so it reads as heavier
    // at the same height. Its smaller mark also made the gap to its
    // label wider than the other rows. `trash` follows the same
    // measurement from the photo row.
    static let album: CGFloat = glyph * 0.86
    static let shrink: CGFloat = glyph * 0.79
    static let trash: CGFloat = glyph * 0.85
    static let hit: CGFloat = 40
    static let spacing: CGFloat = 20
    static let labelFont = Font.system(size: 10, weight: .semibold)
    /// Gap between the rail's bottom edge and the video's bottom edge, the
    /// playhead seam. The rail sits on top of the video. See
    /// `FeedPageContent.actionRail`.
    static let seamClearance: CGFloat = 12
}

// MARK: - Accent-filled buttons

extension View {
    /// Black label for a button filled with the plain accent color, for
    /// example `.buttonStyle(.borderedProminent)` with no `.tint`
    /// override. The accent is a light sky blue, so the system's default
    /// white label is hard to read on it. Chain this after
    /// `.buttonStyle`, the same spot `.tint` goes.
    func accentButtonLabel() -> some View {
        foregroundStyle(.black)
    }
}

// MARK: - Formatting

/// Shared value formatting for the feed caption, the bin header, and the
/// shrink sheet. All three use these functions, so their formats stay the
/// same.
enum Fmt {
    /// Formats a byte count, for example "428 MB". Uses
    /// `ByteCountFormatter` with the `.file` count style.
    static func bytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Formats seconds as "0:34", "1:12", or "12:03".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Classifies a video's resolution by its short side into "4K",
    /// "1440p", "1080p", "720p", or its literal pixel count, for example
    /// "1179p". Uses the same dimension `isAboveShrinkThreshold` below
    /// classifies by, so the caption and shrink eligibility can never
    /// disagree.
    ///
    /// A size strictly between the 1080p and 1440p tiers reports its
    /// literal pixel count instead of rounding down to "1080p".
    static func resolution(_ size: CGSize) -> String {
        let short = Int(min(size.width, size.height))
        switch short {
        case 2160...:     return "4K"
        case 1440..<2160: return "1440p"
        case 1081..<1440: return "\(short)p"
        case 1080:        return "1080p"
        case 720..<1080:  return "720p"
        default:          return short > 0 ? "\(short)p" : ""
        }
    }

    /// True when the asset's short side is 2160px or more, the 4K tier.
    /// 1440p and smaller sizes, including screen-recording resolutions
    /// like 1179x2556, do not qualify.
    ///
    /// `resolution(_:)` above uses the same short-side measurement, so a
    /// video this returns `true` for is always labeled "4K" there.
    /// `PhotoLibraryService` stores this result in the asset metadata.
    /// The caption and the rail read that stored value.
    static func isAboveShrinkThreshold(_ size: CGSize) -> Bool {
        Int(min(size.width, size.height)) >= 2160
    }
}

// MARK: - Stage geometry

/// Pure geometry for the fixed 9:16 video stage. `FeedView` uses it for
/// the top chrome placement. `PlayerPageView` uses it for the video's own
/// position and `ScrubberView`'s seam.
///
/// Each caller passes in its own `GeometryReader` proxy values rather than
/// reading a shared instance, because neither type has another source for
/// them. Every function here takes only a container size and, where
/// relevant, the real safe-area top inset a `GeometryReader` proxy
/// reports. It never reads UIKit directly.
enum StageGeometry {
    /// Height of the band the fixed 9:16 stage leaves above and below the
    /// video, before the island-clearance shift below applies. Equal on
    /// both sides: half of the screen's leftover vertical space.
    static func naturalBand(containerSize: CGSize) -> CGFloat {
        max(0, (containerSize.height - containerSize.width * 16 / 9) / 2)
    }

    /// The y position of the top edge of the chrome, from the window top.
    ///
    /// For an inset of 44pt or more, the chrome moves 11pt up into the
    /// inset, below the island or notch. For a smaller inset, the chrome
    /// sits 2pt below the inset, below the status bar text.
    static func chromeTop(safeAreaTop: CGFloat) -> CGFloat {
        safeAreaTop >= 44 ? safeAreaTop - 11 : safeAreaTop + 2
    }

    /// Height of the chrome.
    static let chromeHeight: CGFloat = 32
    /// Gap kept between the chrome's bottom edge and the video's top edge.
    static let chromeToVideoGap: CGFloat = 4

    /// Extra downward shift applied to the whole stage, so the fixed top
    /// chrome clears the Dynamic Island without the video overflowing the
    /// screen.
    ///
    /// The shift is the smallest value that fits `chromeTop` +
    /// `chromeHeight` + `chromeToVideoGap` in the top band. It is 0 when
    /// the natural band is large enough. It is never more than the band,
    /// so the bottom band cannot go negative.
    static func downShift(safeAreaTop: CGFloat, containerSize: CGSize) -> CGFloat {
        let band = naturalBand(containerSize: containerSize)
        let requiredTopBand = chromeTop(safeAreaTop: safeAreaTop) + chromeHeight + chromeToVideoGap
        let shortfall = requiredTopBand - band
        guard shortfall > 0 else { return 0 }
        return min(shortfall, band)
    }

    /// Height of the black band below the down-shifted 9:16 stage: the
    /// natural band minus whatever `downShift` moved the stage by. This is
    /// where the video's bottom edge, the playhead seam, sits, measured
    /// from the page bottom.
    ///
    /// `PlayerPageView` uses this value for the stage and the scrubber.
    /// `FeedPageContent` uses it for the rail, so the rail can never
    /// disagree with the video about where that edge sits.
    static func bottomBand(safeAreaTop: CGFloat, containerSize: CGSize) -> CGFloat {
        max(0, naturalBand(containerSize: containerSize) - downShift(safeAreaTop: safeAreaTop, containerSize: containerSize))
    }

    /// `ChinNavigation`'s own vertical anchor in Videos mode. Photos mode
    /// uses the same spot, since it has no chin to center on.
    ///
    /// Derived from `FeedView.captionZone`'s fixed layout: a
    /// `.padding(.bottom, 20)` under a two-line block, 16pt semibold plus
    /// 14pt body with 3pt spacing. The system line heights put the block
    /// at roughly 39pt. This value is a fixed offset from the page
    /// bottom on every device, not a fraction of `bottomBand`'s
    /// device-varying chin height. The rounded value of 40 avoids
    /// re-deriving UIFont line metrics at runtime.
    static let captionCenterFromBottom: CGFloat = 40

    /// The caption block's top edge sits at `captionCenterFromBottom`
    /// plus half of that same 39pt block, rounded up. This is measured
    /// from the page bottom.
    ///
    /// The feed's loading ring uses this value. The ring sits inside the
    /// stage. On a phone close to 16:9, the band under the stage is zero.
    /// Then the stage bottom is the page bottom. A fixed gap above the
    /// stage would put the ring on the caption. The ring compares itself
    /// against this number and lifts when it needs to.
    static let captionTopFromBottom: CGFloat = 60
}
