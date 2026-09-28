//
//  DeckViewModel.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Combine
import SwiftData
import AVFoundation
import os

/// A single slot in the shuffled deck.
///
/// `position` gives each slot a stable, unique identity for SwiftUI. The
/// same asset can appear more than once across reshuffle cycles, so
/// `assetID` alone cannot identify a slot. Each reshuffle appends a new
/// cycle: a full pass completes, then the remainder, or the whole library,
/// reshuffles and appends to the deck.
///
/// `position` is an absolute slot number in the shuffle stream. The deck
/// allocates each number once and never reuses or renumbers it. `position`
/// is not the entry's index in `deck`. Trimming the consumed head of the
/// deck shifts every index. Renumbering would give each surviving row a new
/// `id`. SwiftUI then removes and recreates the visible pages, and
/// `scrollPosition(id:)` loses its position mid-scroll.
struct DeckEntry: Identifiable, Hashable {
    let assetID: String
    let position: Int
    /// Stored, not computed. `ForEach` reads the id of every element on every
    /// diff pass. A computed `"\(position)_\(assetID)"` would allocate one
    /// string per deck slot per body pass. On a deck of 10,000 entries, that is
    /// 10,000 allocations per swipe and per export progress tick.
    let id: String

    init(assetID: String, position: Int) {
        self.assetID = assetID
        self.position = position
        self.id = "\(position)_\(assetID)"
    }
}

@MainActor
final class DeckViewModel: ObservableObject {
    @Published private(set) var deck: [DeckEntry] = []
    @Published var currentIndex: Int = 0
    /// The stable `DeckEntry.id` of `deck[currentIndex]`.
    ///
    /// `FeedView` reads this to re-anchor its `scrollPosition(id:)` binding.
    /// It re-anchors whenever this view model moves the cursor itself: in
    /// `start()`, `pageBecameCurrent()`, or the reconciliation inside
    /// `performLibraryChange()`, rather than through the pager's own scroll.
    /// Without this property, a deck rebuild during live scrolling can set
    /// `currentIndex` to a slot the pager's `currentPageID` never follows.
    /// The rail then acts on a different video than the one on screen.
    /// Or it acts on no video, if that slot's id no longer exists in the
    /// `ForEach`.
    @Published private(set) var currentEntryID: String?
    /// True once a reshuffle attempt finds nothing left to add. Every
    /// remaining video is liked or queued for trash. This also becomes true
    /// under `.limited` library access, where the app cannot verify the
    /// pool. `FeedView` uses this flag to show a real end state, instead of
    /// a pager that stops on its last page with inactive controls.
    @Published private(set) var isPoolExhausted: Bool = false
    /// Under the "On this date" filter, the feed is finite: one pass, then a
    /// final page, never a reshuffle. A date sort already ends. Under this
    /// filter, `extendDeckAfterExhaustion` refuses to extend a Random cycle, so
    /// its last dealt video ends the feed too.
    var showsDoneForTodayAtEnd: Bool { options.filters.onThisDate }
    /// Fires after `like(assetID:)` commits the shield, so the trash queue can
    /// drop a matching pending entry. The shield must always win over a
    /// pending delete. The trash queue is a separate service, and this view
    /// model holds no reference to it.
    var onLiked: ((String) -> Void)?
    /// Distinct ids the next shuffle cycle can draw from: the library, minus
    /// liked ids, minus ids queued for trash. The UI's space-counter row and
    /// the tests read this value. It recomputes on every event that can
    /// change it: a fresh library snapshot, a like or unlike, or a
    /// trash-queue change. It does not recompute on every read, so reading
    /// it never repeats a full PhotoKit enumeration.
    @Published private(set) var totalPoolCount: Int = 0
    /// Absolute slot numbers (`DeckEntry.position`) of every entry within one
    /// page of `currentIndex`. `refreshPreloadableSlots()` recomputes this set
    /// at every site that assigns `currentIndex`.
    ///
    /// This is the O(1), allocation-free equivalent of scanning the whole
    /// deck's array indices on every body pass. It is keyed by position, not
    /// array index. Membership still holds once the deck trims its consumed
    /// head, when array indices no longer line up with slot numbers. The
    /// window stays fixed at one page on each side of the current page.
    @Published private(set) var preloadableSlots: Set<Int> = []

    /// False until the first deal completes. While this is false, `FeedView`
    /// shows plain black instead of "No Videos". An empty deck means "no
    /// videos" only once the deck has actually been checked. A re-deal never
    /// clears this flag. The old deck stays mounted until the new one replaces
    /// it, so filter changes and library changes never show an empty state.
    @Published private(set) var hasDealtFirstDeck = false

    // MARK: - Filter and sort

    /// The options this deck is currently dealt under. Only `apply(options:)`
    /// and `start()`'s initial read of the store assign this property.
    @Published private(set) var options: FeedOptions = .default

    /// Mirrors `AssetKeyResolver.filteredPooledCount`. The UI renders it as
    /// `pool_filtered_<n>`. `totalPoolCount` keeps its own, unfiltered count.
    @Published private(set) var filteredPoolCount: Int = 0

    /// The newest library snapshot as facts, in `options.sort` order. This is
    /// the only input to the filter predicate and to the sorted deck.
    private var index: [VideoFacts] = []

    private var isSortedMode: Bool { options.sort != .random }

    /// Fixed UserDefaults keys. This type is their only reader and writer.
    ///
    /// `DeckOrder` and `DeckState` are CloudKit-ready models, so no code here
    /// adds a field to either: a schema change costs a migration. Both
    /// values are device-local, so UserDefaults stores them: a
    /// local-identifier cursor, and a signature describing a deck order
    /// that is itself local.
    static let deckSignatureKey = "feed.deck.optionsSignature"
    static let sortedCursorKey = "feed.deck.sortedCursorAssetID"

    #if DEBUG
    /// The absolute position of the deck entry after the current one, or `nil`
    /// at the deck's true tail.
    ///
    /// Deck slots are not contiguous. A liked, trash-queued, or vanished
    /// video's slot is never reused, so the next entry after the current
    /// page is often more than one slot away.
    /// `CloudfullUITests/FeedUITestCase.swift` reads this to predict where a
    /// swipe should land. `FeedView`'s probe renders a `nil` value as
    /// `deck_next_end`. Debug-only.
    var debugNextSlotAfterCurrent: Int? {
        deck.indices.contains(currentIndex + 1) ? deck[currentIndex + 1].position : nil
    }
    #endif

    private let library: PhotoLibraryService
    private let modelContext: ModelContext
    private let resolver = AssetKeyResolver.shared
    /// The only owner of the seen-history table. Built from this view model's
    /// own `modelContext.container`, so it shares the same underlying store
    /// without ever sharing the non-`Sendable` context.
    private let seenStore: SeenStore
    private var deckState: DeckState?
    private var deckOrder: DeckOrder?
    private var libraryChangeTask: Task<Void, Never>?
    private var observerToken: LibraryObserverToken?
    /// This view model outlives `FeedView`: `RootView`'s mode switch only
    /// unmounts the view, as `AppMode.swift`'s own comment documents. Without
    /// a floor, PhotoKit's change notifications keep landing while a different
    /// screen is active, and each one triggers a video-index rebuild and deck
    /// reconciliation. `scheduleLibraryChangeHandling()` floors the spacing
    /// between real reconciliations at this interval.
    private static let libraryChangeMinInterval: TimeInterval = 5
    private var lastLibraryChangeRun: Date = .distantPast

    /// The in-memory half of `markSeen`'s decision. `SeenStore`'s own
    /// `markSeen` re-checks durably. A miss here costs one background fetch
    /// and nothing on the main thread, while a hit is O(1) and instant. Every
    /// call to `SeenStore.clearSeen` clears this set too. Otherwise a video
    /// whose history was just reset could never be marked seen again this
    /// session.
    private var markedSeenThisSession: Set<String> = []

    /// Every deck rebuild that needs a library enumeration suspends. Two
    /// could interleave and leave the deck half-rebuilt, for example when a
    /// library change lands inside `start()`'s own enumeration. This FIFO
    /// queue makes that impossible.
    private var deckWork: Task<Void, Never>?
    /// `markSeen` is fire-and-forget, so it must stay ordered against
    /// `SeenStore.clearSeen`. Without ordering, a `markSeen` task started at
    /// `.readyToPlay` on the same page-change tick that begins
    /// `extendDeckAfterExhaustion` could land after that cycle's clear. That
    /// would leave a live `SeenEntry` row for a video the reshuffle just
    /// cleared. The next launch would record it as an exception slot, so
    /// the replay skips it. This FIFO queue, the same shape as `deckWork`,
    /// makes a clear always drain every `markSeen` enqueued ahead of it first.
    private var seenWork: Task<Void, Never>?
    /// Guards the exhaustion-triggered extension, so an `await` inside it
    /// cannot let two page changes start two extensions.
    private var extensionTask: Task<Void, Never>?

    /// The cursor is a monotonic high-water mark. Only the next launch reads
    /// it, so it does not need to be durable the instant it moves — only
    /// durable before the process ends. Writes coalesce at 1.0 second, and
    /// flush unconditionally when the app leaves the foreground (`FeedView`
    /// calls `flushPendingWrites()`) and before any other deck save.
    private var pendingCursor: Int?
    private var pendingSortedCursorAssetID: String?
    private var cursorFlushTask: Task<Void, Never>?
    private static let cursorFlushDelay: UInt64 = 1_000_000_000

