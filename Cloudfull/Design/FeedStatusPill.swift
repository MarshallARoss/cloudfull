//
//  FeedStatusPill.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// A glass pill with a spinner and text for every short feed status.
///
/// `FeedView` shows "Updating feed…" while
/// `DeckViewModel.isApplyingOptions` is true. `FeedView` also shows
/// "Loading videos…" on a cold launch. `PhotoFeedView` shows "Loading
/// photos…".
///
/// The pill uses the same `feedGlass` capsule, padding, font, and spinner
/// in every case. Each call site keeps its own accessibility identifier,
/// label, and timing rule. This view owns only the shared shape.
struct FeedStatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(.white)
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .feedGlass(in: Capsule())
    }
}
