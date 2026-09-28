//
//  AssetKeyResolver.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftData
import Photos

/// AssetKeyResolver decides whether a stored key shields or queues a live
/// asset. Every consumer reads this one instance.
///
/// A local identifier can rotate when the device restores or migrates data.
/// A direct comparison of a stored key to a live asset id can miss a
/// rotated asset. The row's cloud key still names the asset correctly.
/// Every consumer reads this resolver instead of comparing keys directly.
///
/// `AssetKeyResolver.shared` is a process-lifetime singleton, like
/// `PhotoLibraryService.shared`. One shared instance lets every consumer
/// read the same resolution state without an instance passed through each
/// initializer.
@MainActor
final class AssetKeyResolver: ObservableObject {

    enum ResolutionState: String {
        /// `primeSynchronously` has not run for this session.
        case unprimed
        /// Every stored row's raw key names a live asset, or no row needed
        /// resolution.
        case clean
        /// PhotoKit resolved the rotation candidates for this session.
        case resolved
        /// Rotation candidates exist. Resolution is not complete yet.
        case pending
        /// The authorization status is `.limited`. The visible library is a
        /// subset, so no resolution attempt is reliable.
        case partial
    }

    /// A stored row whose raw key does not name a live asset yet. Its cloud
    /// key is worth resolving in the background.
    struct RotationCandidate {
        let assetKey: String
        let cloudKey: String
    }

    static let shared = AssetKeyResolver()

    @Published private(set) var state: ResolutionState = .unprimed {
        didSet {
            #if DEBUG
            if state != oldValue {
                DiagnosticsLog.shared.log("Resolver", "state_\(oldValue.rawValue)_to_\(state.rawValue)")
            }
            #endif
        }
    }
    /// Increases by one on every change to `shieldedIDs`, `queuedIDs`, or
    /// the live library snapshot. Views include it in an identity key to
    /// redraw after a change.
    @Published private(set) var generation: Int = 0
    /// Equal to `libraryIDs.count` minus the excluded live id count, never
    /// below zero. `DeckViewModel.totalPoolCount` reads this value in O(1).
    @Published private(set) var pooledCount: Int = 0

    private(set) var libraryIDs: Set<String> = []
    /// The photo library's own live local identifiers, kept separate from
    /// `libraryIDs`. Every pool-count path — `recompute()`, `pooledCount`,
    /// `filteredPooledCount` — reads `libraryIDs` as the video library only.
    /// See `DeckViewModel.totalPoolCount`.
    ///
    /// `PhotoDeck.scheduleBinPhotoIDRefresh` and `TrashService` feed this
    /// set through `refreshPhotoLibrarySnapshot`. It holds only the kept
    /// or queued ids that a `fetchAssets(withLocalIdentifiers:)` spot
    /// check confirmed are live. It does not hold the whole photo
    /// library, so the set stays O(kept + queued).
    ///
    /// `exclusionKey` and `currentLocalIdentifier` read this set. It lets a
    /// shared-bin consumer, such as `TrashService.emptyBin`, confirm a
    /// photo row's asset exists, not only a video row's.
    private(set) var photoLibraryIDs: Set<String> = []
    private var cloudToLocal: [String: String] = [:]
    /// Every local identifier that currently names a shielded asset, plus
    /// every `LikedEntry`'s raw stored key. The set is over-inclusive by
    /// design. A stale key names nothing, because local identifiers are
    /// UUID-based and never reused. An extra member can never shield the
    /// wrong asset. A missing member exposes a kept video to Delete.
    private(set) var shieldedIDs: Set<String> = []
    private(set) var queuedIDs: Set<String> = []
    private var excludedLive: Set<String> = []

    /// Ids the active filters exclude. This set is separate from
    /// `shieldedIDs` and `queuedIDs`: a filtered-out video is not shielded
    /// and not queued. `pool_total_` must keep reporting the unfiltered
    /// count. Clearing a filter must restore the id without changing any
    /// stored row.
    private(set) var filterExcludedIDs: Set<String> = []

    /// Equal to `libraryIDs.count` minus the live ids the exclusion set
    /// and the filters remove, never below zero.
    /// `DeckViewModel.filteredPoolCount` reads this value and renders it
    /// as `pool_filtered_<n>`.
    @Published private(set) var filteredPooledCount: Int = 0

    /// Every handler registered through `onResolutionLanded(_:)`. Each
    /// handler runs in order once a late cloud-key resolution finishes,
    /// with the ids that newly became excluded.
    ///
    /// The list holds more than one handler, matching
    /// `PhotoLibraryService.libraryChangeHandlers`. `DeckViewModel` needs
    /// the callback to remove a rotated shielded or queued video already
    /// dealt into the deck before resolution finished. `TrashService`
    /// independently needs the callback to rebuild its own live-key
    /// lookup. A single assignable closure would let the second
    /// registration replace the first.
    private var resolutionLandedHandlers: [([String]) -> Void] = []

