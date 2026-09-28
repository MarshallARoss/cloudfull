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
        return Set(matched.map(\.assetKey))
    }

    /// Deletes every `SeenEntry` whose key is in `ids`, and returns the
    /// number of rows deleted.
    ///
    /// The method does not change rows for other ids. It fetches only
    /// the matching rows, through a predicate, instead of loading the
    /// whole table and filtering in Swift.
    @discardableResult
    func clearSeen(in ids: Set<String>) -> Int {
        let idList = Array(ids)
        let descriptor = FetchDescriptor<SeenEntry>(predicate: #Predicate { idList.contains($0.assetKey) })
        let matched = (try? modelContext.fetch(descriptor)) ?? []
        for entry in matched {
            modelContext.delete(entry)
        }
        if !matched.isEmpty { try? modelContext.save() }
        return matched.count
    }
}

// Do not add `FetchCounters.swiftData` calls to this file. That counter
// proves that no SwiftData work runs on the render path. Work on this
// background actor is not render-path work, so counting it here would make
// the counter less accurate, not more.
