//
//  DuoContextQueries.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Photos
import UIKit
import os

/// PhotoKit lookups for the Duo book's right page (pose 4/4W): the
/// "Same day" 3×3 grid and the "Biggest" list.
///
/// Every query here is a narrow `PHFetchOptions` predicate with a
/// `fetchLimit`, never a walk of the whole library. `PhotoLibraryService
/// .videoIndex(sort:)` enumerates every video for the main deck, which is
/// the right tradeoff there because the deck needs the whole pool. The
/// right page needs nine tiles and eight rows, out of a library that can
/// hold 186,000 items, so it asks PhotoKit to do the narrowing instead of
/// fetching everything and filtering in Swift.
///
/// Every entry point is `nonisolated static` and does its PhotoKit work
/// inside `Task.detached`, the same shape as `PhotoLibraryService
/// .loadVideoIndex(sort:)`. "Same day" also needs one cheap hop to the
/// main actor, to ask `AssetKeyResolver` which candidates are already
/// queued for trash; that resolver is `@MainActor`, and the hop only ever
/// filters an array already bounded to `fetchLimit`, never PhotoKit I/O.
enum DuoContextQueries {

    // MARK: - Same day

    /// One tile in the "Same day" grid: play-on-tap only, so no size or
    /// pixel data travels with it.
    struct ContextAsset: Sendable, Identifiable, Equatable {
        let id: String
        let creationDate: Date?
        let duration: TimeInterval
    }

    struct SameDayResult: Sendable {
        /// Up to nine assets, oldest first (matches the grid's reading
        /// order). Never includes the video the right page is open next
        /// to, and never one already queued for trash.
        let assets: [ContextAsset]
        /// The video's own creation date. The header reads "Same day ·
        /// Jun 8" against this when `usedWeekFallback` is false.
        let referenceDate: Date
        /// True once the day alone could not fill nine tiles and the
        /// query widened to the calendar week.
        let usedWeekFallback: Bool
        /// Only set when `usedWeekFallback` is true: the exact
        /// `Calendar.dateInterval(of: .weekOfYear, for:)` bounds this
        /// result was drawn from, for a "Same week · Jun 3–9" header.
        /// `DuoRightPage` formats the bounds; this type only hands back
        /// the interval it already had to compute to run the query.
        let weekInterval: DateInterval?
    }

