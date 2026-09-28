//
//  PhotoDeck.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Combine
import SwiftData
import Photos

/// One slot in the shuffled photo deck.
///
/// `position` matches `DeckEntry.position` in `DeckViewModel`: it is an
/// absolute slot number, assigned once and never reused. The slot number
/// stays stable across reshuffles and library edits, even when the index of
/// the entry in `entries` changes.
struct PhotoDeckEntry: Identifiable, Hashable {
    let assetID: String
    let position: Int
    /// Milliseconds since epoch, or -1 when the asset has no creation date.
    /// Comes straight from `PhotoWindowItem.createdMs`. The entry stores
    /// this value itself, not in a side dictionary, so it survives
    /// `pruneHistory` the same way `assetID` and `position` do. The cost is
    /// one Int64 per entry, small next to `maxEntries` (200).
    let createdMs: Int64
    /// Stored, not computed. See `DeckEntry.id` for why this matters to
    /// `ForEach`'s diffing cost on a large deck.
    let id: String

    init(assetID: String, position: Int, createdMs: Int64) {
        self.assetID = assetID
        self.position = position
        self.createdMs = createdMs
        self.id = "\(position)_\(assetID)"
    }
}

/// Deals photos from the library in random order, with seen memory so each
/// photo shows once before any repeat.
///
/// `PhotoLibraryPool` holds the library as a lazy `PHFetchResult`. Dealing
/// samples a window of `windowSize` unseen photos at random indices from
/// that result. It extends by another window once the user is within
/// `extendThreshold` of the end.
///
/// Dealing never enumerates the whole library. A full enumeration costs
/// seconds on a very large library. Holding the whole library in `entries`
/// also forces `PhotoFeedView`'s `ForEach` to re-diff tens of thousands of
/// rows on every geometry change. That is a measured 791 ms main-thread
/// stall.
///
/// Unlike the video deck (`DeckViewModel`), this deck does not persist a
/// replayable cycle (a seed, a digest, and a swap log). Replaying a cycle
/// would need the exact whole-library array that the window-based deal
/// avoids building. A random deck has nothing a user can notice about the
/// difference, so a relaunch deals a fresh window instead.
///
/// `PhotoDeckState` keeps `seed`, `cursor`, and `nextSlot` so slot numbers
/// stay monotonic across launches. This deck does not replay a cycle from
/// them. The video deck replays its cycle. Each photo shows once before any
/// repeat.
///
/// Seen memory is the SwiftData id set `PhotoSeenEntry`: a window never
/// deals an id that is seen or already dealt this cycle. A cycle ends when
/// a full sweep of the pool finds nothing to deal, or when the pool's
/// consumed count reaches `poolCount`. The end of a cycle clears seen
/// memory. Both tests are O(1) and never search the library.
///
/// This deck reads `AssetKeyResolver.shared`'s `isShielded` and `isQueued`
/// sets directly. It does not use `isEligible` or `isExcluded`. Those two
/// intersect against the resolver's video library snapshot, and would
/// silently exclude nothing for a photo id that is not in that snapshot. A
/// kept photo and a kept video share the same `LikedEntry` table and the
/// same `shieldedIDs` set. Reading those sets directly is correct for
/// either kind of media.
@MainActor
final class PhotoDeck: ObservableObject {
    static let shared = PhotoDeck()

    @Published private(set) var entries: [PhotoDeckEntry] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var currentEntryID: String?
    @Published private(set) var hasDealtFirstDeck = false
    /// Library photos minus kept minus queued, shown as `photo_pool_<n>`.
    /// `PHFetchResult.count` is O(1), so this never walks the library. The
    /// subtraction needs the id snapshot, and becomes exact the moment the
    /// background job in `scheduleBinPhotoIDRefresh` completes.
    @Published private(set) var poolCount: Int = 0
    /// Counts up each time `pruneHistory` removes leading entries, so
    /// `PhotoFeedView` can re-anchor its scroll the same way it does after a
    /// queued-page prune. Nothing else changes this value.
    @Published private(set) var historyPruneNonce = 0
    /// Posts crushed away by a delete, and the height each one keeps.
    ///
    /// A post whose top has scrolled off screen crushes only until its
    /// bottom edge meets the top of the scroll view, never past it. The
    /// kept height is exactly the part that was already above the screen.
    /// The content above the viewport does not move, so the scroll view
    /// has nothing to clamp. A fully visible post keeps a height of 0.
    ///
    /// The row itself is never removed. Removing a row makes the list
    /// recompute sizes for unmounted rows above, and the correction then
    /// arrives a frame late, which shows as a jump.
    ///
    /// This dictionary lives on the deck, not in the post's `@State`,
    /// because a `LazyVStack` unmounts rows that scroll far away. View
    /// state stored there would be lost, and the post would return at full
    /// height. A wholesale re-deal clears this dictionary.
    @Published private(set) var collapsedHeights: [String: CGFloat] = [:]
    /// True from the instant the app accepts a filter change until it deals
    /// a fresh window.
    ///
    /// The re-deal runs asynchronously, and `entries` is empty until the
    /// new window is dealt. `PhotoFeedView` reads this flag to show a
    /// loading state, not the "no photos match" state, during that time.
    @Published private(set) var isReloadingForFilters = false
    /// True once a pass under "On this date" reaches its end. The feed
    /// shows a "done for today" card as its last row instead of re-dealing —
    /// one pass, then a final card, never a loop. A filter change or a
    /// refresh resets this flag.
    @Published private(set) var isDoneForToday = false

    private init() {}

    private let resolver = AssetKeyResolver.shared
    private let pool = PhotoLibraryPool.shared
    private var modelContext: ModelContext?
    private var seenStore: PhotoSeenStore?
    private var deckState: PhotoDeckState?
    private var didStart = false
    private var activeOptions: PhotoOptions = .default
    /// True for either date sort, false for Random. Many paths read this
    /// value. A computed property over `activeOptions` cannot disagree with
    /// it, and a second stored flag can.
    private var isSortedMode: Bool { activeOptions.sort != .random }
    /// The next `PHFetchResult` index a sorted deal pages from. Do not
    /// persist this value: a relaunch always restarts a date sort at the
    /// top. `dealSortedWindow` resets it to 0 on every `replacingDeck: true`
    /// deal. A launch, an options change, and a pull-to-refresh each make
    /// such a deal.
    private var sortedNextIndex = 0
    /// The last asset id a sorted deal dealt. Read only by
    /// `resyncSortedIndex()`, after a real library change. See that method.
    private var lastDealtSortedAssetID: String?

