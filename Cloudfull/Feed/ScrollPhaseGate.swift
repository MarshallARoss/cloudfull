//
//  ScrollPhaseGate.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Publishes whether the pager is scrolling, so that callers can hold
/// video engine work until it stops.
///
/// Do not attach, play, pause, or connect a player layer while
/// `isScrolling` is true.
///
/// Attach, play, pause, and player-layer connection calls can each block
/// for about 600 ms during a swipe, on an iPhone 16 Pro with iCloud
/// videos. The block happens on an AVFoundation internal lock, on any
/// thread. Callers wait on `waitUntilIdle()` or observe `isScrolling`,
/// and start engine work after the scroll phase returns to `.idle`.
///
/// `FeedView` and `PhotoFeedView` write `isScrolling` from
/// `.onScrollPhaseChange`. Player, photo, and metadata code waits on it.
@MainActor
final class ScrollPhaseGate: ObservableObject {
    static let shared = ScrollPhaseGate()

    @Published private(set) var isScrolling = false

    private init() {}

    func update(isScrolling: Bool) {
        guard isScrolling != self.isScrolling else { return }
        self.isScrolling = isScrolling
    }

    /// Suspends until the pager is idle. Polls every 50 ms, which is
    /// coarse on purpose. A swipe lasts hundreds of milliseconds, and the
    /// wake-up cost must stay small next to the engine work it delays.
    func waitUntilIdle() async {
        while isScrolling {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
        }
    }
}