    /// Up to nine videos from the same calendar day as `referenceDate`,
    /// falling back to the same calendar week when the day alone has
    /// fewer than nine eligible candidates.
    ///
    /// `currentID` (the video the right page sits next to) is dropped
    /// first, so a tap can never "play next" the video already playing.
    /// `AssetKeyResolver.shared.isQueued` drops anything already queued
    /// for trash; a liked or filtered-out video is not excluded, since the
    /// grid is a browsing surface, not the main deck's pool.
    nonisolated static func sameDay(
        around referenceDate: Date,
        excluding currentID: String,
        calendar: Calendar = .current
    ) async -> SameDayResult {
        let started = Date()

        var usedWeekFallback = false
        var weekInterval: DateInterval?

        var picked: [VideoFacts] = []
        if let dayPredicate = dayPredicate(containing: referenceDate, calendar: calendar) {
            let dayCandidates = await Task.detached(priority: .userInitiated) {
                Self.fetchVideos(matching: dayPredicate, fetchLimit: 40)
            }.value
            picked = await excludingQueuedAndCurrent(dayCandidates, currentID: currentID)
        }

        if picked.count < 9, let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) {
            usedWeekFallback = true
            weekInterval = interval
            let weekPredicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                interval.start as NSDate, interval.end as NSDate
            )
            let weekCandidates = await Task.detached(priority: .userInitiated) {
                Self.fetchVideos(matching: weekPredicate, fetchLimit: 40)
            }.value
            picked = await excludingQueuedAndCurrent(weekCandidates, currentID: currentID)
        }

        let assets = Array(picked.prefix(9)).map {
            ContextAsset(id: $0.id, creationDate: $0.creationDate, duration: $0.duration)
        }
        logSameDay(count: assets.count, usedWeekFallback: usedWeekFallback, ms: msSince(started))
        return SameDayResult(
            assets: assets,
            referenceDate: referenceDate,
            usedWeekFallback: usedWeekFallback,
            weekInterval: weekInterval
        )
    }

    /// The one place this file reads `AssetKeyResolver`. Hops to the main
    /// actor once per candidate list (at most twice per `sameDay` call: a
    /// day attempt and, only if that falls short, a week attempt). The
    /// filter itself is two `Set` membership checks per candidate, over an
    /// array already bounded by `fetchLimit`, so the hop costs nothing
    /// beyond the actor switch.
    @MainActor
    private static func excludingQueuedAndCurrent(_ facts: [VideoFacts], currentID: String) -> [VideoFacts] {
        let resolver = AssetKeyResolver.shared
        return facts.filter { $0.id != currentID && !resolver.isQueued($0.id) }
    }

    // MARK: - Biggest of the week

    /// One row in the "Biggest" list. Not `Equatable`: `PhotoLibraryService
    /// .AssetSize` isn't, and nothing here needs row-level equality —
    /// `DuoRightPage` reloads the whole list after an action instead of
    /// diffing individual rows.
    struct BiggestAsset: Sendable, Identifiable {
        let id: String
        let creationDate: Date?
        let duration: TimeInterval
        let pixelWidth: Int
        let pixelHeight: Int
        /// The real, resource-level size — never the no-I/O estimate this
        /// query ranks the shortlist with. See `biggestOfWeek`.
        let size: PhotoLibraryService.AssetSize
    }

    struct BiggestResult: Sendable {
        /// Up to eight assets, largest real size first.
        let items: [BiggestAsset]
        /// The calendar week the ranking was drawn from, if the week
        /// could be computed. `nil` only when `Calendar.dateInterval(of:
        /// .weekOfYear, for:)` itself fails, which does not happen for any
        /// real date.
        let weekInterval: DateInterval?
    }

    /// The eight largest videos in the calendar week containing
    /// `referenceDate`, by real file size.
    ///
    /// Two passes, exactly as the spec calls for: a first pass over up to
    /// 300 candidates, ranked by `FeedFilters.estimatedBytes` — pixel count
    /// and duration only, no `PHAssetResource` read — then a second pass
    /// that reads the real resource size (`PhotoLibraryService
    /// .assetSize(for:)`) for only the top 20 estimates. A week rarely
    /// holds 300 videos; the cap exists so one outlier week cannot turn
    /// this into a second full-resource scan.
    ///
    /// Every PHAsset this method touches, including the top-20 re-fetch
    /// for the real size, stays inside the single `Task.detached` call.
    /// `PHAsset` is not `Sendable` and this method never needs to hand one
    /// across an executor boundary: it converts to `BiggestAsset`, a plain
    /// Sendable value, before returning.
    nonisolated static func biggestOfWeek(
        around referenceDate: Date,
        calendar: Calendar = .current
    ) async -> BiggestResult {
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) {
            Self.biggestOfWeekSync(referenceDate: referenceDate, calendar: calendar)
        }.value
        logBiggest(fetched: result.fetchedCount, shown: result.result.items.count, ms: msSince(started))
        return result.result
    }

    private nonisolated static func biggestOfWeekSync(
        referenceDate: Date,
        calendar: Calendar
    ) -> (result: BiggestResult, fetchedCount: Int) {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else {
            return (BiggestResult(items: [], weekInterval: nil), 0)
        }
        let predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            interval.start as NSDate, interval.end as NSDate
        )
        let facts = fetchVideos(matching: predicate, fetchLimit: 300)

        // Pass 1: no I/O. Ranks the whole fetched set by the same estimate
        // `FeedFilters.matches` uses for the Big filter, so "biggest" here
        // means the same thing it means everywhere else in the app.
        let shortlist = facts
            .map { (facts: $0, estimated: FeedFilters.estimatedBytes($0)) }
            .sorted { $0.estimated > $1.estimated }
            .prefix(20)
            .map(\.facts)

        // Pass 2: a real `PHAssetResource` read, only for the 20 the
        // estimate ranked highest. `fetchAsset` is one
        // `fetchAssets(withLocalIdentifiers:)` call per id, the same
        // primitive `PhotoLibraryService.asset(for:)` uses elsewhere.
        let withRealSize: [BiggestAsset] = shortlist.compactMap { facts in
            guard let asset = PhotoLibraryService.fetchAsset(facts.id) else { return nil }
            return BiggestAsset(
                id: facts.id,
                creationDate: facts.creationDate,
                duration: facts.duration,
                pixelWidth: facts.pixelWidth,
                pixelHeight: facts.pixelHeight,
                size: PhotoLibraryService.assetSize(for: asset)
            )
        }
        .sorted { $0.size.bytes > $1.size.bytes }

        let result = BiggestResult(items: Array(withRealSize.prefix(8)), weekInterval: interval)
        return (result, facts.count)
    }

    // MARK: - Thumbnails

    /// Resolves a "Same day" or "Biggest" thumbnail through
    /// `DuoContextThumbnailCache`, so repeated renders of the same grid or
    /// list reuse an already-decoded image instead of re-asking PhotoKit.
    /// `dayKey` should be the same value for every tile on one right-page
    /// render — `referenceDate`'s start of day, or `weekInterval!.start`
    /// after a fallback — so the cache can evict a whole page's images
    /// together when the feed scrolls to a different video. See that
    /// type's own comment.
    static func thumbnail(for id: String, dayKey: Date, side: CGFloat) async -> UIImage? {
        await DuoContextThumbnailCache.shared.thumbnail(for: id, dayKey: dayKey, side: side)
    }

    // MARK: - PhotoKit fetch

    /// The shared fetch body for both queries: narrow by `predicate`,
    /// bound by `fetchLimit`, sorted oldest-first to match the grid's
    /// reading order and `PhotoLibraryService.videoIndex(sort:)`'s own
    /// ascending convention. Converts straight to `VideoFacts`, the same
    /// Sendable shape `videoIndex(sort:)` returns, so both call sites
    /// here reuse `FeedFilters.estimatedBytes` with no translation.
    ///
    /// Call only from inside `Task.detached`, or from another
    /// `nonisolated static` body that already is: this makes a
    /// synchronous PhotoKit fetch.
    private nonisolated static func fetchVideos(matching predicate: NSPredicate, fetchLimit: Int) -> [VideoFacts] {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        let options = PHFetchOptions()
        options.predicate = predicate
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = fetchLimit
        let result = PHAsset.fetchAssets(with: .video, options: options)

        var facts: [VideoFacts] = []
        facts.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            facts.append(VideoFacts(
                id: asset.localIdentifier,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.duration,
                mediaSubtypes: asset.mediaSubtypes,
                creationDate: asset.creationDate
            ))
        }
        return facts
    }

    private nonisolated static func dayPredicate(containing date: Date, calendar: Calendar) -> NSPredicate? {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
    }

    // MARK: - Diagnostics

    /// `-cloudfull-log-duoctx`: one line per query, giving the result
    /// count and wall-clock time, so a slow fetch on a large library shows
    /// up as a number instead of a guess. Off by default, like every other
    /// `-cloudfull-log-` flag. Read with
    /// `log stream --predicate 'category == "DuoContext"'`.
    #if DEBUG
    private nonisolated static let log = Logger(subsystem: "com.cloudfull.app", category: "DuoContext")

    private nonisolated static func logSameDay(count: Int, usedWeekFallback: Bool, ms: Int) {
        guard DiagnosticsGate.isOn("-cloudfull-log-duoctx") else { return }
        let line = "duoctx_sameday_\(count)_week_\(usedWeekFallback ? 1 : 0)_\(ms)ms"
        log.notice("\(line, privacy: .public)")
        DiagnosticsLog.shared.log("DuoContext", line)
    }

    private nonisolated static func logBiggest(fetched: Int, shown: Int, ms: Int) {
        guard DiagnosticsGate.isOn("-cloudfull-log-duoctx") else { return }
        let line = "duoctx_biggest_fetched_\(fetched)_shown_\(shown)_\(ms)ms"
        log.notice("\(line, privacy: .public)")
        DiagnosticsLog.shared.log("DuoContext", line)
    }
    #else
    private nonisolated static func logSameDay(count: Int, usedWeekFallback: Bool, ms: Int) {}
    private nonisolated static func logBiggest(fetched: Int, shown: Int, ms: Int) {}
    #endif

    private nonisolated static func msSince(_ start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}

