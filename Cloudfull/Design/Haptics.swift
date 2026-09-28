//
//  Haptics.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// The only haptic in Cloudfull: one light impact when the user keeps an
/// item or moves an item to the bin.
///
/// Nothing else in the app fires a haptic. Do not add another feedback
/// style or another haptic call outside this type.
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)

    static func tap() {
        light.prepare()
        light.impactOccurred()
    }
}