    /// Makes `start()` run its full setup only once. `FeedView`'s `.task`
    /// re-runs on every remount — an access downgrade and restore in Settings
    /// is enough to trigger one. Without this flag, a re-entry re-deals a
    /// deck whose old entries SwiftUI already holds.
    private var didStart = false

    /// Slot number of the last deck entry that already triggered an
    /// extension. One arrival at the true end of the deck must produce one
    /// appended cycle, no matter how many times the pager reports that slot.
    private var lastExtendedPosition: Int?

    /// How many already-watched slots stay in the deck behind the current
    /// page. Each exhaustion appends a whole library cycle, and nothing ever
    /// removes an old one. Both `deck` and the persisted deck order would
    /// otherwise grow without bound. That growth would carry across
    /// sessions. Twenty slots is more scroll-back than a forward-facing
    /// triage feed offers, and it bounds the array whatever the library
    /// size.
    private let historyWindow = 20

    init(library: PhotoLibraryService, modelContext: ModelContext) {
        self.library = library
        self.modelContext = modelContext
        self.seenStore = SeenStore(modelContainer: modelContext.container)
    }

    deinit {
        libraryChangeTask?.cancel()
        if let observerToken {
            library.removeLibraryChangeObserver(observerToken)
        }
    }

    // MARK: - Deck construction

    /// Deals the first deck and registers the library observer.
    ///
    /// Guarded by `didStart`, so a `FeedView` remount reconciles instead of
    /// re-dealing. See that property's comment.
    ///
    /// Primes `AssetKeyResolver` with the library snapshot's raw stored keys
    /// synchronously, before anything below reads `resolver.isExcluded` or
    /// `isShielded` to decide what goes in the deck. The cache is never empty
    /// of raw keys. It can only be incomplete on the resolved-cloud-key
    /// fallback for a rotation candidate. Those candidates resolve in the
    /// background. `removeResolvedExclusionsFromFuture` applies the result
    /// later, rather than blocking the first paint on a PhotoKit round trip.
    ///
    /// The body runs through `enqueueDeckWork`, so it cannot interleave with a
    /// queued `apply(options:)`, `performLibraryChange()`, or exhaustion
    /// extension. `FeedView`'s `.task` calls this method.
    func start() {
        enqueueDeckWork { [weak self] in
            await self?.performStart()
        }
    }

    private func performStart() async {
        guard !didStart else {
            await reconcileAfterRemount()
            return
        }
        // `hasDealtFirstDeck` must end up true on every path out of this
        // function: the restored-deck return, the sorted-mode return, and the
        // fresh-deal fallthrough alike. This stops `FeedView` from showing "No
        // Videos" for a deck that has simply not been checked yet.
        let dealStarted = Date()
        defer {
            hasDealtFirstDeck = true
            Usage.shared.firstDeal(mode: .videos, ms: Int(Date().timeIntervalSince(dealStarted) * 1000))
        }
        didStart = true
        lastExtendedPosition = nil
        // Read the persisted options before anything below decides what goes
        // in the pool or which restore branch applies.
        options = FeedOptionsStore.shared.options

        await refreshIndex()
        let ids = index.map(\.id)
        let idsSet = Set(ids)
        let candidates = resolver.primeSynchronously(libraryIDs: idsSet, authStatus: library.authStatus, modelContext: modelContext)
        resolver.onResolutionLanded { [weak self] newlyExcludedIDs in
            self?.removeResolvedExclusionsFromFuture(newlyExcludedIDs)
        }
        if !candidates.isEmpty {
            Task { [weak resolver] in
                await resolver?.resolveCandidates(candidates)
            }
        }

        // Liked ids are shielded forever, and trash-queued ids are pending
        // deletion, so neither may enter this or any later cycle.
        // Filtered-out ids are a second, independent reason for exclusion.
        // `isEligible` checks both.
        let poolIDs = ids.filter { resolver.isEligible($0) }
        totalPoolCount = resolver.pooledCount
        filteredPoolCount = resolver.filteredPooledCount

        #if DEBUG
        // `scripts/gate_all.sh`'s pool cross-check launches with
        // `-cloudfull-reset-deck-state` alongside this argument, so the store
        // is empty and `resolver` has already settled to `.clean`
        // synchronously above. Nothing here needs to wait on the async
        // rotation-candidate resolution path.
        if ProcessInfo.processInfo.arguments.contains(CloudfullApp.reportPoolArgument) {
            let pooled = totalPoolCount
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.cloudfull.app", category: "PoolReport")
                .log("pool_report_\(ids.count)_\(pooled)")
            exit(0)
        }
        #endif

        let state = fetchOrCreateDeckState()
        deckState = state
        let order = fetchOrCreateDeckOrder()
        deckOrder = order
        migrateIfNeeded(order: order, state: state)

        // `SeenStore` runs this fetch on its own actor, off the main thread.
        // A row whose key is absent from this fetch stays dormant. Nothing
        // here deletes it.
        var seenKeys = await seenStore.seenKeys(limitedTo: idsSet)

        // "Completed" is judged against the eligible pool, not the raw
        // library. If everything left is liked or trash-queued, the pool is
        // empty. The deck then stops extending. Do not reshuffle or clear
        // seen history.
        //
        // Under `.limited` access, `fetchAllVideoIDs()` sees only the
        // user-selected subset, so an apparently finished pass proves nothing
        // about the real library. Treat it as not completed, rather than
        // clear seen history against a partial view.
        let cycleJustCompleted = library.authStatus == .authorized
            && !poolIDs.isEmpty
            && poolIDs.allSatisfy { seenKeys.contains($0) }
        if cycleJustCompleted {
            // Drain every `markSeen` enqueued ahead of this clear first. See
            // the comment on `seenWork`. Without this wait, a `markSeen`
            // task enqueued earlier in this process could still be in
            // flight and land after the clear below. That would leave a
            // live row this reshuffle was supposed to erase.
            await seenWork?.value
            // Full pass complete: reshuffle by clearing seen history for the
            // ids that exist now. Dormant rows for absent ids stay untouched,
            // so a deleted video that returns later keeps its seen state.
            _ = await seenStore.clearSeen(in: idsSet)
            markedSeenThisSession.subtract(idsSet)
            seenKeys.removeAll()
        }

        if let observerToken {
            library.removeLibraryChangeObserver(observerToken)
        }
        observerToken = library.addLibraryChangeObserver { [weak self] in
            self?.scheduleLibraryChangeHandling()
        }

        // Restore path. The saved cycle log is the plan the deck already
        // committed to. It alone decides what comes next: it only has to
        // replay to the same order. `rebuildDeck` returns `nil`, and the
        // fresh path below runs, exactly when the pool the cycle was dealt
        // from can no longer be reproduced.
        //
        // A saved random cycle replays only when today's options match the
        // ones it was dealt under. Any mismatch, including a switch into
        // sorted mode, falls through to a fresh deal for that mode.
        if !isSortedMode, readDeckSignature() == options.probeToken,
           order.schemaVersion == 1, let restored = rebuildDeck(order: order, libraryIDs: ids) {
            let dealtIDs = Set(restored.map(\.assetID))
            deck = restored
            // The cursor is an absolute slot number, so resuming means
            // searching for the first surviving slot at or past it. No index
            // rebasing is needed, and a slot removed while the app was closed
            // simply falls forward to the next one.
            currentIndex = deck.firstIndex { $0.position >= state.cursor } ?? max(deck.count - 1, 0)
            refreshPreloadableSlots()
            // Drop the slots the user already scrolled past in earlier
            // sessions. Do not carry every cycle ever dealt back into
            // memory and into the persisted order.
            trimConsumedHistory(order: order)
            // Merge in anything imported since the deck was last saved, such
            // as a video recorded while the app was closed. This keeps it
            // visible before exhaustion, rather than invisible until then.
            mergeNewImports(order: order, libraryIDs: ids, alreadyDealt: dealtIDs, seenKeys: seenKeys)
            currentEntryID = deck.indices.contains(currentIndex) ? deck[currentIndex].id : nil
            saveDeck()
            return
        }

        if isSortedMode {
            rebuildSortedDeck(resumeAssetID: readSortedCursor())
            return
        }

        dealFreshCycle(order: order, state: state, poolIDs: poolIDs, seenKeys: seenKeys)
        writeDeckSignature()
    }

    // MARK: - Applying new options

    /// True while a re-deal from `apply(options:)` or `refresh()` is in
    /// flight. `FeedView` shows an "Updating feed…" overlay while this is
    /// true.
    @Published private(set) var isApplyingOptions = false

    /// Re-deals the feed for a new set of options. If the options are
    /// unchanged, it returns immediately. FeedView's `onChange` can call it
    /// any number of times.
    ///
    /// A filter change starts a fresh cycle. Seen state is kept and
    /// respected: nothing here ever deletes a seen row, a `LikedEntry`, or a
    /// `TrashEntry`. The user's memory of what they have watched survives
    /// every filter change and every trip through a date sort.
    func apply(options newOptions: FeedOptions) {
        wdMark("apply")
        guard newOptions != options else { return }
        let previous = options
        options = newOptions
        isApplyingOptions = true
        // Queued behind whatever deck rebuild is already in flight, so an
        // options change landing mid-enumeration cannot interleave with it.
        enqueueDeckWork { [weak self] in
            await self?.performApply(previous: previous)
            self?.isApplyingOptions = false
        }
    }

