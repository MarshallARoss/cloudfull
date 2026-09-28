//
//  CloudDownloadRing.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The video feed's loading indicator: a cloud glyph inside a progress ring.
///
/// The share rail draws its own copy of this ring, inline, and must keep
/// doing so. Do not extract a shared implementation for the two rings. A
/// shared view changes the share rail's glyph size. Only `PlayerPageView`
/// shows this view. Nothing here can affect the share rail's ring.
///
/// This is a deliberate copy of the photo feed's ring
/// (`PhotoPostView.loadingOverlay` with `runCreep`, `applyLiveFetchProgress`,
/// and `finishLiveRing`), not a shared implementation. Every number below
/// matches that view's number. Do not change one value on its own. The two
/// rings must stay visually identical.
///
/// The ring follows four rules.
///
/// 1. **The ring always moves.** A creep animation runs the arc from 0 to
///    90 % over ten seconds on a decelerating curve, then moves slowly to
///    97 % over 20 s.
/// 2. **A real download percentage can pull the arc forward, but only by a
///    bounded amount.** PhotoKit can report a high percentage almost
///    immediately when the resource is already local, while readiness can
///    still take many more seconds to arrive. An unbounded pull would move
///    the arc most of the way round at once and then leave it to move
///    very slowly.
/// 3. **A reading never reaches 100 %.** Any fraction at or past the
///    ceiling is ignored. Only rule 4 draws a full circle.
/// 4. **Finishing draws the full circle.** When the wait ends, the arc
///    sweeps the rest of the way round and fades out at the same time,
///    over 0.22 s.
///
/// The view runs three Core Animations per appearance and does no
/// per-frame work.
struct CloudDownloadRing: View {

    // MARK: - The photo ring's numbers

    // `PhotoPostView.loadingOverlay` draws a 20pt ring with a 2pt line and
    // a 9pt glyph at 80 % white opacity. A 35 % black disc, with 5pt of
    // padding, sits behind all of it. The disc is not decoration. At this
    // size, a white hairline over a bright poster needs its own
    // background. The disc also keeps the ring visible under
    // `FeedView.bottomScrim`. The action rail sits above that gradient.
    // This ring sits below the gradient.

    static let standardDiameter: CGFloat = 20
    static let standardGlyph: CGFloat = 9
    static let standardLineWidth: CGFloat = 2
    /// Gap between the ring and the edge of its dark disc.
    static let discPadding: CGFloat = 5

    /// A value from 0 to 1 from PhotoKit while a real download is in
    /// progress. This is `nil` when there is nothing to measure: the copy is
    /// already on the device, or the wait is player buffering, not a
    /// fetch. The arc runs in both cases. A real value only ever pulls the
    /// arc forward.
    var fraction: Double?
    /// True while the app wants the ring shown.
    ///
    /// Do not drive opacity from the caller. This view owns its own fade
    /// in and fade out. Setting opacity to zero from outside cuts off rule
    /// 4's finishing sweep before the user sees it.
    var isRunning: Bool
    var diameter: CGFloat = CloudDownloadRing.standardDiameter
    /// Set explicitly. Do not derive this from `diameter`. A shared
    /// derivation risks resizing the share rail's glyph if this pattern is
    /// ever extracted into common code.
    var glyphSize: CGFloat = CloudDownloadRing.standardGlyph
    var lineWidth: CGFloat = CloudDownloadRing.standardLineWidth

