//
//  PhotoPerfProbe.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if DEBUG
import Foundation
import SwiftUI

/// Counts the photo feed's own main-thread work per scroll, for numbers
/// `MainThreadWatchdog` cannot show on a simulator.
///
/// The watchdog only counts gaps over 250 ms. A Mac host runs fast enough
/// that the photo pager never crosses that threshold on the simulator.
/// The same code visibly stutters on a phone. One scroll frame schedules a
/// fixed amount of main-thread work, and that cost scales straight to a
/// device.
///
/// This file counts five things:
/// - how many times `PhotoFeedView`'s whole body is invalidated
/// - how many geometry callbacks fire
/// - how many of those callbacks turn into a recompute
/// - how many `UIImage`s are handed to SwiftUI
/// - how many of those images arrive already decoded, counted in
///   `preparedDeliveries`
///
/// The code can count these values on any host. A fix that divides them by
/// twenty on the simulator divides the same work by twenty on a phone.
///
/// The stored counters mirror into the `@Published` values once each
/// second, as in `MainThreadWatchdog`. A publish on every increment would
/// re-render the view that the probe counts.
@MainActor
final class PhotoPerfProbe: ObservableObject {
    static let shared = PhotoPerfProbe()

    /// `PhotoFeedView.body` evaluations.
    private(set) var feedBodyPasses = 0
    /// Row `.onGeometryChange` callbacks — one per mounted row per moved frame.
    private(set) var geometryCallbacks = 0
    /// Geometry callbacks that actually ran `recomputeGeometry`.
    private(set) var geometryRecomputes = 0
    /// Images handed to SwiftUI. `preparedDeliveries` counts the subset that
    /// were already decoded off the main thread before publication.
    private(set) var imageDeliveries = 0
    private(set) var preparedDeliveries = 0

    // These counters show that a deal does not walk the whole library.
    // `worstSampleMs` is the index-walk time and stays near 0 on the deal
    // path. `entriesCount` is the row count that `PhotoFeedView`'s
    // `ForEach` diffs.

    /// `PhotoDeck.poolCount` at the last deal or prune.
    private(set) var poolSize = 0
    /// `PhotoDeck.entries.count` at the last deal or prune.
    private(set) var entriesCount = 0
    /// How many windows this run has dealt.
    private(set) var windowsDealt = 0
    /// Photos in the last dealt window.
    private(set) var lastWindowCount = 0
    /// The worst `PhotoLibraryPool.sample` time so far, in milliseconds.
    private(set) var worstSampleMs = 0
    /// `object(at:)` calls the last sample cost.
    private(set) var lastMaterialisations = 0

    /// One identifier for the UI test / `idb` read, mirrored at 1 Hz.
    @Published private(set) var readout = "0_0_0_0_0"
    /// The deal's own identifier, mirrored on the same 1 Hz tick.
    @Published private(set) var deckReadout = "0_0_0_0_0"

    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.mirror() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reset() {
        feedBodyPasses = 0
        geometryCallbacks = 0
        geometryRecomputes = 0
        imageDeliveries = 0
        preparedDeliveries = 0
        windowsDealt = 0
        lastWindowCount = 0
        worstSampleMs = 0
        lastMaterialisations = 0
        mirror()
    }

    func noteDeal(windowCount: Int, sampleMs: Int, materialisations: Int) {
        windowsDealt += 1
        lastWindowCount = windowCount
        worstSampleMs = max(worstSampleMs, sampleMs)
        lastMaterialisations = materialisations
        mirror()
    }

    func noteDeckSize(pool: Int, entries: Int) {
        poolSize = pool
        entriesCount = entries
        mirror()
    }

    func noteFeedBody() { feedBodyPasses += 1 }
    func noteGeometryCallback() { geometryCallbacks += 1 }
    func noteGeometryRecompute() { geometryRecomputes += 1 }
    func noteImageDelivery(prepared: Bool) {
        imageDeliveries += 1
        if prepared { preparedDeliveries += 1 }
    }

    private func mirror() {
        let next = "\(feedBodyPasses)_\(geometryCallbacks)_\(geometryRecomputes)_\(imageDeliveries)_\(preparedDeliveries)"
        if readout != next { readout = next }
        let deck = "\(poolSize)_\(windowsDealt)_\(lastWindowCount)_\(entriesCount)_\(worstSampleMs)"
        if deckReadout != deck {
            deckReadout = deck
            // This diagnostics log only fires on a changed value, matching
            // the `@Published` write above, so a tick with no change logs
            // nothing.
            if DiagnosticsSwitch.shared.isOn {
                DiagnosticsLog.shared.log("PhotoDeal", "photo_deal_\(deck)")
            }
        }
    }
}

/// "photo_perf_<bodies>_<geomCallbacks>_<recomputes>_<images>_<prepared>".
/// Its own view with its own observation, so mirroring the counters once a
/// second cannot invalidate any other view. This matches
/// `MainStallProbeView`'s reasoning.
struct PhotoPerfProbeView: View {
    @ObservedObject private var probe = PhotoPerfProbe.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("photo_perf_\(probe.readout)")
            .task { PhotoPerfProbe.shared.start() }
    }
}

/// "photo_deal_<pool>_<windowsDealt>_<lastWindowCount>_<entries>_<worstSampleMs>".
/// Reading this string in one place answers:
/// - how big the pool is
/// - how many windows this run has dealt
/// - how many photos the last window held
/// - how many rows the feed's `ForEach` is diffing
/// - the worst time any single deal spent inside `PhotoLibraryPool.sample`
struct PhotoDeckProbeView: View {
    @ObservedObject private var probe = PhotoPerfProbe.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("photo_deal_\(probe.deckReadout)")
    }
}
#endif
