//
//  DeviceIdentity.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security

/// A random id for this install. Every synced row this device inserts
/// (`TrashEntry`, `SeenEntry`, `PhotoSeenEntry`) stamps its own
/// `originDeviceID` with this value, through each model's init default.
/// `TrashService.reconcileWithLibrary` reads it to decide whether a bin
/// row is this device's own to mark and delete, or another device's,
/// which it must never touch.
///
/// Stored in the Keychain, not `UserDefaults`, with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. A `UserDefaults`
/// value restores onto a new device from an encrypted backup or a
/// device-to-device migration, which would make the new device share
/// this id with the old one — exactly the sharing `originDeviceID` exists
/// to prevent. `ThisDeviceOnly` keychain data is excluded from both: a
/// restore or migration finds no item, and this type mints a fresh id,
/// which is what a genuinely different device needs.
///
/// A `UserDefaults` value under the old key (`sync.deviceID`), from an
/// earlier build of this branch, is ignored. 1.0 never wrote one.
enum DeviceIdentity {
    private static let service = "com.cloudfull.app.deviceID"
    private static let account = "sync.deviceID"

    static let current: String = {
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
        if let existing = readFromKeychain() {
            return existing
        }
        let created = UUID().uuidString
        writeToKeychain(created)
        return created
    }()

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func readFromKeychain() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `ThisDeviceOnly`: this item never leaves this device, through a
    /// backup, iCloud Keychain, or Quick Start migration. That is the
    /// whole point — see this type's doc comment.
    private static func writeToKeychain(_ value: String) {
        var query = keychainQuery()
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // A failed write leaves `current` holding this launch's freshly
        // minted id in memory, but nothing on the Keychain to read back
        // next launch; the next launch mints another id the same way.
        // Not destructive either way: at worst, two launches of the same
        // device each pick their own fresh id, which still correctly
        // belongs to no one else.
        SecItemAdd(query as CFDictionary, nil)
    }
}