    /// Registers a handler to run once the background cloud-key resolution
    /// from priming finishes, when `state` moves from `.pending` to
    /// `.resolved`. No caller ever removes the handler, because every
    /// caller is a process-lifetime consumer reachable through `.shared`,
    /// like this resolver itself.
    func onResolutionLanded(_ handler: @escaping ([String]) -> Void) {
        resolutionLandedHandlers.append(handler)
    }

    private var modelContext: ModelContext?

    /// The time limit, in nanoseconds (1.5 s), for the background
    /// cloud-key round trip. `resolveCandidates(_:)` does not apply this
    /// limit. No code uses this constant yet.
    private static let candidateResolutionTimeout: UInt64 = 1_500_000_000

    private init() {}

    /// False while `state` is `.pending`, `.partial`, or `.unprimed`. Every
    /// destructive path checks this value, including `TrashService.queue`,
    /// `emptyBin`, `reconcileWithLibrary`, and `ShrinkService`'s liked
    /// re-checks.
    var isDestructiveActionSafe: Bool { state == .clean || state == .resolved }

    func isShielded(_ id: String) -> Bool { shieldedIDs.contains(id) }
    func isQueued(_ id: String) -> Bool { queuedIDs.contains(id) }
    func isExcluded(_ id: String) -> Bool { excludedLive.contains(id) }

    // MARK: - Filters

    func isFilterExcluded(_ id: String) -> Bool { filterExcludedIDs.contains(id) }

    /// The single membership question every pool-building path asks.
    func isEligible(_ id: String) -> Bool {
        guard !isQueued(id), !isFilterExcluded(id) else { return false }
        return !isShielded(id)
    }

    /// Replaces the whole filter-exclusion set. `DeckViewModel` calls this
    /// after every library-index refresh and every options change, never
    /// incrementally, because an options change can flip any id in either
    /// direction.
    func setFilterExclusions(_ ids: Set<String>) {
        guard ids != filterExcludedIDs else { return }
        filterExcludedIDs = ids
        recompute()
    }

    /// The local identifier this stored row currently names. This value is
    /// never nil, because pool filtering uses it as the exclusion key,
    /// where an unresolvable row must still read as excluded. This method
    /// also checks `photoLibraryIDs`; see that property's comment.
    func exclusionKey(assetKey: String, cloudKey: String?) -> String {
        if libraryIDs.contains(assetKey) || photoLibraryIDs.contains(assetKey) { return assetKey }
        if let cloudKey, let resolved = cloudToLocal[cloudKey] { return resolved }
        return assetKey
    }

    /// The live local identifier, or `nil` when neither key names a live
    /// asset right now. Every destructive path uses this method, never
    /// `exclusionKey`, so a row with no live asset can never become a
    /// delete target.
    ///
    /// This method also checks `photoLibraryIDs`; see that property's
    /// comment. `TrashService.emptyBin()` uses this method to resolve a
    /// shared-bin row's delete target, and a photo row must resolve here
    /// exactly like a video row.
    func currentLocalIdentifier(assetKey: String, cloudKey: String?) -> String? {
        if libraryIDs.contains(assetKey) || photoLibraryIDs.contains(assetKey) { return assetKey }
        if let cloudKey, let resolved = cloudToLocal[cloudKey],
           libraryIDs.contains(resolved) || photoLibraryIDs.contains(resolved) {
            return resolved
        }
        return nil
    }

    /// The reverse lookup of `cloudToLocal`. `DeckViewModel.like(assetID:)`
    /// uses it to write a known `cloudKey` into a new `LikedEntry`, with
    /// no PhotoKit round trip on the tap. `cloudToLocal` holds only
    /// rotation candidates, so this is a short scan, not a reverse index
    /// over the whole library.
    func knownCloudKey(forLiveID id: String) -> String? {
        cloudToLocal.first { $0.value == id }?.key
    }

    // MARK: - Priming

