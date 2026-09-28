//
//  CloudKeyBackfiller.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftData
import Foundation
import Photos
import os

// MARK: - CloudKeyBackfiller

/// Fills `cloudKey` on every `SeenEntry`, `LikedEntry`, and `TrashEntry` row
/// that still has none. `DeckViewModel` and `TrashService` write these rows
/// without a synchronous PhotoKit call, so a fresh row starts with
/// `cloudKey == nil`. Without this backfill, a local-identifier rotation
/// loses every shield and every queued delete.
///
/// This type uses `@ModelActor`, not a `Task.detached` against the main
/// context. A `ModelContext` is not `Sendable`. Enumerating the library on
/// the main actor is slow. `@ModelActor` gives this work its own context
/// and executor. The SwiftData fetches and the PhotoKit mapping calls never
/// touch the main thread.
@ModelActor
actor CloudKeyBackfiller {

    struct Result: Sendable {
        let resolved: Int
        let pending: Int
        let total: Int
    }

    private static let log = Logger(subsystem: "com.cloudfull.app", category: "CloudKeyBackfiller")

    /// Fills `cloudKey` on every row that still has none. A row that
    /// PhotoKit cannot map keeps `cloudKey == nil` and counts as pending.
    /// The backfiller tries the row again on the next launch. This method
    /// never deletes or changes such a row.
    func run() async -> Result {
        let seenNilDescriptor = FetchDescriptor<SeenEntry>(predicate: #Predicate { $0.cloudKey == nil })
        let likedNilDescriptor = FetchDescriptor<LikedEntry>(predicate: #Predicate { $0.cloudKey == nil })
        let trashNilDescriptor = FetchDescriptor<TrashEntry>(predicate: #Predicate { $0.cloudKey == nil })

        // Check the row counts first. `fetchCount` does not load any row
        // data, so this step does no real work once every row has a key.
        #if DEBUG
        FetchCounters.swiftData += 3
        #endif
        let seenNilCount = (try? modelContext.fetchCount(seenNilDescriptor)) ?? 0
        let likedNilCount = (try? modelContext.fetchCount(likedNilDescriptor)) ?? 0
        let trashNilCount = (try? modelContext.fetchCount(trashNilDescriptor)) ?? 0
        guard seenNilCount + likedNilCount + trashNilCount > 0 else {
            return Result(resolved: 0, pending: 0, total: 0)
        }

        #if DEBUG
        FetchCounters.swiftData += 3
        #endif
        let seenRows = (try? modelContext.fetch(seenNilDescriptor)) ?? []
        let likedRows = (try? modelContext.fetch(likedNilDescriptor)) ?? []
        let trashRows = (try? modelContext.fetch(trashNilDescriptor)) ?? []

        // An asset can appear as both a `SeenEntry` and a `TrashEntry`. One
        // mapping call resolves the key for both rows.
        var distinctKeys = Set<String>()
        distinctKeys.formUnion(seenRows.map(\.assetKey))
        distinctKeys.formUnion(likedRows.map(\.assetKey))
        distinctKeys.formUnion(trashRows.map(\.assetKey))

        let keyList = Array(distinctKeys)
        var cloudKeyByLocalID: [String: String] = [:]
        var offset = 0
        while offset < keyList.count {
            let end = min(offset + 200, keyList.count)
            let chunk = Array(keyList[offset..<end])
            let mapped = PhotoLibraryService.cloudIdentifierMappings(forLocalIdentifiers: chunk)
            cloudKeyByLocalID.merge(mapped) { _, new in new }
            offset = end
            if offset < keyList.count {
                await Task.yield()
            }
        }

        for row in seenRows {
            if let cloudKey = cloudKeyByLocalID[row.assetKey] { row.cloudKey = cloudKey }
        }
        for row in likedRows {
            if let cloudKey = cloudKeyByLocalID[row.assetKey] { row.cloudKey = cloudKey }
        }
        for row in trashRows {
            if let cloudKey = cloudKeyByLocalID[row.assetKey] { row.cloudKey = cloudKey }
        }

        do {
            try modelContext.save()
        } catch {
            // A save error here means no key reached disk, so every row
            // still reads `cloudKey == nil` on the next launch. Report each
            // fetched row as pending, so the probe and
            // `CloudKeyBackfillLauncher` match what disk actually holds.
            Self.log.error("CloudKeyBackfiller failed to save resolved cloudKeys: \(error.localizedDescription, privacy: .public)")
            let total = seenRows.count + likedRows.count + trashRows.count
            return Result(resolved: 0, pending: total, total: total)
        }

        // Each fetched row lands in exactly one bucket, counted by
        // re-reading `cloudKey` after the write. `total` therefore always
        // equals `resolved + pending`, not two separately computed numbers.
        let resolved = seenRows.lazy.filter { $0.cloudKey != nil }.count
            + likedRows.lazy.filter { $0.cloudKey != nil }.count
            + trashRows.lazy.filter { $0.cloudKey != nil }.count
        let pending = seenRows.lazy.filter { $0.cloudKey == nil }.count
            + likedRows.lazy.filter { $0.cloudKey == nil }.count
            + trashRows.lazy.filter { $0.cloudKey == nil }.count

        return Result(resolved: resolved, pending: pending, total: resolved + pending)
    }
}

// MARK: - CloudKeyBackfillLauncher

/// Starts `CloudKeyBackfiller` once per process, from
/// `PermissionGateView.body`'s `.task`. In a DEBUG build, it can also run a
/// test-album purge or an export-replacement pass first, when the process
/// arguments request one. All three paths start from the same `.task` and
/// need photo authorization first. The purge deletes only the app's own
/// test albums, titled with the prefix "Cloudfull UITest ", and never
/// touches an asset inside one. It runs only when
/// `CloudfullApp.purgeTestAlbumsArgument` is present, and adds no
/// measurable delay before the backfill's 2-second wait.
@MainActor
final class CloudKeyBackfillLauncher {
    static let shared = CloudKeyBackfillLauncher()

    private var didRun = false

    private init() {}

    func runIfNeeded(container: ModelContainer) async {
        guard !didRun else { return }

        // Set `didRun` only after the authorization guard passes.
        // `PermissionGateView`'s `.task(id: library.authStatus)` re-fires on
        // each status change, so a launch that starts `.notDetermined` and
        // later gets access still gets one real attempt.
        //
        // This requires `.authorized`, not `.limited`. A limited launch can
        // see only the user-selected subset of the library, so a backfill
        // pass over that subset would leave every row outside it unresolved
        // with no way to retry. Requiring `.authorized` keeps `didRun`
        // false during a limited launch, so `PermissionGateView` fires a
        // real attempt the moment full access is granted.
        let authStatus = PhotoLibraryService.shared.authStatus
        guard authStatus == .authorized else { return }
        didRun = true

        #if DEBUG
        // A launch that passes `suppressBackfillArgument` seeds `SeenEntry`,
        // `LikedEntry`, and `TrashEntry` rows and must exit with every
        // `cloudKey` still nil. Returning here lets a later launch run the
        // backfill against a fixed row count. It avoids starting the
        // 2-second delay at the same time as the seed writes.
        if ProcessInfo.processInfo.arguments.contains(CloudfullApp.suppressBackfillArgument) {
            return
        }
        if ProcessInfo.processInfo.arguments.contains(CloudfullApp.purgeTestAlbumsArgument) {
            await PhotoLibraryService.shared.deleteAlbums(titledWithPrefix: "Cloudfull UITest ")
        }
        // This runs from the same place and for the same reason as the
        // purge hook above: it needs photo authorization, which this
        // `.task(id: library.authStatus)`-driven launcher already
        // guarantees.
        if ProcessInfo.processInfo.arguments.contains(CloudfullApp.exportReplacementArgument) {
            await ReplacementExporter.run()
            exit(0)
        }
        #endif

        BackfillProbe.shared.markRunning()

        // Starts 2 seconds after this task launches, so it never competes
        // with `DeckViewModel.start()` for PhotoKit access at launch.
        try? await Task.sleep(for: .seconds(2))

        let backfiller = CloudKeyBackfiller(modelContainer: container)
        let result = await backfiller.run()
        BackfillProbe.shared.finish(result)
    }
}

// MARK: - BackfillProbe

/// A DEBUG-read mirror of the backfill's progress. `FeedView` formats it as
/// `backfill_<state>_<resolved>_<pending>_<total>`. This type compiles into
/// every build, since the launcher writes to it either way, but callers
/// read it only inside `#if DEBUG`.
@MainActor
final class BackfillProbe: ObservableObject {
    static let shared = BackfillProbe()

    enum State: String { case idle, running, done }

    @Published private(set) var state: State = .idle
    @Published private(set) var resolved = 0
    @Published private(set) var pending = 0
    @Published private(set) var total = 0

    private init() {}

    func markRunning() {
        state = .running
    }

    func finish(_ result: CloudKeyBackfiller.Result) {
        resolved = result.resolved
        pending = result.pending
        total = result.total
        state = .done
    }
}
