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
import os

/// Moves the four local-only models (`DeckState`, `DeckOrder`,
/// `PhotoDeckState`, `PhotoMetaRecord`) out of the 1.0 file
/// (`CloudfullModelContainer.syncedStoreURL`, "default.store") and into
/// the new `local.store`, once per install. `CloudfullModelContainer.make()`
/// calls `runIfNeeded()` before it opens either file, so a device
/// upgrading from 1.0 never exports a deck row or a cache row to
/// CloudKit.
///
/// `runIfNeeded()` returns `false` if this launch's attempt threw
/// partway through. `make()` must then open ONE configuration, with the
/// full 8-model schema, at `syncedStoreURL` only — `.none`, mode
/// `.localOnly`, never CloudKit however this build is declared, and not
/// `local.store` at all this launch — so that a local model's table,
/// still physically in the 1.0 file because step 3g never ran, is not
/// read with a narrower schema that would make SwiftData's inferred
/// migration drop it. The safety argument above only holds once this
/// pass has actually finished. The flag stays false, so the next launch
/// retries from scratch.
///
/// Why this order is safe: the CloudKit config only ever sees
/// `default.store` after step 3g below has emptied the four local
/// tables in it. When `make()` then opens `default.store` with the
/// synced-only schema, SwiftData's inferred migration drops those four
/// now-empty tables. Re-running after a crash is safe: every attempt
/// deletes any existing `local.store` first (see `runIfNeeded()`), so
/// step 3c never trusts a destination row a partial earlier attempt may
/// have left behind — it always copies fresh from the 1.0 file.
///
/// Known cost: SQLite does not shrink `default.store` after the
/// metadata-cache delete. There is no `VACUUM` in M7.
enum StoreSplitMigrator {

    private static let flagKey = "storage.splitV1Done"
    private static let log = Logger(subsystem: "com.cloudfull.app", category: "Storage")

    /// Thrown by `stampOriginDeviceID` when there are 1.0 rows to stamp
    /// but this device's id cannot currently be read. Caught by
    /// `runIfNeeded()`'s own `catch`, the same as any other mid-split
    /// failure: the flag stays false, `make()` falls back to the single
    /// full-schema container for this launch, and the whole split
    /// (stamping included) retries next launch.
    private enum MigrationError: Error {
        case deviceIdentityUnavailable
    }