    /// `PHFetchResult.count`. Each deal, a remount, and an external library
    /// change update this value. The read is O(1).
    private var assetCount: Int = 0
    /// The kept or queued ids that still name a live photo, not the whole
    /// library. See `scheduleBinPhotoIDRefresh`.
    private var photoIDSnapshot: Set<String> = []
    private var binIDsTask: Task<Void, Never>?
    private var binIDsDirty = false
    /// Seeds `PhotoLibraryPool`'s consumed set from `PhotoSeenEntry`. Runs
    /// alongside the first deal, never before it. See `performStart`.
    private var seenLoadTask: Task<Void, Never>?
    /// The value the `photo_seen_probe_` UI-test probe reports. Stored, not
    /// queried, because a view body reads it. A `fetchCount` there would
    /// run a SwiftData aggregate on every body pass, against a table that
    /// holds one row per photo the user has seen.
    private var seenRowEstimate = 0

    /// Deduplicates writes to the seen table only. Bounded by how many
    /// photos the user looked at this session, not by the library size.
    /// The cycle's full consumed set lives on `PhotoLibraryPool`, off the
    /// main actor.
    private var markedSeenThisSession: Set<String> = []
    private var seenWork: Task<Void, Never>?
    /// One FIFO queue, so a `start()` remount reconcile and an
    /// `apply(options:)` re-deal can never interleave and leave the deck
    /// half-rebuilt. Same reasoning as `DeckViewModel.enqueueDeckWork`.
    private var deckWork: Task<Void, Never>?
    private var extensionTask: Task<Void, Never>?
    private var lastExtendedPosition: Int?

    private var pendingCursor: Int?
    private var cursorFlushTask: Task<Void, Never>?
    private static let cursorFlushDelay: UInt64 = 1_000_000_000

    /// The number of photos one deal adds to the deck.
    private let windowSize = 60
    /// Extends the deck once the current index is this close to the last
    /// entry. The window deals early enough to warm its images before the
    /// user scrolls into it. It deals late enough that a short visit
    /// needs only one extension.
    private let extendThreshold = 15
    /// Same bound and reasoning as `DeckViewModel.historyWindow`. A photo
    /// library is usually much larger than a video library, so this bound
    /// is more important here.
    private let historyWindow = 20
    /// Hard ceiling on `entries`. Reached only after a very long
    /// single-session scroll, since every extension adds `windowSize`. A
    /// forced prune on a mode-switch remount (`reconcileAfterRemount`)
    /// normally keeps the deck far below it. See `pruneHistory` for why
    /// this is not simply `historyWindow + windowSize`.
    private let maxEntries = 200

    // MARK: - Deck construction

    func start(modelContext: ModelContext) {
        enqueueDeckWork { [weak self] in
            await self?.performStart(modelContext: modelContext)
        }
    }

    private func performStart(modelContext: ModelContext) async {
        guard !didStart else {
            await reconcileAfterRemount()
            return
        }
        let dealStarted = Date()
        defer {
            hasDealtFirstDeck = true
            Usage.shared.firstDeal(mode: .photos, ms: Int(Date().timeIntervalSince(dealStarted) * 1000))
        }
        didStart = true
        self.modelContext = modelContext
        self.seenStore = PhotoSeenStore(modelContainer: modelContext.container)
        lastExtendedPosition = nil

        let state = fetchOrCreateDeckState()
        deckState = state
        purgeLegacyCycleLog(state)

        // Apply the saved filters and sort direction before the first
        // fetch. Then a launch never deals an unfiltered or wrongly
        // ordered window and replaces it on screen.
        activeOptions = PhotoOptionsStore.shared.options
        await pool.setFilterPredicate(activeOptions.filters.fetchPredicate)
        await pool.setSort(ascending: activeOptions.sort != .dateNewest)

        // O(1) on the library: a lazy fetch plus its count. This is the
        // entire startup PhotoKit cost.
        assetCount = await pool.refresh()
        refreshPoolCount()

        // Both calls run alongside the first deal, never in front of it.
        // The seen-table read grows with the library and can delay the
        // first photo by seconds. See `scheduleSeenLoad` for what the
        // first window gives up by not waiting for it.
        scheduleSeenLoad()
        scheduleBinPhotoIDRefresh()

        await dealWindow(replacingDeck: true)
    }

    /// One-time cleanup of the old, pre-window persisted cycle log.
    ///
    /// The old cycle log stored, per reshuffle, a digest and a swap list.
    /// It also stored one exception slot per removed photo, and the
    /// literal ids of every merged import.
    ///
    /// On a large library these arrays can grow to the size of the
    /// library. SwiftData loads them when the launch path fetches
    /// `PhotoDeckState`, and no code reads them. Emptying them once
    /// removes that load permanently. The properties stay on the model,
    /// since the schema is CloudKit-shaped and dropping them would need a
    /// migration for no gain.
    private func purgeLegacyCycleLog(_ state: PhotoDeckState) {
        guard state.schemaVersion < 2 else { return }
        state.cycleSeeds = []
        state.cycleBaseSlots = []
        state.cycleCounts = []
        state.cycleDigests = []
        state.cycleSwaps = []
        state.cycleIsLiteral = []
        state.literalIDs = []
        state.exceptionSlots = []
        state.exceptionIDs = []
        state.schemaVersion = 2
        try? modelContext?.save()
    }

