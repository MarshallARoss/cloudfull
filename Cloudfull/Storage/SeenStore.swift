//
//  SeenStore.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftData
import Foundation

// MARK: - SeenStore

/// The only owner of `SeenEntry` records.
///
/// This type is a `@ModelActor`, for the same reason `CloudKeyBackfiller`
/// is one: a `ModelContext` is not `Sendable`, and no SwiftData work on the
/// load path may run on the main actor.
///
/// Every method fetches only the matching rows on this background actor.
/// A full-table fetch on the main thread creates one object per seen
/// video and blocks page changes.
///
/// Every parameter and return value here is `Sendable` (`String`,
/// `Set<String>`, `Int`). No model object ever leaves this actor.
@ModelActor
actor SeenStore {

    /// Session cache: cloud key -> the local id it currently maps to.
    /// `foreignMatches()` fills this as it meets a cloud key it has not
    /// resolved yet, so a key already looked up this session costs no
    /// second PhotoKit round trip.
    private var foreignLocalByCloudKey: [String: String] = [:]

    /// Inserts a `SeenEntry` for `assetKey`, unless one already exists.
    ///
    /// The caller does not wait for this method. The deck's own
    /// in-memory memo, `DeckViewModel.markedSeenThisSession`, makes the
    /// seen decision immediately. This method only writes the durable
    /// copy.
    ///
    /// This method does not set `cloudKey`. `CloudKeyBackfiller` sets it
    /// later.
    func markSeen(_ assetKey: String) {
        let descriptor = FetchDescriptor<SeenEntry>(predicate: #Predicate { $0.assetKey == assetKey })
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        guard existing.isEmpty else { return }
        modelContext.insert(SeenEntry(assetKey: assetKey))
        try? modelContext.save()
        // This actor is not the main actor, and `CloudKeyBackfillLauncher`
        // is. Hop over to resolve this row's cloudKey within seconds.
        Task { @MainActor in
            CloudKeyBackfillLauncher.shared.noteNewRow(assetKey)
        }
    }

    /// Returns every stored seen key that is also in `ids`.
    ///
    /// The filter runs as a predicate on the fetch itself, so the actor
    /// never loads rows it does not need. Only a `Set<String>` crosses back
    /// to the caller. SwiftData predicates need an `Array`, not a `Set`,
    /// so the method converts `ids` first.
    func seenKeys(limitedTo ids: Set<String>) -> Set<String> {
        let idList = Array(ids)
        let descriptor = FetchDescriptor<SeenEntry>(predicate: #Predicate { idList.contains($0.assetKey) })
        let matched = (try? modelContext.fetch(descriptor)) ?? []
        var result = Set(matched.map(\.assetKey))
        // A row another device inserted matches on its cloud key, not its
        // stored (that device's own) raw key. `ids` is this device's
        // live library, so only a foreign row whose mapped local id is
        // also in `ids` counts as seen here.
        for match in foreignMatches() where ids.contains(match.localID) {
            result.insert(match.localID)
        }
        return result
    }

    /// Deletes every `SeenEntry` whose key is in `ids`, and returns the
    /// number of rows deleted.
    ///
    /// The method does not change rows for other ids. It fetches only
    /// the matching rows, through a predicate, instead of loading the
    /// whole table and filtering in Swift.
    ///
    /// Also deletes a foreign row whose mapped local id is in `ids`, so
    /// a reshuffle clears a cross-device seen mark too, the same as a
    /// direct one. This delete syncs to every device through CloudKit.
    @discardableResult
    func clearSeen(in ids: Set<String>) -> Int {
        let idList = Array(ids)
        let descriptor = FetchDescriptor<SeenEntry>(predicate: #Predicate { idList.contains($0.assetKey) })
        let matched = (try? modelContext.fetch(descriptor)) ?? []
        for entry in matched {
            modelContext.delete(entry)
        }
        let foreignMatchesToClear = foreignMatches().filter { ids.contains($0.localID) }
        for match in foreignMatchesToClear {
            modelContext.delete(match.row)
        }
        let count = matched.count + foreignMatchesToClear.count
        if count > 0 { try? modelContext.save() }
        return count
    }

    /// Every `SeenEntry` another device inserted, mapped to the local id
    /// it currently names on this device. A "foreign" row has
    /// `originDeviceID` set to neither this device nor `""` (a 1.0 row,
    /// which is this device's own in practice and matches on `assetKey`
    /// as today), and has a `cloudKey` to map from.
    ///
    /// Maps only the cloud keys not already in `foreignLocalByCloudKey`,
    /// in chunks of 200, the same batching `CloudKeyBackfiller` uses. A
    /// key that does not map to a live asset on this device (not in this
    /// device's library, or not yet synced) is simply absent from the
    /// result.
    private func foreignMatches() -> [(row: SeenEntry, localID: String)] {
        let me = DeviceIdentity.current
        let descriptor = FetchDescriptor<SeenEntry>(predicate: #Predicate {
            $0.originDeviceID != me && $0.originDeviceID != "" && $0.cloudKey != nil
        })
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        guard !rows.isEmpty else { return [] }

        let uncachedKeys = Array(Set(rows.compactMap(\.cloudKey)).subtracting(foreignLocalByCloudKey.keys))
        var offset = 0
        while offset < uncachedKeys.count {
            let end = min(offset + 200, uncachedKeys.count)
            let mapped = PhotoLibraryService.localIdentifierMappings(forCloudIdentifiers: Array(uncachedKeys[offset..<end]))
            foreignLocalByCloudKey.merge(mapped) { _, new in new }
            offset = end
        }

        let out = rows.compactMap { row -> (row: SeenEntry, localID: String)? in
            guard let cloudKey = row.cloudKey, let localID = foreignLocalByCloudKey[cloudKey] else { return nil }
            return (row, localID)
        }
        #if DEBUG
        // M7-QUESTION: the spec names one shared `SeenForeignProbe.mapped`
        // "set by both stores", not two separate counts. Conservative
        // reading: each store overwrites it with its own latest count,
        // so `seen_foreign_` reflects whichever of `SeenStore`/
        // `PhotoSeenStore` computed last, not a true video+photo total.
        // `M7Tests` only ever seeds one foreign video-seen row per run,
        // so this never shows up there.
        SeenForeignProbe.mapped = out.count
        #endif
        return out
    }
}

// Do not add `FetchCounters.swiftData` calls to this file. That counter
// proves that no SwiftData work runs on the render path. Work on this
// background actor is not render-path work, so counting it here would make
// the counter less accurate, not more.
