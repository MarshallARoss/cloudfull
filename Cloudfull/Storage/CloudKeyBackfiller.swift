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

/// Fills `cloudKey` on every `SeenEntry`, `LikedEntry`, `TrashEntry`, and
/// `PhotoSeenEntry` row that still has none. `DeckViewModel`, `PhotoDeck`,
/// and `TrashService` write these rows without a synchronous PhotoKit
/// call, so a fresh row starts with `cloudKey == nil`. Without this
/// backfill, a local-identifier rotation loses every shield and every
/// queued delete, and a seen row never cross-matches another device's
/// copy of the same asset.
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
        await runBackfill(onlyAssetKeys: nil)
    }

    /// Same as `run()`, but only considers a nil-cloudKey row whose
    /// `assetKey` is in `keys`. `CloudKeyBackfillLauncher.noteNewRow`
    /// uses this to resolve a just-inserted row within seconds, instead
    /// of waiting for the next full-table pass.
    func run(onlyAssetKeys keys: Set<String>) async -> Result {
        await runBackfill(onlyAssetKeys: keys)
    }

    /// The shared body behind `run()` and `run(onlyAssetKeys:)`. `nil`
    /// means every nil-cloudKey row, matching `run()`'s own contract.
    private func runBackfill(onlyAssetKeys keys: Set<String>?) async -> Result {
        let seenNilDescriptor: FetchDescriptor<SeenEntry>
        let likedNilDescriptor: FetchDescriptor<LikedEntry>
        let trashNilDescriptor: FetchDescriptor<TrashEntry>
        let photoSeenNilDescriptor: FetchDescriptor<PhotoSeenEntry>
        if let keys {
            // `#Predicate` needs an `Array`, and it captures a local
            // `let`, not the parameter itself.
            let keyList = Array(keys)
            seenNilDescriptor = FetchDescriptor<SeenEntry>(predicate: #Predicate { $0.cloudKey == nil && keyList.contains($0.assetKey) })
            likedNilDescriptor = FetchDescriptor<LikedEntry>(predicate: #Predicate { $0.cloudKey == nil && keyList.contains($0.assetKey) })
            trashNilDescriptor = FetchDescriptor<TrashEntry>(predicate: #Predicate { $0.cloudKey == nil && keyList.contains($0.assetKey) })
            photoSeenNilDescriptor = FetchDescriptor<PhotoSeenEntry>(predicate: #Predicate { $0.cloudKey == nil && keyList.contains($0.assetKey) })
        } else {
            seenNilDescriptor = FetchDescriptor<SeenEntry>(predicate: #Predicate { $0.cloudKey == nil })
            likedNilDescriptor = FetchDescriptor<LikedEntry>(predicate: #Predicate { $0.cloudKey == nil })
            trashNilDescriptor = FetchDescriptor<TrashEntry>(predicate: #Predicate { $0.cloudKey == nil })
            photoSeenNilDescriptor = FetchDescriptor<PhotoSeenEntry>(predicate: #Predicate { $0.cloudKey == nil })
        }

        // Check the row counts first. `fetchCount` does not load any row
        // data, so this step does no real work once every row has a key.
        #if DEBUG
        FetchCounters.swiftData += 4
        #endif
        let seenNilCount = (try? modelContext.fetchCount(seenNilDescriptor)) ?? 0
        let likedNilCount = (try? modelContext.fetchCount(likedNilDescriptor)) ?? 0
        let trashNilCount = (try? modelContext.fetchCount(trashNilDescriptor)) ?? 0
        let photoSeenNilCount = (try? modelContext.fetchCount(photoSeenNilDescriptor)) ?? 0
        guard seenNilCount + likedNilCount + trashNilCount + photoSeenNilCount > 0 else {
            return Result(resolved: 0, pending: 0, total: 0)
        }

        #if DEBUG
        FetchCounters.swiftData += 4
        #endif
        let seenRows = (try? modelContext.fetch(seenNilDescriptor)) ?? []
        let likedRows = (try? modelContext.fetch(likedNilDescriptor)) ?? []
        let trashRows = (try? modelContext.fetch(trashNilDescriptor)) ?? []
        let photoSeenRows = (try? modelContext.fetch(photoSeenNilDescriptor)) ?? []

        // An asset can appear as both a `SeenEntry` and a `TrashEntry`. One
        // mapping call resolves the key for both rows.
        var distinctKeys = Set<String>()
        distinctKeys.formUnion(seenRows.map(\.assetKey))
        distinctKeys.formUnion(likedRows.map(\.assetKey))
        distinctKeys.formUnion(trashRows.map(\.assetKey))
        distinctKeys.formUnion(photoSeenRows.map(\.assetKey))

        let keyList = Array(distinctKeys)
        var cloudKeyByLocalID: [String: String] = [:]
        var offset = 0
        while offset < keyList.count {
            let end = min(offset + 200, keyList.count)
            let chunk = Array(keyList[offset..<end])
            let mapped = PhotoLibraryService.cloudIdentifierMappings(forLocalIdentifiers: chunk)
            guard !mapped.isEmpty else {
                // This chunk's 200 local ids mapped to nothing: the
                // library almost certainly has no cloud identifiers
                // available right now (no iCloud Photos). Mapping every
                // later chunk would cost the same for the same result.
                // Every row this pass has not already resolved stays
                // nil and pending; the next launch tries again.
                #if DEBUG
                DiagnosticsLog.shared.log("CloudKeyBackfiller", "backfill_stopped_unmapped")
                #endif
                break
            }
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
        for row in photoSeenRows {
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
            let total = seenRows.count + likedRows.count + trashRows.count + photoSeenRows.count
            return Result(resolved: 0, pending: total, total: total)
        }

        // Each fetched row lands in exactly one bucket, counted by
        // re-reading `cloudKey` after the write. `total` therefore always
        // equals `resolved + pending`, not two separately computed numbers.
        let resolved = seenRows.lazy.filter { $0.cloudKey != nil }.count
            + likedRows.lazy.filter { $0.cloudKey != nil }.count
            + trashRows.lazy.filter { $0.cloudKey != nil }.count
            + photoSeenRows.lazy.filter { $0.cloudKey != nil }.count
        let pending = seenRows.lazy.filter { $0.cloudKey == nil }.count
            + likedRows.lazy.filter { $0.cloudKey == nil }.count
            + trashRows.lazy.filter { $0.cloudKey == nil }.count
            + photoSeenRows.lazy.filter { $0.cloudKey == nil }.count

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

    /// Keys `noteNewRow` has collected since the last narrow pass ran.
    private var pendingNewRowKeys: Set<String> = []
    /// Non-nil while a narrow pass's 2-second wait is in flight. Keeps a
    /// burst of `noteNewRow` calls from starting more than one task.
    private var pendingNewRowTask: Task<Void, Never>?

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

    /// Called after a successful insert of a `SeenEntry`, `LikedEntry`,
    /// `TrashEntry`, or `PhotoSeenEntry` row whose `cloudKey` is still
    /// nil. Without this, that row waits for the next launch's full-table
    /// pass before it can shield, queue, or cross-device-match through
    /// its cloud key. Adds `assetKey` to a pending set, and starts, if
    /// none is already running, a task that sleeps 2 s, takes the set,
    /// and runs a narrow `CloudKeyBackfiller` pass against exactly those
    /// keys.
    ///
    /// A no-op before `runIfNeeded()`'s initial pass has actually run
    /// (`didRun == false`, which also covers "access not yet
    /// `.authorized`"): that pass sees every unresolved row anyway, this
    /// one included.
    func noteNewRow(_ assetKey: String) {
        guard didRun else { return }
        #if DEBUG
        // `M4Tests.testCloudKeyBackfillAccountsForEveryRow`'s seeding
        // launch needs every row it writes to still read `cloudKey ==
        // nil` when the process terminates. See the identical guard in
        // `runIfNeeded()`.
        if ProcessInfo.processInfo.arguments.contains(CloudfullApp.suppressBackfillArgument) {
            return
        }
        #endif
        pendingNewRowKeys.insert(assetKey)
        guard pendingNewRowTask == nil else { return }
        pendingNewRowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            let keys = self.pendingNewRowKeys
            self.pendingNewRowKeys = []
            self.pendingNewRowTask = nil
            guard !keys.isEmpty else { return }
            _ = await CloudKeyBackfiller(modelContainer: CloudfullModelContainer.shared).run(onlyAssetKeys: keys)
        }
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