    /// Reads the seen table into the pool's consumed set, off the main
    /// actor, without the first deal waiting for it.
    ///
    /// The pool samples the first window before `scheduleSeenLoad` loads the
    /// seen set.
    /// After a relaunch in the middle of a cycle, the first window can
    /// show again some photos that the user saw. The maximum is one
    /// window, out of a library that can hold hundreds of thousands. Every
    /// later window rejects the full seen set. The alternative, blocking
    /// the first photo on a table read that grows with the library, is
    /// worse.
    private func scheduleSeenLoad() {
        guard seenLoadTask == nil, let seenStore else { return }
        seenLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let keys = await seenStore.allSeenKeys()
            // Seed the set on the pool actor, not the main actor. The set
            // holds one string per photo in the pool. Hashing it into a
            // main-actor set would mean hundreds of thousands of
            // insertions on the main thread during launch.
            await self.pool.seedConsumed(keys)
            self.seenRowEstimate = keys.count
            self.seenLoadTask = nil
        }
    }

    /// Runs when `start()` runs again on an already-started instance.
    /// `PhotoFeedView` remounts every time the chin navigation switches
    /// back to Photos, the same as `FeedView`'s own remount path.
    ///
    /// This method re-deals only when the stored options changed, through
    /// `apply`. Otherwise it keeps the deck and the scroll position,
    /// refreshes the pool count, and prunes history while nothing is on
    /// screen.
    private func reconcileAfterRemount() async {
        // Applies options that changed while Photos was not mounted, such
        // as a notification tap that sets a filter and switches mode in
        // one call. `PhotoFeedView` can then mount already holding the new
        // options, so its `onChange` never fires. This call is the only
        // other thing that runs on that path.
        //
        // This runs here, not as `initial: true` on the view's watcher.
        // That also fires on a cold launch. `performStart` reads the same
        // options a moment later there, and the redundant apply would
        // stack an "Updating feed" pill over the "Loading" one. This
        // method sits behind `guard !didStart`, so it never runs on a
        // cold launch. `apply` refuses a no-op, so an ordinary remount
        // costs one comparison.
        apply(options: PhotoOptionsStore.shared.options)

        // Calls `count()`, not `refresh()`. A re-fetch makes Photos resolve
        // a sorted query over the whole library, which is slow on a large
        // library. `PhotoFeedView` remounts on every switch into Photos.
        // This reuses the existing fetch result. A real library change
        // comes back through `refreshPoolAfterExternalChange` below.
        assetCount = await pool.count()
        refreshPoolCount()
        scheduleBinPhotoIDRefresh()
        // A remount keeps the deck. Only an options change
        // (`apply(options:)`) or a pull-to-refresh deals a new window.
        pruneHistory(force: true)
    }

    // MARK: - Filters and sort

    /// Applies a full `PhotoOptions` change: filters and sort together. A
    /// sort change goes through the same drop-and-redeal path as a filter
    /// change. Switching to or from a date sort restarts paging at the top
    /// with no extra code. `dealWindow(replacingDeck: true)` always resets
    /// `sortedNextIndex` to 0 for a sorted deal. See `dealSortedWindow`.
    func apply(options newOptions: PhotoOptions) {
        guard newOptions != activeOptions else { return }
        activeOptions = newOptions
        // Both flags change now, on the tap, not when the deal completes.
        // The entries on screen no longer match what the user just asked
        // for. Leaving them up for the length of a PhotoKit fetch would
        // show stale results. Clearing `entries` also lets
        // `PhotoFeedView.content`'s existing empty and loading branches
        // handle this case without a second code path.
        isReloadingForFilters = true
        isDoneForToday = false
        entries = []
        currentIndex = 0
        currentEntryID = nil
        enqueueDeckWork { [weak self] in
            await self?.performApplyOptions()
        }
    }

    /// Pull-to-refresh on the photo feed. Runs the same re-fetch and
    /// re-deal an options change does, with the options unchanged. It
    /// picks up new photos, reshuffles a Random cycle or restarts a date
    /// sort at the top, and keeps seen history.
    ///
    /// Drops the entries at once, for the same reason `apply(options:)`
    /// does. It waits for the queued work, so the `.refreshable` spinner
    /// stops only when the new deck is dealt.
    func refresh() async {
        Usage.shared.pullRefresh(mode: .photos)
        isReloadingForFilters = true
        isDoneForToday = false
        entries = []
        currentIndex = 0
        currentEntryID = nil
        await enqueueDeckWork { [weak self] in
            await self?.performApplyOptions()
        }.value
    }

    private func performApplyOptions() async {
        guard modelContext != nil else { return }
        // Filtering is PhotoKit's job, not this type's. The pool gets the
        // filter as a fetch predicate, so `assetCount`, each sample, and
        // each cycle-end test use the filtered library. The pool also gets
        // the sort direction. Nothing else in this type needs to know
        // filters exist.
        await pool.setFilterPredicate(activeOptions.filters.fetchPredicate)
        await pool.setSort(ascending: activeOptions.sort != .dateNewest)
        assetCount = await pool.refresh()
        refreshPoolCount()
        await dealWindow(replacingDeck: true)
        // Now there is something real to show, including the "no photos
        // match" case. `PhotoFeedView.content` renders that from an empty
        // `entries` once this flag is false.
        isReloadingForFilters = false
    }

    // MARK: - Paging

    func pageBecameCurrent(_ pageID: String) {
        guard let index = entries.firstIndex(where: { $0.id == pageID }) else { return }
        currentIndex = index
        currentEntryID = entries[index].id
        triggerMetadataPrefetch()

        // A date sort must not write `state.cursor`, the high-water mark
        // of the Random resume. Photos keeps no sorted cursor.
        // `dealSortedWindow` has the same guard. The extension trigger
        // below runs in both modes.
        if !isSortedMode, let state = deckState {
            let position = entries[index].position
            if position > max(state.cursor, pendingCursor ?? Int.min) {
                pendingCursor = position
                scheduleCursorFlush()
            }
        }

        // Extend when the current index is within `extendThreshold` of the
        // tail. Then the next window and its images are ready before the
        // user reaches it. The latch permits one extension for each tail
        // position, the same latch `DeckViewModel.pageBecameCurrent` uses.
        if index >= entries.count - extendThreshold, let end = entries.last,
           lastExtendedPosition != end.position, extensionTask == nil {
            let position = end.position
            // The latch arms whether or not the deal produced anything. An
            // empty deal means nothing is left to deal from this tail.
            // Retrying on every settle would re-run a whole-pool sweep,
            // and at a cycle seam, a seen-table clear, on every swipe. The
            // latch re-arms on its own the moment the tail moves, which is
            // exactly when a retry could give a different answer.
            lastExtendedPosition = position
            extensionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.enqueueDeckWork {
                    await self.extendDeck()
                }.value
                self.extensionTask = nil
            }
        }
    }

    /// Prefetches tier 1 and tier 2 metadata (`PhotoMetadataPrefetcher`)
    /// for the previous two slots and the next six around `currentIndex`,
    /// off the main actor. The next call cancels ids that fall out of that
    /// window, not this one.
    ///
    /// The deal paths (`dealWindow`, `dealSortedWindow`) call this method
    /// after each deal, and `pageBecameCurrent` calls it on every settle.
    /// The window is warm before the first post mounts. `pruneQueuedPages`
    /// and `resumeBackgroundWork` also call it, to re-centre the window
    /// after their own changes.
    private func triggerMetadataPrefetch() {
        // This method prefetches nothing for a mode the user is not
        // looking at. A deal that completes just after the user switched
        // to Videos would otherwise start a fresh window of full-size
        // iCloud requests. Photos is not visible while that happens. See
        // `PhotoImagePipeline.suspend()`.
        guard AppModeStore.shared.mode == .photos else { return }
        guard entries.indices.contains(currentIndex) else { return }
        let lower = max(currentIndex - 2, 0)
        let upper = min(currentIndex + 6, entries.count - 1)
        var ids: [String] = []
        var nearIDs: Set<String> = []
        for i in lower...upper where i != currentIndex {
            let id = entries[i].assetID
            ids.append(id)
            if abs(i - currentIndex) <= 1 { nearIDs.insert(id) }
        }
        PhotoMetadataPrefetcher.shared.updateWindow(ids: ids, nearIDs: nearIDs)
        // The same -2/+6 window also warms pixels, not only metadata.
        // Without this call, each photo cell starts a cold PhotoKit
        // request the moment it mounts. On a library set to iCloud
        // "Optimize Storage," the download starts only once the cell
        // appears. The cell shows a grey placeholder until the download
        // finishes. This window includes the current post, unlike the
        // metadata window above, because the post's own view loads its
        // own metadata.
        var imageIDs: [String] = [entries[currentIndex].assetID]
        imageIDs.append(contentsOf: ids)
        PhotoImagePipeline.shared.setWindow(imageIDs)
    }

    // MARK: - Mode suspend / resume

    /// Stops every piece of photo background work: the image pipeline's
    /// caching and in-flight requests, and the metadata and place
    /// prefetcher's tasks. Called from `PhotoFeedView.onDisappear`, that
    /// is, whenever Photos stops being the visible mode.
    ///
    /// Without this call, Photos continues to download after the user
    /// leaves it, and uses bandwidth that Videos needs.
    func suspendBackgroundWork() {
        PhotoMetadataPrefetcher.shared.updateWindow(ids: [], nearIDs: [])
        PhotoImagePipeline.shared.suspend()
    }

    /// Restarts the background work Photos had running when it was last
    /// visible.
    func resumeBackgroundWork() {
        PhotoImagePipeline.shared.resume()
        triggerMetadataPrefetch()
    }

    /// Called by the post after it has been current for 0.5 seconds. O(1)
    /// on the main actor: a set insert, plus a hand-off to `PhotoSeenStore`.
    func markSeen(_ assetID: String) {
        // A date sort does not skip seen photos. Do not mark photos seen
        // in a date sort. The marks would complete a Random cycle that
        // the user did not browse. That would cause a reshuffle that
        // erases real progress the next time they switch back to Random.
        // Mirrors `DeckViewModel.markSeen`'s identical guard, for the same
        // reason.
        guard !isSortedMode else { return }
        guard markedSeenThisSession.insert(assetID).inserted else { return }
        seenRowEstimate += 1
        guard let seenStore else { return }
        // Chained onto `seenWork`, same reasoning as
        // `DeckViewModel.markSeen`: a clear at a cycle seam must wait for
        // every earlier `markSeen` call to complete before it deletes.
        let previous = seenWork
        seenWork = Task { @MainActor in
            await previous?.value
            await seenStore.markSeen(assetID)
        }
    }

    // MARK: - Keep / bin exclusion

    /// Drops `assetID` from every slot ahead of the current page. The
    /// Keep path calls this method after it commits the shield.
    func noteKept(assetID: String) {
        #if DEBUG
        if DiagnosticsGate.isOn("-cloudfull-log-deck") {
            let index = entries.firstIndex(where: { $0.assetID == assetID }) ?? -1
            DiagnosticsLog.shared.log("PhotoDeck", "deck_keep_\(assetID)_index_\(index)_entries_\(entries.count)")
        }
        #endif
        removeFromFuture(assetID: assetID)
    }

    /// The next window dealt stops excluding the id. There is nothing to
    /// remove from the live deck.
    func noteUnkept(assetID: String) {
        photoIDSnapshot.remove(assetID)
        refreshPoolCount()
        scheduleBinPhotoIDRefresh()
    }

    /// The one path that re-reads the library itself. Runs only on a real
    /// change notice, such as a photo imported, deleted, or edited outside
    /// the app, never on a mode switch.
    func refreshPoolAfterExternalChange() {
        enqueueDeckWork { [weak self] in
            guard let self else { return }
            self.assetCount = await self.pool.refresh()
            // An import or delete can move the asset at `sortedNextIndex`.
            // Run the resync after `pool.refresh()`, and only in sorted
            // mode. See `resyncSortedIndex`.
            await self.resyncSortedIndex()
            self.refreshPoolCount()
            self.scheduleBinPhotoIDRefresh()
        }
    }

    /// Records a crushed post and the height it keeps. See
    /// `collapsedHeights`.
    @discardableResult
    func markCollapsed(_ entryID: String, keeping height: CGFloat) {
        guard collapsedHeights[entryID] == nil else { return }
        collapsedHeights[entryID] = max(height, 0)
    }

    /// The photo-side twin of `DeckViewModel.pruneQueuedPages`. See that
    /// method's own comment for the full reasoning.
    ///
    /// The caller calls this method only after the pager settles on
    /// `pageID`, never mid-animation. A prune during the advance animation
    /// removes the post that the animation leaves, and the pager then
    /// stops one post past the reported id. Returns `true` if it removed
    /// anything, so the caller knows to re-anchor its scroll on `pageID`.
    func pruneQueuedPages(keeping pageID: String) -> Bool {
        let before = entries.count
        #if DEBUG
        let removedIDs = entries.filter { $0.id != pageID && resolver.isQueued($0.assetID) }.map(\.assetID)
        #endif
        // Do not remove a crushed row. The removal makes the list
        // recompute row sizes above, and the feed jumps. The row keeps
        // only the height that was already off screen.
        entries.removeAll {
            $0.id != pageID && resolver.isQueued($0.assetID) && collapsedHeights[$0.id] == nil
        }
        guard entries.count != before else { return false }
        if let index = entries.firstIndex(where: { $0.id == pageID }) {
            currentIndex = index
        }
        triggerMetadataPrefetch()
        #if DEBUG
        if DiagnosticsGate.isOn("-cloudfull-log-deck") {
            let ids = removedIDs.prefix(3).joined(separator: "|")
            DiagnosticsLog.shared.log("PhotoDeck", "deck_remove_queued_page_count_\(before)_to_\(entries.count)_current_\(currentIndex)_ids_\(ids)")
        }
        #endif
        return true
    }

    /// Removes every occurrence of `assetID` sitting after the current
    /// page from the live deck, and refreshes the pool count. Same shape
    /// and reasoning as `DeckViewModel.removeFromFuture` — see that
    /// method's own comment — minus the exception-slot bookkeeping. That
    /// bookkeeping supports a replayable cycle, and this deck does not
    /// replay cycles.
    ///
    /// `keepingEntryID` names the row whose own trash tap called this
    /// method. It stays in place whatever its index. A fully visible post
    /// is often one row below the deck's current page. The centre of the
    /// screen can still be on the post above.
    ///
    /// Without `keepingEntryID`, this method would count that row as
    /// "future" and remove it before its crush animation could start. The
    /// tapped row is always the one being crushed. Only other copies of the
    /// asset further down count as future.
    func removeFromFuture(assetID: String, keepingEntryID: String? = nil) {
        #if DEBUG
        let before = entries.count
        var removedIDs: [String] = []
        #endif
        var index = entries.count - 1
        while index >= 0 {
            if entries[index].assetID == assetID, index > currentIndex, entries[index].id != keepingEntryID {
                #if DEBUG
                removedIDs.append(entries[index].assetID)
                #endif
                entries.remove(at: index)
            }
            index -= 1
        }
        // The id is in the deck, so it is a live photo. Record that
        // directly, rather than making the pool count wait for the spot
        // check to confirm what this method already knows.
        photoIDSnapshot.insert(assetID)
        refreshPoolCount()
        #if DEBUG
        if !removedIDs.isEmpty, DiagnosticsGate.isOn("-cloudfull-log-deck") {
            let ids = removedIDs.prefix(3).joined(separator: "|")
            DiagnosticsLog.shared.log("PhotoDeck", "deck_remove_future_asset_count_\(before)_to_\(entries.count)_current_\(currentIndex)_ids_\(ids)")
        }
        #endif
    }

    func flushPendingWrites() {
        cursorFlushTask?.cancel()
        cursorFlushTask = nil
        applyPendingCursor()
        try? modelContext?.save()
    }

    #if DEBUG
    var debugNextSlotAfterCurrent: Int? {
        entries.indices.contains(currentIndex + 1) ? entries[currentIndex + 1].position : nil
    }

    /// A stored count, not a query. `PhotoFeedView`'s body reads this
    /// hundreds of times during a scroll. The seen table holds one row
    /// per photo the user has seen. A `fetchCount` here would run a
    /// SwiftData aggregate on every body pass against a table that grows
    /// with the library.
    var debugSeenRowCount: Int { seenRowEstimate }

    /// The value the `photo_facts_<createdMs>` UI-test probe reports: the
    /// current post's creation date, taken straight from its
    /// `PhotoDeckEntry`, with no extra PhotoKit read. Mirrors
    /// `FeedView`'s own `feed_facts_` probe field, with the same
    /// -1-if-missing convention. A date-sort test reads this to confirm
    /// the order the deck actually dealt in.
    var debugCurrentCreatedMs: Int64 {
        entries.indices.contains(currentIndex) ? entries[currentIndex].createdMs : -1
    }
    #endif

    // MARK: - Pool membership

    /// The ids no window may ever deal: kept (shielded) or queued for the
    /// bin. Read straight off the resolver's own sets. This deliberately
    /// does not use `resolver.isEligible(_:)` — see this type's own doc
    /// comment for why that would silently under-exclude a photo id.
    private func excludedIDs() -> Set<String> {
        resolver.shieldedIDs.union(resolver.queuedIDs)
    }

    /// Set arithmetic over the kept and queued sets only, the same shape
    /// as `AssetKeyResolver.recompute()`. `assetCount` is
    /// `PHFetchResult.count`, which is O(1) however large the library is.
    /// Until the spot check completes, `photoIDSnapshot` is empty, and the
    /// count includes kept and queued photos.
    private func refreshPoolCount() {
        let excludedLivePhotos = excludedIDs().intersection(photoIDSnapshot)
        poolCount = max(assetCount - excludedLivePhotos.count, 0)
    }

    /// Tells `AssetKeyResolver` which kept or queued ids still name a
    /// live photo. Cost is O(kept + queued), never O(library): walking
    /// every id in the library would not scale to a very large one. The
    /// only consumer is `AssetKeyResolver.photoLibraryIDs`, read by
    /// `currentLocalIdentifier`/`exclusionKey` so `TrashService` can
    /// confirm a queued photo row's asset is still live for the shared
    /// bin. TrashService asks this only about existing rows, which are
    /// few. A spot check on those ids is sufficient.
    ///
    /// Coalesced: one refresh runs at a time. A request made while one is
    /// running sets `binIDsDirty`, so it runs once more, and requests do
    /// not accumulate.
    private func scheduleBinPhotoIDRefresh() {
        guard binIDsTask == nil else {
            binIDsDirty = true
            return
        }
        let candidates = Array(excludedIDs())
        binIDsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // An actor call, so the fetch runs on the cooperative pool,
            // never on the main actor.
            let live = await self.pool.existingPhotoIdentifiers(among: candidates)
            self.photoIDSnapshot = live
            self.resolver.refreshPhotoLibrarySnapshot(live)
            self.refreshPoolCount()
            self.binIDsTask = nil
            if self.binIDsDirty {
                self.binIDsDirty = false
                self.scheduleBinPhotoIDRefresh()
            }
        }
    }

    // MARK: - Dealing

    /// Deals one window and either replaces the deck with it or appends
    /// it.
    ///
    /// This touches only `windowSize` assets, never the whole library.
    /// `PhotoLibraryPool.sample` rejects everything already consumed this
    /// cycle and everything kept or queued. An appended window can never
    /// repeat a photo the user has already reached.
    ///
    /// Do not remove the branch on the first line below. A sorted deal
    /// must branch to `dealSortedWindow` before any other code in this
    /// method runs, and must never fall through past it. The cycle-end
    /// test a few lines down calls `clearCycle()`, which deletes every
    /// row of `PhotoSeenEntry`. That can be tens of thousands of rows on
    /// a large library, deleted silently, with no undo.
    ///
    /// A date sort ignores the seen cycle (see `dealSortedWindow`'s own
    /// doc comment). If a sorted deal reaches this test, it deletes the
    /// Random-mode seen history for no reason. Branching on the first
    /// line, rather than deeper inside, keeps that question easy to
    /// answer. Reading four lines answers whether a sorted deal can ever
    /// reach `clearCycle()`.
    private func dealWindow(replacingDeck: Bool) async {
        if isSortedMode {
            await dealSortedWindow(replacingDeck: replacingDeck)
            return
        }

        let state: PhotoDeckState
        if let existing = deckState {
            state = existing
        } else {
            state = fetchOrCreateDeckState()
            deckState = state
        }

        let excluded = excludedIDs()
        let seed = UInt64.random(in: UInt64.min...UInt64.max)

        // The cycle-end test is a count, not a search. The pool's
        // consumed count reaching `poolCount` means every eligible photo
        // has been dealt or seen. Both sides are O(1), the only cheap way
        // to ask this on a very large library. The sampler's own
        // `exhausted` flag stays exact for a library small enough to
        // sweep. An empty deal ends the cycle for all other library
        // sizes.
        if poolCount > 0, await pool.consumedCount() >= poolCount {
            // A pass over "this date" ends with a status card, not a
            // re-deal.
            if !replacingDeck, activeOptions.filters.onThisDate {
                isDoneForToday = true
                return
            }
            await clearCycle()
        }

        var deal = await pool.sample(
            need: windowSize,
            excluding: excluded,
            seed: seed
        )
        if deal.exhausted || deal.items.isEmpty {
            if !replacingDeck, activeOptions.filters.onThisDate {
                isDoneForToday = true   // Same "done for today" rule as above.
                return
            }
            // Nothing is left this cycle. Clear seen memory and keep
            // going: the rule stays "each photo once before repeating."
            await clearCycle()
            // At a cycle seam the consumed set has just emptied. Opening
            // the next cycle could otherwise replay a photo the user saw
            // a moment ago. The deal rejects the last `gap` dealt ids,
            // like `ShuffleEngine.openingWithoutRecentRepeat`. The cap at
            // half the pool is necessary. Without it, a small library
            // rejects every photo, and the feed stops.
            let gap = min(historyWindow, max(deal.assetCount / 2, 0))
            let recent = Set(entries.suffix(gap).map(\.assetID))
            deal = await pool.sample(
                need: windowSize,
                excluding: excluded,
                avoiding: recent,
                seed: seed &+ 0x9E37_79B9_7F4A_7C15
            )
        }
        assetCount = deal.assetCount
        refreshPoolCount()

        #if DEBUG
        PhotoPerfProbe.shared.noteDeal(
            windowCount: deal.items.count,
            sampleMs: deal.sampleMs,
            materialisations: deal.materialisations
        )
        #endif

        guard !deal.items.isEmpty else {
            if replacingDeck {
                #if DEBUG
                let before = entries.count
                let removedIDs = entries.map(\.assetID)
                #endif
                entries = []
                currentIndex = 0
                currentEntryID = nil
                state.seed = Int64(bitPattern: seed)
                saveDeck()
                triggerMetadataPrefetch()
                #if DEBUG
                if before > 0, DiagnosticsGate.isOn("-cloudfull-log-deck") {
                    let ids = removedIDs.prefix(3).joined(separator: "|")
                    DiagnosticsLog.shared.log("PhotoDeck", "deck_remove_cycle_empty_count_\(before)_to_0_current_0_ids_\(ids)")
                }
                #endif
            }
            return
        }

        let baseSlot = state.nextSlot
        var dealt: [PhotoDeckEntry] = []
        dealt.reserveCapacity(deal.items.count)
        for (offset, item) in deal.items.enumerated() {
            dealt.append(PhotoDeckEntry(assetID: item.id, position: baseSlot + offset, createdMs: item.createdMs))
        }
        state.nextSlot = baseSlot + dealt.count
        state.seed = Int64(bitPattern: seed)

        // The post's placeholder can now show the right height on its
        // very first layout pass. There is no wait on tier 1, and no
        // reflow under the user's finger when the image arrives.
        PhotoImagePipeline.shared.noteAspects(deal.items)

        if replacingDeck {
            #if DEBUG
            let before = entries.count
            let removedIDs = entries.map(\.assetID)
            #endif
            // This deal replaces the whole deck, so it also clears the
            // crushed placeholders.
            collapsedHeights.removeAll()
            entries = dealt
            currentIndex = 0
            state.cursor = dealt[0].position
            #if DEBUG
            if entries.count < before, DiagnosticsGate.isOn("-cloudfull-log-deck") {
                let ids = removedIDs.prefix(3).joined(separator: "|")
                DiagnosticsLog.shared.log("PhotoDeck", "deck_remove_replace_window_count_\(before)_to_\(entries.count)_current_\(currentIndex)_ids_\(ids)")
            }
            #endif
        } else {
            entries.append(contentsOf: dealt)
            pruneHistory(force: false)
        }
        currentEntryID = entries.indices.contains(currentIndex) ? entries[currentIndex].id : nil

        saveDeck()
        // The window's far edge may now reach slots that did not exist a
        // moment ago. Re-centre the prefetch so it pulls those in too.
        triggerMetadataPrefetch()
        #if DEBUG
        PhotoPerfProbe.shared.noteDeckSize(pool: poolCount, entries: entries.count)
        #endif
    }

    /// Deals one window of a date sort, in order. The `dealWindow` twin
    /// for `isSortedMode`, branched to from that method's own first line
    /// and never reached any other way.
    ///
    /// A date sort ignores the seen cycle and lists every eligible photo
    /// in date order, repeats included. Unlike `dealWindow`, this never
    /// reads or writes `consumed`/`PhotoSeenEntry`, and never calls
    /// `clearCycle()`. The only exclusion is `excludedIDs()` (kept or
    /// queued), the same small set `dealWindow` also excludes.
    ///
    /// `replacingDeck` resets `sortedNextIndex` to 0. This reset makes a
    /// sort change restart paging at the top. `apply(options:)` always
    /// deals with `replacingDeck: true`. No code saves the index, so a
    /// relaunch always starts a date sort at the top too.
    private func dealSortedWindow(replacingDeck: Bool) async {
        let state: PhotoDeckState
        if let existing = deckState {
            state = existing
        } else {
            state = fetchOrCreateDeckState()
            deckState = state
        }

        if replacingDeck {
            sortedNextIndex = 0
            lastDealtSortedAssetID = nil
        }

        let excluded = excludedIDs()
        let page = await pool.page(from: sortedNextIndex, need: windowSize, excluding: excluded)
        sortedNextIndex = page.nextIndex
        assetCount = page.assetCount
        refreshPoolCount()

        guard !page.items.isEmpty else {
            // The sorted twin of `dealWindow`'s own two `isDoneForToday`
            // checks. An extension that finds nothing means the user has
            // scrolled to the end of today's photos, not that the initial
            // deal came up short. `replacingDeck` gates this the same way
            // there, for the same reason: never show "done" before
            // showing whatever photos do exist.
            if !replacingDeck, activeOptions.filters.onThisDate {
                isDoneForToday = true
            }
            if replacingDeck {
                #if DEBUG
                let before = entries.count
                let removedIDs = entries.map(\.assetID)
                #endif
                entries = []
                currentIndex = 0
                currentEntryID = nil
                saveDeck()
                triggerMetadataPrefetch()
                #if DEBUG
                if before > 0, DiagnosticsGate.isOn("-cloudfull-log-deck") {
                    let ids = removedIDs.prefix(3).joined(separator: "|")
                    DiagnosticsLog.shared.log("PhotoDeck", "deck_remove_sorted_empty_count_\(before)_to_0_current_0_ids_\(ids)")
                }
                #endif
            }
            return
        }

        let baseSlot = state.nextSlot
        var dealt: [PhotoDeckEntry] = []
        dealt.reserveCapacity(page.items.count)
        for (offset, item) in page.items.enumerated() {
            dealt.append(PhotoDeckEntry(assetID: item.id, position: baseSlot + offset, createdMs: item.createdMs))
        }
        state.nextSlot = baseSlot + dealt.count
        lastDealtSortedAssetID = page.items.last?.id

        // The post's placeholder can now show the right height on its
        // very first layout pass. There is no wait on tier 1, and no
        // reflow under the user's finger when the image arrives.
        PhotoImagePipeline.shared.noteAspects(page.items)

        if replacingDeck {
            #if DEBUG
            let before = entries.count
            let removedIDs = entries.map(\.assetID)
            #endif
            // This deal replaces the whole deck, so it also clears the
            // crushed placeholders.
            collapsedHeights.removeAll()
            entries = dealt
            currentIndex = 0
            // Only in random mode. `state.cursor` is the Random resume's
            // high-water mark. This method runs only in sorted mode, so
            // the guard is a safety check: a date sort must never write
            // `cursor`.
            if !isSortedMode {
                state.cursor = dealt[0].position
            }
            #if DEBUG
            if entries.count < before, DiagnosticsGate.isOn("-cloudfull-log-deck") {
                let ids = removedIDs.prefix(3).joined(separator: "|")
                DiagnosticsLog.shared.log("PhotoDeck", "deck_remove_replace_sorted_window_count_\(before)_to_\(entries.count)_current_\(currentIndex)_ids_\(ids)")
            }
            #endif
        } else {
            entries.append(contentsOf: dealt)
            pruneHistory(force: false)
        }
        currentEntryID = entries.indices.contains(currentIndex) ? entries[currentIndex].id : nil

        saveDeck()
        triggerMetadataPrefetch()
        #if DEBUG
        PhotoPerfProbe.shared.noteDeckSize(pool: poolCount, entries: entries.count)
        #endif
    }

    /// Appends one more window to the deck.
    private func extendDeck() async {
        guard PhotoLibraryService.shared.authStatus == .authorized else { return }
        await dealWindow(replacingDeck: false)
    }

    /// Re-anchors `sortedNextIndex` after a real library change, such as
    /// an import or a deletion outside the app. See
    /// `PhotoLibraryPool.resyncSortedIndex` for the bounded +/-64 search
    /// this wraps. Does nothing outside sorted mode: Random has no
    /// comparable index to drift, since `sample` picks fresh random
    /// indices on every deal.
    private func resyncSortedIndex() async {
        guard isSortedMode else { return }
        sortedNextIndex = await pool.resyncSortedIndex(near: sortedNextIndex, lastDealtID: lastDealtSortedAssetID)
    }

    /// Ends the cycle. Clears the pool's consumed set now, and chains the
    /// delete of every `PhotoSeenEntry` row after `seenWork`, so the
    /// delete runs after every earlier `markSeen` write.
    private func clearCycle() async {
        // The background seen load must not complete after this call and
        // re-populate the set it just emptied.
        await seenLoadTask?.value
        await pool.clearConsumed()
        markedSeenThisSession.removeAll()
        seenRowEstimate = 0

        // Chain the table delete onto `seenWork`, and do not await it.
        // The table can hold a very large number of rows, and an awaited
        // delete stops dealing when the user needs more photos. Chaining
        // keeps the delete ordered after every pending `markSeen` write.
        guard let seenStore else { return }
        let previous = seenWork
        seenWork = Task { @MainActor in
            await previous?.value
            await seenStore.clearAllSeen()
        }
    }

    /// Drops leading entries the user is long past, so `entries` (and
    /// therefore `PhotoFeedView`'s `ForEach`) stays bounded however far
    /// one session scrolls.
    ///
    /// This does not run after every extension. Removing rows above the
    /// viewport shrinks the scroll content above it. A `ScrollView` keeps
    /// its content offset, so the feed visibly jumps. `PhotoFeedView` can
    /// re-anchor, and already does after a queued-page prune. Re-anchoring
    /// puts the current post's top edge at the viewport top, an abrupt
    /// jump in a free-scrolling feed where the user may have released
    /// mid-post. So:
    ///
    /// * `force` (a mode-switch remount, from `reconcileAfterRemount`)
    ///   prunes to `historyWindow`. Nothing is on screen, so nothing can
    ///   jump.
    /// * Otherwise this prunes only once `entries` passes `maxEntries`,
    ///   which takes a very long scroll, and accepts one re-anchor jump
    ///   at that time.
    private func pruneHistory(force: Bool) {
        guard force || entries.count > maxEntries else { return }
        guard currentIndex > historyWindow else { return }
        let dropCount = currentIndex - historyWindow
        guard dropCount > 0 else { return }

        #if DEBUG
        let before = entries.count
        let removedIDs = entries.prefix(dropCount).map(\.assetID)
        #endif
        entries.removeFirst(dropCount)
        currentIndex -= dropCount
        currentEntryID = entries.indices.contains(currentIndex) ? entries[currentIndex].id : nil
        if let state = deckState, entries.indices.contains(0) {
            state.trimmedBeforeSlot = max(state.trimmedBeforeSlot, entries[0].position)
        }
        if !force { historyPruneNonce += 1 }
        #if DEBUG
        PhotoPerfProbe.shared.noteDeckSize(pool: poolCount, entries: entries.count)
        if DiagnosticsGate.isOn("-cloudfull-log-deck") {
            let reason = force ? "mode_switch" : "hard_cap"
            let ids = removedIDs.prefix(3).joined(separator: "|")
            DiagnosticsLog.shared.log("PhotoDeck", "deck_remove_\(reason)_count_\(before)_to_\(entries.count)_current_\(currentIndex)_ids_\(ids)")
        }
        #endif
    }

    private func saveDeck() {
        applyPendingCursor()
        try? modelContext?.save()
    }

    // MARK: - Main-thread discipline

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

    private func applyPendingCursor() {
        guard let pendingCursor else { return }
        self.pendingCursor = nil
        guard let state = deckState else { return }
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

    // MARK: - Helpers

    private func fetchOrCreateDeckState() -> PhotoDeckState {
        guard let modelContext else { return PhotoDeckState() }
        if let existing = try? modelContext.fetch(FetchDescriptor<PhotoDeckState>()).first {
            return existing
        }
        let state = PhotoDeckState()
        modelContext.insert(state)
        return state
    }
}

