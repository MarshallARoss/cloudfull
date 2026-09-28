//
//  FullscreenPlayerChrome.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The minimal chrome shown over a rotated, fullscreen video.
/// `PlayerPageView` mounts this view only while `isFullscreen` is true,
/// inside the same rotated canvas as the video itself, so it rotates with
/// the video and reads upright in the user's hand. This view never reads
/// `deviceStance` or applies its own rotation.
///
/// Hidden by default. A tap anywhere on the stage toggles `revealed`; that
/// tap gesture lives on `PlayerPageView`, not here, since this view only
/// renders the state. The chrome auto-hides 3 seconds after it is
/// revealed, unless VoiceOver is running, in which case it stays up. A
/// hidden-until-tapped control is unreachable to a screen-reader user, and
/// the dismiss button is the only non-physical way to leave fullscreen.
struct FullscreenPlayerChrome: View {
    /// Owned by `PlayerPageView` (`chromeRevealed`), which resets it under
    /// its own rules for leaving fullscreen. This view only toggles it
    /// through the auto-hide timer below.
    @Binding var revealed: Bool
    /// `PlayerPageView` increases this value on every stage tap while
    /// fullscreen; see its own doc comment. `chromeTaskID` below folds this
    /// value in. A repeat tap while `revealed` is already `true` still
    /// restarts the auto-hide countdown, instead of leaving the original
    /// timer running.
    let revealNonce: Int
    /// A value from 0 to 1, the same value `PlayerPageView` reads for the
    /// scrubber, which this view does not show. It drives only the
    /// read-only hairline.
    let progress: Double
    let isMuted: Bool
    let onDismiss: () -> Void
    let onToggleMute: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// The auto-hide delay: 3 seconds. No other value in this app shares it.
    private static let autoHideDelay: TimeInterval = 3.0

    /// The chrome's actual on-screen state: the explicit toggle, or
    /// VoiceOver forcing it up regardless of the toggle.
    private var isShown: Bool { revealed || voiceOverEnabled }

    var body: some View {
        ZStack {
            if isShown {
                controls
                    .transition(.opacity)
            }
            hairline

            // `fullscreen_overlay` lives on its own leaf, not on this `ZStack`
            // directly. A bare `.accessibilityIdentifier` on a group applies to
            // every descendant that has no identifier of its own, and outranks
            // the ones that do. This container holds `fullscreen_dismiss` and
            // `fullscreen_mute_toggle`, which must keep resolving by their own
            // strings. An invisible 1x1 leaf carries `fullscreen_overlay`
            // instead, and nothing else does.
            //
            // This leaf stays present for the whole fullscreen session,
            // regardless of `isShown`. It sits unconditionally in the tree,
            // not inside the `if isShown` branch above. This lets a test check
            // whether the app is in fullscreen without first tapping to
            // reveal anything.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("fullscreen_overlay")
        }
        .animation(.easeInOut(duration: 0.2), value: isShown)
        // Schedules the auto-hide exactly once per reveal. `.task(id:)`
        // cancels and restarts on every change of `chromeTaskID`. A new tap,
        // or the hide this task performs itself, always replaces a pending
        // sleep instead of running alongside it. `FeedView` uses the same
        // cancel-and-restart shape with a stored `Task` handle. This view
        // expresses it as a task identity instead, since a view is not a
        // reference type.
        //
        // This key includes both `revealed` and `revealNonce`, not `revealed`
        // alone. `PlayerPageView`'s stage tap sets `revealed = true`
        // unconditionally, so a tap while already revealed is a same-value
        // assignment. `revealed` alone would not register that as a change,
        // which would leave the original timer running unextended.
        // Increasing `revealNonce` on every such tap makes each tap a new
        // id, so each tap restarts the countdown.
        .task(id: chromeTaskID) {
            guard revealed, !voiceOverEnabled else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.autoHideDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            revealed = false
        }
    }

    private struct ChromeTaskID: Equatable {
        let revealed: Bool
        let nonce: Int
    }

    private var chromeTaskID: ChromeTaskID {
        ChromeTaskID(revealed: revealed, nonce: revealNonce)
    }

    private var controls: some View {
        VStack {
            HStack(alignment: .top) {
                dismissButton
                Spacer()
                muteButton
            }
            .padding(.top, 44)
            .padding(.horizontal, 44)
            Spacer(minLength: 0)
        }
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .tint(.white)
        .accessibilityIdentifier("fullscreen_dismiss")
        .accessibilityLabel("Exit fullscreen")
        .accessibilityHint("Returns this video to the feed")
    }

    /// Uses the same glyphs as `feed_mute_toggle`, but is a new element
    /// with a new identifier. `feed_mute_toggle`'s string is frozen and
    /// belongs to a control that stays mounted throughout, so reusing it
    /// here would give the singular lookup
    /// `app.buttons["feed_mute_toggle"]` two matches while fullscreen is
    /// up.
    private var muteButton: some View {
        Button(action: onToggleMute) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .tint(.white)
        .accessibilityIdentifier("fullscreen_mute_toggle")
        .accessibilityLabel(isMuted ? "Sound off" : "Sound on")
        .accessibilityHint("Double tap to turn sound \(isMuted ? "on" : "off")")
    }

    /// A plain, decorative two-tone `Capsule` pair, with no gesture, no
    /// `ScrubberView`, and no identifier, so position stays visible
    /// without re-deriving any scrub math in a rotated coordinate space.
    /// This view renders the hairline unconditionally, not only inside the
    /// `if isShown` branch above. Position then stays legible even while
    /// the rest of the chrome is hidden, which matches `ScrubberView`'s
    /// own idle-state behavior elsewhere in this app.
    private var hairline: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 2)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
