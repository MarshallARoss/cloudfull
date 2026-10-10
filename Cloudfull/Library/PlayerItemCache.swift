//
//  PlayerItemCache.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation

/// One warm-window slot: the stable page id a resolved item is handed
/// back to, and the asset id PhotoKit actually resolves for it. Two
/// pages that happen to hold the same asset — a reshuffle can repeat
/// one, just not within swipe-reachable distance of each other — must
/// never share a slot. An `AVPlayerItem` attaches to at most one player
/// at a time, so handing one resolved item to two holders would break
/// whichever one attaches second.
struct WarmSlot {
    let pageID: String
    let assetID: String
}

/// Player items resolved ahead of the swipe, for the whole warm window:
/// the render window (the current page and its immediate ±1
/// neighbours) plus one slot further out. The expensive half of
/// playing an iCloud-offloaded video is `PHImageManager
/// .requestPlayerItem` resolving the asset, which takes seconds. This
/// is why `withPhotoKitTimeout` uses a 20 s bound. That half is
/// separable from playback. An `AVPlayerItem` that has never been
/// attached to an `AVPlayer` does no buffering, no decoding, and
/// occupies no decode pipeline — this cache only ever holds unattached
/// items. The live-render cap of 3 attached items at once is a
/// different rule, enforced by the holders that actually attach them,
/// not by this cache, so it needs no capacity limit of its own: the
/// warm window itself is never more than 4 slots wide.
///
/// Keyed by page id (`DeckEntry.id`), never by asset id: see
/// `WarmSlot`'s own comment.
///
/// A request started here is cancelled only when its page id leaves
/// the warm window, in a later `setWindow` call. A view cancelling its
/// own load task never reaches this cache's request:
/// `DeckViewModel.playerItem(for:pageID:)` only joins `take(_:)`, it
/// does not drive cancellation. This is what lets a page abandoned
/// mid-load, and revisited before it leaves the window, come back to
/// the same request instead of starting a second one.
@MainActor
final class PlayerItemCache {
    static let shared = PlayerItemCache()

    /// Resolved items not yet claimed by `take`, keyed by page id.
    private var resolved: [String: AVPlayerItem] = [:]
    /// Resolution in flight, keyed by page id. Void-returning: the item
    /// itself always lands in `resolved`, or nowhere on cancellation or
    /// failure, before this task finishes. So `take` never needs the
    /// task's own return value, only the fact that it is done.
    private var inFlight: [String: Task<Void, Never>] = [:]

    private init() {}

    /// Hands over the resolved item for `pageID`, if there is one, and
    /// removes it from the cache as it does. One resolved item goes to
    /// one consumer, ever. An `AVPlayerItem` may be attached to only one
    /// `AVPlayer`, so a cache that returns one item twice breaks
    /// playback — this is also why the cache is keyed by page id: two
    /// pages that happen to hold the same asset must never be handed
    /// the same resolved item.
    ///
    /// This method is `async` because a warm request may still be in
    /// flight. Joining that request is correct; issuing a second
    /// request for the same page would download its asset twice.
    /// Returns `nil` immediately when there is neither a resolved item
    /// nor a request in flight.
    ///
    /// If the calling task is cancelled while this joins an in-flight
    /// request — the page's own view went away, not the window — the
    /// resolved item is left in the cache for whoever retakes it next,
    /// rather than discarded unused. This is what lets a page abandoned
    /// mid-load come back to the same request: the view's cancel never
    /// reaches `setWindow`, so the page id stays retained and its
    /// result stays here until something actually takes it.
    func take(_ pageID: String) async -> AVPlayerItem? {
        if let task = inFlight[pageID] {
            await task.value
        }
        guard !Task.isCancelled else { return nil }
        return resolved.removeValue(forKey: pageID)
    }

    /// Where evicted items are released. See `setWindow`.
    private static let releaseQueue = DispatchQueue(label: "com.cloudfull.player-item-release", qos: .utility)

    /// Declares the warm window and starts resolving it. Evicts and
    /// releases anything no longer named, then starts a resolution for
    /// every slot in `starting` that is not already resolved or in
    /// flight, and for every slot in `networkGatedStarting` too, but
    /// only when `allowNetwork` is true.
    ///
    /// `starting` is the render window — the current page and its
    /// immediate ±1 neighbours — and always starts, cellular or not: it
    /// is what the page actually on screen, and the one swipe away from
    /// it, need. `networkGatedStarting` is the one slot further out
    /// (+2), where paying an iCloud download on a cellular connection
    /// the user is not looking at yet is worth gating. Both start sets
    /// start tasks and return at once; neither ever suspends the
    /// caller.
    ///
    /// `retain` is the full warm window: every page id that must not be
    /// cancelled or evicted, whether or not this call starts a
    /// resolution for it. A page id can sit retained, not yet started,
    /// and then move into `starting` on a later call without ever being
    /// cancelled in between.
    func setWindow(retain: [WarmSlot], starting: [WarmSlot], networkGatedStarting: [WarmSlot], allowNetwork: Bool) {
        wdMark("itemCache")
        let wanted = Set(retain.map(\.pageID))
        for (id, task) in inFlight where !wanted.contains(id) {
            task.cancel()
        }
        // Do not release an evicted `AVPlayerItem` on the main thread.
        // Its engine teardown can stall the main thread for hundreds of
        // milliseconds. Send evicted items to `releaseQueue` instead.
        var evicted: [AVPlayerItem] = []
        for id in resolved.keys where !wanted.contains(id) {
            if let item = resolved.removeValue(forKey: id) { evicted.append(item) }
        }
        if !evicted.isEmpty {
            Self.releaseQueue.async { _ = evicted; evicted.removeAll() }
        }

        func start(_ slots: [WarmSlot]) {
            for slot in slots {
                guard resolved[slot.pageID] == nil, inFlight[slot.pageID] == nil else { continue }
                let task = Task { [weak self] in
                    let item = await PhotoLibraryService.shared.playerItem(for: slot.assetID)
                    guard let self else { return }
                    // Clear the slot whether or not this task was
                    // cancelled. Leaving a cancelled task's id in
                    // `inFlight` forever would stop its page id from
                    // ever starting again once it re-enters the
                    // window — the old bug this fixes.
                    self.inFlight[slot.pageID] = nil
                    // A cancelled task was superseded, or its page id
                    // left the window outright. Either way, nobody is
                    // waiting for this result, so it must not be
                    // stored under a slot that may already belong to
                    // someone else.
                    guard !Task.isCancelled else { return }
                    if let item { self.resolved[slot.pageID] = item }
                }
                inFlight[slot.pageID] = task
            }
        }
        start(starting)
        // Posters still prefetch on cellular, because they are local
        // thumbnails. The item resolution below is the expensive half,
        // so only the one slot furthest from the render window is
        // gated on it.
        if allowNetwork { start(networkGatedStarting) }
    }
}
