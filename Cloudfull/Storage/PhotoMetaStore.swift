//
//  PhotoMetaStore.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftData
import Photos

/// The disk half of the photo metadata cache (`PhotoMetaRecord`,
/// `Cloudfull/Photos/PhotoModels.swift`). It survives a relaunch.
/// `PhotoMetadataCache` (`Cloudfull/Photos/PhotoMetadata.swift`) is the
/// in-memory half for the current session.
///
/// `@ModelActor`, for the same reason as `SeenStore` and `PhotoSeenStore`:
/// a `ModelContext` is not `Sendable`. No SwiftData work, and no PhotoKit
/// freshness check either, runs on the main actor.
@ModelActor
actor PhotoMetaStore {
    static let shared = PhotoMetaStore(modelContainer: CloudfullModelContainer.shared)

    /// A save on every write causes too much SQLite I/O. A tier-1 load, a
    /// tier-2 load, and a place resolution can each write within
    /// milliseconds of each other during a fast scroll. Each `writeXXX`
    /// method below only mutates its `PhotoMetaRecord` in memory and
    /// calls `scheduleFlush()`. The one pending flush task coalesces
    /// however many writes land inside its window into a single
    /// `modelContext.save()`.
    private var pendingFlush: Task<Void, Never>?

    /// Batches writes about 500 ms apart, and never commits mid-scroll.
    /// The save runs on this actor's executor, off the main actor. The
    /// `pwrite` it causes still competes with the render thread for CPU
    /// and I/O. It waits for `ScrollPhaseGate` to go idle before
    /// flushing.
    private func scheduleFlush() {
        guard pendingFlush == nil else { return }
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            await ScrollPhaseGate.shared.waitUntilIdle()
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    private func flush() {
        pendingFlush = nil
        guard modelContext.hasChanges else { return }
        try? modelContext.save()
    }

    /// Reads the disk row for `assetID`, and returns it only while it is
    /// still fresh. `PhotoLibraryService.fetchAsset` is a cheap lookup in
    /// the on-device Photos index. It reads no image data and uses no
    /// network. It runs on this actor, off the main actor. Its
    /// `modificationDate` must still match what was stored at write
    /// time. Returns `nil` on a disk miss, a deleted asset, or a stale
    /// row. The caller (`PhotoMetadataCache.resolvedTier1` or
    /// `resolvedTier2`) reloads fully from PhotoKit in every one of
    /// those cases.
    ///
    /// `place` is a double optional, the same shape `PlaceLookup` uses.
    /// The outer `nil` means the place has never been resolved for this
    /// asset. The inner `nil` means it was resolved and there is no
    /// place to show. This lets a second sighting of a geotagged photo
    /// skip reverse geocoding.
    func fetchIfFresh(
        assetID: String
    ) -> (tier1: PhotoMetadata.Tier1?, tier2: PhotoMetadata.Tier2?, place: String??)? {
        let descriptor = FetchDescriptor<PhotoMetaRecord>(predicate: #Predicate { $0.assetID == assetID })
        guard let record = (try? modelContext.fetch(descriptor))?.first else { return nil }
        guard let asset = PhotoLibraryService.fetchAsset(assetID) else { return nil }
        guard record.modificationDate == asset.modificationDate else { return nil }
        return (record.tier1, record.tier2, record.hasPlace ? .some(record.placeText) : nil)
    }

    /// Saves one resolved place. Called for photo assets only; the video
    /// side shares `PlaceLookup` but not this table.
    func writePlace(_ place: String?, assetID: String) {
        // Do not call this on the main thread. The SwiftData work here
        // blocks the UI. The assert stops DEBUG builds if a caller moves
        // it there.
        assert(!Thread.isMainThread, "PhotoMetaStore.writePlace reached the main thread")
        let record = fetchOrCreate(assetID: assetID)
        record.hasPlace = true
        record.placeText = place
        if record.modificationDate == nil {
            record.modificationDate = PhotoLibraryService.fetchAsset(assetID)?.modificationDate
        }
        scheduleFlush()
    }

    func writeTier1(_ tier1: PhotoMetadata.Tier1, assetID: String) {
        assert(!Thread.isMainThread, "PhotoMetaStore.writeTier1 reached the main thread")
        let record = fetchOrCreate(assetID: assetID)
        record.apply(tier1: tier1)
        record.modificationDate = PhotoLibraryService.fetchAsset(assetID)?.modificationDate
        record.fetchedAt = Date()
        scheduleFlush()
    }

    func writeTier2(_ tier2: PhotoMetadata.Tier2, assetID: String) {
        assert(!Thread.isMainThread, "PhotoMetaStore.writeTier2 reached the main thread")
        let record = fetchOrCreate(assetID: assetID)
        record.apply(tier2: tier2)
        // A tier-1 write usually already stamps this, since every caller
        // loads tier 1 first. Set it here too so a tier-2-only record
        // still has one.
        if record.modificationDate == nil {
            record.modificationDate = PhotoLibraryService.fetchAsset(assetID)?.modificationDate
        }
        scheduleFlush()
    }

    private func fetchOrCreate(assetID: String) -> PhotoMetaRecord {
        let descriptor = FetchDescriptor<PhotoMetaRecord>(predicate: #Predicate { $0.assetID == assetID })
        if let existing = (try? modelContext.fetch(descriptor))?.first { return existing }
        let record = PhotoMetaRecord(assetID: assetID)
        modelContext.insert(record)
        return record
    }
}