/// Caches `PhotoLibraryService.thumbnail(for:side:contentMode:.aspectFill)`
/// results for the Duo right page, keyed by `dayKey` — the calendar day or
/// week the current grid/list is showing, not the individual asset id.
///
/// The right page re-renders every time the feed settles on a new video,
/// each with its own "Same day" and "Biggest" query. Without a cache
/// boundary, every video the user has ever paused on this session would
/// keep its thumbnails resident. Keying and evicting by day, instead of by
/// asset, means a session that browses forty videos in one afternoon holds
/// at most `maxDays` worth of 3×3 grids and 8-row lists at once, not forty
/// scattered one-off entries with no shared eviction trigger.
actor DuoContextThumbnailCache {
    static let shared = DuoContextThumbnailCache()

    private var images: [Date: [String: UIImage]] = [:]
    /// Day keys, oldest-touched first. Bounds memory independent of how
    /// many distinct days the session happens to visit.
    private var recentDays: [Date] = []
    private let maxDays = 6

    private init() {}

    func thumbnail(for id: String, dayKey: Date, side: CGFloat) async -> UIImage? {
        if let hit = images[dayKey]?[id] { return hit }
        guard let image = await PhotoLibraryService.shared.thumbnail(
            for: id, side: side, contentMode: .aspectFill
        ) else { return nil }
        store(image, id: id, dayKey: dayKey)
        return image
    }

    private func store(_ image: UIImage, id: String, dayKey: Date) {
        images[dayKey, default: [:]][id] = image
        recentDays.removeAll { $0 == dayKey }
        recentDays.append(dayKey)
        while recentDays.count > maxDays {
            let evicted = recentDays.removeFirst()
            images.removeValue(forKey: evicted)
        }
    }
}
