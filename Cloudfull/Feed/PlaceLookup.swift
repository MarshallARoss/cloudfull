//
//  PlaceLookup.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CoreLocation
import MapKit
import os

/// Reverse-geocodes an asset's `CLLocation` into a short place string, for
/// example "Encino, CA", for the feed caption.
///
/// Uses `MKReverseGeocodingRequest` (MapKit, iOS 26 and later).
/// `CLGeocoder` is deprecated in iOS 26.
///
/// Obey these four rules:
/// - Use `place(for:location:)` only for the current page. Never call it
///   for a preloaded neighbour page. `prefetch(assetID:location:)` below
///   handles the prefetch window instead, through its own concurrency slot
///   that never touches `inFlight`.
/// - Cache every result by asset id, including a true "nothing usable"
///   answer. This way, the same asset never triggers a second lookup.
/// - Keep one request in flight. A new lookup cancels whatever the
///   previous one was still doing, so the newest page always wins the
///   single slot.
/// - Never cache errors or cancellations. They are not a "no place found"
///   answer, so the next visit gets a fresh lookup.
@MainActor
final class PlaceLookup {
    static let shared = PlaceLookup()

    /// Logs which address field `format(_:)` used, and each lookup when
    /// `-cloudfull-log-place` is on.
    private static let log = Logger(subsystem: "com.cloudfull.app", category: "PlaceLookup")

    private var cache: [String: String?] = [:]
    /// Least-recently-used order for `cache`. Without a cap, `cache`
    /// grows by one entry for each geotagged photo that
    /// `PhotoMetadataPrefetcher` prefetches.
    private var cacheOrder: [String] = []
    private let cacheCapacity = 400

    private func rememberPlace(_ place: String?, for assetID: String) {
        cache[assetID] = .some(place)
        if let index = cacheOrder.firstIndex(of: assetID) { cacheOrder.remove(at: index) }
        cacheOrder.append(assetID)
        while cacheOrder.count > cacheCapacity {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        notifyWatchers(assetID)
    }

    /// Listeners for each asset id. `rememberPlace(_:for:)` is the only
    /// write path, so it notifies them for a live lookup, a prefetch, and
    /// a seeded place.
    private var watchers: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]