// MARK: - KeepStore

/// The one Keep writer for Photos mode. Does exactly what
/// `DeckViewModel.like`/`unlike` do to `LikedEntry` and `AssetKeyResolver`,
/// without making `DeckViewModel` generic. Keep is one shield across both
/// modes: a kept photo and a kept video share the same `LikedEntry` table
/// and the same `AssetKeyResolver.shieldedIDs`.
///
/// Deliberately narrow: this type only ever writes or removes the shield
/// row and tells the resolver. Deck bookkeeping
/// (`PhotoDeck.noteKept`/`noteUnkept`) and trash bookkeeping
/// (`TrashService.restore`) are separate calls that the caller makes in
/// sequence.
@MainActor
final class KeepStore: ObservableObject {
    static let shared = KeepStore()
    private init() {}

    private let resolver = AssetKeyResolver.shared
    private var modelContext: ModelContext?

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func isKept(_ assetID: String) -> Bool {
        resolver.isShielded(assetID)
    }

    @discardableResult
    func keep(assetID: String) -> Bool {
        guard let modelContext else { return false }
        guard !isKept(assetID) else { return false }
        // Stamping a cloud key on insert costs nothing extra when one is
        // already known. See `DeckViewModel.like`'s own comment on why a
        // synchronous PhotoKit round trip does not belong on a
        // user-interactive tap.
        let cloudKey = resolver.knownCloudKey(forLiveID: assetID)
        modelContext.insert(LikedEntry(assetKey: assetID, cloudKey: cloudKey))
        try? modelContext.save()
        resolver.noteLiked(assetKey: assetID, cloudKey: cloudKey)
        return true
    }

