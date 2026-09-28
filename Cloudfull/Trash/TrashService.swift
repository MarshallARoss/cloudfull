//
//  TrashService.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftData
import os

/// The trash queue holds assets the user swiped to delete. The service has
/// not yet removed these assets from the photo library.
///
/// A tap on the trash rail only adds an entry to the queue. The system shows
/// one delete confirmation for the whole batch, in `emptyBin()`.
///
/// The queue also gives undo. `restore(assetID:)` removes the queued entry.
/// This needs no system interaction, because the asset is still in the
/// photo library.
@MainActor
final class TrashService: ObservableObject {
    @Published private(set) var entries: [TrashEntry] = []
    /// Ids that `emptyBin()` is deleting. The set holds them for the full
    /// PhotoKit call, from the confirmation dialog until `performChanges`
    /// completes. `restore(assetID:)` refuses these ids, even after the
    /// dialog closes.
    @Published private(set) var pendingEmptyIDs: Set<String> = []

    /// Ids this service has confirmed, through its own bounded PhotoKit
    /// spot check, do not currently name a live asset. `TrashView`'s cell
    /// and preview treat every other queued id as live. This is the
    /// optimistic default a freshly queued row needs.
    ///
    /// `queue(assetID:)` and `restore(assetID:)` call `refreshLiveness()`,
    /// and `TrashView` calls it when the bin sheet opens. `emptyBin()` and
    /// `reconcileWithLibrary()` update the set from their own spot checks.
    /// This service can answer the liveness question for its own rows
    /// without depending on another component's unrelated refresh schedule.
    ///
    /// `TrashEntry.dormantSince` is a separate timer for the deletion of
    /// rows whose asset is gone. This set does not change it.
    @Published private(set) var confirmedDeadIDs: Set<String> = []

    private let library: PhotoLibraryService
    private let modelContext: ModelContext
    private let resolver = AssetKeyResolver.shared
    private let logger = Logger(subsystem: "com.cloudfull.app", category: "TrashService")
    private var libraryChangeTask: Task<Void, Never>?
    private var observerToken: LibraryObserverToken?
    private var didStart = false

    /// Maps each entry's stored `assetKey` and its resolved live id to
    /// the entry. `load()` rebuilds it after every change. The lookup
    /// still finds a row after its key rotates.
    private var entriesByLiveKey: [String: TrashEntry] = [:]

    /// Fires after `queue(assetID:)` commits. `DeckViewModel` uses this to
    /// remove the asset from every slot ahead of the current page.
    var onQueued: ((String) -> Void)?
    /// Fires after `emptyBin()` succeeds. The argument holds the stored
    /// `assetKey` of each deleted entry.
    var onEmptied: (([String]) -> Void)?
    /// Fires after `restore(assetID:)` commits.
    var onRestored: ((String) -> Void)?

    var count: Int { entries.count }
    /// Net bytes still queued for deletion: the sum, over every
    /// `TrashEntry`, of `max(bytes - replacementBytes, 0)`. `load()` and
    /// `applyZeroByteRepair()` recompute this value. It is a stored
    /// property, not one recomputed on every access, so this and
    /// `reclaimedBytes` always read the same `entries` snapshot during a
    /// mutation. The `max(…, 0)` guard stops a shrink whose replacement is
    /// larger than the original from contributing a negative number. A
    /// negative number would hide a real queued delete. The name avoids
    /// "total bytes": a shrunk original's replacement permanently occupies
    /// part of that space. Not every byte in the queue is reclaimable.
    @Published private(set) var pendingBytes: Int64 = 0
    /// The all-time total of bytes freed by completed `emptyBin()` passes.
    /// Each pass adds the same `max(bytes - replacementBytes, 0)`
    /// expression used by `pendingBytes`, evaluated from the pre-delete
    /// snapshot. UserDefaults stores this value under `reclaimedAllTimeKey`.
    /// `init` loads it.
    @Published private(set) var reclaimedBytes: Int64 = 0
    /// True if any queued entry's size is an estimate rather than a
    /// measured size (see `PhotoLibraryService.fileSize(for:)`). The UI
    /// uses this to show "about" before a pending or freed figure instead
    /// of an exact number.
    var hasEstimatedSizes: Bool { entries.contains { $0.isEstimatedBytes } }
    /// Counts rows by their stored `mediaKind`. A row with no stored kind
    /// has the default "video", so it counts as a video.
    var videoCount: Int { entries.filter { $0.mediaKind == TrashMediaKind.video.rawValue }.count }
    var photoCount: Int { entries.filter { $0.mediaKind == TrashMediaKind.photo.rawValue }.count }

