//
//  BinShake.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Shakes the bin icon after each addition when the bin holds 12 or more
/// items. The shake gets stronger as the count grows.
///
/// One modifier applies to the bin pill in both top bars. The two views
/// always agree on when the bin starts shaking and how hard.
///
/// A shake on every delete is too frequent. The shake starts at
/// `threshold` items, and its strength grows with the count up to
/// `ceiling`.
private struct BinShakeModifier: ViewModifier {
    /// The current bin count. This modifier tracks its own previous value,
    /// so each call site does not need to track one.
    let count: Int

    /// The shake starts at this count. Below it, nothing happens.
    private static let threshold = 12
    /// The count where the shake reaches its strongest. Past this point the
    /// shake does not grow further.
    private static let ceiling = 40

    @State private var previousCount: Int?
    @State private var shakeToken = 0
    @State private var intensity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(
                initialValue: 0.0,
                trigger: shakeToken
            ) { view, angle in
                view.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                // The shake swings left and right with a decreasing
                // amplitude after the first swing, and ends at zero so
                // the pill does not stay rotated.
                let peak = 4.0 + 8.0 * intensity
                KeyframeTrack {
                    CubicKeyframe(-peak, duration: 0.05)
                    CubicKeyframe(peak, duration: 0.09)
                    CubicKeyframe(-peak * 0.6, duration: 0.09)
                    CubicKeyframe(peak * 0.35, duration: 0.08)
                    CubicKeyframe(0, duration: 0.07)
                }
            }
            .onChange(of: count) { old, new in
                handle(old: previousCount ?? old, new: new)
            }
            .onAppear { previousCount = count }
    }

    private func handle(old: Int, new: Int) {
        defer { previousCount = new }
        // Only additions trigger a shake. Emptying the bin or restoring an
        // item already fixes the condition this shake warns about.
        guard new > old, new >= Self.threshold else { return }
        // Respect Reduce Motion. This effect is motion only, so the correct
        // response is no shake, not a smaller one.
        guard !reduceMotion else { return }
        let span = Double(Self.ceiling - Self.threshold)
        intensity = min(max(Double(new - Self.threshold) / span, 0), 1)
        shakeToken += 1
    }
}

extension View {
    /// Shakes this view each time `count` increases to a value at or
    /// above the shake threshold. See `BinShakeModifier` for the rules.
    func binShake(count: Int) -> some View {
        modifier(BinShakeModifier(count: count))
    }
}
