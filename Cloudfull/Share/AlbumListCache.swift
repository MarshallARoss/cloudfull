//
//  AlbumListCache.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import Photos

/// The album list, held in memory and kept in the order the user last used.
///
/// This type keeps to a few rules:
///
/// * Opening the app loads the list off the main thread, so nothing waits
///   on it.
/// * Tapping Add to Album shows what is already loaded, with no refetch.
/// * Adding to an album moves that album to the top, again with no
///   refetch, and the next open shows it there. Repeat adds keep stacking
///   that way for as long as the session lasts.
/// * After the first load, a refetch happens only when the app returns
///   from the background.
/// * An exception: if the picker was on screen when the app backgrounded,
///   the list stays as it is instead of refreshing.
/// * If a tap arrives before the first fetch finishes, the picker shows a
///   loader instead of a stale or empty list.
///
/// Limit: the list does not show album changes that the Photos app makes
/// while Cloudfull is in the foreground. The next background-and-return
/// shows them. On an iCloud library, `photoLibraryDidChange` fires often,
/// so a refresh on each notification makes the cache useless.
@MainActor
final class AlbumListCache: ObservableObject {
    static let shared = AlbumListCache()

    /// The list, or nil before the first fetch loads anything. `isLoading`
    /// tells the difference between "still fetching" and "fetched and
    /// empty".
    @Published private(set) var albums: [PhotoLibraryService.AlbumSummary]?
    @Published private(set) var isLoading = false

    /// The album the user just made with +, pinned to the top of the
    /// picker in its own section until they have seen it there once.
    ///
    /// Creating an album already adds the current item and closes the
    /// sheet, so the pin applies to the next open of the picker. It
    /// survives exactly one presentation, then clears itself.
    @Published private(set) var pinnedNewAlbumID: String?
    /// Set once the pin has actually been on screen, so `pickerBecameHidden`
    /// knows to drop it. Without this, the same dismissal that creating the
    /// album caused would clear the pin, and the user would never see it.
    private var pinWasShown = false

