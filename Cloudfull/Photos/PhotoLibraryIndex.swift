//
//  PhotoLibraryIndex.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Photos
import Foundation

/// One dealt photo. It holds everything the deck needs to make an entry,
/// plus the two pixel dimensions `PhotoImagePipeline` uses to size a post's
/// placeholder before tier-1 metadata loads. It reads from a `PHAsset` the
/// deal already materialised, so it costs nothing beyond the
/// materialisation itself.
struct PhotoWindowItem: Sendable, Equatable {
    let id: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// Milliseconds since epoch, or -1 when the asset has no creation
    /// date. This is the same convention `VideoFacts.createdMs` uses in
    /// `Cloudfull/Library/PhotoLibraryService.swift`. The
    /// `photo_facts_<createdMs>` UI-test probe reports this value. A
    /// date-sort test uses it to check the deal order; the id alone
    /// cannot show that order.
    let createdMs: Int64

    /// The one place a dealt `PHAsset` becomes a `PhotoWindowItem`. Both
    /// `sample` and `page` call this initializer instead of building the
    /// struct manually, so a field cannot appear on one path only.
    init(from asset: PHAsset) {
        self.id = asset.localIdentifier
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.createdMs = asset.creationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? -1
    }
}

/// The result of one window deal. See `PhotoLibraryPool.sample`.
struct PhotoWindowDeal: Sendable {
    /// The dealt photos, already filtered against everything the caller
    /// asked to reject. The array may be shorter than `need` near the end
    /// of a cycle.
    let items: [PhotoWindowItem]
    /// True only when a full sweep of the index space found no unrejected
    /// asset. The current cycle is then finished. A short but non-empty
    /// deal does not mean exhaustion.
    let exhausted: Bool
    /// `PHFetchResult.count` at sample time: the whole library, cheap to
    /// read.
    let assetCount: Int
    /// How many `object(at:)` materialisations the sample cost.
    let materialisations: Int
    /// The wall time the sample took, in milliseconds: the `index-walk ms`
    /// probe.
    let sampleMs: Int
    /// How many ids the cycle used up after this deal. This value is
    /// O(1) to read. `PhotoDeck` tests it against `poolCount` to end a
    /// cycle.
    let consumedCount: Int
}

/// The result of one date-sort page. See `PhotoLibraryPool.page`. This is
/// the photo twin of `PhotoWindowDeal`. It has no `exhausted` or
/// `consumedCount`, because a date sort has no seen cycle. It has no
/// `materialisations` or `sampleMs`, because a short forward scan needs no
/// performance probe.
struct PhotoWindowPage: Sendable {
    /// The dealt photos, in the active sort's order, already filtered
    /// against `excluding`. The array may be shorter than `need` when the
    /// scan reaches the end of the fetch result first.
    let items: [PhotoWindowItem]
    /// The fetch-result index to resume from for the next page. This
    /// value equals `assetCount` once the scan reaches the end of the
    /// ordered list. `PhotoDeck` uses this to detect the end; it needs no
    /// separate check.
    let nextIndex: Int
    /// `PHFetchResult.count` at page time: the whole filtered library.
    let assetCount: Int
}