    /// The synchronous half of priming. It seeds `libraryIDs`,
    /// `shieldedIDs`, and `queuedIDs` from raw stored keys only: two
    /// SwiftData fetches, no PhotoKit call, and no `await`. A caller can
    /// deal a deck right after this call. Shield and queue membership is
    /// then correct for every row that needs no rotation resolution. That
    /// is the common case on every launch.
    ///
    /// Returns the candidates that still need a PhotoKit round trip. The
    /// caller resolves them with `resolveCandidates(_:)`.
    /// `DeckViewModel.start()` deals first and resolves in the background.
    /// Its `onResolutionLanded` handler then removes newly excluded
    /// videos. Returns an empty array when `state` is `.clean` or
    /// `.partial`, because nothing is left to resolve.
    @discardableResult
    func primeSynchronously(
        libraryIDs ids: Set<String>,
        authStatus: PHAuthorizationStatus,
        modelContext: ModelContext
    ) -> [RotationCandidate] {
        self.modelContext = modelContext
        self.libraryIDs = ids
        // `resolvingWithCache` mirrors `refreshLibrarySnapshot`. Once the
        // resolver already knows a rotation candidate's cloud key, a
        // re-prime, such as `reconcileAfterRemount`, must not drop back to
        // raw-key-only membership. That drop would cause a spurious
        // pool-count change.
        rebuildFromStore(resolvingWithCache: !cloudToLocal.isEmpty)

        // The `.limited` check must run before the empty-candidates
        // short-circuit. `collectRotationCandidates()` finds a candidate
        // only when its `cloudKey` is non-nil. On a fresh install, or
        // before the cloud-key backfill sets `cloudKey`, every row's
        // `cloudKey` is nil, so `candidates` also reads empty under
        // Limited access. This order keeps `state` out of `.clean` under
        // Limited access when no row needs rotation resolution. That is
        // the common case.
        guard authStatus != .limited else {
            // No resolution runs, and the resolver judges no row.
            // `isDestructiveActionSafe` is false, because the visible
            // library is a subset. A row's absent key proves nothing here.
            state = .partial
            recompute()
            return []
        }

        let candidates = collectRotationCandidates()
        guard !candidates.isEmpty else {
            state = .clean
            recompute()
            return []
        }

        state = .pending
        recompute()
        return candidates
    }

    /// Sets `state` to `.partial` as soon as a live session observes a
    /// downgrade to `.limited`. If this method does not run, a resolver in
    /// `.clean` or `.resolved` keeps `isDestructiveActionSafe == true`
    /// after access changes to Limited. It stays unsafe-but-true until the
    /// next prime.
    ///
    /// This method does nothing before the first prime, because
    /// `.unprimed` is already unsafe. It also does nothing when `state` is
    /// already `.partial`.
    func handleAuthDowngradeToLimited() {
        guard state != .unprimed, state != .partial else { return }
        state = .partial
        recompute()
    }

    /// The asynchronous half of priming. It resolves the candidates'
    /// cloud keys in one batch PhotoKit round trip, off the main actor,
    /// merges the result, and sets `state` to `.resolved`.
    ///
    /// It reports the ids that newly became excluded through
    /// `onResolutionLanded`, so a caller that already dealt from the
    /// `.pending` snapshot can remove them. This method does nothing if
    /// `state` moved on from `.pending` before it returns, because a
    /// fresher prime superseded it.
    func resolveCandidates(_ candidates: [RotationCandidate]) async {
        guard !candidates.isEmpty else { return }
        let keys = Array(Set(candidates.map(\.cloudKey)))
        let mapping = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.localIdentifierMappings(forCloudIdentifiers: keys)
        }.value

        guard state == .pending else { return }
        let before = excludedLive
        cloudToLocal.merge(mapping) { _, new in new }
        rebuildFromStore(resolvingWithCache: true)
        state = .resolved
        recompute()

