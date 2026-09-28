//
//  PosterCache.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Caches the feed's poster frames across mounts and prefetches them for
/// the whole warm window. A swipe must always find its frame ready.
///
/// This type uses `NSCache`, not a custom LRU cache. `NSCache` evicts
/// on memory pressure by itself, which suits a cache of full-screen
/// `UIImage`s, and an eviction only costs a re-fetch. A page that shows a
/// poster holds its own strong reference in `@State`, so an eviction can
/// never remove an image from a page on screen.
@MainActor
final class PosterCache {
    static let shared = PosterCache()

    /// 1920 px on the long side. This matches the stage's own long side in
    /// pixels, the default side `PlayerPageView` uses when it asks
    /// `PosterCache` for a poster.
    static let feedSide: CGFloat = 1920

    private let cache = NSCache<NSString, UIImage>()

    /// In-flight fetches, keyed the same way as `cache`, as
    /// `"<assetID>@<side>"`. This lets `setWindow` cancel precisely and
    /// lets two callers for one id share one request. A caller reaches the
    /// `inFlight` branch of `poster(for:side:onImage:)` only when nothing
    /// is cached yet for that key. The fetch writes each image into
    /// `cache` the moment it arrives, before yielding to any suspension
    /// point. No image a late caller could have missed is ever left
    /// uncached.
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// Callbacks waiting on an in-flight fetch, keyed the same way.
    private var subscribers: [String: [@MainActor (UIImage) -> Void]] = [:]
    /// The identity of the `runFetch` call that currently owns each key,
    /// keyed the same way. `Task` has no equality of its own. This small
    /// reference-identity box lets a `runFetch` teardown check that it is
    /// still the current fetch for a key. A stale fetch's teardown can run
    /// after a newer retry already replaced it. That teardown must not
    /// clear the newer fetch's `inFlight` or `subscribers` entries.
    private var owner: [String: RunToken] = [:]

    private final class RunToken {}

    private init() {
        // A count cap alone is not enough: six 1080x1920 posters already
        // use about 50 MB. Both caps apply together.
        cache.countLimit = 6
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    private static func key(for assetID: String, side: CGFloat) -> String {
        "\(assetID)@\(Int(side))"
    }

    /// Returns a cache hit, or `nil`. This method never fetches and never
    /// suspends. `PlayerPageView` calls it from the first line of
    /// `deliverPoster()` and from its body's first-frame fallback.
    func image(for assetID: String, side: CGFloat = PosterCache.feedSide) -> UIImage? {
        cache.object(forKey: Self.key(for: assetID, side: side) as NSString)
    }

    /// Delivers this asset's poster progressively. `onImage` runs on the
    /// main actor, at most twice, with the newest image last. It runs once
    /// with PhotoKit's degraded frame as soon as one exists, within
    /// milliseconds even for an iCloud-offloaded video. It runs once more
    /// with the full-quality frame, as soon as that frame is ready. This
    /// method returns once no further image is coming. A cache hit calls
    /// `onImage` once, synchronously, and returns.
    ///
    /// Do not wait for a sharp frame here the way `thumbnail(for:)` does. A
    /// poster needs a fast first frame, not a guaranteed-sharp one.
    func poster(
        for assetID: String,
        side: CGFloat = PosterCache.feedSide,
        onImage: @escaping @MainActor (UIImage) -> Void
    ) async {
        let key = Self.key(for: assetID, side: side)
        if let cached = cache.object(forKey: key as NSString) {
            onImage(cached)
            return
        }
        subscribers[key, default: []].append(onImage)
        if let existing = inFlight[key] {
            await existing.value
            // `setWindow` can cancel the fetch this call just joined. When that
            // happens, `runFetch` clears `subscribers[key]` and `inFlight[key]` on
            // its way out and delivers nothing. That leaves a page with no poster,
            // since `deliverPoster()` never runs again for an unchanged
            // `posterKey`. Starting one fresh fetch here fixes that case.
            if let cached = cache.object(forKey: key as NSString) {
                onImage(cached)
                return
            }
            subscribers[key, default: []].append(onImage)
            if inFlight[key] == nil {
                let token = RunToken()
                owner[key] = token
                let retry = Task { [weak self] () -> Void in
                    await self?.runFetch(assetID: assetID, side: side, key: key, token: token)
                }
                inFlight[key] = retry
            }
            await inFlight[key]?.value
            return
        }
        let token = RunToken()
        owner[key] = token
        let task = Task { [weak self] () -> Void in
            await self?.runFetch(assetID: assetID, side: side, key: key, token: token)
        }
        inFlight[key] = task
        await task.value
    }

    /// Declares the warm window. Starts a prefetch for every id that is
    /// neither cached nor already in flight, and cancels the in-flight
    /// request for every id no longer named. This method never suspends
    /// the caller. It starts the prefetches and returns at once.
    func setWindow(_ assetIDs: [String], side: CGFloat = PosterCache.feedSide) {
        wdMark("posterCache")
        let wanted = Set(assetIDs.map { Self.key(for: $0, side: side) })
        for (key, task) in inFlight where !wanted.contains(key) {
            task.cancel()
        }
        for assetID in assetIDs {
            let key = Self.key(for: assetID, side: side)
            guard cache.object(forKey: key as NSString) == nil, inFlight[key] == nil else { continue }
            let token = RunToken()
            owner[key] = token
            let task = Task { [weak self] () -> Void in
                await self?.runFetch(assetID: assetID, side: side, key: key, token: token)
            }
            inFlight[key] = task
        }
    }

    /// The shared fetch body for both `poster(for:side:onImage:)` and
    /// `setWindow`'s own prefetch. It writes each image `posterImages`
    /// yields into `cache` as it arrives, then hands it to every
    /// subscriber registered for this key, so a later `image(for:)` sees
    /// the newest image.
    ///
    /// `token` identifies this call's own start of the fetch. The teardown
    /// below clears `inFlight`, `subscribers`, and `owner` only when
    /// `token` is still the current owner for `key`. See the `owner`
    /// property above for why a stale teardown must not run.
    private func runFetch(assetID: String, side: CGFloat, key: String, token: RunToken) async {
        for await rawImage in PhotoLibraryService.shared.posterImages(for: assetID, side: side) {
            // PhotoKit hands back a lazy image (opportunistic and fast),
            // so SwiftUI would otherwise decode a 1920-px poster on the
            // main thread at first draw. Decode it here, off the main
            // actor, before it is cached or delivered.
            let image = await Task.detached(priority: .userInitiated) { rawImage.preparingForDisplay() ?? rawImage }.value
            if Task.isCancelled { return }
            cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            for subscriber in subscribers[key] ?? [] {
                subscriber(image)
            }
        }
        guard owner[key] === token else { return }
        inFlight[key] = nil
        subscribers[key] = nil
        owner[key] = nil
    }

    /// Returns the decoded byte count. `cache.totalCostLimit` only
    /// reflects real memory use when the cost is the decoded size, not
    /// the compressed source size.
    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    #if DEBUG
    /// Drops every cached and in-flight entry. Used only by the
    /// `-cloudfull-reset-deck-state` launch path.
    func resetForTesting() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        subscribers.removeAll()
        owner.removeAll()
        cache.removeAllObjects()
    }
    #endif
}