    /// Fetches every row and matches on either key, the same as
    /// `DeckViewModel.unlike`. See that method's own comment on why a
    /// predicate fetch on the raw key alone would miss a rotated row.
    @discardableResult
    func unkeep(assetID: String) -> Bool {
        guard let modelContext else { return false }
        // Tries the fast path first: the row whose raw key is this id.
        // That is by far the common case, and it is a predicate fetch
        // rather than a materialisation of every kept row. This runs on
        // the main actor from a rail tap, and `LikedEntry` holds every
        // photo and video the user has ever kept.
        var direct = FetchDescriptor<LikedEntry>(predicate: #Predicate { $0.assetKey == assetID })
        direct.fetchLimit = 1
        var matches = (try? modelContext.fetch(direct)) ?? []
        if matches.isEmpty {
            // Falls back to the slow path only for a row stored under a
            // rotated cloud key. That case cannot be a predicate, so it
            // needs the scan.
            let all = (try? modelContext.fetch(FetchDescriptor<LikedEntry>())) ?? []
            matches = all.filter {
                resolver.exclusionKey(assetKey: $0.assetKey, cloudKey: $0.cloudKey) == assetID
            }
        }
        guard !matches.isEmpty else { return false }
        for entry in matches {
            let (assetKey, cloudKey) = (entry.assetKey, entry.cloudKey)
            modelContext.delete(entry)
            resolver.noteUnliked(assetKey: assetKey, cloudKey: cloudKey)
        }
        try? modelContext.save()
        return true
    }
}

// MARK: - PhotoSeenStore

/// The photo-side twin of `SeenStore` in `Cloudfull/Storage/SeenStore.swift`.
/// Same `@ModelActor` reasoning: a `ModelContext` is not `Sendable`, and no
/// SwiftData work on the load path may run on the main actor. Has its own
/// table, `PhotoSeenEntry`, so the two decks' seen memory never mixes.
@ModelActor
actor PhotoSeenStore {
    /// A plain insert, with no fetch first to check the row is not
    /// already there. `PhotoSeenEntry` has no `#Index`, because the model
    /// is CloudKit-shaped. A check fetch scans the full table on each
    /// mark, a heavy cost on a very large library.
    ///
    /// The check is unnecessary: `PhotoDeck.markSeen` already guards on
    /// `markedSeenThisSession`, a hashed set in memory. A duplicate row
    /// can only appear across two sessions, and a duplicate row is
    /// harmless. Every reader here builds a `Set`, and `clearAllSeen`
    /// removes rows by type, not by id.
    func markSeen(_ assetKey: String) {
        modelContext.insert(PhotoSeenEntry(assetKey: assetKey))
        try? modelContext.save()
    }

    /// Every seen key, with no library id set to intersect against. The
    /// table only ever holds photo ids, so its whole contents are the
    /// cycle's consumed set. Fetching the library's id list just to filter
    /// it would be the whole-library walk this deck avoids. A row whose
    /// asset has since left the library is harmless: it names nothing, so
    /// it rejects nothing.
    ///
    /// This call grows with how much of the library the user has seen, so
    /// nothing may wait on it. `PhotoDeck.scheduleSeenLoad` runs it
    /// alongside the first deal, never before it.
    func allSeenKeys() -> Set<String> {
        // A fresh, throwaway context, not this actor's long-lived one.
        // The fetch creates one managed object per row, and a
        // `ModelContext` keeps every object it fetches registered for its
        // own lifetime. Reading this table through the actor's own
        // context would pin one object per photo the user has ever seen.
        // That memory stays for the life of the process. A local context
        // releases all of it the moment this method returns. Only the
        // plain `Set<String>` survives.
        let context = ModelContext(modelContainer)
        let all = (try? context.fetch(FetchDescriptor<PhotoSeenEntry>())) ?? []
        return Set(all.map(\.assetKey))
    }

    /// One batch delete, not a fetch-then-delete loop. At a cycle seam
    /// this table holds one row per photo in the pool, so a fetch of
    /// every row before the delete costs O(library).
    func clearAllSeen() {
        try? modelContext.delete(model: PhotoSeenEntry.self)
        try? modelContext.save()
    }
}
