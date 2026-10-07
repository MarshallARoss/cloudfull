//
//  StoreSplitMigrator.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftData
import Photos

/// Moves the four local-only models (`DeckState`, `DeckOrder`,
/// `PhotoDeckState`, `PhotoMetaRecord`) out of the 1.0 file
/// (`CloudfullModelContainer.syncedStoreURL`, "default.store") and into
/// the new `local.store`, once per install. `CloudfullModelContainer.make()`
/// calls `runIfNeeded()` before it opens either file, so a device
/// upgrading from 1.0 never exports a deck row or a cache row to
/// CloudKit.
///
/// Why this order is safe: the CloudKit config only ever sees
/// `default.store` after step 3g below has emptied the four local
/// tables in it. When `make()` then opens `default.store` with the
/// synced-only schema, SwiftData's inferred migration drops those four
/// now-empty tables. Re-running after a crash is safe: step 3c skips a
/// table already copied, by checking the destination first.
///
/// Known cost: SQLite does not shrink `default.store` after the
/// metadata-cache delete. There is no `VACUUM` in M7.
enum StoreSplitMigrator {

    private static let flagKey = "storage.splitV1Done"

    static func runIfNeeded() {
        if UserDefaults.standard.bool(forKey: flagKey) { return }

        guard FileManager.default.fileExists(atPath: CloudfullModelContainer.syncedStoreURL.path) else {
            // Fresh install. There is no 1.0 file to migrate rows out of.
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }

        let start = Date()
        var deckCopied = false, orderCopied = false, photoDeckCopied = false

        do {
            // Both containers, and the Core Data stack each one opens
            // underneath, must be released before `make()` opens
            // `syncedStoreURL` and `localStoreURL` again for real. This
            // pool makes sure that happens at the end of this scope,
            // not whenever ARC next happens to collect them.
            try autoreleasepool {
                let fullSchema = Schema(CloudfullModelContainer.syncedModels + CloudfullModelContainer.localModels)
                let localSchema = Schema(CloudfullModelContainer.localModels)

                // The 1.0 file, opened with every model, `.none`. This is
                // what a 1.0 install actually wrote: lightweight
                // migration adds the new 1.1 columns (`originDeviceID`,
                // and friends) on open, same as any other SwiftData
                // migration.
                let legacyConfig = ModelConfiguration(
                    "default", schema: fullSchema, url: CloudfullModelContainer.syncedStoreURL, cloudKitDatabase: .none
                )
                let legacy = try ModelContainer(for: fullSchema, configurations: legacyConfig)
                let legacyContext = ModelContext(legacy)

                let localConfig = ModelConfiguration(
                    "local", schema: localSchema, url: CloudfullModelContainer.localStoreURL, cloudKitDatabase: .none
                )
                let local = try ModelContainer(for: localSchema, configurations: localConfig)
                let localContext = ModelContext(local)

                deckCopied = try copyDeckStateIfNeeded(from: legacyContext, to: localContext)
                orderCopied = try copyDeckOrderIfNeeded(from: legacyContext, to: localContext)
                photoDeckCopied = try copyPhotoDeckStateIfNeeded(from: legacyContext, to: localContext)
                try localContext.save()

                try stampOriginDeviceID(in: legacyContext)
                try backfillCloudKeysIfAuthorized(in: legacyContext)

                // This store is `.none` here, so a batch delete is fine:
                // nothing is exporting from it yet.
                try deleteLocalModelRows(in: legacyContext)
                try legacyContext.save()
            }
        } catch {
            #if DEBUG
            DiagnosticsLog.shared.log("Storage", "store_split_failed_\(error.localizedDescription)")
            #endif
            return   // Flag stays false. The next launch retries from scratch.
        }

        UserDefaults.standard.set(true, forKey: flagKey)
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        DiagnosticsLog.shared.log(
            "Storage",
            "store_split_done_\(ms)_\(deckCopied ? 1 : 0)_\(orderCopied ? 1 : 0)_\(photoDeckCopied ? 1 : 0)"
        )
        #endif
    }

    // MARK: - Deck-state copy (step 3c)

    /// Every stored property of `DeckState`, copied by hand from
    /// `Cloudfull/Storage/Models.swift`. Returns `false`, doing nothing,
    /// if the local store already has a row (a prior pass already
    /// copied it) or the legacy store has none to copy.
    private static func copyDeckStateIfNeeded(from legacy: ModelContext, to local: ModelContext) throws -> Bool {
        guard try local.fetch(FetchDescriptor<DeckState>()).first == nil else { return false }
        guard let source = try legacy.fetch(FetchDescriptor<DeckState>()).first else { return false }
        let copy = DeckState()
        copy.seed = source.seed
        copy.cursor = source.cursor
        local.insert(copy)
        return true
    }