    /// Pull-to-refresh on the video pager. Re-reads the library and deals
    /// again, exactly like a filter change whose options happen to be
    /// unchanged. Sorted modes restart at the top. Random deals a fresh
    /// cycle from the pool minus what is already seen. This never erases
    /// progress — it only picks up new videos and reshuffles the order.
    /// Awaits the queued work, so `.refreshable`'s spinner stays up until the
    /// deck is actually rebuilt.
    func refresh() async {
        wdMark("refresh")
        Usage.shared.pullRefresh(mode: .videos)
        isApplyingOptions = true
        let previous = options
        await enqueueDeckWork { [weak self] in
            await self?.performApply(previous: previous)
            self?.isApplyingOptions = false
        }.value
    }

    private func performApply(previous: FeedOptions) async {
        await refreshIndex()

        if isSortedMode {
            // Position is remembered until sort or filters change. This is
            // such a change, so the list starts at the top.
            clearSortedCursor()
            rebuildSortedDeck(resumeAssetID: nil)
        } else {
            // Back from a date sort, or from a filter change inside Random,
            // the pool the live cycle was dealt from no longer describes
            // the feed.
            await dealFreshCycleForCurrentPool(previousWasSorted: previous.sort != .random)
        }
    }

    /// A thin wrapper around `dealFreshCycle`. Recomputes the pool from the
    /// just-refreshed `index` and the current seen keys, then deals over it
    /// exactly like `start()`'s fresh-deal path.
    private func dealFreshCycleForCurrentPool(previousWasSorted: Bool) async {
        let order = deckOrder ?? fetchOrCreateDeckOrder()
        deckOrder = order
        let state = deckState ?? fetchOrCreateDeckState()
        deckState = state

        let idsSet = Set(index.map(\.id))
        let poolIDs = index.filter { resolver.isEligible($0.id) }.map(\.id)
        // Reads seen history on `SeenStore`'s own background actor, instead
        // of on the main actor.
        let seenKeys = await seenStore.seenKeys(limitedTo: idsSet)

        dealFreshCycle(order: order, state: state, poolIDs: poolIDs, seenKeys: seenKeys)
        writeDeckSignature()
    }

    /// Builds the whole filtered, ordered list as the deck. No seed, no
    /// cycle record, and no digest: a date-sorted list is reproducible from
    /// the library and the predicate alone. Persisting one would only add
    /// an unbounded stored blob. Slots still come from `DeckOrder.nextSlot`.
    /// A `DeckEntry.id` dealt here can never collide with one already on
    /// screen or with one dealt in an earlier session.
    private func rebuildSortedDeck(resumeAssetID: String?) {
        let order = deckOrder ?? fetchOrCreateDeckOrder()
        deckOrder = order

        let ids = index.filter { resolver.isEligible($0.id) }.map(\.id)
        let baseSlot = order.nextSlot
        deck = entries(for: ids, baseSlot: baseSlot)
        order.nextSlot = baseSlot + ids.count
        #if DEBUG
        DeckWriteCounters.ints += 1
        #endif

        // Position is remembered until options change. A resume id that is
        // no longer in the list falls to the top, not to a neighbor. A
        // filtered list has no meaningful "next" entry.
        currentIndex = resumeAssetID.flatMap { id in deck.firstIndex { $0.assetID == id } } ?? 0
        isPoolExhausted = false
        lastExtendedPosition = nil
        refreshPreloadableSlots()
        currentEntryID = deck.indices.contains(currentIndex) ? deck[currentIndex].id : nil
        filteredPoolCount = resolver.filteredPooledCount
        saveDeck()                 // Commits `order.nextSlot` only.
        writeDeckSignature()
        persistSortedCursor()
    }

    /// One library enumeration feeds the index, the resolver's library
    /// snapshot, and the resolver's filter-exclusion set. Every path in
    /// this type that needs the library calls this method, so the filter
    /// set can never go stale behind a library change.
    ///
    /// `loadVideoIndex` runs the enumeration off the main actor. This
    /// `await` frees the main thread for the page-change tick that
    /// triggered it.
    private func refreshIndex() async {
        index = await library.loadVideoIndex(sort: options.sort)
        let idsSet = Set(index.map(\.id))
        resolver.refreshLibrarySnapshot(idsSet)
        let filters = options.filters
        var excluded = Set<String>()
        if !filters.isDefault {
            for facts in index where !filters.matches(facts) { excluded.insert(facts.id) }
        }
        resolver.setFilterExclusions(excluded)
        totalPoolCount = resolver.pooledCount
        filteredPoolCount = resolver.filteredPooledCount
    }

    private func writeDeckSignature() {
        UserDefaults.standard.set(options.probeToken, forKey: Self.deckSignatureKey)
    }

    private func readDeckSignature() -> String? {
        UserDefaults.standard.string(forKey: Self.deckSignatureKey)
    }

    /// The live asset id of the page the user is on in a date sort.
    /// Deferred through the same 1.0-second coalesced flush as the
    /// random-mode cursor: a date-sorted position is exactly as disposable
    /// as the random high-water mark. It must be durable before the
    /// process ends, not on every tap.
    private func persistSortedCursor() {
        guard isSortedMode, deck.indices.contains(currentIndex) else { return }
        pendingSortedCursorAssetID = deck[currentIndex].assetID
        scheduleCursorFlush()
    }

    private func readSortedCursor() -> String? {
        UserDefaults.standard.string(forKey: Self.sortedCursorKey)
    }

    private func clearSortedCursor() {
        UserDefaults.standard.removeObject(forKey: Self.sortedCursorKey)
    }

    /// Deals one cycle over the whole eligible pool and makes it the deck.
    ///
    /// The cycle's input is the full pool, not the unseen remainder. The
    /// replay checks the digest against this input. A seen-history table
    /// that keeps growing cannot reconstruct which ids were seen at deal
    /// time. The unseen filter
    /// applies to the dealt slots instead: an already-seen id still claims
    /// its slot, and that slot is recorded as an exception. The user still
    /// never sees it twice in one pass, and the replay drops exactly the
    /// same slots.
    private func dealFreshCycle(order: DeckOrder, state: DeckState, poolIDs: [String], seenKeys: Set<String>) {
        let seed = UInt64.random(in: UInt64.min...UInt64.max)
        let baseSlot = order.nextSlot
        let cycleIDs = ShuffleEngine.permutation(of: poolIDs, seed: seed)

        // Empty pool: everything in the library is liked or trash-queued.
        // Do not record a zero-length cycle. It would reconstruct to
        // nothing, send the next launch down this same path, and append
        // another one. That would grow the log by one record per launch
        // for as long as the pool stays empty. The stale records already
        // in the log are harmless: every slot they hold is an exception,
        // so they replay to nothing.
        guard !cycleIDs.isEmpty else {
            deck = []
            currentIndex = 0
            currentEntryID = nil
            refreshPreloadableSlots()
            state.seed = Int64(bitPattern: seed)
            saveDeck()
            return
        }

        appendCycle(
            seed: seed,
            baseSlot: baseSlot,
            count: cycleIDs.count,
            digest: ShuffleEngine.digest(of: poolIDs),
            swaps: "",
            literalIDs: nil,
            to: order
        )

        var entries: [DeckEntry] = []
        var seenSlots: [Int] = []
        var seenIDs: [String] = []
        for (offset, id) in cycleIDs.enumerated() {
            let slot = baseSlot + offset
            if seenKeys.contains(id) {
                seenSlots.append(slot)
                seenIDs.append(id)
            } else {
                entries.append(DeckEntry(assetID: id, position: slot))
            }
        }
        appendExceptions(slots: seenSlots, ids: seenIDs, to: order)
        // A fresh deal replaces the whole deck, so no cycle below this one
        // is used any more. Prune them here, rather than leaving the log
        // to grow by one record per rebuild.
        pruneConsumedCycles(order: order, boundary: baseSlot)

        deck = entries
        currentIndex = 0
        refreshPreloadableSlots()
        currentEntryID = deck.first?.id
        state.seed = Int64(bitPattern: seed)
        state.cursor = deck.first?.position ?? baseSlot
        saveDeck()
    }

    /// Runs instead of a full re-deal when `start()` is called again on an
    /// already-started instance, such as a `FeedView` remount. Re-primes
    /// the resolver against a fresh library snapshot and refreshes
    /// `totalPoolCount`, but re-deals nothing. The deck already on screen,
    /// and the `scrollPosition` SwiftUI holds for it, stay exactly as they
    /// are.
    private func reconcileAfterRemount() async {
        // A notification tap switches the app's mode and sets the filters
        // in one synchronous call, so `FeedView` can be created already
        // holding the new options. Its `onChange` takes that as its
        // baseline and never fires. This method is the only other thing
        // that runs on that path, so it re-reads the options here.
        //
        // Do not use `initial: true` on the view's watcher. It also fires
        // on a cold launch, where `performStart` already reads the same
        // options, and shows a second "Updating feed…" pill.
        //
        // `apply` refuses a no-op (`guard newOptions != options`), so the
        // ordinary remount costs one comparison and shows no pill.
        apply(options: FeedOptionsStore.shared.options)

        // `refreshIndex()` re-derives shield and queue membership from the
        // existing `cloudToLocal` cache, and re-sets the filter-exclusion
        // set. A re-prime with fresh rotation-candidate resolution belongs
        // only to the real launch path, in `start()`'s first call.
        await refreshIndex()
    }