        let newlyExcluded = Array(excludedLive.subtracting(before))
        for handler in resolutionLandedHandlers { handler(newlyExcluded) }
    }

    // MARK: - Incremental maintenance

    func noteLiked(assetKey: String, cloudKey: String?) {
        shieldedIDs.insert(assetKey)
        shieldedIDs.insert(exclusionKey(assetKey: assetKey, cloudKey: cloudKey))
        recompute()
    }

    func noteUnliked(assetKey: String, cloudKey: String?) {
        shieldedIDs.remove(assetKey)
        shieldedIDs.remove(exclusionKey(assetKey: assetKey, cloudKey: cloudKey))
        recompute()
    }

    func noteQueued(assetKey: String, cloudKey: String?) {
        queuedIDs.insert(assetKey)
        queuedIDs.insert(exclusionKey(assetKey: assetKey, cloudKey: cloudKey))
        recompute()
    }

    func noteUnqueued(assetKey: String, cloudKey: String?) {
        queuedIDs.remove(assetKey)
        queuedIDs.remove(exclusionKey(assetKey: assetKey, cloudKey: cloudKey))
        recompute()
    }

    func noteEmptied(_ deletedIDs: Set<String>) {
        queuedIDs.subtract(deletedIDs)
        libraryIDs.subtract(deletedIDs)
        recompute()
    }

    /// Re-seeds `libraryIDs` after a full re-enumeration, such as
    /// `extendDeckAfterExhaustion` or `handleLibraryChange`. It re-derives
    /// shield and queue membership against the existing `cloudToLocal`
    /// cache, with no new PhotoKit traffic.
    ///
    /// A mid-session library change cannot cause a new rotation. Rotation
    /// happens only to rows written before this process started, so this
    /// method does not collect candidates again.
    func refreshLibrarySnapshot(_ ids: Set<String>) {
        libraryIDs = ids
        rebuildFromStore(resolvingWithCache: !cloudToLocal.isEmpty)
        recompute()
    }

    /// The photo-side twin of `refreshLibrarySnapshot`.
    /// `PhotoDeck.scheduleBinPhotoIDRefresh` and `TrashService` both call
    /// it; see `TrashService.confirmedDeadIDs`'s comment.
    ///
    /// This method does not touch `shieldedIDs`, `queuedIDs`, or
    /// `recompute()`. `PhotoDeck` judges its own pool membership directly
    /// against `isShielded` and `isQueued`, never against `isEligible` or
    /// the pool counts, which stay video-only by design; see `PhotoDeck`'s
    /// comment. This method only gives `exclusionKey` and
    /// `currentLocalIdentifier` a photo existence check. `TrashService`
    /// needs it, because its bin holds photos and videos. `DeckViewModel`
    /// and `PhotoDeck` use it through their `exclusionKey` lookups.
    ///
    /// This method unions `ids` into `photoLibraryIDs` instead of
    /// replacing it. `PhotoDeck`'s spot check asks only about the deck's
    /// excluded ids, on its own schedule, and only after Photos mode has
    /// started. `TrashService` checks the bin's own ids on queue, restore,
    /// empty, bin-sheet open, and reconcile. Its check often runs first.
    /// For example, a user queues a photo from Videos mode after a
    /// relaunch, before `PhotoDeck` runs. A wholesale replace from either
    /// side would discard what the other side already confirmed live.
    ///
    /// The set only grows, and that is safe. A PhotoKit fetch confirmed
    /// every id live at call time. A member goes stale only if the user
    /// later deletes the asset. The resolver already tolerates stale ids.
    func refreshPhotoLibrarySnapshot(_ ids: Set<String>) {
        photoLibraryIDs.formUnion(ids)
    }

    // MARK: - Private

    private func collectRotationCandidates() -> [RotationCandidate] {
        guard let modelContext else { return [] }
        #if DEBUG
        FetchCounters.swiftData += 2
        #endif
        let liked = (try? modelContext.fetch(FetchDescriptor<LikedEntry>())) ?? []
        let trashed = (try? modelContext.fetch(FetchDescriptor<TrashEntry>())) ?? []
        var out: [RotationCandidate] = []
        for entry in liked where !libraryIDs.contains(entry.assetKey) {
            if let cloudKey = entry.cloudKey { out.append(RotationCandidate(assetKey: entry.assetKey, cloudKey: cloudKey)) }
        }
        for entry in trashed where !libraryIDs.contains(entry.assetKey) {
            if let cloudKey = entry.cloudKey { out.append(RotationCandidate(assetKey: entry.assetKey, cloudKey: cloudKey)) }
        }
        return out
    }

    private func rebuildFromStore(resolvingWithCache: Bool) {
        guard let modelContext else { return }
        #if DEBUG
        FetchCounters.swiftData += 2
        #endif
        let liked = (try? modelContext.fetch(FetchDescriptor<LikedEntry>())) ?? []
        let trashed = (try? modelContext.fetch(FetchDescriptor<TrashEntry>())) ?? []

        var shielded = Set<String>()
        for entry in liked {
            shielded.insert(entry.assetKey)
            if resolvingWithCache, let cloudKey = entry.cloudKey, let live = cloudToLocal[cloudKey] {
                shielded.insert(live)
            }
        }
        var queued = Set<String>()
        for entry in trashed {
            queued.insert(entry.assetKey)
            if resolvingWithCache, let cloudKey = entry.cloudKey, let live = cloudToLocal[cloudKey] {
                queued.insert(live)
            }
        }
        shieldedIDs = shielded
        queuedIDs = queued
    }

    private func recompute() {
        excludedLive = shieldedIDs.union(queuedIDs).intersection(libraryIDs)
        pooledCount = max(libraryIDs.count - excludedLive.count, 0)
        // Filters apply on top of the unfiltered count. `pool_total_`
        // reports the unfiltered number.
        let filteredLive = filterExcludedIDs.intersection(libraryIDs)
        filteredPooledCount = max(libraryIDs.count - excludedLive.union(filteredLive).count, 0)
        generation += 1
    }
}
