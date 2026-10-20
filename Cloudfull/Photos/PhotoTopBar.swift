//
//  PhotoTopBar.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Photos-mode top chrome. It uses independent `.glass` buttons and no
/// `GlassEffectContainer`, for the same XCUITest hit-target reason as
/// `FeedView.topChrome`.
///
/// Left to right: `live_toggle` (where the mute pill is in Videos),
/// `PhotoFilterMenuView`, a spacer, the invisible `space_counter` text,
/// and `bin_open`.
struct PhotoTopBar: View {
    @ObservedObject var trashService: TrashService
    @Binding var isLiveOn: Bool
    let safeAreaTop: CGFloat
    let onOpenBinRequested: () -> Void
    /// Mirrored-layout round: true when the host's own `DuoLayout
    /// .isMirrored` reads true — see `FeedView.topChrome`'s identical
    /// mirror for the reasoning. Default `false`, pixel-identical to
    /// before this round.
    ///
    /// Decision 1 (owner, 2026-10-12): "the heart to delete got
    /// mirrored. Don't do that." `PhotoFeedView` now always passes
    /// `false` here — this row's own order must stay exactly as if
    /// not mirrored even in a mirrored window; only `ChinNavigation`
    /// (the tab switcher) still moves. `row`'s `if isMirrored` branch
    /// below is left in place rather than removed, but it is
    /// unreachable from `PhotoFeedView` as of this decision.
    var isMirrored: Bool = false
    /// Non-nil on the Duo poses that place this row themselves —
    /// `DuoLayout.photosTopRowRect` — in true window space. `nil` keeps
    /// the original padding placement below, byte-for-byte: regular
    /// iPhone, `.tent`.
    var placement: CGRect? = nil
    /// `true` only on poses 3/4 (`.openWide`/`.book`), where the row
    /// starts flush at the window's own leading edge and the display's
    /// rounded top corner is big enough to clip the Live button there.
    var clearsCorner: Bool = false
    /// The window's own control-cluster width, on an iPadOS 26 windowed
    /// app — see `FeedView.topChrome`'s own comment for the full
    /// reasoning. Zero everywhere else, including when `placement` is
    /// non-nil: `DuoLayout.photosTopRowRect` already folds this same
    /// value into `placement` itself for that case, so only the `nil`
    /// branch below still needs it.
    var windowControlLeadingInset: CGFloat = 0

    @ObservedObject private var photoOptionsStore = PhotoOptionsStore.shared

    var body: some View {
        Group {
            if let placement {
                if clearsCorner {
                    row
                        .frame(width: placement.width, height: placement.height, alignment: .center)
                        .containerCornerOffset(.top)
                        .position(x: placement.midX, y: placement.midY)
                } else {
                    row
                        .frame(width: placement.width, height: placement.height, alignment: .center)
                        .position(x: placement.midX, y: placement.midY)
                }
            } else {
                row
                    .padding(.horizontal, 12)
                    .padding(.top, StageGeometry.chromeTop(safeAreaTop: safeAreaTop))
                    // This view's own caller (`PhotoFeedView`) already
                    // hands this whole branch a FIXED width — its
                    // `.frame(width: availableRect.width, …)`, unchanged
                    // — so padding the row in on the leading side alone
                    // shrinks what `row`'s own `Spacer` has left to
                    // fill, rather than growing this view's own
                    // reported size past that fixed width. Slides the
                    // row clear of an iPadOS 26 window's own
                    // control cluster while leaving `binButton`'s
                    // trailing edge exactly where it always was. See
                    // `FeedView.topChrome`'s own comment for why a
                    // vertical-only fix (`containerCornerOffset(.top)`,
                    // `clearsCorner`'s own branch above) could never
                    // have cleared this on its own.
                    .padding(.leading, windowControlLeadingInset)
            }
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 8) {
            // Review fix: Bin is the OUTERMOST control in the mirrored
            // row, same as `FeedView.topChrome`'s own mirrored branch —
            // the owner's rule, "Bin outermost, same as the mirrored
            // top row." This row used to read counter-then-Bin.
            if isMirrored {
                binButton
                counterCapsule
                Spacer(minLength: 8)
                PhotoFilterMenuView(store: photoOptionsStore)
                liveToggleButton
            } else {
                liveToggleButton
                // The photo-specific filter menu, distinct from the
                // video feed's filter menu.
                PhotoFilterMenuView(store: photoOptionsStore)
                Spacer(minLength: 8)
                counterCapsule
                binButton
            }
        }
    }

