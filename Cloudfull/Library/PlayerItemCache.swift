//
//  PlayerItemCache.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation

/// Player items resolved ahead of the swipe, for the warm-only slots of
/// the preload window. The expensive half of playing an iCloud-offloaded
/// video is `PHImageManager.requestPlayerItem` resolving the asset, which
/// takes seconds. This is why `withPhotoKitTimeout` uses a 20 s bound.
/// That half is separable from playback. An `AVPlayerItem` that has
/// never been attached to an `AVPlayer` does no buffering, no decoding,
/// and occupies no decode pipeline. A warm slot pays the resolution cost
/// early, so the render window stays exactly ±1.
@MainActor
final class PlayerItemCache {
    static let shared = PlayerItemCache()

    /// At most two warm items alive at once (the warm window is one slot
    /// wider than the render window in each direction it grows).
    static let capacity = 2

    /// Resolved items not yet claimed by `take`, keyed by asset id.
    private var resolved: [String: AVPlayerItem] = [:]
    /// Resolution in flight, keyed by asset id. Void-returning: the item
    /// itself always lands in `resolved`, or nowhere on cancellation or
    /// failure, before this task finishes. So `take` never needs the
    /// task's own return value, only the fact that it is done.
    private var inFlight: [String: Task<Void, Never>] = [:]

    private init() {}

    /// Hands over the resolved item for `assetID`, if there is one, and
    /// removes it from the cache as it does. One resolved item goes to
    /// one consumer, ever. An `AVPlayerItem` may be attached to only one
    /// `AVPlayer`, so a cache that returns one item twice breaks
    /// playback when the deck repeats an asset.
    ///
    /// This method is `async` because a warm request may still be in
    /// flight. Joining that request is correct; issuing a second request
    /// for the same asset would download it twice. Returns `nil`
    /// immediately when there is neither a resolved item nor a request in
    /// flight.
    ///
    /// An accepted race: `setWindow` may cancel this id's request while a
    /// `take` call is in flight for it. Then `resolved[assetID]` is never
    /// populated, and this returns `nil`. That is slower for the caller,
    /// since `load()` then falls through to a fresh request, but never
    /// wrong.
    func take(_ assetID: String) async -> AVPlayerItem? {
        if let task = inFlight[assetID] {
            await task.value
        }
        return resolved.removeValue(forKey: assetID)
    }

    /// Where evicted items are released. See `setWindow`.
    private static let releaseQueue = DispatchQueue(label: "com.cloudfull.player-item-release", qos: .utility)

    /// Declares the warm-only slots: the ids in the warm window that are
    /// not in the render window, which resolve their own items through
    /// `load()`. Starts a resolution for each, evicts and releases
    /// anything no longer named, and does nothing at all when
    /// `allowNetwork` is false. It starts tasks and returns at once. It
    /// never suspends the caller.
    ///
    /// `assetIDs` is the full retain set: the ids that must not be
    /// cancelled or evicted. `starting` is the subset to actually begin
    /// resolving. Keeping these separate matters. An id can sit in the
    /// warm window, retained but not yet started, and then move into the
    /// render window on the next swipe without ever being cancelled.
    func setWindow(_ assetIDs: [String], starting: [String], allowNetwork: Bool) {
        wdMark("itemCache")
        let wanted = Set(assetIDs)
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
        // Resolve player items early only when `allowNetwork` is true,
        // which saves battery and data on cellular. Posters still
        // prefetch on cellular, because they are local thumbnails.
        guard allowNetwork else { return }
        for assetID in starting.prefix(Self.capacity) {
            guard resolved[assetID] == nil, inFlight[assetID] == nil else { continue }
            let task = Task { [weak self] in
                let item = await PhotoLibraryService.shared.playerItem(for: assetID)
                guard let self else { return }
                // A cancelled task was superseded. Do not clear the slot
                // the replacement now owns.
                guard !Task.isCancelled else { return }
                self.inFlight[assetID] = nil
                if let item { self.resolved[assetID] = item }
            }
            inFlight[assetID] = task
        }
    }
}