    /// Called when the pager settles on a new slot, identified by that
    /// slot's stable `DeckEntry.id`, never by raw array position. Array
    /// position shifts under live library edits, and using it would let
    /// the wrong row get marked seen.
    func pageBecameCurrent(_ pageID: String) {
        wdMark("pageCurrent")
        guard let index = deck.firstIndex(where: { $0.id == pageID }) else { return }
        currentIndex = index
        refreshPreloadableSlots()
        currentEntryID = deck[index].id

        // A date sort persists only its cursor. It skips the
        // `DeckState.cursor` write, since a date-sort excursion must not
        // move the random resume's high-water mark. It also skips the
        // extension attempt, since the list is finite.
        if isSortedMode {
            persistSortedCursor()
            return
        }

        let state = deckState ?? fetchOrCreateDeckState()
        deckState = state
        // Track the cursor as a monotonic high-water mark, in absolute
        // slot space, rather than as an index into the deck array. A
        // backward swipe to rewatch an earlier video must not move the
        // persisted cursor backward. Otherwise the restore in `start()`
        // resumes behind where the user actually got to.
        //
        // No SwiftData write happens on the page-change tick. The write
        // is deferred and coalesced at 1.0 second
        // (`scheduleCursorFlush`). It flushes unconditionally when the
        // app leaves the foreground (`FeedView` calls
        // `flushPendingWrites()`) and before any other deck save.
        let position = deck[index].position
        if position > max(state.cursor, pendingCursor ?? Int.min) {
            pendingCursor = position
            scheduleCursorFlush()
        }

        // The extension is queued like every other deck rebuild, rather
        // than running synchronously inside this tick. Running it
        // synchronously would enumerate the whole library and fetch every
        // seen-history row while the pager is still settling.
        // `extensionTask == nil` is required: with an `await` inside the
        // queued work, two page
        // changes could otherwise start two extensions.
        //
        // The key is the end slot's absolute position, not whether the
        // index is still the last one. That condition flips back to true
        // every time a later cycle is consumed. Positions are never
        // reused. Each true end-of-deck slot extends the deck exactly
        // once, even if the pager reports it more than once.
        if index == deck.count - 1, let end = deck.last,
           lastExtendedPosition != end.position, extensionTask == nil {
            let position = end.position
            extensionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // Only use up this slot's one extension attempt if it
                // actually appended something. `extendDeckAfterExhaustion()`
                // can return early with an empty pool, when everything left
                // is liked or trash-queued. If that used up the slot
                // anyway, restoring or unliking an asset later could never
                // trigger another attempt here. The pager would stop
                // advancing on this page for the rest of the process.
                // Routed through `enqueueDeckWork`, so it cannot
                // interleave with a queued `apply(options:)` or
                // `performLibraryChange()`.
                var extended = false
                await self.enqueueDeckWork {
                    extended = await self.extendDeckAfterExhaustion()
                }.value
                if extended {
                    self.lastExtendedPosition = position
                }
                self.extensionTask = nil
            }
        }
    }

    /// A binned video leaves the feed entirely. Swipe back skips it. Only
    /// the bin can restore it. `removeFromFuture` already drops every slot
    /// ahead the moment the trash is tapped. It deliberately leaves the
    /// page on screen, and anything behind it, in place. This method runs
    /// once the pager has settled on a new page, and drops every
    /// trash-queued entry except that page. The video the user just
    /// binned vanishes the moment they leave it, and a backward swipe
    /// lands on the video before it. Nothing needs to persist:
    /// `removeFromFuture` scans the whole deck for its exception slots. The
    /// launch replay already drops these entries. Only the live array kept
    /// them.
    ///
    /// Called by `FeedView` only once the pager is at rest on `pageID`.
    /// Never called from inside `removeFromFuture`, or from the
    /// `currentPageID` change that the trash tap's own advance animation
    /// triggers. Pruning while that animation is in flight removes the page
    /// the pager is animating away from. The animation keeps its offset
    /// target, and lands one page past the intended one.
    ///
    /// Returns true if anything was removed. The caller must then
    /// re-anchor the pager on `pageID` — see `FeedView.reanchorNonce`.
    /// `ScrollView` keeps its offset, not its anchored id, when items
    /// above the current page leave a `LazyVStack`. Without re-anchoring,
    /// the pager silently ends up one page further on than the id it
    /// reports.
    @discardableResult
    func pruneQueuedPages(keeping pageID: String) -> Bool {
        wdMark("prune")
        let before = deck.count
        deck.removeAll { $0.id != pageID && resolver.isQueued($0.assetID) }
        guard deck.count != before else { return false }
        if let index = deck.firstIndex(where: { $0.id == pageID }) {
            currentIndex = index
        }
        refreshPreloadableSlots()
        return true
    }

    /// Marks a video seen. Called only once its player item actually
    /// reaches `.readyToPlay` — see `PlayerPageView`. A video that failed
    /// to load, such as a dropped iCloud stream or a network error, is
    /// never marked seen. The user must see a frame of it first.
    ///
    /// O(1) on the main actor: a set insert and a task hand-off. The
    /// SwiftData fetch, insert, and save run on `SeenStore` instead.
    ///
    /// `markedSeenThisSession` makes the duplicate check immediate. The
    /// store's own `markSeen` re-checks durably, so a miss here costs one
    /// background fetch and nothing on the main thread.
    func markSeen(_ assetID: String) {
        wdMark("markSeen")
        // A date sort does not skip seen videos, so marking them would
        // silently complete a random cycle the user never watched. That
        // would trigger a reshuffle that erases their real progress.
        guard !isSortedMode else { return }
        guard markedSeenThisSession.insert(assetID).inserted else { return }
        let store = seenStore
        // Each task chains onto `seenWork`, like `enqueueDeckWork` chains
        // deck rebuilds. A `clearSeen` at a cycle seam —
        // `extendDeckAfterExhaustion` or `performStart` — awaits this
        // chain, so every earlier `markSeen` lands first. See the comment
        // on `seenWork`.
        let previous = seenWork
        seenWork = Task { @MainActor in
            await previous?.value
            await store.markSeen(assetID)
        }
    }

    func playerItem(for assetID: String, onProgress: (@Sendable (Double) -> Void)? = nil) async -> AVPlayerItem? {
        // A warm slot may already hold this asset's resolved item, or
        // still be resolving it. Either way, this is the only consumer,
        // so joining is correct: a second request would download the
        // item twice. `take` removes what it returns, so one resolved
        // item can never reach two players.
        if let warmed = await PlayerItemCache.shared.take(assetID) { return warmed }
        return await library.playerItem(for: assetID, onProgress: onProgress)
    }

    // MARK: - Like / trash exclusion

    /// O(1): reads `AssetKeyResolver.shieldedIDs` instead of running a
    /// SwiftData predicate fetch on every render of every mounted page's
    /// rail.
    func isLiked(_ assetID: String) -> Bool {
        resolver.isShielded(assetID)
    }

    /// Shields a video forever. It can never be trashed from the app, and
    /// it leaves the deck everywhere except the page currently on screen
    /// — see `removeFromFuture`. The shield saves before the deck edit,
    /// so a concurrent read of `isLiked` never observes the removal
    /// without the reason for it.
    @discardableResult
    func like(assetID: String) -> Bool {
        let wasApplied = !isLiked(assetID)
        if wasApplied {
            // Stamping a cloud key on insert costs nothing extra when one
            // is already known, such as a rotation candidate this
            // session's resolution has resolved. Otherwise it stays
            // `nil`. A synchronous PhotoKit lookup would block the main
            // thread on this user-interactive tap.
            let cloudKey = resolver.knownCloudKey(forLiveID: assetID)
            modelContext.insert(LikedEntry(assetKey: assetID, cloudKey: cloudKey))
            try? modelContext.save()
            resolver.noteLiked(assetKey: assetID, cloudKey: cloudKey)
        }
        removeFromFuture(assetID: assetID)
        // The shield always wins over a pending delete: a video queued
        // for trash and then liked must never still sit in the trash
        // queue. `TrashService` owns that row, not this view model, so
        // the actual removal happens through this callback.
        onLiked?(assetID)
        return wasApplied
    }

    /// Lifts the shield. This needs no immediate deck edit: the id simply
    /// stops being excluded the next time a cycle is built, in `start()`,
    /// `extendDeckAfterExhaustion()`, or `performLibraryChange()`.
    @discardableResult
    func unlike(assetID: String) -> Bool {
        // `assetID` is the live local identifier. The resolver shields it
        // through `cloudToLocal`, which is why the heart renders filled
        // and every tap routes here. A fetch on the raw key alone misses a
        // row whose stored `assetKey` changed, for example after a device
        // restore. That would leave the `LikedEntry` permanently
        // un-unlikeable. Fetch every row and match on either key, exactly
        // like `TrashService.entriesByLiveKey` does.
        #if DEBUG
        FetchCounters.swiftData += 1
        #endif
        let all = (try? modelContext.fetch(FetchDescriptor<LikedEntry>())) ?? []
        let matches = all.filter {
            $0.assetKey == assetID || resolver.exclusionKey(assetKey: $0.assetKey, cloudKey: $0.cloudKey) == assetID
        }
        guard !matches.isEmpty else { return false }
        for entry in matches {
            let (assetKey, cloudKey) = (entry.assetKey, entry.cloudKey)
            modelContext.delete(entry)
            // Called with the row's stored key, not the live id, to
            // match `noteLiked`'s own insertion shape.
            resolver.noteUnliked(assetKey: assetKey, cloudKey: cloudKey)
        }
        try? modelContext.save()
        refreshTotalPoolCount()
        return true
    }

    /// Wired to `AssetKeyResolver.onResolutionLanded` from `start()`. A
    /// rotated shielded or queued video can be dealt into the deck before
    /// its cloud key resolves. Its Delete button stays disabled until
    /// then, so this is cosmetic, not a correctness gap. This method
    /// removes the video from every slot ahead of the current page the
    /// moment resolution lands.
    func removeResolvedExclusionsFromFuture(_ ids: [String]) {
        for id in ids { removeFromFuture(assetID: id) }
    }

    /// Removes every occurrence of `assetID` sitting after the current page
    /// from the live deck. The page on screen stays untouched, even if it
    /// happens to be this very asset. Shared by `like`, where the id is
    /// shielded, and by the trash queue's exclusion —
    /// `TrashService.onQueued` calls this directly once an entry is
    /// queued. Both callers need the asset gone from everything still
    /// ahead of the user, without disturbing what the user is looking at
    /// right now.
    ///
    /// This method appends one slot number and one id per occurrence to
    /// the exception list, at most one per live cycle, independent of
    /// library size.
    ///
    /// The scan covers the whole deck, not just the slots after the
    /// current page, because the exception list has two jobs. It tells the
    /// launch replay which slots to drop: only the ones removed here
    /// matter for that. It also tells the replay which ids to add back
    /// when it rebuilds this cycle's deal-time input. The id the user just
    /// liked is excluded from the pool now. Its slot on the current page
    /// must be recorded too, or the digest can never match again.
    /// Recording it also means a relaunch resumes on the next video,
    /// rather than on the one the user just shielded, which is the
    /// correct outcome.
    func removeFromFuture(assetID: String) {
        var slots: [Int] = []
        var index = deck.count - 1
        while index >= 0 {
            if deck[index].assetID == assetID {
                slots.append(deck[index].position)
                // The page on screen is left exactly where it is, even
                // when it is this very asset.
                if index > currentIndex {
                    deck.remove(at: index)
                }
            }
            index -= 1
        }

        // Sorted mode still removes the id from the live deck above, but
        // there is no cycle log to inform. Writing an exception from
        // sorted mode would corrupt the random deck's replay.
        if !slots.isEmpty, !isSortedMode {
            let order = deckOrder ?? fetchOrCreateDeckOrder()
            deckOrder = order
            appendExceptions(
                slots: slots,
                ids: Array(repeating: assetID, count: slots.count),
                to: order
            )
            saveDeck()
        }

        refreshTotalPoolCount()
    }

    /// Recomputes `totalPoolCount` from `AssetKeyResolver.pooledCount`,
    /// O(1). A like, unlike, or trash-queue action changes only the
    /// exclusion set, which the resolver's own `note*` methods already
    /// update by the time this runs. It never changes the library snapshot
    /// itself.
    private func refreshTotalPoolCount() {
        let newCount = resolver.pooledCount
        if newCount > totalPoolCount {
            // The pool grew, from an unlike or a restore from the trash
            // bin. Clear the last extension slot, so that the deck can
            // extend again when the user reaches that slot.
            lastExtendedPosition = nil
            isPoolExhausted = false
        }
        totalPoolCount = newCount
        // The "pool grew" check above reads the unfiltered count on
        // purpose. A restore or an unlike must clear the latch whether or
        // not a filter currently hides the restored video.
        filteredPoolCount = resolver.filteredPooledCount
    }

    /// Recomputes `totalPoolCount` and the exhaustion latch after an id
    /// becomes eligible again through a path this view model was not told
    /// about directly. Restoring a video from the trash queue is one
    /// example. No deck edit is needed: the id simply stops being excluded
    /// the next time a cycle is built, exactly like `unlike`.
    func refreshPoolAfterExternalChange() {
        refreshTotalPoolCount()
    }

    // MARK: - Exhaustion (live, in-session)

    /// Reaching the last slot in the deck means every prior slot has been
    /// scrolled through this cycle. Clears seen history and appends a
    /// freshly shuffled cycle, so the pager keeps scrolling without
    /// needing a relaunch to trigger the reshuffle in `start()`.
    ///
    /// Returns `true` if a fresh cycle was actually appended. `false`
    /// means the pool was empty and nothing changed. The caller must not
    /// treat that as having consumed this slot's one extension attempt —
    /// see `pageBecameCurrent`.
    ///
    /// Runs async, off the page-change tick. Called only through
    /// `pageBecameCurrent`'s `extensionTask`, itself routed through
    /// `enqueueDeckWork`, so it cannot interleave with another queued deck
    /// rebuild.
    @discardableResult
    private func extendDeckAfterExhaustion() async -> Bool {
        // A finite sorted list simply ends. Nothing extends it.
        guard !isSortedMode else { return false }

        // A pass over "this date" ends with a card, not a reshuffle.
        // Checked before the index re-read below, since the pager
        // re-asks on every settle of the last page and this answer is
        // free.
        guard !options.filters.onThisDate else { return false }

        // Under `.limited` access, the enumeration below only ever sees
        // the user-selected subset, so an apparent exhaustion proves
        // nothing about the real library. Report exhausted without
        // touching seen history, rather than reshuffle against a
        // partial view.
        guard library.authStatus == .authorized else {
            isPoolExhausted = true
            return false
        }

        await refreshIndex()
        guard !Task.isCancelled else { return false }
        let ids = index.map(\.id)
        let idsSet = Set(ids)

        // Same exclusion as `start()`: a liked, trash-queued, or
        // filtered-out id may not reappear in the cycle that replaces the
        // one just finished.
        let poolIDs = ids.filter { resolver.isEligible($0) }
        // Empty-pool edge case: everything left is liked or
        // trash-queued. Stop extending, rather than shuffle nothing onto
        // the deck. Publish the exhaustion flag, so the feed can show a
        // real end state instead of a pager that loops its last page.
        guard !poolIDs.isEmpty else {
            isPoolExhausted = true
            return false
        }
        isPoolExhausted = false

        // A filtered cycle exhausts on a narrow subset. Clearing seen for
        // the whole library here would erase the user's memory of every
        // video, just because they finished a five-video filter. Under
        // default options `filterExcludedIDs` is empty, so this matches
        // the unfiltered case exactly.
        //
        // This runs as a single call on `SeenStore`'s background actor,
        // instead of a main-actor fetch with a per-row delete loop.
        let cycleIDs = idsSet.subtracting(resolver.filterExcludedIDs)
        // `markSeen` fires at `.readyToPlay` on the same page-change tick
        // that starts this extension. Without draining first, a
        // `markSeen` task already in flight for a video in `cycleIDs`
        // could land after this clear. That would leave a live
        // `SeenEntry` row the reshuffle just erased. See the comment on
        // `seenWork`.
        await seenWork?.value
        _ = await seenStore.clearSeen(in: cycleIDs)
        guard !Task.isCancelled else { return false }
        markedSeenThisSession.subtract(cycleIDs)

        let order = deckOrder ?? fetchOrCreateDeckOrder()
        deckOrder = order
        let state = deckState ?? fetchOrCreateDeckState()
        deckState = state

        let seed = UInt64.random(in: UInt64.min...UInt64.max)
        let shuffled = ShuffleEngine.permutation(of: poolIDs, seed: seed)
        // The seam guard runs against the live in-memory deck, so the
        // dealt order matches what the user actually sees. `appendCycle`
        // records its rearrangement. The launch replay applies the
        // recorded swaps to a freshly permuted array, instead of trying
        // to reconstruct a previous cycle that no longer exists.
        let gap = min(deck.count, shuffled.count / 2)
        let recent = Set(deck.suffix(max(gap, 0)).map(\.assetID))
        let guarded = ShuffleEngine.openingWithoutRecentRepeat(shuffled, avoiding: recent, gap: gap)

        let baseSlot = order.nextSlot
        appendCycle(
            seed: seed,
            baseSlot: baseSlot,
            count: guarded.cycle.count,
            digest: ShuffleEngine.digest(of: poolIDs),
            swaps: encodeSwaps(guarded.swaps),
            literalIDs: nil,
            to: order
        )
        deck.append(contentsOf: entries(for: guarded.cycle, baseSlot: baseSlot))

        state.seed = Int64(bitPattern: seed)
        // A cycle is only appended once the previous one is fully
        // consumed, so prune consumed cycles here to keep the log size
        // bounded.
        pruneConsumedCycles(order: order, boundary: state.cursor - historyWindow)

        saveDeck()
        return true
    }

    /// Drops slots the user scrolled past in earlier sessions from the
    /// deck, and raises the persisted trim boundary so the launch replay
    /// stops reconstructing them. Without this, the restored order would
    /// carry every cycle ever dealt into the next launch. Library size
    /// would not bound it: a small library can accumulate hundreds of
    /// stored slots after a few sessions.
    ///
    /// Call this only from `start()`, before the pager exists. Removing
    /// rows above the viewport of a live `ScrollView` does not move
    /// `scrollPosition(id:)` with them. The offset does not change. The
    /// viewport lands further down the deck. If it lands on the last
    /// slot, the feed extends, trims, and lands there again: an
    /// unbounded loop of extensions with no swipes behind them.
    ///
    /// The cursor is not rebased. Slots are absolute, so `DeckState.cursor`
    /// stays correct as written, with no rebasing arithmetic needed.
    private func trimConsumedHistory(order: DeckOrder) {
        guard currentIndex > historyWindow else { return }
        let dropCount = currentIndex - historyWindow
        let boundary = deck[dropCount].position

        deck.removeFirst(dropCount)
        currentIndex -= dropCount
        refreshPreloadableSlots()

        order.trimmedBeforeSlot = max(order.trimmedBeforeSlot, boundary)
        #if DEBUG
        DeckWriteCounters.ints += 1
        #endif
        pruneConsumedCycles(order: order, boundary: boundary)
    }

    // MARK: - Library change handling

    /// Coalesces bursts of PhotoKit change notifications, routine during
    /// an iCloud sync, into a single reconciliation, instead of rebuilding
    /// the deck once per notification.
    ///
    /// The full-library enumeration (`loadVideoIndex`) runs off the main
    /// actor, and the reconciliation itself is queued through
    /// `enqueueDeckWork`. It cannot interleave with `start()`,
    /// `apply(options:)`, or an in-flight exhaustion extension.
    private func scheduleLibraryChangeHandling() {
        libraryChangeTask?.cancel()
        libraryChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }

            // Nothing here, including the video-index rebuild inside
            // `refreshIndex()`, may run while Photos is the active mode.
            // Wait for Videos to be current again. One run then covers
            // everything that happened while away, the same contract
            // `PhotoImagePipeline.suspend()` and `resume()` already keep
            // on the photo side.
            while AppModeStore.shared.mode != .videos {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled else { return }

            // Floor the spacing between real reconciliations. A burst of
            // PhotoKit notifications is routine during an iCloud sync. It
            // must coalesce into at most one run per interval, not one
            // per notification that survives the 300 ms debounce above.
            let elapsed = Date().timeIntervalSince(self.lastLibraryChangeRun)
            if elapsed < Self.libraryChangeMinInterval {
                try? await Task.sleep(nanoseconds: UInt64((Self.libraryChangeMinInterval - elapsed) * 1_000_000_000))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled else { return }

            self.lastLibraryChangeRun = Date()
            self.enqueueDeckWork { [weak self] in
                await self?.performLibraryChange()
            }
        }
    }

    private func performLibraryChange() async {
        // One enumeration feeds the index, the resolver's library
        // snapshot, and the resolver's filter-exclusion set. The filter
        // set can never go stale behind a library change.
        await refreshIndex()
        let ids = index.map(\.id)
        let idsSet = Set(ids)

        // Under `.limited` access, `idsSet` is only the user-selected
        // subset. Treating "not in `idsSet`" as "gone" would drop a
        // merely hidden video from the deck. The next full enumeration
        // would treat it as an exception that never returns.
        // `refreshIndex()` above already refreshed the pool counts, which
        // are accurate for the visible subset, so stop here: no deck
        // rebuild, no exception, no `DeckOrder` write. A hidden asset is
        // not a gone asset.
        guard library.authStatus == .authorized else {
            return
        }

        let excluded: Set<String> = Set(ids.filter { !resolver.isEligible($0) })

        // A date sort rebuilds its whole filtered, ordered list from the
        // fresh index on every library change. It needs no exceptions and
        // no cycle append, since a sorted deck keeps no cycle log to
        // inform.
        if isSortedMode {
            // The random path below applies the same guard, for the same
            // reason. A favorite toggle or an iCloud sync tick must not
            // re-identify every DeckEntry and drop the pager's anchor.
            let eligible = index.filter { resolver.isEligible($0.id) }.map(\.id)
            let known = Set(deck.map(\.assetID))
            let vanished = deck.contains { !idsSet.contains($0.assetID) }
            let added = eligible.contains { !known.contains($0) }
            guard vanished || added else { return }
            rebuildSortedDeck(
                resumeAssetID: deck.indices.contains(currentIndex) ? deck[currentIndex].assetID : readSortedCursor()
            )
            return
        }

        // Drop slots whose asset really left the library, so a dead id
        // does not sit in the deck as a permanently black page. Every
        // other slot keeps its place, including the lookahead past the
        // current page. A trash-queued asset actually deleted through
        // `TrashService.emptyBin()` leaves the same way: it drops out of
        // `idsSet` and is filtered here like any other vanished asset.
        let survivors = deck.filter { idsSet.contains($0.assetID) }
        // Each vanished slot is recorded as an exception, the same
        // append-only path a like or a trash tap takes. The launch replay
        // then drops exactly these slots, instead of re-dealing a dead id
        // into a permanently black page.
        let vanished = deck.filter { !idsSet.contains($0.assetID) }

        // Anything imported since the deck was dealt goes on the end. A
        // video recorded while the app is open is reachable without
        // waiting for a relaunch. Liked and trash-queued ids are excluded
        // even if new, matching every other cycle-building path.
        //
        // "Not currently in `deck`" is not the same as "never shown".
        // Every launch's `trimConsumedHistory()` deliberately drops the
        // consumed head of the deck, so an already-watched id routinely
        // sits outside `deck` while still being fully seen. This filter
        // also excludes ids in the seen-history table. An unrelated
        // library change, such as an iCloud sync tick, cannot re-append
        // the whole trimmed history as if it were freshly imported. That
        // would break the no-repeat-until-a-full-pass rule.
        let known = Set(deck.map(\.assetID))
        // Reads seen history on `SeenStore`'s own background actor,
        // instead of on the main actor.
        let seenKeys = await seenStore.seenKeys(limitedTo: idsSet)
        let added = ids.filter {
            !known.contains($0) && !excluded.contains($0) && !seenKeys.contains($0) && resolver.isEligible($0)
        }

        // PhotoKit posts a change notification for edits that touch
        // nothing in this deck. Examples are a toggled favorite, a
        // renamed album, or a routine iCloud sync. Rebuilding on those
        // would cost the user their place in the feed.
        guard !vanished.isEmpty || !added.isEmpty else { return }

        let state = deckState ?? fetchOrCreateDeckState()
        deckState = state
        let order = deckOrder ?? fetchOrCreateDeckOrder()
        deckOrder = order

        // Pin the visible page by its own slot, not by its asset id. The
        // same video legitimately occupies one slot per reshuffle cycle.
        // An asset-id match would find the first of those and rewind the
        // user a whole cycle. Only fall forward to the next
        // surviving slot when that exact slot is gone, meaning the video
        // in view was the one deleted. Absolute slot numbers make both
        // cases one search.
        let previousPosition = deck.indices.contains(currentIndex) ? deck[currentIndex].position : 0

        appendExceptions(slots: vanished.map(\.position), ids: vanished.map(\.assetID), to: order)

        var newDeck = survivors
        if !added.isEmpty {
            let seed = UInt64.random(in: UInt64.min...UInt64.max)
            let shuffled = ShuffleEngine.permutation(of: added, seed: seed)
            newDeck.append(contentsOf: appendLiteralCycle(shuffled, to: order))
            state.seed = Int64(bitPattern: seed)
        }

        let newCursor = newDeck.firstIndex { $0.position >= previousPosition } ?? max(newDeck.count - 1, 0)

        deck = newDeck
        currentIndex = min(max(newCursor, 0), max(newDeck.count - 1, 0))
        refreshPreloadableSlots()
        currentEntryID = deck.indices.contains(currentIndex) ? deck[currentIndex].id : nil
        // The tail changed shape, so an earlier extension of the old end
        // slot says nothing about the new one. Leaving it set could leave
        // a rebuilt deck unable to extend, and stop the feed at its
        // last page.
        lastExtendedPosition = nil

        // Still a monotonic high-water mark: the deck lost slots, but the
        // user did not un-watch anything.
        if deck.indices.contains(currentIndex) {
            state.cursor = max(state.cursor, deck[currentIndex].position)
        }

        saveDeck()
    }

    /// Appends anything imported since the deck was last saved as a
    /// literal cycle. A video recorded while the app was closed is
    /// reachable without waiting for a relaunch.
    ///
    /// These ids come from no seed, so they cannot be regenerated: they
    /// are stored verbatim. The stored count is bounded by imports since
    /// the deal, typically zero. A bulk import large enough to matter
    /// changes the pool, and forces a full rebuild through the digest
    /// guard anyway.
    private func mergeNewImports(
        order: DeckOrder,
        libraryIDs: [String],
        alreadyDealt: Set<String>,
        seenKeys: Set<String>
    ) {
        let newIDs = libraryIDs.filter {
            !alreadyDealt.contains($0) && !seenKeys.contains($0) && resolver.isEligible($0)
        }
        guard !newIDs.isEmpty else { return }
        let seed = UInt64.random(in: UInt64.min...UInt64.max)
        let shuffled = ShuffleEngine.permutation(of: newIDs, seed: seed)
        deck.append(contentsOf: appendLiteralCycle(shuffled, to: order))
    }

    // MARK: - Deck order persistence
    //
    // Every `DeckOrder` write to the cycle-log and exception arrays goes
    // through the four methods below. Each one increments
    // `DeckWriteCounters` by the exact number of elements it wrote, so
    // the probe reports work done, not calls made. "A tap writes O(1)"
    // is machine-checkable rather than code-read. `DeckOrder.ids` is
    // written nowhere except `migrateIfNeeded`, and only ever assigned an
    // empty array.

    /// Records one dealt cycle and advances the absolute slot allocator.
    /// `literalIDs` is `nil` for a seeded cycle, the ordinary case, and
    /// holds the verbatim ids for a literal one.
    private func appendCycle(
        seed: UInt64,
        baseSlot: Int,
        count: Int,
        digest: String,
        swaps: String,
        literalIDs: [String]?,
        to order: DeckOrder
    ) {
        order.cycleSeeds.append(Int64(bitPattern: seed))
        order.cycleBaseSlots.append(baseSlot)
        order.cycleCounts.append(count)
        order.cycleDigests.append(digest)
        order.cycleSwaps.append(swaps)
        order.cycleIsLiteral.append(literalIDs != nil)
        if let literalIDs {
            order.literalIDs.append(contentsOf: literalIDs)
        }
        order.nextSlot = baseSlot + count
        #if DEBUG
        // seed, baseSlot, count, isLiteral, nextSlot
        DeckWriteCounters.ints += 5
        DeckWriteCounters.idStrings += 2 + (literalIDs?.count ?? 0)
        #endif
    }

    /// Claims a slot range for ids no seed produced, and returns the
    /// entries for them. Consecutive literal appends coalesce into one
    /// record. Every shrink save posts a library change, so a session
    /// that shrinks repeatedly would otherwise grow the cycle log one
    /// record at a time.
    private func appendLiteralCycle(_ ids: [String], to order: DeckOrder) -> [DeckEntry] {
        guard !ids.isEmpty else { return [] }
        let baseSlot = order.nextSlot

        if let last = order.cycleSeeds.indices.last,
           order.cycleIsLiteral.count == order.cycleSeeds.count,
           order.cycleCounts.count == order.cycleSeeds.count,
           order.cycleBaseSlots.count == order.cycleSeeds.count,
           order.cycleIsLiteral[last],
           order.cycleBaseSlots[last] + order.cycleCounts[last] == baseSlot {
            order.cycleCounts[last] += ids.count
            order.literalIDs.append(contentsOf: ids)
            order.nextSlot = baseSlot + ids.count
            #if DEBUG
            DeckWriteCounters.ints += 2
            DeckWriteCounters.idStrings += ids.count
            #endif
        } else {
            appendCycle(
                seed: 0,
                baseSlot: baseSlot,
                count: ids.count,
                digest: "",
                swaps: "",
                literalIDs: ids,
                to: order
            )
        }
        return entries(for: ids, baseSlot: baseSlot)
    }

    /// The hot-path write: one `Int` and one `String` per removed slot.
    private func appendExceptions(slots: [Int], ids: [String], to order: DeckOrder) {
        guard !slots.isEmpty, slots.count == ids.count else { return }
        order.exceptionSlots.append(contentsOf: slots)
        order.exceptionIDs.append(contentsOf: ids)
        #if DEBUG
        DeckWriteCounters.ints += slots.count
        DeckWriteCounters.idStrings += ids.count
        #endif
    }

    /// Drops every leading cycle that ends below `boundary`, together with
    /// its exceptions and its literal ids. This keeps the cycle log
    /// bounded however long the session runs.
    ///
    /// A bound of three seeded cycles holds naturally, since a seeded
    /// cycle is only appended at a true exhaustion. It does not hold for
    /// literal ones. `performLibraryChange` appends one on every burst
    /// that brings new ids, and a shrink save is exactly such a burst.
    /// Coalescing, see `appendLiteralCycle`, plus this prune keeps the
    /// count small. The bound is enforced by construction, through
    /// pruning, rather than by an assertion that could crash mid-session.
    private func pruneConsumedCycles(order: DeckOrder, boundary: Int) {
        let cycleCount = order.cycleSeeds.count
        guard cycleCount > 1,
              order.cycleBaseSlots.count == cycleCount,
              order.cycleCounts.count == cycleCount,
              order.cycleDigests.count == cycleCount,
              order.cycleSwaps.count == cycleCount,
              order.cycleIsLiteral.count == cycleCount
        else { return }

        // Cycles are appended in slot order, so only a prefix is ever
        // consumed. The newest cycle is never dropped, so the log always
        // holds at least one cycle.
        var firstKept = 0
        var droppedLiteralIDs = 0
        while firstKept < cycleCount - 1,
              order.cycleBaseSlots[firstKept] + order.cycleCounts[firstKept] <= boundary {
            if order.cycleIsLiteral[firstKept] {
                droppedLiteralIDs += order.cycleCounts[firstKept]
            }
            firstKept += 1
        }
        guard firstKept > 0 else { return }

        let minSlot = order.cycleBaseSlots[firstKept]
        order.cycleSeeds.removeFirst(firstKept)
        order.cycleBaseSlots.removeFirst(firstKept)
        order.cycleCounts.removeFirst(firstKept)
        order.cycleDigests.removeFirst(firstKept)
        order.cycleSwaps.removeFirst(firstKept)
        order.cycleIsLiteral.removeFirst(firstKept)
        if droppedLiteralIDs > 0 {
            order.literalIDs.removeFirst(min(droppedLiteralIDs, order.literalIDs.count))
        }

        if order.exceptionSlots.count == order.exceptionIDs.count {
            var keptSlots: [Int] = []
            var keptIDs: [String] = []
            for i in order.exceptionSlots.indices where order.exceptionSlots[i] >= minSlot {
                keptSlots.append(order.exceptionSlots[i])
                keptIDs.append(order.exceptionIDs[i])
            }
            order.exceptionSlots = keptSlots
            order.exceptionIDs = keptIDs
        }

        #if DEBUG
        DeckWriteCounters.ints += order.cycleSeeds.count * 4 + order.exceptionSlots.count
        DeckWriteCounters.idStrings += order.cycleSeeds.count * 2 + order.literalIDs.count + order.exceptionIDs.count
        #endif
    }

    /// The one place the deck commits to SwiftData. Applies whatever
    /// cursor write the page-change tick deferred first, so a deck save
    /// can never commit a stale cursor.
    private func saveDeck() {
        applyPendingCursorValue()
        try? modelContext.save()
        #if DEBUG
        DeckWriteCounters.saves += 1
        #endif
    }

    // MARK: - Main-thread discipline

    /// Every deck rebuild that needs a library enumeration suspends. See
    /// the comment on `deckWork` for why two could interleave and leave
    /// the deck half-rebuilt. This FIFO queue makes that impossible.
    /// Returns the chained `Task`, so a caller that needs the work's side
    /// effects observed before it continues, such as
    /// `pageBecameCurrent`'s extension attempt, can await `.value`.
    @discardableResult
    private func enqueueDeckWork(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = deckWork
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        deckWork = task
        return task
    }

    /// The assignment half of `flushPendingWrites()`, split out so
    /// `saveDeck()` can apply a pending cursor value without also calling
    /// its own `modelContext.save()`. The caller's save commits it, which
    /// keeps `saveDeck()`'s `DeckWriteCounters.saves` bookkeeping at
    /// exactly one per save.
    private func applyPendingCursorValue() {
        if let id = pendingSortedCursorAssetID {
            UserDefaults.standard.set(id, forKey: Self.sortedCursorKey)
            pendingSortedCursorAssetID = nil
        }
        guard let pendingCursor else { return }
        self.pendingCursor = nil
        let state = deckState ?? fetchOrCreateDeckState()
        deckState = state
        guard pendingCursor > state.cursor else { return }
        state.cursor = pendingCursor
    }

    private func scheduleCursorFlush() {
        cursorFlushTask?.cancel()
        cursorFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.cursorFlushDelay)
            guard !Task.isCancelled else { return }
            self?.flushPendingWrites()
        }
    }

    /// Applies and commits everything the page-change tick deferred.
    /// Called by the flush task, and by `FeedView` when the scene leaves
    /// `.active`.
    func flushPendingWrites() {
        cursorFlushTask?.cancel()
        cursorFlushTask = nil
        applyPendingCursorValue()
        try? modelContext.save()
    }

    // MARK: - Deck reconstruction

    /// Replays the persisted cycle log into a deck, or returns `nil` when
    /// it cannot be replayed exactly. When it returns `nil`, `start()`
    /// deals a fresh cycle instead.
    ///
    /// A seeded cycle's input was `libraryIDs.filter { !excluded }` at
    /// deal time. A like, a trash queue, or an asset leaving the library
    /// excludes everything since then. This deck records each exclusion
    /// by appending its id to `exceptionIDs`. Adding those ids back
    /// reproduces the deal-time pool exactly, in
    /// the same creation-date order, because the filter preserves
    /// `libraryIDs`' order. The digest then proves the reproduction is
    /// correct, rather than assuming it. An unlike, a restore, a
    /// deletion while the app was closed, or any error in this
    /// reconstruction forces a rebuild instead of a wrong order. A
    /// rebuild costs one fresh cycle and the scroll position. It never
    /// costs seen history, a shield, or a queued row.
    private func rebuildDeck(order: DeckOrder, libraryIDs: [String]) -> [DeckEntry]? {
        let cycleCount = order.cycleSeeds.count
        guard cycleCount > 0,
              order.cycleBaseSlots.count == cycleCount,
              order.cycleCounts.count == cycleCount,
              order.cycleDigests.count == cycleCount,
              order.cycleSwaps.count == cycleCount,
              order.cycleIsLiteral.count == cycleCount,
              order.exceptionSlots.count == order.exceptionIDs.count
        else { return nil }

        let libraryIDSet = Set(libraryIDs)
        let exceptionSlotSet = Set(order.exceptionSlots)
        var entries: [DeckEntry] = []
        var literalCursor = 0

        for k in 0..<cycleCount {
            let base = order.cycleBaseSlots[k]
            let count = order.cycleCounts[k]
            guard count >= 0 else { return nil }
            var cycleIDs: [String]

            if order.cycleIsLiteral[k] {
                guard literalCursor + count <= order.literalIDs.count else { return nil }
                cycleIDs = Array(order.literalIDs[literalCursor..<(literalCursor + count)])
                literalCursor += count
                // A literal cycle has no seed to check it against, so
                // its ids are checked directly. Without this check, one
                // that left the library while the app was closed would
                // sit in the deck as a permanently black page.
                guard cycleIDs.allSatisfy({ libraryIDSet.contains($0) }) else { return nil }
            } else {
                var reinstated = Set<String>()
                for i in order.exceptionSlots.indices {
                    let slot = order.exceptionSlots[i]
                    if slot >= base && slot < base + count {
                        reinstated.insert(order.exceptionIDs[i])
                    }
                }
                var input = libraryIDs.filter { resolver.isEligible($0) || reinstated.contains($0) }
                // Tolerates a pure addition to the library since this
                // cycle was dealt. This is the common case of a video
                // recorded or imported while the app was closed.
                // `libraryIDs` is creation-date ascending. A newly added
                // id, almost always the newest content on the device,
                // lands at the tail of this filtered array. That is the
                // same place it lands in `libraryIDs` itself.
                //
                // If trimming exactly the excess off the tail reproduces
                // a digest match, the remainder is this cycle's exact
                // deal-time pool. The trimmed ids are new:
                // `mergeNewImports`, called on this method's success
                // path, appends them as the literal cycle it exists for.
                //
                // If the trim does not restore the digest, the excess is
                // not a clean tail append, such as an old-dated backup
                // restore. This falls through to `nil`, so an unlike, a
                // restore, or a deletion always forces a rebuild.
                if input.count > count {
                    input = Array(input.prefix(count))
                }
                guard input.count == count,
                      ShuffleEngine.digest(of: input) == order.cycleDigests[k]
                else { return nil }
                cycleIDs = ShuffleEngine.permutation(of: input, seed: UInt64(bitPattern: order.cycleSeeds[k]))
                ShuffleEngine.applySwaps(decodeSwaps(order.cycleSwaps[k]), to: &cycleIDs)
            }

            for (offset, id) in cycleIDs.enumerated() {
                let slot = base + offset
                if slot < order.trimmedBeforeSlot { continue }
                if exceptionSlotSet.contains(slot) { continue }
                entries.append(DeckEntry(assetID: id, position: slot))
            }
        }

        guard !entries.isEmpty else { return nil }
        // Absolute slots are allocated once and never reused, so the
        // allocator can only ever move forward.
        order.nextSlot = max(order.nextSlot, (entries[entries.count - 1].position) + 1)
        return entries
    }

    /// A one-time reset. A legacy `ids` blob cannot be converted, because
    /// no seed produces it: `removeFromFuture` edited the array after the
    /// deal. `DeckState.cursor` also changes from an array index to an
    /// absolute slot, so carrying it forward would point at the wrong
    /// video.
    ///
    /// The seen-history table, `LikedEntry`, and `TrashEntry` are not
    /// touched. The user keeps their shields, their queue, and their seen
    /// history. They lose only their exact scroll position, once.
    private func migrateIfNeeded(order: DeckOrder, state: DeckState) {
        guard order.schemaVersion == 0 else { return }
        order.ids = []
        order.schemaVersion = 1
        order.cycleSeeds = []
        order.cycleBaseSlots = []
        order.cycleCounts = []
        order.cycleDigests = []
        order.cycleSwaps = []
        order.cycleIsLiteral = []
        order.literalIDs = []
        order.exceptionSlots = []
        order.exceptionIDs = []
        order.trimmedBeforeSlot = 0
        order.nextSlot = 0
        state.cursor = 0
        saveDeck()
    }

    // MARK: - Helpers

    /// Builds entries for `ids` over the slot range starting at
    /// `baseSlot`. Slot numbers come from `DeckOrder.nextSlot`, which is
    /// persisted and only ever incremented. A slot dealt in this call
    /// can never collide with one already on screen or with one dealt in
    /// an earlier session.
    private func entries(for ids: [String], baseSlot: Int) -> [DeckEntry] {
        ids.enumerated().map { DeckEntry(assetID: $1, position: baseSlot + $0) }
    }

    /// Encodes seam-guard swaps as comma-separated `from>to` pairs, for
    /// example "3>17,5>21". Empty when the guard made no swaps.
    private func encodeSwaps(_ swaps: [(Int, Int)]) -> String {
        swaps.map { "\($0.0)>\($0.1)" }.joined(separator: ",")
    }

    private func decodeSwaps(_ encoded: String) -> [(Int, Int)] {
        guard !encoded.isEmpty else { return [] }
        return encoded.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: ">")
            guard parts.count == 2, let from = Int(parts[0]), let to = Int(parts[1]) else { return nil }
            return (from, to)
        }
    }

    private func fetchOrCreateDeckState() -> DeckState {
        #if DEBUG
        FetchCounters.swiftData += 1
        #endif
        if let existing = try? modelContext.fetch(FetchDescriptor<DeckState>()).first {
            return existing
        }
        let state = DeckState()
        modelContext.insert(state)
        return state
    }

    /// Recomputes `preloadableSlots` from `currentIndex`, over the
    /// array-index window `currentIndex - 1 ... currentIndex + 1`, clamped
    /// to `deck`'s bounds. Stores each surviving entry's `position`,
    /// rather than the index itself. Call this at every site that assigns
    /// `currentIndex`.
    private func refreshPreloadableSlots() {
        guard !deck.isEmpty else {
            preloadableSlots = []
            refreshWarmWindow()
            return
        }
        let lower = max(0, currentIndex - 1)
        let upper = min(deck.count - 1, currentIndex + 1)
        guard lower <= upper else {
            preloadableSlots = []
            refreshWarmWindow()
            return
        }
        preloadableSlots = Set(deck[lower...upper].map(\.position))

        refreshWarmWindow()
    }

    /// Poster prefetch for the whole warm window, and item resolution for
    /// the slots the render window does not already cover. Both calls are
    /// fire-and-forget: nothing here suspends, so nothing here can hold
    /// the main actor.
    ///
    /// The warm window reaches two slots ahead. No player mounts for a
    /// warm-only slot, so players stay limited to ±1.
    private func refreshWarmWindow() {
        wdMark("warmWindow")
        // This runs off the pager's position change, so it can fire
        // mid-swipe, before the pager settles. Poster and item cache
        // work waits for idle. Only one deferred refresh is pending at a
        // time, and it re-reads the deck when it fires.
        if ScrollPhaseGate.shared.isScrolling {
            guard !warmWindowRefreshPending else { return }
            warmWindowRefreshPending = true
            Task { @MainActor [weak self] in
                await ScrollPhaseGate.shared.waitUntilIdle()
                guard let self else { return }
                self.warmWindowRefreshPending = false
                self.refreshWarmWindow()
            }
            return
        }
        guard !deck.isEmpty else {
            PosterCache.shared.setWindow([])
            PlayerItemCache.shared.setWindow([], starting: [], allowNetwork: false)
            return
        }
        let lower = max(0, currentIndex - 1)
        let upper = min(deck.count - 1, currentIndex + 2)
        guard lower <= upper else { return }
        let warm = deck[lower...upper]
        PosterCache.shared.setWindow(warm.map(\.assetID))
        // Only the slots `load()` will not resolve for itself. Resolving
        // an id twice would download it twice.
        let warmOnly = warm.filter { !preloadableSlots.contains($0.position) }.map(\.assetID)
        // `assetIDs` is the retain set: the whole warm window. An id
        // that just entered the render window is not cancelled or
        // evicted out from under `load()`'s own `take()`. `starting` is
        // only the slots `load()` will not resolve for itself.
        PlayerItemCache.shared.setWindow(
            warm.map(\.assetID),
            starting: warmOnly,
            allowNetwork: !library.isNetworkExpensiveOrConstrained
        )
    }

    /// See `refreshWarmWindow`.
    private var warmWindowRefreshPending = false

    private func fetchOrCreateDeckOrder() -> DeckOrder {
        #if DEBUG
        FetchCounters.swiftData += 1
        #endif
        if let existing = try? modelContext.fetch(FetchDescriptor<DeckOrder>()).first {
            return existing
        }
        let order = DeckOrder()
        modelContext.insert(order)
        return order
    }
}