    // MARK: - Live toggle

    private var liveToggleButton: some View {
        Button {
            isLiveOn.toggle()
            Usage.shared.liveToggled(nowOn: isLiveOn)
        } label: {
            Image(systemName: isLiveOn ? "livephoto" : "livephoto.slash")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .tint(.white)
        // This toggle is a feed-wide setting, not a per-photo control, so
        // it is never dimmed for a still post. It always carries its
        // identifier, unlike the video top chrome's `isFullscreen`-gated
        // controls, since Photos mode has no fullscreen mode to hide it
        // for.
        .accessibilityIdentifier("live_toggle")
        .accessibilityLabel(isLiveOn ? "Live Photos on" : "Live Photos off")
        .accessibilityHint("Double tap to turn Live Photos \(isLiveOn ? "off" : "on")")
    }

    // MARK: - Space counter (mirrors FeedView.counterCapsule)
    //
    // `binButton`'s text shows the pending-bytes figure (see
    // `binBadgeText`). This view still exists, sized to 1x1 and invisible.
    // It stays only so `space_counter`'s identifier and label keep
    // resolving for `M11Tests` (`spaceCounterLabel()` reads it in Photos
    // mode too).
    // `.accessibilityHidden` would remove it from the tree those tests
    // query through `app.staticTexts["space_counter"]`. So this stays a
    // real, accessibility-visible `Text` with the same label, collapsed to
    // no size and no glass.
    @ViewBuilder
    private var counterCapsule: some View {
        if trashService.pendingBytes > 0 {
            Text(pendingSpaceText)
                .accessibilityIdentifier("space_counter")          // Frozen identifier, on the Text
                .accessibilityLabel(pendingSpaceAccessibilityLabel)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
    }

    private var pendingSpaceText: String {
        let prefix = trashService.hasEstimatedSizes ? "About " : ""
        return "\(prefix)\(Fmt.bytes(trashService.pendingBytes)) pending"
    }

    private var pendingSpaceAccessibilityLabel: String {
        "\(Fmt.bytes(trashService.pendingBytes)) pending. Freed after you empty the bin and Photos clears Recently Deleted."
    }

    // MARK: - Bin (mirrors FeedView.binButton)

    private var binButton: some View {
        Button(action: onOpenBinRequested) {
            HStack(spacing: 5) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 15, weight: .medium))
                if let binBadgeText {
                    Text(binBadgeText)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(.white)
            .frame(minHeight: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.white)
        // Shakes on each addition once the bin is worth emptying.
        .binShake(count: trashService.count)
        .accessibilityIdentifier("bin_open")
        // Do not add the byte figure to this label. A test that filters
        // digits would read "314" instead of "3". `binBadgeText` shows the
        // bytes on screen, and `space_counter` announces them.
        .accessibilityLabel(trashService.count > 0 ? "Bin, \(trashService.count) queued" : "Bin")
        .accessibilityHint("Opens the list of videos and photos queued for deletion")
    }

    /// The bin pill's own on-screen text: just the count when nothing is
    /// pending, "1 · 14 MB" once something is. Mirrors `FeedView.binBadgeText`
    /// exactly, minus that view's shrink-job gate, since Photos mode has
    /// no `ShrinkService` jobs to hide the figure behind.
    private var binBadgeText: String? {
        guard trashService.count > 0 else { return nil }
        guard trashService.pendingBytes > 0 else { return "\(trashService.count)" }
        return "\(trashService.count) \u{00B7} \(Fmt.bytes(trashService.pendingBytes))"
    }
}