    /// Returns `true` once the 1.0 file is safe for `make()` to open with
    /// the narrower, synced-only schema — whether that is because this
    /// call just finished the split, a prior launch already did, or this
    /// is a fresh install with no 1.0 file to move rows out of. Returns
    /// `false` only when this attempt threw partway through; see this
    /// type's doc comment for what the caller must do then.
    @discardableResult
    static func runIfNeeded() -> Bool {
        if UserDefaults.standard.bool(forKey: flagKey) { return true }

        guard FileManager.default.fileExists(atPath: CloudfullModelContainer.syncedStoreURL.path) else {
            // Fresh install. There is no 1.0 file to migrate rows out of,
            // and no pre-M7 `TrashEntry` row to stamp either.
            UserDefaults.standard.set(true, forKey: flagKey)
            return true
        }

        // A partial earlier attempt can have already written some of
        // `local.store` before this launch's own process died or threw.
        // Left in place, `copy*IfNeeded`'s "does the destination already
        // have a row" check would treat a stale, or only partially
        // committed, write as "already copied" and skip copying this
        // device's own real deck rows out of the 1.0 file. Every attempt
        // starts from a clean slate instead.
        deleteLocalStoreIfExists()

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

                // Throws `MigrationError.deviceIdentityUnavailable` if
                // there is a pre-M7 row to stamp and this device's id
                // cannot currently be read — caught below, same as any
                // other mid-split failure. Stamping with no readable id
                // would need a sentinel this device itself could never
                // recognize again once its real id becomes readable;
                // retrying the whole split next launch is simpler and
                // safe, since nothing has been committed yet.
                try stampOriginDeviceID(in: legacyContext)
                try backfillCloudKeysIfAuthorized(in: legacyContext)

                // This store is `.none` here, so a batch delete is fine:
                // nothing is exporting from it yet.
                try deleteLocalModelRows(in: legacyContext)
                try legacyContext.save()
            }
        } catch {
            // Logged in every build, not only DEBUG: `make()` reacts to
            // this failure by forcing local-only for the launch, which a
            // release build must still be able to diagnose.
            log.error("store_split_failed_\(error.localizedDescription, privacy: .public)")
            #if DEBUG
            DiagnosticsLog.shared.log("Storage", "store_split_failed_\(error.localizedDescription)")
            #endif
            return false   // Flag stays false. The next launch retries from scratch.
        }

        UserDefaults.standard.set(true, forKey: flagKey)
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        DiagnosticsLog.shared.log(
            "Storage",
            "store_split_done_\(ms)_\(deckCopied ? 1 : 0)_\(orderCopied ? 1 : 0)_\(photoDeckCopied ? 1 : 0)"
        )
        #endif
        return true
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
    ///
    /// This runs only once, inside the one-time split, before CloudKit
    /// ever opens — so it can only ever stamp this device's own pre-M7
    /// rows, never another device's. Throws if there is a row to stamp
    /// and this device's id cannot currently be read: the caller's own
    /// `catch` then leaves the flag false, so the whole split (this step
    /// included) retries next launch, instead of this method silently
    /// stamping a sentinel the device could never recognize again.
    private static func stampOriginDeviceID(in legacy: ModelContext) throws {
        let rows = try legacy.fetch(FetchDescriptor<TrashEntry>(predicate: #Predicate { $0.originDeviceID == "" }))
        guard !rows.isEmpty else { return }
        guard let current = DeviceIdentity.currentIfAvailable else {
            throw MigrationError.deviceIdentityUnavailable
        }
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

        // Liked (shield) rows first, then Trash rows, then whatever is
        // left over past the cap below. A `Set` has no order, so
        // building the ordered list by hand, instead of a `Set` union,
        // is what makes the cap actually drop the least important rows
        // first: a Liked row's `cloudKey` protects it from a rotation
        // mistakenly reading it as eligible for deletion, which matters
        // more than a Trash row's.
        var orderedKeys: [String] = []
        var seenKeys = Set<String>()
        for key in likedRows.map(\.assetKey) where !seenKeys.contains(key) {
            orderedKeys.append(key)
            seenKeys.insert(key)
        }
        for key in trashRows.map(\.assetKey) where !seenKeys.contains(key) {
            orderedKeys.append(key)
            seenKeys.insert(key)
        }
        // Caps the main-thread PhotoKit round trip at 2,000 rows. This
        // runs before the first frame, inside `CloudfullModelContainer`'s
        // static initializer; an unexpectedly large bin or keep table
        // here could otherwise trip `MainThreadWatchdog` or crash-loop
        // the launch. A row this cap leaves out keeps `cloudKey == nil`
        // and stays pending: `CloudKeyBackfiller` does the same mapping
        // off the main actor on this and every later launch.
        let keyList = Array(orderedKeys.prefix(2000))

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

    // MARK: - Clean slate for the local store

    /// Removes `local.store` and its `-shm`/`-wal` sidecar files, if any
    /// are there, before this attempt opens it. `copyDeckStateIfNeeded`
    /// and its two siblings only copy a row across when the destination
    /// has none yet; without this, a partial earlier attempt's own
    /// write — possibly only partially committed — would read as
    /// "already copied" and never be replaced with a fresh copy from
    /// `default.store`. Each candidate not existing is the common case
    /// (no prior partial attempt) and not an error.
    private static func deleteLocalStoreIfExists() {
        let base = CloudfullModelContainer.localStoreURL.path
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: base + suffix)
        }
    }
}