    /// A stream of "this asset's place changed" signals. It carries no
    /// payload. The listener re-reads `cachedPlace(for:)` itself. Buffers
    /// only the newest signal, the same reasoning as
    /// `PhotoMetadataCache.changes(for:)`.
    func changes(for assetID: String) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let token = UUID()
            watchers[assetID, default: [:]][token] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in
                    PlaceLookup.shared.watchers[assetID]?.removeValue(forKey: token)
                    if PlaceLookup.shared.watchers[assetID]?.isEmpty == true { PlaceLookup.shared.watchers[assetID] = nil }
                }
            }
        }
    }

    private func notifyWatchers(_ assetID: String) {
        guard let listeners = watchers[assetID] else { return }
        for continuation in listeners.values { continuation.yield() }
    }

    /// The current-page request. `MKReverseGeocodingRequest` is one
    /// object for each lookup, so this property enforces one request in
    /// flight.
    private var inFlight: MKReverseGeocodingRequest?
    /// Bounds `prefetch(assetID:location:)` below to 2 concurrent lookups.
    /// This stays separate from `inFlight`. Do not let a prefetch read or
    /// write `inFlight`. A prefetch that cancels the current page lookup
    /// leaves the caption empty.
    private let prefetchLimiter = PlaceLookupSemaphore(limit: 2)

    private init() {}

    /// The resolved place for this asset if one is already known, with no
    /// lookup and no suspension. A double optional. The outer `nil` means
    /// "never resolved". The inner `nil` means "resolved, no place".
    ///
    /// `PhotoPostView` reads this the moment a post appears, so the load
    /// badge can say whether the place was already there ("place pre") or
    /// had to load while the user viewed the photo ("place live").
    func cachedPlace(for assetID: String) -> String?? {
        cache[assetID]
    }

    /// Injects a place resolved in an earlier session, read back from
    /// `PhotoMetaRecord`. Never overwrites a value this session already has.
    func seed(assetID: String, place: String?) {
        guard cache[assetID] == nil else { return }
        rememberPlace(place, for: assetID)
        Self.logLookup("seed", assetID: assetID, place: place, ms: 0)
    }

    func place(for assetID: String, location: CLLocation?) async -> String? {
        if let cached = cache[assetID] {
            Self.logLookup("hit", assetID: assetID, place: cached, ms: 0)
            return cached
        }
        let started = Date()
        guard let location else {
            rememberPlace(nil, for: assetID)
            return nil
        }
        // The newest page wins the single slot. The older call's own
        // `await` below then either throws or returns with `isCancelled`
        // true, and both land on the path that never caches.
        inFlight?.cancel()
        // A failable initializer; the SDK declares it as returning an
        // optional. A refusal here is not a true "no place found" answer,
        // so it is not cached, the same treatment as a thrown error.
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        inFlight = request
        // Checked by identity, so a stale call's completion can never
        // clear a newer call's registration.
        defer { if inFlight === request { inFlight = nil } }

        let mapItems: [MKMapItem]
        do {
            mapItems = try await request.mapItems
        } catch {
            // Any throw, our own `cancel()` from a newer page's lookup, a
            // network failure, or a rate limit, is not a true "no place
            // found" answer, so it is never cached.
            return nil
        }
        // A cancelled request can complete with an empty array instead of
        // a throw. Otherwise an empty array caches as a true miss for the
        // rest of the session. Check both cancellation flags before you
        // write to the cache.
        guard !Task.isCancelled, !request.isCancelled else { return nil }
        let place = Self.format(mapItems)
        rememberPlace(place, for: assetID)
        Self.logLookup("live", assetID: assetID, place: place, ms: Self.msSince(started))
        return place
    }

    /// Fills `cache` for a prefetch-window asset, so `place(for:location:)`
    /// finds the result in the cache when the post appears.
    ///
    /// This is not the same code path as `place(for:location:)`. That
    /// method serves the current page only and cancels whatever the
    /// previous current-page lookup was doing. A prefetch call must never
    /// cancel the real current page's own request, so this runs on its
    /// own concurrency-limited slot and never reads or writes `inFlight`.
    ///
    /// Skips an asset that is already in the cache. This is checked once
    /// before waiting for a slot, and again after, since the on-screen
    /// path may resolve it while this waits. The caller in
    /// `PhotoMetadata.swift` skips an asset with no coordinate.
    func prefetch(assetID: String, location: CLLocation) async {
        guard cache[assetID] == nil else { return }
        let started = Date()
        Self.logLookup("start", assetID: assetID, place: nil, ms: 0)
        await prefetchLimiter.wait()
        defer { Task { await prefetchLimiter.signal() } }
        guard cache[assetID] == nil else { return }
        guard let request = MKReverseGeocodingRequest(location: location) else { return }
        let mapItems: [MKMapItem]
        do {
            mapItems = try await request.mapItems
        } catch {
            // Never cached, the same reasoning as `place(for:location:)`'s
            // own catch: not a true "no place found" answer.
            return
        }
        guard !Task.isCancelled, !request.isCancelled else { return }
        guard cache[assetID] == nil else { return }
        let place = Self.format(mapItems)
        rememberPlace(place, for: assetID)
        Self.logLookup("pre", assetID: assetID, place: place, ms: Self.msSince(started))
    }

    /// `-cloudfull-log-place`: one line per lookup, for example
    /// "place_pre_412ms_Los Angeles, CA_<assetID>". The simulator's seeded
    /// library has no geotags, so this is the only way to confirm
    /// prefetching fires for the window at deal time: log every lookup
    /// and read the order and timing off a device. DEBUG-only and off by
    /// default, like `-cloudfull-log-meta`.
    #if DEBUG
    private static func logLookup(_ stage: StaticString, assetID: String, place: String?, ms: Int) {
        guard DiagnosticsGate.isOn("-cloudfull-log-place") else { return }
        log.notice("place_\(stage, privacy: .public)_\(ms, privacy: .public)ms_\(place ?? "none", privacy: .public)_\(assetID, privacy: .public)")
        DiagnosticsLog.shared.log("PlaceLookup", "place_\(stage)_\(ms)ms_\(place ?? "none")_\(assetID)")
    }
    #else
    private static func logLookup(_ stage: StaticString, assetID: String, place: String?, ms: Int) {}
    #endif

    private static func msSince(_ start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    /// Builds a string like "Los Angeles, CA".
    /// `MKAddressRepresentations.cityWithContext` gives the `locality,
    /// administrativeArea` pair. Do not read `MKMapItem.placemark`; it is
    /// deprecated in iOS 26.
    ///
    /// `mapItems.first` does not always carry the full pair. A
    /// neighbourhood-level or POI-level result can lead the array with a
    /// partial address, for example "Encino" with no state, while a later
    /// item in the same response resolves "Los Angeles, CA". This function
    /// scans the full array for the first item whose `cityWithContext` is
    /// non-nil, before falling back to `mapItems.first`'s weaker fields.
    private static func format(_ mapItems: [MKMapItem]) -> String? {
        let first = mapItems.first
        log.debug("place lookup rungs: addressRepresentations nil=\(first?.addressRepresentations == nil, privacy: .public) cityWithContext=\(first?.addressRepresentations?.cityWithContext ?? "nil", privacy: .private) cityName=\(first?.addressRepresentations?.cityName ?? "nil", privacy: .private) name=\(first?.name ?? "nil", privacy: .private) items=\(mapItems.count, privacy: .public)")
        if let winner = mapItems.first(where: { trimmed($0.addressRepresentations?.cityWithContext) != nil }) {
            return trimmed(winner.addressRepresentations?.cityWithContext)
        }
        guard let item = first else { return nil }
        let address = item.addressRepresentations
        if let city = trimmed(address?.cityName) {
            return city
        }
        if let name = trimmed(item.name) {
            return name
        }
        if let region = trimmed(address?.regionName) {
            return region
        }
        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

/// A small counting semaphore that limits `prefetch` concurrency. It
/// copies the file-private `AsyncSemaphore` in `PhotoMetadata.swift`, so
/// that type can stay private.
private actor PlaceLookupSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