/// The photo pool, sampled in windows.
///
/// `PhotoLibraryPool` keeps the lazy `PHFetchResult` itself as the pool.
/// `count` is O(1) and `object(at:)` is random access, so a deal never
/// walks the library. It picks random indices until it has `need` photos
/// (about 60 for one window), materialises only those, and returns them
/// as `PhotoWindowItem`s. Nothing in this file is O(library). The sweep
/// is capped. An existence check on a handful of kept or queued ids uses
/// `existingPhotoIdentifiers(among:)` instead of a whole-library walk.
///
/// This type is an actor on purpose. The `PHFetchResult` and every
/// `object(at:)` it serves must stay off the main actor, because nothing
/// on the main actor may wait on PhotoKit. An actor enforces that by
/// construction, instead of a `Task.detached` at every call site.
///
/// `makeFetchOptions` below sets photo filters as `PHFetchOptions.predicate`.
/// Nothing else in this file has to change: `assetCount` and every
/// sample then describe the filtered pool with no extra work.
actor PhotoLibraryPool {
    static let shared = PhotoLibraryPool()

    private var result: PHFetchResult<PHAsset>?

    /// Ids this cycle used up: everything ever dealt, plus whatever
    /// the persisted seen table contributed through `seedConsumed`. A
    /// hashed `Set`, never an array, because every deal tests about 60
    /// candidates against it.
    ///
    /// This set lives here, on the actor, not on `PhotoDeck`. At the end
    /// of a cycle it can hold one string per photo in a large library.
    /// Keeping it on the actor avoids two costs on the main thread. One
    /// cost is hashing every string while seeding it from the seen table.
    /// The other cost is a full copy-on-write copy of the set. That copy
    /// happens when `PhotoDeck` passed it to this actor while `markSeen`
    /// could still change it. One actor both owns and reads the set, so
    /// neither cost occurs on the main thread.
    private var consumed: Set<String> = []

    /// How many ids the current cycle used up.
    func consumedCount() -> Int { consumed.count }

    /// Adds the persisted seen ids. This runs once per session, from the
    /// background seen load, so the union runs on this actor's executor.
    func seedConsumed(_ ids: Set<String>) { consumed.formUnion(ids) }

    /// Ends the cycle in memory. The matching table delete is the
    /// caller's job. It does not gate the next deal.
    func clearConsumed() { consumed.removeAll() }

    /// The active filters, as a PhotoKit predicate. `makeFetchOptions`
    /// applies it to `PHAsset.fetchAssets(with: .image, options:)`, sorted
    /// by creation date per `sortAscending`. The only invariant is that
    /// the order stays fixed for the life of one fetch result. That fixed
    /// order gives meaning to an index into it. An index from `sample`'s
    /// random picks or `page`'s sequential scan means the same thing from
    /// one call to the next.
    ///
    /// This property holds the predicate here. No call passes it in,
    /// because `refresh()` rebuilds the fetch result and every later
    /// `sample` or `page` reads that same result. A filter or sort-direction change
    /// means: set this value, then call `refresh()`.
    /// `PhotoDeck.performStart` and `PhotoDeck.performApplyOptions` are
    /// the only two callers that do this.
    ///
    /// `dealSortedWindow` does not call `refresh()`. After an external
    /// change, `refreshPoolAfterExternalChange` calls `refresh()`, which
    /// can shift `sortedNextIndex`. `resyncSortedIndex` then corrects
    /// that index.
    private var filterPredicate: NSPredicate?

    /// Random and Oldest both fetch ascending. Newest fetches descending.
    /// This follows the same rule `PhotoLibraryService.videoIndex` uses
    /// for the video side: `let ascending = (sort != .dateNewest)`.
    private var sortAscending = true

    /// Replaces the active predicate. The caller must call `refresh()`
    /// afterward for the change to take effect. This method does not
    /// re-run the existing fetch result, because that is real work on a
    /// large library. The caller usually deals a fresh window right after
    /// the refresh.
    func setFilterPredicate(_ predicate: NSPredicate?) {
        filterPredicate = predicate
    }

    /// Replaces the active fetch direction. The caller must call
    /// `refresh()` afterward, for the same reason as `setFilterPredicate`
    /// above. `PhotoDeck.performStart` and `PhotoDeck.performApplyOptions`
    /// are the callers: each sets this value and then re-deals.
    /// `dealSortedWindow` never calls this method.
    func setSort(ascending: Bool) {
        sortAscending = ascending
    }

    private func makeFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: sortAscending)]
        // With the predicate set on the fetch, `assetCount` and every
        // sample describe the filtered pool with no extra work. No other
        // code in this file has to know filters exist.
        options.predicate = filterPredicate
        return options
    }

    /// Re-fetches the pool and returns its count. This call is cheap,
    /// because `fetchAssets` is lazy and `count` does not materialise
    /// anything.
    @discardableResult
    func refresh() -> Int {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        let fetched = PHAsset.fetchAssets(with: .image, options: makeFetchOptions())
        result = fetched
        return fetched.count
    }

    /// The pool size, fetching once if this is the first call.
    func count() -> Int {
        if result == nil { return refresh() }
        return result?.count ?? 0
    }

    /// Deals up to `need` photos whose ids are not in `excluding` or
    /// `avoiding`.
    ///
    /// This method runs two stages, in order:
    ///
    /// 1. Rejection sampling. It picks random indices with a seeded
    ///    `SplitMix64`, materialises each one, and keeps it unless the
    ///    loop already rejected or picked the id. This is the normal
    ///    path, and it touches about `need` assets, never the whole
    ///    library.
    /// 2. A bounded sweep, only if stage 1 finds too few photos. It walks
    ///    a run of consecutive indices from a random start, at most
    ///    `maxSweepMaterialisations` of them. This finds the remaining
    ///    photos when the unconsumed remainder is too thin for random
    ///    probing.
    ///
    /// The sweep's cap keeps this method safe on a large library. An
    /// uncapped sweep is O(library): on a library of hundreds of
    /// thousands of assets, that is seconds of work for one window of 60.
    /// Nothing here may ever be O(library). The sweep stops and reports
    /// what it found. `PhotoDeck` then decides about the cycle from its
    /// own O(1) counts: `consumedCount()` against `poolCount`.
    /// `exhausted` is `true` only when the sweep covers the whole pool
    /// and finds nothing. On a large library the sweep cannot cover the
    /// whole pool, so `exhausted` stays `false`.
    ///
    /// This method adds everything picked to `consumed` before it
    /// returns, so the caller never has to hand a library-sized rejection
    /// set back in. `excluding` is the kept or queued set, and `avoiding`
    /// is the set of photos still in the deck when a new cycle starts.
    /// Both sets are small. This method tests both with an O(1) lookup
    /// instead of a union.
    func sample(
        need: Int,
        excluding: Set<String> = [],
        avoiding: Set<String> = [],
        seed: UInt64
    ) -> PhotoWindowDeal {
        let start = Date()
        if result == nil { _ = refresh() }
        guard let result else {
            return PhotoWindowDeal(
                items: [], exhausted: true, assetCount: 0, materialisations: 0,
                sampleMs: 0, consumedCount: consumed.count
            )
        }
        let assetCount = result.count
        guard assetCount > 0, need > 0 else {
            return PhotoWindowDeal(
                items: [], exhausted: true, assetCount: assetCount, materialisations: 0,
                sampleMs: Self.elapsedMs(since: start), consumedCount: consumed.count
            )
        }

        let wanted = min(need, assetCount)
        var rng = SplitMix64(seed: seed)
        var picked: [PhotoWindowItem] = []
        picked.reserveCapacity(wanted)
        var pickedIDs = Set<String>()
        var probed = Set<Int>()
        var materialisations = 0

        // Stage 1. The attempt budget keeps this stage bounded, however
        // much of the pool the method already picked. When the budget
        // runs out, the sweep below continues.
        let budget = min(max(wanted * 6, 120), max(assetCount * 2, 1))
        var attempts = 0
        while picked.count < wanted, attempts < budget {
            attempts += 1
            let index = Int(rng.next() % UInt64(assetCount))
            guard probed.insert(index).inserted else { continue }
            materialisations += 1
            let asset = result.object(at: index)
            let id = asset.localIdentifier
            guard !consumed.contains(id), !excluding.contains(id), !avoiding.contains(id),
                  !pickedIDs.contains(id) else { continue }
            pickedIDs.insert(id)
            picked.append(PhotoWindowItem(from: asset))
        }

        // Stage 2, capped.
        var sweepReachedWholePool = false
        if picked.count < wanted {
            let sweepLimit = min(assetCount, Self.maxSweepMaterialisations)
            sweepReachedWholePool = sweepLimit == assetCount
            let origin = Int(rng.next() % UInt64(assetCount))
            var offset = 0
            while offset < sweepLimit, picked.count < wanted {
                let index = (origin + offset) % assetCount
                offset += 1
                guard !probed.contains(index) else { continue }
                materialisations += 1
                let asset = result.object(at: index)
                let id = asset.localIdentifier
                guard !consumed.contains(id), !excluding.contains(id), !avoiding.contains(id),
                  !pickedIDs.contains(id) else { continue }
                pickedIDs.insert(id)
                picked.append(PhotoWindowItem(from: asset))
            }
        }

        consumed.formUnion(pickedIDs)

        return PhotoWindowDeal(
            items: picked,
            exhausted: sweepReachedWholePool && picked.isEmpty,
            assetCount: assetCount,
            materialisations: materialisations,
            sampleMs: Self.elapsedMs(since: start),
            consumedCount: consumed.count
        )
    }

    /// The sweep's ceiling. Large enough that the sweep still covers a
    /// small or mid-sized library exactly, so `exhausted` stays
    /// meaningful there. Small enough that a very large library can never
    /// turn one deal into a library walk.
    private static let maxSweepMaterialisations = 4000

    /// Deals up to `need` photos starting at `startIndex`, in order. This
    /// is the date-sort twin of `sample` above, and it is deliberately
    /// not a rejection sample. A date sort must show every eligible photo
    /// in the fetch result's order. So this method scans forward, one
    /// `object(at:)` call per index. It stops at `need` photos or at the
    /// end of the fetch result.
    ///
    /// This method reads and writes no `consumed` set, because a date
    /// sort ignores the seen cycle entirely; see
    /// `PhotoDeck.dealSortedWindow`'s comment. This method skips only
    /// `excluding`, the kept or queued set, the same small set `sample`
    /// tests against with an O(1) lookup.
    ///
    /// The same limit that bounds `sample` also bounds this method. The scan advances
    /// at most `need` positions, plus however many of `excluding`'s ids
    /// it happens to pass, never the whole library.
    func page(from startIndex: Int, need: Int, excluding: Set<String> = []) -> PhotoWindowPage {
        if result == nil { _ = refresh() }
        guard let result else {
            return PhotoWindowPage(items: [], nextIndex: startIndex, assetCount: 0)
        }
        let assetCount = result.count
        guard need > 0, startIndex < assetCount else {
            return PhotoWindowPage(items: [], nextIndex: max(min(startIndex, assetCount), 0), assetCount: assetCount)
        }

        var items: [PhotoWindowItem] = []
        items.reserveCapacity(need)
        var index = max(startIndex, 0)
        while items.count < need, index < assetCount {
            let asset = result.object(at: index)
            index += 1
            guard !excluding.contains(asset.localIdentifier) else { continue }
            items.append(PhotoWindowItem(from: asset))
        }

        return PhotoWindowPage(items: items, nextIndex: index, assetCount: assetCount)
    }

    /// A bounded re-anchor for `PhotoDeck`'s sorted paging index after a
    /// real library change. `sortedNextIndex` is a raw position in the
    /// active sort's `PHFetchResult`. A same-session import or delete can
    /// shift that position, because one photo landing earlier in the
    /// order pushes every later index up by one.
    ///
    /// An exact re-derivation needs a scan from the start. That scan is
    /// O(library), which this file must avoid. This method searches only
    /// `resyncRadius` positions on each side of the caller's guess for
    /// the id it last dealt.
    ///
    /// When the method finds that id, it resumes just past it. When the
    /// id is not within the bound, the method accepts the drift and
    /// resumes from the guess as is. The worst case is a handful of
    /// photos skipped or repeated once, around one import. That cost is
    /// far cheaper than a library walk, and no worse than what the random
    /// deck already accepts at the start of a new cycle.
    private static let resyncRadius = 64

    func resyncSortedIndex(near guess: Int, lastDealtID: String?) -> Int {
        let assetCount = result?.count ?? 0
        let clampedGuess = min(max(guess, 0), assetCount)
        guard let result, let lastDealtID, assetCount > 0, clampedGuess > 0 else { return clampedGuess }
        let lower = max(clampedGuess - Self.resyncRadius, 0)
        let upper = min(clampedGuess + Self.resyncRadius, assetCount - 1)
        guard lower <= upper else { return clampedGuess }
        for index in lower...upper where result.object(at: index).localIdentifier == lastDealtID {
            return index + 1   // resume after the last photo already dealt
        }
        return clampedGuess
    }

    /// Which of `ids` still name a live photo in the library.
    ///
    /// The only consumers need an existence answer for a handful of ids:
    /// the rows in the shared bin and the kept list. This method asks
    /// about exactly those ids, and `fetchAssets(withLocalIdentifiers:)`
    /// answers in one call that is O(ids), not O(library). See
    /// `AssetKeyResolver.photoLibraryIDs`.
    ///
    /// This method filters to `.image`, so the returned set keeps meaning
    /// what its name says. This method does not return a video id in
    /// `ids`. The resolver checks video ids against its own video
    /// snapshot.
    func existingPhotoIdentifiers(among ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var out = Set<String>()
        found.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image { out.insert(asset.localIdentifier) }
        }
        return out
    }

    private static func elapsedMs(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}