    /// Every stored property of `DeckOrder`, copied by hand.
    private static func copyDeckOrderIfNeeded(from legacy: ModelContext, to local: ModelContext) throws -> Bool {
        guard try local.fetch(FetchDescriptor<DeckOrder>()).first == nil else { return false }
        guard let source = try legacy.fetch(FetchDescriptor<DeckOrder>()).first else { return false }
        let copy = DeckOrder()
        copy.ids = source.ids
        copy.schemaVersion = source.schemaVersion
        copy.cycleSeeds = source.cycleSeeds
        copy.cycleBaseSlots = source.cycleBaseSlots
        copy.cycleCounts = source.cycleCounts
        copy.cycleDigests = source.cycleDigests
        copy.cycleSwaps = source.cycleSwaps
        copy.cycleIsLiteral = source.cycleIsLiteral
        copy.literalIDs = source.literalIDs
        copy.exceptionSlots = source.exceptionSlots
        copy.exceptionIDs = source.exceptionIDs
        copy.trimmedBeforeSlot = source.trimmedBeforeSlot
        copy.nextSlot = source.nextSlot
        local.insert(copy)
        return true
    }

    /// Every stored property of `PhotoDeckState`, copied by hand from
    /// `Cloudfull/Photos/PhotoModels.swift`.
    private static func copyPhotoDeckStateIfNeeded(from legacy: ModelContext, to local: ModelContext) throws -> Bool {
        guard try local.fetch(FetchDescriptor<PhotoDeckState>()).first == nil else { return false }
        guard let source = try legacy.fetch(FetchDescriptor<PhotoDeckState>()).first else { return false }
        let copy = PhotoDeckState()
        copy.seed = source.seed
        copy.cursor = source.cursor
        copy.schemaVersion = source.schemaVersion
        copy.cycleSeeds = source.cycleSeeds
        copy.cycleBaseSlots = source.cycleBaseSlots
        copy.cycleCounts = source.cycleCounts
        copy.cycleDigests = source.cycleDigests
        copy.cycleSwaps = source.cycleSwaps
        copy.cycleIsLiteral = source.cycleIsLiteral
        copy.literalIDs = source.literalIDs
        copy.exceptionSlots = source.exceptionSlots
        copy.exceptionIDs = source.exceptionIDs
        copy.trimmedBeforeSlot = source.trimmedBeforeSlot
        copy.nextSlot = source.nextSlot
        local.insert(copy)
        return true
    }

    // MARK: - Trash ownership and cloudKey stamping (steps 3e, 3f)

    /// Every `TrashEntry` a 1.0 install wrote has `originDeviceID == ""`
    /// (the lightweight migration default). Stamping it with this
    /// device's id here, before the first CloudKit export, makes every
    /// pre-M7 row this device's own from the start. `DeviceIdentity` is
    /// itself new in M7 (Step C); nothing before this migration ever
    /// read or wrote it.
    private static func stampOriginDeviceID(in legacy: ModelContext) throws {
        let rows = try legacy.fetch(FetchDescriptor<TrashEntry>(predicate: #Predicate { $0.originDeviceID == "" }))
        guard !rows.isEmpty else { return }
        let current = DeviceIdentity.current
        for row in rows { row.originDeviceID = current }
    }

    /// Fills `cloudKey` on every `TrashEntry` and `LikedEntry` row that
    /// still has none, the same way `CloudKeyBackfiller.run()` does,
    /// but only when photo access is already `.authorized`. These are
    /// small tables (the bin and the keeps), so one pass here, before
    /// the first export, is cheap. `SeenEntry` and `PhotoSeenEntry` rows
    /// are left to the normal backfiller: there can be many thousands of
    /// them, and a nil `cloudKey` there costs nothing but a slower
    /// cross-device seen match until it resolves.
    private static func backfillCloudKeysIfAuthorized(in legacy: ModelContext) throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }

        let trashRows = try legacy.fetch(FetchDescriptor<TrashEntry>(predicate: #Predicate { $0.cloudKey == nil }))
        let likedRows = try legacy.fetch(FetchDescriptor<LikedEntry>(predicate: #Predicate { $0.cloudKey == nil }))
        guard !trashRows.isEmpty || !likedRows.isEmpty else { return }

        var keys = Set<String>()
        keys.formUnion(trashRows.map(\.assetKey))
        keys.formUnion(likedRows.map(\.assetKey))
        let keyList = Array(keys)

        var cloudKeyByLocalID: [String: String] = [:]
        var offset = 0
        while offset < keyList.count {
            let end = min(offset + 200, keyList.count)
            let mapped = PhotoLibraryService.cloudIdentifierMappings(forLocalIdentifiers: Array(keyList[offset..<end]))
            cloudKeyByLocalID.merge(mapped) { _, new in new }
            offset = end
        }

        for row in trashRows {
            if let cloudKey = cloudKeyByLocalID[row.assetKey] { row.cloudKey = cloudKey }
        }
        for row in likedRows {
            if let cloudKey = cloudKeyByLocalID[row.assetKey] { row.cloudKey = cloudKey }
        }
    }

    // MARK: - Emptying the local models out of the legacy file (step 3g)

    private static func deleteLocalModelRows(in legacy: ModelContext) throws {
        try legacy.delete(model: DeckState.self)
        try legacy.delete(model: DeckOrder.self)
        try legacy.delete(model: PhotoDeckState.self)
        try legacy.delete(model: PhotoMetaRecord.self)
    }
}
