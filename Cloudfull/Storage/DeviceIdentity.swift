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
///
/// `currentIfAvailable` is this type's only entry point. There is no
/// once-per-process `current` sentinel. The Keychain item sits in the
/// same availability class (`ThisDeviceOnly`) as the SwiftData store
/// file's own default protection (`completeUntilFirstUserAuthentication`),
/// so a row is only ever inserted by a user action that needs an
/// unlocked, foreground UI — by the time any caller needs an id to stamp
/// or compare, the Keychain is reachable too. A `nil` result is the
/// impossible-in-practice case, returned instead of a random per-process
/// sentinel: minting and stamping a row with such a sentinel would make
/// that row look permanently foreign once a later, reliable launch mints
/// or reads the real id, since the sentinel is random and never
/// persisted. Every caller treats `nil` as "foreign for now" (a stamp of
/// `""`, or "not my row this pass") and simply retries on its next
/// access instead.
enum DeviceIdentity {
    private static let service = "com.cloudfull.app.deviceID"
    private static let account = "sync.deviceID"
    private static let log = Logger(subsystem: "com.cloudfull.app", category: "Storage")

    #if DEBUG
    // `-cloudfull-device-id <value>` takes the value as the next launch
    // argument, the same shape as `-cloudfull-slow-load`. Lets a UI test
    // simulate a second device without a second simulator. The value is
    // used as-is and never stored, so a later launch without the
    // argument never inherits it.
    private static let debugOverride: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-cloudfull-device-id"), flagIndex + 1 < arguments.count else {
            return nil
        }
        return arguments[flagIndex + 1]
    }()
    #endif

    /// Set once resolution has actually worked: a real Keychain read, or
    /// a freshly minted id on this device's first-ever access
    /// (`errSecItemNotFound`). Never set for any other failing status —
    /// see `currentIfAvailable`. `cacheLock` guards every read and write,
    /// since this runs from the main actor and from every `@ModelActor`
    /// background actor that can insert a synced row (`SeenStore`,
    /// `PhotoSeenStore`, `StoreSplitMigrator`'s own contexts).
    private static var cachedID: String?
    private static let cacheLock = NSLock()

    /// When the last failed read happened. A bulk insert of seen rows
    /// calls `currentIfAvailable` once per row; this keeps a locked
    /// Keychain from being read (and logged) once per row.
    private static var lastFailureAt: Date?

    /// This device's id, or `nil` if the Keychain cannot currently be
    /// read — for example `errSecInteractionNotAllowed`, before the
    /// device's first unlock this boot. A failed read is never cached:
    /// the next access tries the Keychain again from scratch, instead of
    /// being stuck behind a cached failure for the rest of the process
    /// (after a 2 s pause, see `lastFailureAt`).
    static var currentIfAvailable: String? {
        #if DEBUG
        if let debugOverride { return debugOverride }
        #endif
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedID { return cachedID }
        if let lastFailureAt, Date().timeIntervalSince(lastFailureAt) < 2 { return nil }

        let (existing, status) = readFromKeychain()
        if let existing {
            cachedID = existing
            return existing
        }
        guard status == errSecItemNotFound else {
            // Any failure other than "no item yet" means this read
            // cannot tell whether a real id already exists. Minting and
            // persisting one here could silently orphan the real id
            // once the Keychain becomes reachable again, and every row
            // this process inserts in the meantime would carry an id no
            // later launch can ever recognize as its own. Cache nothing,
            // so the next access tries the real read again from scratch.
            log.error("DeviceIdentity Keychain read failed, status \(status, privacy: .public); will retry in 2 s")
            lastFailureAt = Date()
            return nil
        }
        let created = UUID().uuidString
        writeToKeychain(created)
        cachedID = created
        return created
    }

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
        // A failed write leaves `cachedID` holding this launch's freshly
        // minted id in memory, but nothing on the Keychain to read back
        // next launch; the next launch mints another id the same way.
        // Not destructive either way: at worst, two launches of the same
        // device each pick their own fresh id, which still correctly
        // belongs to no one else.
        SecItemAdd(query as CFDictionary, nil)
    }
}
