//
//  ScrubberView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// `PlayerPageView` mounts this view as an overlay on `stageContent`,
/// after that view's own `.clipped()`. The clip then does not cut the
/// part of this view below the stage. This view shows a hairline progress
/// line at rest. On touch-and-hold, it thickens into a draggable track
/// and knob. It scrolls with its own page, the same as the rail.
///
/// The scrubber's resting anchor is the stage's bottom seam, in both
/// states. `track`'s top edge stays pinned there, whether it is the 2pt
/// idle line or the 6pt active track. The knob, when scrubbing, shares
/// that same top edge instead of centering on the track. Nothing ever
/// renders above the seam, into video pixels, in either state (see
/// `seamOffset`). Only the content drawn from that fixed anchor changes
/// between states. The anchor itself never moves, so idle to active never
/// jumps up onto the video first. The time readout sits below the track,
/// inside the band, never higher than the track or knob.
///
/// This view holds no state. `PlayerPageView` owns `isScrubbing`, the
/// finger-driven fraction, playback pause and resume, and the seek
/// itself. `PlayerPageView` also owns the long-press-anywhere entry
/// point. That gesture must attach to the whole stage, not just this
/// 28pt strip.
struct ScrubberView: View {
    /// 0...1 idle playback position, from `PlayerHolder`'s periodic time
    /// observer. Ignored while `isScrubbing` — the finger position wins.
    let progress: Double
    let isScrubbing: Bool
    /// 0...1 finger-driven position while `isScrubbing` is true.
    let scrubFraction: Double
    let durationSeconds: Double
    /// Height of the black band `PlayerPageView` leaves below the fixed
    /// 9:16 stage on this screen. Drives `seamOffset` — the scrubber (idle
    /// or active) only moves to the seam when this band has room for it.
    let bandHeight: CGFloat
    /// Gates every accessibility identifier: off-center pages render the
    /// same hairline, fully interactive, without identifiers.
    let isActive: Bool
    let reduceMotion: Bool
    /// Fires continuously while the user drags the 28pt strip, with the
    /// raw fraction under the finger. `PlayerPageView` owns starting and
    /// ending the scrub and the actual seek.
    let onStripDrag: (Double) -> Void
    let onStripEnded: () -> Void

    private var displayedFraction: Double {
        isScrubbing ? scrubFraction : progress
    }

    private var currentSeconds: Double {
        displayedFraction * durationSeconds
    }

    /// `track`'s own hit box height — fixed regardless of state, so
    /// `seamOffset` (below) never has to change between idle and active and
    /// the anchor never translates.
    private static let trackBoxHeight: CGFloat = 28
    /// Knob diameter. Matches the `Circle` in `track`.
    private static let knobHeight: CGFloat = 14
    private static let readoutGap: CGFloat = 6
    /// Distance from the seam to the top of the time readout.
    private static let readoutTopOffset: CGFloat = knobHeight + readoutGap
    /// Below this much band, the active state's full stack (knob, plus
    /// `readoutTopOffset` and the readout's own height) would extend below
    /// the bottom edge of this page. Below this threshold, both states
    /// fall back to the on-video placement instead of the seam.
    private static let minimumSeamBand: CGFloat = 50

    /// How far to shift `track` down so its top edge lands on the seam.
    /// Unshifted, that edge sits flush with this view's bottom edge,
    /// `trackBoxHeight` above the seam. Idle and active share this one
    /// anchor. The transition between them only changes what is drawn from
    /// it, never where it is. Zero when the band is too small to hold the
    /// shift.
    private var seamOffset: CGFloat {
        bandHeight >= Self.minimumSeamBand ? Self.trackBoxHeight : 0
    }

    var body: some View {
        ZStack(alignment: .top) {
            track
            if isScrubbing {
                Text(timeText)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .feedGlass(in: Capsule())
                    .transition(reduceMotion ? .identity : .opacity)
                    // Below `track`, inside the band — never above it,
                    // into video pixels.
                    .offset(y: Self.readoutTopOffset)
                    // Hide from VoiceOver. The track's `.accessibilityValue`
                    // speaks the same time. This view is a sibling of
                    // `track`, so `track`'s `.accessibilityElement()` does
                    // not hide its identifier.
                    .accessibilityHidden(true)
                    .accessibilityIdentifier(isActive ? "scrubber_time" : "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .offset(y: seamOffset)
        // Use the same animation as `track`. With Reduce Motion on, both
        // use no animation.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isScrubbing)
        .allowsHitTesting(true)
    }

    private var timeText: String {
        "\(clock(currentSeconds)) / \(clock(durationSeconds))"
    }

    /// `Fmt.duration` returns "" for zero or a negative value. The readout
    /// shows "0:00" in that case, so the "current / total" pair is never
    /// half empty.
    private func clock(_ seconds: Double) -> String {
        let text = Fmt.duration(seconds)
        return text.isEmpty ? "0:00" : text
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            // `.topLeading`: horizontal leading, so the fill grows from
            // the left. Vertical top, so the 2pt idle line and the 6pt
            // active track share one top edge, the seam. Neither grows
            // from a shared centerline.
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: isScrubbing ? 6 : 2)
                Capsule()
                    .fill(Color.white.opacity(isScrubbing ? 1.0 : 0.55))
                    .frame(width: width * displayedFraction, height: isScrubbing ? 6 : 2)
                if isScrubbing {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .offset(x: width * displayedFraction - 7)
                        // Top-aligned with the track above, not centered
                        // on it. Centering a 14pt knob on a 6pt track
                        // anchored at the seam would push 4pt of the knob
                        // above the seam, into video.
                        // Hidden from VoiceOver, matching `scrubber_time`.
                        .accessibilityHidden(true)
                        .accessibilityIdentifier(isActive ? "scrubber_knob" : "")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .frame(height: 28)
            .contentShape(Rectangle())
            // Direct entry: `minimumDistance: 0` means touching the strip
            // starts scrubbing immediately, with no hold required. The
            // long-press requirement applies only to entering from
            // elsewhere on the stage, through `PlayerPageView`'s own
            // gesture.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onStripDrag(min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { _ in onStripEnded() }
            )
        }
        .frame(height: 28)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isScrubbing)
        .accessibilityElement()
        .accessibilityIdentifier(isActive ? "scrubber_track" : "")
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(clock(currentSeconds)) of \(clock(durationSeconds))")
        // Reachable without the drag gesture at all, in steps of ±5
        // seconds. `accessibilityAdjustableAction` applies the
        // `.isAdjustable` trait itself; there is no separate trait to add.
        .accessibilityAdjustableAction { direction in
            guard durationSeconds > 0 else { return }
            let step = 5.0 / durationSeconds
            switch direction {
            case .increment:
                let fraction = min(displayedFraction + step, 1)
                onStripDrag(fraction)
                onStripEnded()
            case .decrement:
                let fraction = max(displayedFraction - step, 0)
                onStripDrag(fraction)
                onStripEnded()
            @unknown default:
                break
            }
        }
    }
}
