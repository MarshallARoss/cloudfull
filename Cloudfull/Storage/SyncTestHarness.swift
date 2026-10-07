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

    /// Backs `-cloudfull-seed-foreign-seen`. Takes the newest video's
    /// local id, maps it to its cloud key, and inserts one `SeenEntry`
    /// under a placeholder `assetKey`, stamped with another device's id
    /// and that cloud key — the shape a real cross-device seen row has.
    /// Publishes the target's local id through `ForeignSeenSeedProbe`,
    /// so `M7Tests.testForeignSeenRowCountsAsSeen` can assert that id
    /// never appears on screen, without hard-coding a fixture asset.
    ///
    /// Does nothing if the library has no video, or PhotoKit cannot map
    /// its local id to a cloud key (no iCloud Photos). Either way, no
    /// probe is published, and the test this backs would then wait out
    /// its timeout rather than assert a false positive.
    @MainActor
    static func seedForeignSeen(container: ModelContainer) {
        guard let targetID = PhotoLibraryService.allVideoIDsOffMain().last else { return }
        let mapped = PhotoLibraryService.cloudIdentifierMappings(forLocalIdentifiers: [targetID])
        guard let cloudKey = mapped[targetID] else { return }

        let context = ModelContext(container)
        context.insert(SeenEntry(assetKey: "FOREIGN-\(UUID().uuidString)/L0/001", cloudKey: cloudKey, originDeviceID: "OTHER-DEVICE"))
        try? context.save()

        ForeignSeenSeedProbe.shared.record(targetID)
    }
}
#endif