    @State private var arc: Double = 0
    @State private var ringOpacity: Double = 0
    @State private var startedAt: Date?
    @State private var driftTask: Task<Void, Never>?
    /// Increments on every `start()`, `finish()`, and `cancel()`. A
    /// `finish()` completion runs 0.22 s later and must do nothing when
    /// `run` changed after it. See `finish()` for the check this
    /// enables. This value plays the same role as the photo side's
    /// `liveRingFinishing` latch in `PhotoPostView`.
    @State private var run = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: lineWidth)
            Circle()
                // Show a small arc even at zero. This makes the ring read
                // as started, not as a missing element.
                .trim(from: 0, to: max(arc, 0.02))
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: glyphSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: diameter, height: diameter)
        .foregroundStyle(.white)
        .padding(Self.discPadding)
        .background(Color.black.opacity(0.35), in: Circle())
        .opacity(ringOpacity)
        .allowsHitTesting(false)
        .onChange(of: isRunning, initial: true) { _, running in
            if running { start() } else { finish() }
        }
        .onChange(of: fraction) { _, value in
            if let value { pull(to: value) }
        }
        // Call `cancel()`, not `finish()`. A page leaving the render
        // window did not finish its wait. A 0.22 s sweep on a view being
        // torn down is work nobody sees.
        .onDisappear { cancel() }
    }

    // MARK: - The arc

    private func start() {
        driftTask?.cancel()
        // Incrementing `run` makes a pending finish completion do
        // nothing, so it cannot reset the arc for this new wait.
        run += 1
        startedAt = Date()
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            arc = 0
            ringOpacity = 0
        }
        withAnimation(.easeIn(duration: Self.fadeIn)) { ringOpacity = 1 }
        withAnimation(.timingCurve(0.15, 0.55, 0.45, 1.0, duration: Self.creepDuration)) {
            arc = Self.creepCeiling
        }
        driftTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.creepDuration * 1_000_000_000))
            guard !Task.isCancelled, isRunning else { return }
            withAnimation(.linear(duration: Self.driftDuration)) { arc = Self.driftCeiling }
        }
    }

    /// Rule 4. One animation drives the arc to a full circle and the
    /// opacity to zero at the same time. This lets the ring complete its
    /// path as it leaves, instead of vanishing partway round. This method
    /// matches `PhotoPostView.finishLiveRing`, including the 0.22 s
    /// duration.
    ///
    /// The completion handler resets the arc with animations disabled. The
    /// view stays mounted for the life of the page. Without that reset,
    /// the next wait on this page would start its creep from a full
    /// circle.
    private func finish() {
        driftTask?.cancel()
        driftTask = nil
        let began = startedAt
        startedAt = nil
        // Nothing to finish. This method fires once on mount, when
        // `isRunning` starts false. Without this guard, every page would
        // run a fade-out of an invisible ring as it appeared.
        guard ringOpacity > 0 else { return }
        // A wait shorter than the fade-in is a wait the user never saw.
        // `PlayerPageView.spinnerGrace` is 0, so every page turns the ring
        // on as soon as it appears, and most turn it off again within a
        // few frames. Sweeping a full circle from a ring at roughly 15 %
        // opacity would show a faint partial ring on every swipe. This
        // guard prevents that.
        if let began, Date().timeIntervalSince(began) < Self.fadeIn {
            cancel()
            return
        }
        run += 1
        let token = run
        withAnimation(.easeOut(duration: 0.22), completionCriteria: .logicallyComplete) {
            arc = 1
            ringOpacity = 0
        } completion: {
            // A new wait may have started inside the 0.22 s. Its `start()`
            // already zeroed the arc and launched a fresh ten-second
            // creep. If this handler set `arc = 0` with animations
            // disabled, it would stop that creep animation. The ring
            // would then stay at the 0.02 minimum arc for the full wait.
            // `bufferSpinnerGrace` is also 0, so a clip that plays and
            // then immediately stalls triggers exactly this case.
            guard run == token else { return }
            var immediate = Transaction()
            immediate.disablesAnimations = true
            withTransaction(immediate) { arc = 0 }
        }
    }

    /// This is teardown, not a finish. It runs no sweep and no fade, and
    /// leaves nothing running.
    private func cancel() {
        driftTask?.cancel()
        driftTask = nil
        startedAt = nil
        run += 1
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            arc = 0
            ringOpacity = 0
        }
    }

    /// A real download percentage arrived. It can lead the creep by up to
    /// `maxLead`, but never at or past the ceiling.
    private func pull(to value: Double) {
        guard isRunning, let startedAt else { return }
        guard value > 0, value < Self.creepCeiling else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let creep = Self.creepValue(atElapsed: elapsed)
        guard value > creep else { return }
        let target = min(value, creep + Self.maxLead)
        // Move to the target over 0.2 s, then continue to rise toward the
        // ceiling. Assigning the arc and re-targeting it in the same
        // update makes SwiftUI re-base the running animation, which can
        // show as a single frame moving backward. Two animations avoid
        // this: the second one is delayed.
        let remaining = max(Self.creepDuration - elapsed, 2)
        withAnimation(.easeOut(duration: 0.2)) { arc = target }
        withAnimation(.timingCurve(0.15, 0.55, 0.45, 1.0, duration: remaining).delay(0.2)) {
            arc = Self.creepCeiling
        }
    }

    /// How long the ring takes to fade in, and therefore the shortest wait
    /// that is worth finishing rather than cancelling.
    private static let fadeIn: TimeInterval = 0.2
    private static let creepDuration: TimeInterval = 10
    private static let driftDuration: TimeInterval = 20
    private static let creepCeiling: Double = 0.9
    private static let driftCeiling: Double = 0.97
    private static let maxLead: Double = 0.15

    private static let creepCurve: [Double] = [
        0.0000, 0.1628, 0.2945, 0.4042, 0.4974, 0.5773, 0.6464, 0.7063,
        0.7583, 0.8034, 0.8424, 0.8760, 0.9047, 0.9289, 0.9491, 0.9655,
        0.9784, 0.9881, 0.9948, 0.9987, 1.0000
    ]

    private static func creepValue(atElapsed elapsed: TimeInterval) -> Double {
        guard elapsed < creepDuration else {
            return creepCeiling + (driftCeiling - creepCeiling) * min((elapsed - creepDuration) / driftDuration, 1)
        }
        let position = max(elapsed, 0) / creepDuration * Double(creepCurve.count - 1)
        let index = min(Int(position), creepCurve.count - 2)
        let step = position - Double(index)
        return creepCeiling * (creepCurve[index] + (creepCurve[index + 1] - creepCurve[index]) * step)
    }
}
