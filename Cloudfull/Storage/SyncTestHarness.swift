//
//  SyncTestHarness.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftData

#if DEBUG
/// Test-only seeds and simulated remote events for M7's sync behaviour.
/// Each entry point here backs one DEBUG launch argument, read and
/// dispatched from `CloudfullApp.init()` or `SyncObserver.attach()`, the
/// same way `KeyRotationHarness` backs `-cloudfull-rotate-keys`.
///
/// `#if DEBUG` encloses this whole file, so a release build cannot seed
/// or simulate anything through it.
enum SyncTestHarness {

    /// Backs `-cloudfull-seed-foreign-trash`. Inserts two dormant
    /// `TrashEntry` rows, both `bytes: 1`, `cloudKey: nil`,
    /// `dormantSince: Date() - 120` (already past the two-strike delete
    /// window):
    ///
    /// - `"FOREIGN-<uuid>/L0/001"`, stamped `originDeviceID`
    ///   `"OTHER-DEVICE"`. `TrashService.reconcileWithLibrary` must
    ///   never mark or delete this row.
    /// - `"DEAD-<uuid>/L0/001"`, this device's own id (the init
    ///   default). A control: the normal two-strike delete still runs
    ///   on it.
    ///
    /// Neither asset key names a real asset, so both rows read as dead
    /// on the very first reconcile pass.
    @MainActor
    static func seedForeignTrash(container: ModelContainer) {
        let context = ModelContext(container)
        let dormantSince = Date().addingTimeInterval(-120)

        let foreign = TrashEntry(
            assetKey: "FOREIGN-\(UUID().uuidString)/L0/001",
            bytes: 1,
            cloudKey: nil,
            originDeviceID: "OTHER-DEVICE"
        )
        foreign.dormantSince = dormantSince
        context.insert(foreign)

        let own = TrashEntry(
            assetKey: "DEAD-\(UUID().uuidString)/L0/001",
            bytes: 1,
            cloudKey: nil
        )
        own.dormantSince = dormantSince
        context.insert(own)

        try? context.save()
    }
}
#endif
