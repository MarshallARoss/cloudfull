//
//  DeviceIdentity.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security
import os

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
    private static let log = Logger(subsystem: "com.cloudfull.app", category: "Storage")

    /// The outcome of resolving this device's id, computed once per
    /// process and cached by the `static let` below. `current` and
    /// `isReliable` both read this one resolution, so a Keychain read
    /// that cannot run never mints two different per-process sentinels
    /// across two callers.
    private struct Resolution { let id: String; let reliable: Bool }

    private static let resolution: Resolution = {
        #if DEBUG
        // `-cloudfull-device-id <value>` takes the value as the next
        // launch argument, the same shape as `-cloudfull-slow-load`.
        // Lets a UI test simulate a second device without a second
        // simulator. The value is used as-is and never stored, so a
        // later launch without the argument never inherits it.
        let arguments = ProcessInfo.processInfo.arguments
        if let flagIndex = arguments.firstIndex(of: "-cloudfull-device-id"), flagIndex + 1 < arguments.count {
            return Resolution(id: arguments[flagIndex + 1], reliable: true)
        }
        #endif
        let (existing, status) = readFromKeychain()
        if let existing {
            return Resolution(id: existing, reliable: true)
        }
        guard status == errSecItemNotFound else {
            // Any failure other than "no item yet" — for example
            // `errSecInteractionNotAllowed`, before the device's first
            // unlock this boot — means this read cannot tell whether a
            // real id already exists. Minting and persisting one here
            // could silently orphan the real id once the Keychain
            // becomes reachable again, and every row this process
            // inserts in the meantime would carry an id no later launch
            // can ever recognize as its own. Return a per-process
            // sentinel instead: random, so it matches no stored row,
            // and never written to the Keychain, so the next launch
            // tries the real read again from scratch.
            log.error("DeviceIdentity Keychain read failed, status \(status, privacy: .public); using an unreliable per-process id")
            return Resolution(id: "unreliable-\(UUID().uuidString)", reliable: false)
        }
        let created = UUID().uuidString
        writeToKeychain(created)
        return Resolution(id: created, reliable: true)
    }()

    static var current: String { resolution.id }

    /// False when `current` is this process's unreliable sentinel, not
    /// this device's real, Keychain-persisted id — see `resolution`.
    /// `StoreSplitMigrator` must not stamp `TrashEntry.originDeviceID`
    /// with an unreliable id, and a new synced row must insert with
    /// `stampForNewRow` instead of `current` directly.
    static var isReliable: Bool { resolution.reliable }

    /// The value a newly inserted synced row's `originDeviceID` should
    /// stamp. Equal to `current` while reliable. `""` ("not yet
    /// stamped", same as a 1.0 row) while not: writing the unreliable
    /// sentinel would make this device's own row look permanently
    /// foreign once a later, reliable launch mints the real id — the
    /// sentinel is random and never persisted, so it could never match
    /// again. `""` is safe meanwhile: `TrashService.reconcileWithLibrary`'s
    /// `== DeviceIdentity.current` check already treats it as another
    /// device's row and never auto-deletes it, `SeenStore`/`PhotoDeck`'s
    /// foreign-match checks already treat `""` as this device's own, and
    /// `StoreSplitMigrator`'s origin-stamp step finds and re-stamps any
    /// `""` `TrashEntry` row once this device's id is reliable again.
    static var stampForNewRow: String { isReliable ? current : "" }

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Returns the stored id, or `nil` paired with the failing
    /// `OSStatus` — `errSecItemNotFound` when no id has ever been
    /// written, any other status when the read itself could not run.
    private static func readFromKeychain() -> (value: String?, status: OSStatus) {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return (nil, status) }
        return (String(data: data, encoding: .utf8), status)
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