    init(library: PhotoLibraryService, modelContext: ModelContext) {
        self.library = library
        self.modelContext = modelContext
        // UserDefaults stores the reclaimed total across launches. In
        // DEBUG builds, the `-cloudfull-reset-deck-state` argument clears
        // it.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(CloudfullApp.resetStateArgument) {
            UserDefaults.standard.removeObject(forKey: Self.reclaimedAllTimeKey)
        }
        #endif
        reclaimedBytes = Int64(UserDefaults.standard.integer(forKey: Self.reclaimedAllTimeKey))
        #if DEBUG
        RowCountProbe.lastReclaimed = reclaimedBytes
        #endif
        load()
    }

    private static let reclaimedAllTimeKey = "space.reclaimedAllTime"

    deinit {
        libraryChangeTask?.cancel()
        if let observerToken {
            library.removeLibraryChangeObserver(observerToken)
        }
    }

    /// One-time setup: reconciles the queue against the library as of
    /// launch, and subscribes to future library changes. This is
    /// deliberately not in `init`.
    ///
    /// `PermissionGateView.authorizedView` is a computed property. It
    /// builds a fresh `TrashService` on every SwiftUI body re-evaluation.
    /// Only the first instance survives, kept alive by `FeedView`'s
    /// `@StateObject`. Registering with the singleton `PhotoLibraryService`
    /// from `init` would leave one dead observer closure behind for every
    /// discarded instance.
    ///
    /// Call this from the same `.task` that calls `DeckViewModel.start()`.
    /// `FeedView`'s `.task` can run again after a remount, so `didStart`
    /// makes the observer registration run once. A later call only
    /// schedules a reconciliation.
    func start() {
        guard !didStart else {
            scheduleReconciliation()
            return
        }
        didStart = true

        // Rebuilds `entriesByLiveKey` once a rotation candidate's cloud
        // key resolves in the background. Before that, a row's
        // resolved-live-id mapping reflects only what `load()` last knew,
        // which after a fresh rotation can be nothing.
        //
        // Register this handler once. `AssetKeyResolver` never removes
        // handlers, so a discarded `TrashService` must not register one.
        resolver.onResolutionLanded { [weak self] _ in
            self?.load()
        }

        // Remove rows whose asset is no longer in the library. This
        // occurs after a delete in the Photos app while the app is not
        // running. It also occurs if the process stops before the
        // `emptyBin()` cleanup save.
        Task { [weak self] in
            await self?.reconcileWithLibrary()
        }
        if let observerToken {
            library.removeLibraryChangeObserver(observerToken)
        }
        observerToken = library.addLibraryChangeObserver { [weak self] in
            self?.scheduleReconciliation()
        }
    }

    /// True if `assetID` matches a queued entry's stored key or live id.
    /// See `entriesByLiveKey`.
    func isQueued(_ assetID: String) -> Bool {
        entriesByLiveKey[assetID] != nil
    }

    /// True unless `confirmedDeadIDs` has confirmed this row's asset is
    /// gone. `TrashView`'s cell and preview read this instead of
    /// `AssetKeyResolver.currentLocalIdentifier`. See `confirmedDeadIDs`
    /// for why. The default is optimistic: a row this service has not yet
    /// spot-checked reads as live.
    func isLive(assetKey: String) -> Bool { !confirmedDeadIDs.contains(assetKey) }

    /// Queues an asset for deletion. Returns `false`, refusing the queue,
    /// in three cases:
    ///
    /// - `AssetKeyResolver.isDestructiveActionSafe` is false: rotation
    ///   resolution has not landed, or access is Limited.
    /// - The asset is already queued, so a double tap or a re-delivered
    ///   gesture never double-counts its bytes in the space counter.
    /// - The user liked the asset, even if a caller skips the UI's own check.
    ///
    /// `ShrinkService.onOriginalReadyToTrash` returns this value. Do not
    /// report a delete when it is false.
    ///
    /// Also returns `false` if the SwiftData save fails. The UI must not
    /// show a queued asset that is not on disk. After a relaunch, that
    /// asset would not be in the bin.
    ///
    /// `replacementBytes` is the size of the shrink copy that replaces
    /// this original, or 0 for a plain delete. The entry stores this so
    /// `pendingBytes` can net it out of the space counter.
    ///
    /// `mediaKind` records what the caller is queuing. `FeedView` and
    /// `ShrinkService` pass `.video`, the default. `PhotoPostView` passes
    /// `.photo`. The entry stores this so the bin can report a video
    /// count and a photo count separately, instead of assuming every
    /// entry is a video.
    @discardableResult
    func queue(assetID: String, replacementBytes: Int64 = 0, mediaKind: TrashMediaKind = .video) -> Bool {
        // Do not run PhotoKit reads synchronously on the main actor. If
        // the resolver is still `.unprimed`, refuse the tap and prime
        // the resolver in a background task.
        guard resolver.state != .unprimed else {
            #if DEBUG
            DiagnosticsLog.shared.log("TrashQueue", "refused_unprimed")
            #endif
            Task { [weak self] in await self?.ensureResolverPrimedIfNeeded() }
            return false
        }
        #if DEBUG
        if !resolver.isDestructiveActionSafe || isQueued(assetID) || resolver.isShielded(assetID) {
            DiagnosticsLog.shared.log("TrashQueue", "refused_state_\(resolver.state.rawValue)_auth_\(library.authStatus.rawValue)_queued_\(isQueued(assetID))_shielded_\(resolver.isShielded(assetID))_kind_\(mediaKind.rawValue)")
        }
        #endif
        guard resolver.isDestructiveActionSafe else { return false }
        guard !isQueued(assetID), !resolver.isShielded(assetID) else { return false }
        // The real size read, `library.fileSize(for:)`, does a PHAsset
        // fetch plus a PHAssetResource read, and must not run on this
        // rail tap. Insert with an estimate of zero immediately, so
        // `isQueued`, the rail's queued state, and the bin badge update
        // at once. `load()`'s zero-byte repair below fills in the real
        // size off-main moments later, the same path that repairs a
        // not-yet-downloaded iCloud original's size.
        //
        // Insert with `cloudKey` nil. See `DeckViewModel.markSeen` for
        // the reason. This keeps a synchronous PhotoKit cloud-identifier
        // read off the tap.
        let entry = TrashEntry(assetKey: assetID, bytes: 0, isEstimatedBytes: true, replacementBytes: replacementBytes, mediaKind: mediaKind)
        modelContext.insert(entry)
        // `saveContext()` rolls the context back on failure, which undoes
        // this insert. `load()` afterward re-syncs `entries` with what is
        // actually on disk either way.
        guard saveContext() else {
            load()
            return false
        }
        load()
        resolver.noteQueued(assetKey: assetID, cloudKey: entry.cloudKey)
        onQueued?(assetID)
        // The row already reads as live: `confirmedDeadIDs` starts every
        // fresh entry absent, which is the optimistic default `isLive`
        // needs. This spot check is only consistency maintenance. The UI
        // does not wait for it.
        Task { [weak self] in await self?.refreshLiveness() }
        return true
    }

    /// Removes an asset from the trash queue without touching the photo
    /// library. A no-op if the asset was never queued. Returns `false`,
    /// refusing the restore, while the same id is mid-delete inside
    /// `emptyBin()`. The PhotoKit batch may have already removed the
    /// asset from the library by the time this runs. Restoring a row
    /// whose asset is gone would tell the user the app saved an asset it
    /// did not save.
    ///
    /// The lookup goes through `entriesByLiveKey`, so a restore still
    /// finds the row after its stored key has rotated.
    ///
    /// If the SwiftData save fails, the row stays and the method returns
    /// `false`. `load()` then syncs `entries` with the store, so the UI
    /// still shows the row.
    @discardableResult
    func restore(assetID: String) -> Bool {
        guard !pendingEmptyIDs.contains(assetID) else { return false }
        guard let entry = entriesByLiveKey[assetID] else { return false }
        let (assetKey, cloudKey) = (entry.assetKey, entry.cloudKey)
        modelContext.delete(entry)
        guard saveContext() else {
            load()
            return false
        }
        load()
        // Do not record a usage event here. Each caller records its own
        // event: `TrashView` records `binRestore`, a Keep records
        // `keepPulledFromBin`, and `FeedView` records `unqueuedInFeed`.
        resolver.noteUnqueued(assetKey: assetKey, cloudKey: cloudKey)
        #if DEBUG
        // `gate_all.sh` reads this line to confirm which asset stayed in
        // the library after a restore.
        logger.log("trash_restored_\(assetKey, privacy: .public)")
        #endif
        onRestored?(assetID)
        Task { [weak self] in await self?.refreshLiveness() }
        return true
    }

    /// Deletes every queued asset from the photo library in one PhotoKit
    /// request, which shows exactly one system confirmation for the whole
    /// batch. Returns the ids actually deleted.
    ///
    /// Returns `nil` if the user cancelled the confirmation, PhotoKit
    /// reported an error, or the queue is not currently safe to act on.
    /// The queue is not safe to act on when
    /// `AssetKeyResolver.isDestructiveActionSafe` is false, or access is
    /// not `.authorized`. A `nil` result means PhotoKit deleted no asset,
    /// but rows for liked assets can still be removed from the queue
    /// before that call runs.
    ///
    /// Returns an empty, non-nil result if no queued entry resolved in
    /// the library, or if PhotoKit deleted none of the ids this method
    /// asked about. This counts as nothing to do, not success, so a stale
    /// queue can never report a delete that never happened.
    @discardableResult
    func emptyBin() async -> Set<String>? {
        await ensureResolverPrimedIfNeeded()
        guard library.authStatus == .authorized, resolver.isDestructiveActionSafe else { return nil }

        // Plain copies of what the counts need, taken before the
        // SwiftData delete below. A deleted `@Model` object must not be
        // read afterward.
        struct EmptiedFacts { let assetKey: String; let queuedAt: Date; let bytes: Int64; let replacementBytes: Int64; let isEstimatedBytes: Bool; let mediaKind: String }
        let entriesBeingEmptied = entries.map { EmptiedFacts(assetKey: $0.assetKey, queuedAt: $0.queuedAt, bytes: $0.bytes, replacementBytes: $0.replacementBytes, isEstimatedBytes: $0.isEstimatedBytes, mediaKind: $0.mediaKind) }
        // Do not delete a liked asset. `DeckViewModel.like(assetID:)`
        // removes the matching entry, but a sync conflict can bring it
        // back. This is the last step before an irreversible delete, so
        // check again. Drop the entry, and keep the asset. Check the
        // resolved key too, so a rotated row is still found.
        let shielded = entries.filter { resolver.isShielded($0.assetKey) || resolver.isShielded(resolver.exclusionKey(assetKey: $0.assetKey, cloudKey: $0.cloudKey)) }
        if !shielded.isEmpty {
            // Without this, the row-deleting path would bypass the
            // resolver's incremental maintenance and leave the key in
            // `queuedIDs` for the rest of the session. `isQueued`,
            // `RailState.queued`, and `trashIconName` would keep
            // reporting "Queued" for an asset no longer in the bin.
            for entry in shielded {
                let (assetKey, cloudKey) = (entry.assetKey, entry.cloudKey)
                modelContext.delete(entry)
                resolver.noteUnqueued(assetKey: assetKey, cloudKey: cloudKey)
            }
            _ = saveContext()
            load()
        }

        // Resolve each entry to its current local id. Skip an entry that
        // does not resolve, and keep its row. Try the resolver first. If
        // it fails, use this service's own spot check, so a new photo
        // row is not skipped.
        let liveSnapshot = entries
        let (spotFound, spotResolvedByCloudKey, spotLibraryIsEmpty) = await spotCheckLiveness(for: liveSnapshot)
        if !spotLibraryIsEmpty {
            feedPhotoSnapshot(liveSnapshot, found: spotFound, resolvedByCloudKey: spotResolvedByCloudKey)
            let deadNow = Set(liveSnapshot.compactMap { entry in
                liveIdentifier(for: entry, found: spotFound, resolvedByCloudKey: spotResolvedByCloudKey) == nil ? entry.assetKey : nil
            })
            if deadNow != confirmedDeadIDs { confirmedDeadIDs = deadNow }
        }
        let targets: [(entry: TrashEntry, liveID: String)] = entries.compactMap { entry in
            if let live = resolver.currentLocalIdentifier(assetKey: entry.assetKey, cloudKey: entry.cloudKey) {
                return (entry, live)
            }
            guard !spotLibraryIsEmpty,
                  let live = liveIdentifier(for: entry, found: spotFound, resolvedByCloudKey: spotResolvedByCloudKey)
            else { return nil }
            return (entry, live)
        }
        guard !targets.isEmpty else { return [] }

        let liveIDs = targets.map(\.liveID)
        // `TrashView` calls `restore(assetID:)` with the stored
        // `assetKey`, not the live id. Put both forms in the set so the
        // restore guard matches either one.
        pendingEmptyIDs = Set(liveIDs).union(targets.map { $0.entry.assetKey })
        defer { pendingEmptyIDs = [] }

        guard let deletedLiveIDs = await library.deleteAssets(ids: liveIDs) else {
            // Cancelled or errored. Nothing changed. The queue stays
            // exactly as it was.
            return nil
        }
        guard !deletedLiveIDs.isEmpty else {
            // None of the queued ids still resolve in the library. Leave
            // every row in place as dormant instead of reporting them
            // deleted. A zero-match fetch is not the same thing as a
            // successful empty.
            return []
        }

        let deletedEntries = targets.filter { deletedLiveIDs.contains($0.liveID) }
        // Snapshot each deleted entry's contribution before the delete,
        // using the same `max(bytes - replacementBytes, 0)` expression
        // `load()` uses for `pendingBytes`. Every byte leaves
        // `pendingBytes` once: by a restore, or here, into
        // `reclaimedBytes` after a successful empty. This keeps the bin
        // sheet and the space chip in agreement.
        let reclaimedDelta = deletedEntries.reduce(Int64(0)) {
            $0 + max($1.entry.bytes - $1.entry.replacementBytes, 0)
        }
        for (entry, _) in deletedEntries {
            modelContext.delete(entry)
        }
        // The PhotoKit delete is complete. If the cleanup save fails,
        // `reconcileWithLibrary()` removes the rows on a later pass. Do
        // not report failure here.
        _ = saveContext()
        reclaimedBytes += reclaimedDelta
        UserDefaults.standard.set(Int(reclaimedBytes), forKey: Self.reclaimedAllTimeKey)
        #if DEBUG
        // `RowCountProbe` reads only the store, and `reclaimedBytes` has
        // no SwiftData row. Publish the new value to the probe here and
        // in init.
        RowCountProbe.lastReclaimed = reclaimedBytes
        #endif
        load()
        let deletedAssetKeys = Set(deletedEntries.map { $0.entry.assetKey })
        #if DEBUG
        // `gate_all.sh` reads this line: the exact set this batch
        // deleted. It can check the result against Photos.sqlite
        // directly, instead of only trusting the row count. One line per
        // empty, matching the reader's `tail -1` expectation.
        logger.log("emptybin_deleted_\(deletedAssetKeys.sorted().joined(separator: ","), privacy: .public)")
        #endif
        resolver.noteEmptied(deletedLiveIDs)
        onEmptied?(Array(deletedAssetKeys))
        // Record a usage event with the freed bytes and the age of the
        // oldest deleted entry.
        let freed = entriesBeingEmptied.filter { deletedAssetKeys.contains($0.assetKey) }
        // A shrunk original's saving, original minus replacement, was
        // already counted by the shrink as `bytesFreed.byShrink` when it
        // finished, so only plain deletes count here. Counting the
        // difference again would double `bytesFreed.total`.
        //
        // An entry queued a moment ago may still carry the placeholder
        // `bytes: 0` until the off-main size repair lands. The `known`
        // filter below excludes such an entry, instead of counting it as
        // zero.
        let known = freed.filter { $0.replacementBytes == 0 && !($0.isEstimatedBytes && $0.bytes == 0) }
        let bytes = known.reduce(Int64(0)) { $0 + $1.bytes }
        let oldest = freed.map(\.queuedAt).min().map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 } ?? 0
        Usage.shared.binEmpty(bytes: bytes, oldestDays: oldest)
        // Report the average size of each deleted video or photo. The
        // size is not known at the delete tap, because `queue(assetID:)`
        // stores 0 until the off-main repair runs.
        for raw in Set(freed.map(\.mediaKind)) {   // every kind present, so the per-kind sums add up to `bytes`
            let all = freed.filter { $0.mediaKind == raw }
            let sized = known.filter { $0.mediaKind == raw }
            Usage.shared.binEmptied(mode: raw == TrashMediaKind.photo.rawValue ? .photos : .videos, items: all.count, sizedItems: sized.count, bytes: sized.reduce(Int64(0)) { $0 + $1.bytes })
        }
        return deletedAssetKeys
    }

    // MARK: - Bin liveness

    /// Runs one PhotoKit existence check for the stored keys in
    /// `snapshot` and the local ids of their cloud keys. The cost depends
    /// on the bin size, not the library size. `reconcileWithLibrary()`,
    /// `emptyBin()`, and `refreshLiveness()` share this method, so the
    /// three never disagree about which entries currently resolve. If
    /// `libraryIsEmpty` is true, the caller must not mark any row as
    /// deleted. See `PhotoLibraryService.existingIdentifiers`.
    private func spotCheckLiveness(for snapshot: [TrashEntry]) async -> (found: Set<String>, resolvedByCloudKey: [String: String], libraryIsEmpty: Bool) {
        let cloudKeys = Array(Set(snapshot.compactMap(\.cloudKey)))
        let resolvedByCloudKey: [String: String]
        if cloudKeys.isEmpty {
            resolvedByCloudKey = [:]
        } else {
            resolvedByCloudKey = await Task.detached(priority: .utility) {
                PhotoLibraryService.localIdentifierMappings(forCloudIdentifiers: cloudKeys)
            }.value
        }
        let candidateIDs = Array(Set(snapshot.map(\.assetKey)).union(resolvedByCloudKey.values))
        let existence = await Task.detached(priority: .utility) {
            PhotoLibraryService.existingIdentifiers(among: candidateIDs)
        }.value
        return (existence.found, resolvedByCloudKey, existence.libraryIsEmpty)
    }

    /// Returns `entry`'s current live local id from `found` and
    /// `resolvedByCloudKey`, the outputs of `spotCheckLiveness`. Returns
    /// `nil` if neither its stored key, nor the local id its cloud key
    /// resolves to, names a live asset.
    private func liveIdentifier(for entry: TrashEntry, found: Set<String>, resolvedByCloudKey: [String: String]) -> String? {
        if found.contains(entry.assetKey) { return entry.assetKey }
        if let cloudKey = entry.cloudKey, let resolved = resolvedByCloudKey[cloudKey], found.contains(resolved) {
            return resolved
        }
        return nil
    }

    /// Feeds every photo row this spot check confirmed live into
    /// `AssetKeyResolver.photoLibraryIDs` too, unioned with whatever
    /// `PhotoDeck.scheduleBinPhotoIDRefresh` has already confirmed. See
    /// `AssetKeyResolver.refreshPhotoLibrarySnapshot` for why this only
    /// grows that set. Add only photo rows. `AssetKeyResolver.libraryIDs`
    /// already covers videos.
    private func feedPhotoSnapshot(_ snapshot: [TrashEntry], found: Set<String>, resolvedByCloudKey: [String: String]) {
        let livePhotoIDs = Set(snapshot.compactMap { entry -> String? in
            guard entry.mediaKind == TrashMediaKind.photo.rawValue else { return nil }
            return liveIdentifier(for: entry, found: found, resolvedByCloudKey: resolvedByCloudKey)
        })
        guard !livePhotoIDs.isEmpty else { return }
        resolver.refreshPhotoLibrarySnapshot(livePhotoIDs)
    }

    /// Recomputes `confirmedDeadIDs` with one spot check. `queue(assetID:)`
    /// and `restore(assetID:)` call it, and `TrashView` calls it when the
    /// bin sheet opens. `reconcileWithLibrary()` and `emptyBin()` use
    /// their own spot check, so they do not call it.
    func refreshLiveness() async {
        guard !entries.isEmpty else {
            if !confirmedDeadIDs.isEmpty { confirmedDeadIDs = [] }
            return
        }
        let snapshot = entries
        let (found, resolvedByCloudKey, libraryIsEmpty) = await spotCheckLiveness(for: snapshot)
        guard !libraryIsEmpty else { return }
        feedPhotoSnapshot(snapshot, found: found, resolvedByCloudKey: resolvedByCloudKey)
        let dead = Set(snapshot.compactMap { entry in
            liveIdentifier(for: entry, found: found, resolvedByCloudKey: resolvedByCloudKey) == nil ? entry.assetKey : nil
        })
        #if DEBUG
        // A restore from backup changes local identifiers, so every bin
        // row can show as not available. The stored `cloudKey` lets the
        // spot check find the new id. This log shows which step fails:
        // no cloud keys stored, or no cloud-to-local mappings returned.
        if DiagnosticsGate.isOn("-cloudfull-log-bin") {
            let withCloudKey = snapshot.filter { $0.cloudKey != nil }.count
            let byStoredKey = snapshot.filter { found.contains($0.assetKey) }.count
            DiagnosticsLog.shared.log(
                "BinLiveness",
                "bin_rows_\(snapshot.count)_cloudkeys_\(withCloudKey)_mapped_\(resolvedByCloudKey.count)"
                + "_livebystored_\(byStoredKey)_dead_\(dead.count)"
            )
        }
        #endif
        guard dead != confirmedDeadIDs else { return }
        confirmedDeadIDs = dead
    }

    // MARK: - Reconciliation

    /// Coalesces bursts of PhotoKit change notifications, matching
    /// `DeckViewModel.scheduleLibraryChangeHandling`, so a mid-sync burst
    /// triggers one reconciliation instead of one per notification.
    private func scheduleReconciliation() {
        // iCloud syncing fires PhotoKit change notices continuously.
        // Coalesce them: at most one reconciliation pass runs every 5
        // seconds, one at a time. A notice that lands mid-pass only asks
        // for one more pass afterward.
        if isReconciling { reconcileAgain = true; return }
        libraryChangeTask?.cancel()
        libraryChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            let sinceLast = Date().timeIntervalSince(self.lastReconcileAt)
            if sinceLast < 5 {
                try? await Task.sleep(nanoseconds: UInt64((5 - sinceLast) * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            await self.runReconcilePass()
        }
    }

    private var isReconciling = false
    private var reconcileAgain = false
    private var lastReconcileAt = Date.distantPast

    private func runReconcilePass() async {
        guard !isReconciling else { reconcileAgain = true; return }
        isReconciling = true
        await reconcileWithLibrary()
        lastReconcileAt = Date()
        isReconciling = false
        if reconcileAgain {
            reconcileAgain = false
            scheduleReconciliation()
        }
    }

    /// Removes `TrashEntry` rows whose asset is no longer in the
    /// library. This happens after a delete in the Photos app, or after
    /// a prior `emptyBin()` whose entry-cleanup save never committed.
    /// Without this, such rows would stay in the bin badge and the space
    /// chip for assets that no longer exist to delete.
    ///
    /// This method acts only under `.authorized` access, never
    /// `.limited`. Under Limited access, PhotoKit returns only the
    /// selected assets, so every other queued row would look deleted.
    /// It also acts only while `AssetKeyResolver.isDestructiveActionSafe`.
    /// It applies a two-strike rule through `TrashEntry.dormantSince`. The
    /// second consecutive pass that still cannot resolve a row deletes
    /// it, at least 60 seconds later. This stops a
    /// transient PhotoKit miss or an iCloud sync tick from destroying a
    /// pending delete.
    private func reconcileWithLibrary() async {
        guard library.authStatus == .authorized else { return }
        // With the default tab on Photos, the video deck, which primes
        // the resolver on its own, never starts. Prime first,
        // unconditionally, so this runs before the empty-bin early
        // return below. Every Delete button in the app stays disabled
        // until this runs.
        await ensureResolverPrimedIfNeeded()
        guard !entries.isEmpty else { return }
        guard resolver.isDestructiveActionSafe else { return }

        // Record the keys before the await. The loop below skips a row
        // queued during the await, because the spot check ran before
        // that row existed.
        let preAwaitKeys = Set(entries.map(\.assetKey))

        // The spot check resolves every entry's cloud key in one
        // off-main batch. It does not depend on `AssetKeyResolver`'s
        // cache. It checks every media type, because photos and videos
        // share this bin. If `libraryIsEmpty` is true, the pass stops
        // here, so this method marks no row as gone. See
        // `spotCheckLiveness` for the rest.
        let (idsSet, resolvedByCloudKey, libraryIsEmpty) = await spotCheckLiveness(for: entries)
        guard !libraryIsEmpty else { return }
        feedPhotoSnapshot(entries, found: idsSet, resolvedByCloudKey: resolvedByCloudKey)

        let now = Date()
        var toDelete: [TrashEntry] = []
        var didChange = false
        var deadNow: Set<String> = []
        for entry in entries {
            guard preAwaitKeys.contains(entry.assetKey) else { continue } // queued mid-await, skipped
            let resolves = liveIdentifier(for: entry, found: idsSet, resolvedByCloudKey: resolvedByCloudKey) != nil
            if !resolves { deadNow.insert(entry.assetKey) }

            if resolves {
                if entry.dormantSince != nil {
                    entry.dormantSince = nil
                    didChange = true
                }
                continue
            }
            guard let dormantSince = entry.dormantSince else {
                entry.dormantSince = now
                didChange = true
                continue
            }
            if now.timeIntervalSince(dormantSince) >= 60 {
                toDelete.append(entry)
            }
        }

        // Independent of the two-strike delete decision below, which can
        // validly do nothing on a given pass. The display-liveness
        // signal updates on every pass this method runs, so it never
        // lags 60 seconds or more behind the deletion timer.
        if deadNow != confirmedDeadIDs { confirmedDeadIDs = deadNow }

        guard !toDelete.isEmpty || didChange else { return }
        // Tell the resolver about each deleted row. Otherwise the key
        // of a deleted asset stays in `queuedIDs`. `emptyBin()` does the
        // same for liked assets.
        for entry in toDelete {
            resolver.noteUnqueued(assetKey: entry.assetKey, cloudKey: entry.cloudKey)
            modelContext.delete(entry)
        }
        _ = saveContext()
        load()
    }

    /// Primes `AssetKeyResolver` defensively if nothing has yet.
    /// Normally `DeckViewModel.start()` primes it before this service's
    /// own `start()` runs, since `FeedView.task` calls both, in that
    /// order. This method removes that implicit ordering dependency.
    ///
    /// Without priming, a destructive path stays disabled. `queue()`
    /// cannot suspend, so it refuses the tap and starts this method in a
    /// `Task`. See that guard's own comment. `reconcileWithLibrary()`
    /// awaits this directly.
    ///
    /// Do not add a synchronous form. Priming reads the full library,
    /// and that must not run on the main actor.
    private func ensureResolverPrimedIfNeeded() async {
        guard resolver.state == .unprimed else { return }
        let ids = Set(await Task.detached(priority: .utility) { PhotoLibraryService.allVideoIDsOffMain() }.value)
        guard resolver.state == .unprimed else { return }   // primed by someone else during the await
        let candidates = resolver.primeSynchronously(libraryIDs: ids, authStatus: library.authStatus, modelContext: modelContext)
        guard !candidates.isEmpty else { return }
        Task { [weak resolver] in
            await resolver?.resolveCandidates(candidates)
        }
    }

    /// Reloads `entries` from SwiftData, newest first, and recomputes
    /// `pendingBytes` from that fresh snapshot. `applyZeroByteRepair()`
    /// also updates `pendingBytes`, after it writes a real size into a
    /// zero-byte entry. This method also rebuilds `entriesByLiveKey`.
    ///
    /// It starts an off-main repair for any entry still recorded as 0
    /// bytes. This covers a fresh insert from `queue()`, and an iCloud
    /// original that had not downloaded when `queue(assetID:)` added it. The
    /// SwiftData fetch stays on this context's actor, which is main for
    /// this app. Only the PhotoKit size read moves off it, in
    /// `scheduleZeroByteRepair` below.
    private func load() {
        let descriptor = FetchDescriptor<TrashEntry>(sortBy: [SortDescriptor(\.queuedAt, order: .reverse)])
        #if DEBUG
        FetchCounters.swiftData += 1
        #endif
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        entries = fetched
        pendingBytes = fetched.reduce(Int64(0)) { $0 + max($1.bytes - $1.replacementBytes, 0) }

        var byLiveKey: [String: TrashEntry] = [:]
        byLiveKey.reserveCapacity(fetched.count * 2)
        for entry in fetched {
            byLiveKey[entry.assetKey] = entry
            let resolved = resolver.exclusionKey(assetKey: entry.assetKey, cloudKey: entry.cloudKey)
            byLiveKey[resolved] = entry
        }
        entriesByLiveKey = byLiveKey

        scheduleZeroByteRepair(candidateIDs: fetched.filter { $0.bytes == 0 }.map(\.assetKey))
    }

    /// Ids a `scheduleZeroByteRepair` pass has already dispatched a
    /// PhotoKit read for. A burst of `load()` calls, from queue, restore,
    /// empty, and `onResolutionLanded`, can happen close together. This
    /// set stops a second, redundant `Task.detached` for the same row
    /// while one is still in flight.
    private var zeroByteRepairInFlight: Set<String> = []

    /// The off-main half of `load()`'s zero-byte repair, matching
    /// `spotCheckLiveness`'s own reasoning. `library.fileSize(for:)`
    /// does a `PHAsset` fetch plus a `PHAssetResource` read, which must
    /// never run on the main actor.
    ///
    /// `PhotoLibraryService.fetchAsset` and `assetSize` are the
    /// `nonisolated static` halves `fileSize(for:)` is built from. This
    /// reproduces that method's exact result off-main, without a
    /// `@MainActor` hop into `library`.
    private func scheduleZeroByteRepair(candidateIDs: [String]) {
        let ids = candidateIDs.filter { !zeroByteRepairInFlight.contains($0) }
        guard !ids.isEmpty else { return }
        zeroByteRepairInFlight.formUnion(ids)
        Task { [weak self] in
            let sizes = await Task.detached(priority: .utility) { () -> [String: PhotoLibraryService.AssetSize] in
                var result: [String: PhotoLibraryService.AssetSize] = [:]
                result.reserveCapacity(ids.count)
                for id in ids {
                    if let asset = PhotoLibraryService.fetchAsset(id) {
                        result[id] = PhotoLibraryService.assetSize(for: asset)
                    } else {
                        result[id] = PhotoLibraryService.AssetSize(bytes: 0, isEstimated: false)
                    }
                }
                return result
            }.value
            self?.applyZeroByteRepair(sizes, ids: ids)
        }
    }

    /// Runs on the main actor. Writes the sizes into the current
    /// `entries` and saves once for the batch, not once per id. Entries
    /// are reference types, so the write reaches the current objects
    /// even if `load()` ran again while the read was off-main. A row
    /// restored away during the read is not in `entries`, so the loop
    /// skips it.
    private func applyZeroByteRepair(_ sizes: [String: PhotoLibraryService.AssetSize], ids: [String]) {
        zeroByteRepairInFlight.subtract(ids)
        var didUpdate = false
        for entry in entries where entry.bytes == 0 {
            guard let size = sizes[entry.assetKey], size.bytes > 0 else { continue }
            entry.bytes = size.bytes
            entry.isEstimatedBytes = size.isEstimated
            didUpdate = true
        }
        guard didUpdate else { return }
        _ = saveContext()
        // The loop changes properties on objects in `entries`, not the
        // array, so `@Published` does not fire. Reassign the array to
        // publish the change. Then recompute `pendingBytes`.
        entries = entries
        pendingBytes = entries.reduce(Int64(0)) { $0 + max($1.bytes - $1.replacementBytes, 0) }
    }

    /// Returns `true` if the save succeeds. On failure, logs the error,
    /// rolls back the context, and returns `false`. The rollback keeps
    /// the in-memory models equal to the store.
    @discardableResult
    private func saveContext() -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            logger.error("TrashService modelContext.save() failed: \(error.localizedDescription, privacy: .public)")
            modelContext.rollback()
            return false
        }
    }
}
