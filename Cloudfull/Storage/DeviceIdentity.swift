//
//  DeviceIdentity.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A random id for this install. Every synced row this device inserts
/// (`TrashEntry`, `SeenEntry`, `PhotoSeenEntry`) stamps its own
/// `originDeviceID` with this value, through each model's init default.
/// `TrashService.reconcileWithLibrary` reads it to decide whether a bin
/// row is this device's own to mark and delete, or another device's,
/// which it must never touch.
///
/// `nonisolated`: every actor that touches one of those rows reads this
/// value, from a `@ModelActor` type to the main actor. A `static let`
/// on a value type is already safe to read from any thread once it is
/// initialized; this annotation only makes that explicit.
enum DeviceIdentity {
    private static let storageKey = "sync.deviceID"

    nonisolated static let current: String = {
        #if DEBUG
        // `-cloudfull-device-id <value>` takes the value as the next
        // launch argument, the same shape as `-cloudfull-slow-load`.
        // Lets a UI test simulate a second device without a second
        // simulator. The value is used as-is and never stored, so a
        // later launch without the argument never inherits it.
        let arguments = ProcessInfo.processInfo.arguments
        if let flagIndex = arguments.firstIndex(of: "-cloudfull-device-id"), flagIndex + 1 < arguments.count {
            return arguments[flagIndex + 1]
        }
        #endif
        if let existing = UserDefaults.standard.string(forKey: storageKey) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: storageKey)
        return created
    }()
}