    /// True while the picker is on screen. This is the one condition that
    /// suppresses the refresh-on-return.
    private var isPickerVisible = false
    /// Set when the app backgrounds with the picker not visible. Consumed
    /// on the way back in.
    private var needsRefreshOnForeground = false
    private var fetchTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Cloudfull's own record of when the user last added to each album
    /// through this app, keyed by album id. It preserves that order across
    /// launches. PhotoKit offers nothing here: a `PHAssetCollection`
    /// exposes only `startDate`/`endDate`, the date range of its contents,
    /// never the date the user filed something into it.
    ///
    /// `UserDefaults`, not SwiftData, on purpose: this is a sort hint, not
    /// user data. Losing it degrades the order to the PhotoKit heuristic
    /// and costs nothing else.
    private static let recencyKey = "albumPicker.lastAddedThroughCloudfull"

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidEnterBackground() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillEnterForeground() }
        })
    }

    // MARK: - Loading

    /// Starts the background fetch if nothing is loaded and nothing is in
    /// flight. Safe to call from anywhere, any number of times.
    ///
    /// The feeds call this when they appear, and the picker calls it when
    /// it opens. A tap on Add to Album then usually finds a loaded list.
    func prewarm() {
        guard albums == nil, fetchTask == nil else { return }
        refresh()
    }

    /// Fetches unconditionally, replacing whatever is held.
    func refresh() {
        fetchTask?.cancel()
        isLoading = true
        log("album_fetch_start")
        fetchTask = Task { [weak self] in
            // `userAlbums()` is `nonisolated static`, so this runs off the
            // main actor. It makes one `PHAsset.fetchAssets(in:)` call per
            // regular album, so its cost grows with the number of albums.
            let fetched = await Task.detached(priority: .utility) {
                PhotoLibraryService.userAlbums()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.albums = Self.sortedByRecency(fetched)
            self.isLoading = false
            self.fetchTask = nil
            self.log("album_fetch_done_\(fetched.count)")
        }
    }

    // MARK: - Ordering

    /// Moves `albumID` to the head of the in-memory list and records the
    /// timestamp that will reproduce that order after the next fetch.
    ///
    /// This does not refetch. It adds 1 to the row's count and sets its
    /// newest date to now.
    func noteAdded(albumID: String) {
        noteRecency(albumID: albumID)
        guard var list = albums, let index = list.firstIndex(where: { $0.id == albumID }) else { return }
        let existing = list.remove(at: index)
        list.insert(
            PhotoLibraryService.AlbumSummary(
                id: existing.id,
                title: existing.title,
                count: existing.count + 1,
                keyAssetID: existing.keyAssetID,
                newestAssetDate: Date()
            ),
            at: 0
        )
        albums = list
        log("album_moved_to_top")
    }

    /// A brand-new album, one the list has never seen, goes straight to the
    /// top. It is, by definition, the most recently added to.
    func noteCreated(albumID: String, title: String, keyAssetID: String?) {
        noteRecency(albumID: albumID)
        var list = albums ?? []
        list.removeAll { $0.id == albumID }
        list.insert(
            PhotoLibraryService.AlbumSummary(
                id: albumID,
                title: title,
                count: 1,
                keyAssetID: keyAssetID,
                newestAssetDate: Date()
            ),
            at: 0
        )
        albums = list
        pinnedNewAlbumID = albumID
        pinWasShown = false
        log("album_created_to_top")
    }

    /// Sorts newest first. The sort date is the later of Cloudfull's own
    /// record and the newest asset's creation date. Albums with neither
    /// date sort last, by title.
    private static func sortedByRecency(
        _ list: [PhotoLibraryService.AlbumSummary]
    ) -> [PhotoLibraryService.AlbumSummary] {
        let recency = storedRecency()
        func date(_ album: PhotoLibraryService.AlbumSummary) -> Date? {
            let ours = recency[album.id].map(Date.init(timeIntervalSince1970:))
            switch (ours, album.newestAssetDate) {
            case let (ours?, newest?): return max(ours, newest)
            case let (ours?, nil): return ours
            case let (nil, newest?): return newest
            case (nil, nil): return nil
            }
        }
        return list.sorted {
            switch (date($0), date($1)) {
            case let (lhs?, rhs?):
                return lhs == rhs
                    ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    : lhs > rhs
            case (nil, nil):
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            case (_?, nil): return true
            case (nil, _?): return false
            }
        }
    }

    private static func storedRecency() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: recencyKey) as? [String: Double] ?? [:]
    }

    private func noteRecency(albumID: String, at date: Date = Date()) {
        var map = Self.storedRecency()
        map[albumID] = date.timeIntervalSince1970
        UserDefaults.standard.set(map, forKey: Self.recencyKey)
    }

    // MARK: - Foreground / background

    /// The picker tells the cache when it is on screen, because that is the
    /// one case where returning from the background must not trigger a
    /// refresh.
    func pickerBecameVisible() {
        isPickerVisible = true
        if pinnedNewAlbumID != nil { pinWasShown = true }
    }

    func pickerBecameHidden() {
        isPickerVisible = false
        // The pin lasts one presentation: shown on the open after it was
        // created, gone when that open ends.
        if pinWasShown {
            pinnedNewAlbumID = nil
            pinWasShown = false
            log("album_pin_cleared")
        }
    }

    private func appDidEnterBackground() {
        guard !isPickerVisible else {
            log("album_refresh_skipped_picker_visible")
            return
        }
        needsRefreshOnForeground = true
    }

    private func appWillEnterForeground() {
        guard needsRefreshOnForeground else { return }
        needsRefreshOnForeground = false
        refresh()
    }

    private func log(_ message: String) {
        #if DEBUG
        guard DiagnosticsGate.isOn("-cloudfull-log-albums") else { return }
        DiagnosticsLog.shared.log("AlbumCache", message)
        #endif
    }
}
