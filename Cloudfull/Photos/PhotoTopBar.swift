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

    @ObservedObject private var photoOptionsStore = PhotoOptionsStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            liveToggleButton
            // The photo-specific filter menu, distinct from the video
            // feed's filter menu.
            PhotoFilterMenuView(store: photoOptionsStore)
            Spacer(minLength: 8)
            counterCapsule
            binButton
        }
        .padding(.horizontal, 12)
        .padding(.top, StageGeometry.chromeTop(safeAreaTop: safeAreaTop))
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
