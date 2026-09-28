//
//  ShareCoordinator.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
import SwiftUI
import Foundation
import Photos
import UIKit

/// Runs the rail's share flow: the Wi-Fi guard, file resolution, the
/// system share sheet, and the album picker. Each feed view (`FeedView`,
/// `PhotoFeedView`) owns one instance as a `@StateObject`, because it
/// holds per-feed presentation state.
@MainActor
final class ShareCoordinator: ObservableObject {

    enum ProbeState: String { case idle, preparing, presented }

    struct PresentedShare: Identifiable {
        let id = UUID()
        let assetID: String
        let url: URL
        let isTemporaryCopy: Bool
        /// Every other file this resolution wrote to disk, in addition to
        /// `url`. The sheet does not get these files directly; see
        /// `activityItems`.
        let additionalURLs: [URL]
        /// Non-nil only for the Live pick, one of the three share options:
        /// Still, Video, and Live (a `.pvt` bundle via
        /// `LivePhotoBundleItemSource`). See the doc comment on
        /// `ShareItemResolver.Resolved.activityItemsOverride`.
        let activityItemsOverride: [Any]?

        /// The items for `UIActivityViewController`. For the Live pick,
        /// this is the `LivePhotoBundleItemSource`. For all other shares,
        /// including the Still and Video picks, it is `url` alone.
        var activityItems: [Any] {
            activityItemsOverride ?? [url]
        }
    }

    struct AlbumPickerTarget: Identifiable { let id: String }        // The id is the asset ID.

    @Published private(set) var probeState: ProbeState = .idle
    @Published private(set) var presentedShare: PresentedShare?
    @Published var albumPickerTarget: AlbumPickerTarget?

    /// Non-nil while a callout shows over the rail. `FeedView` and
    /// `PhotoFeedView` show it with the `feed_coming_soon` accessibility
    /// identifier.
    @Published private(set) var calloutMessage: String?
    /// The download's asset ID and its fraction from 0 to 1. The rail's
    /// Share item renders this as a ring. It is nil when no download
    /// runs.
    struct Download: Equatable { let assetID: String; let fraction: Double }
    @Published private(set) var download: Download?

    #if DEBUG
    /// Last successful album add. The `album_verify_` probe reads this
    /// property.
    @Published private(set) var lastAlbumAdd: (assetID: String, albumID: String, count: Int)?

    /// How many share sheets this coordinator has handed to
    /// `ActivityViewControllerHost`. The `share_presented_count_` probe
    /// reads this value.
    ///
    /// The value only increases. It does not follow `probeState`.
    /// `probeState` passes through `.preparing` in about 17 ms for a
    /// local original, because `ShareItemResolver` hands back the Photos
    /// container's own `AVURLAsset` without copying it. When
    /// `probeState` reaches `.presented`, the activity controller
    /// presents, and UIKit removes FeedView — probes included — from the
    /// app's accessibility tree.
    ///
    /// A poll loop cannot see either non-idle state. `XCUIElement.tap()`
    /// returns only when the app is idle, and presentation starts before
    /// that. The counter does not reset. A test reads it after the sheet
    /// closes and FeedView is in the tree again.
    @Published private(set) var presentedShareCount = 0
    #endif

    private let library: PhotoLibraryService
    private var shareTask: Task<Void, Never>?
    private var calloutHideTask: Task<Void, Never>?
    /// The temporary files that the current resolution wrote. The
    /// coordinator deletes them when the share sheet closes. The list is
    /// empty when the shared URL is the original file (`isTemporaryCopy
    /// == false`). A Live Photo share writes the still and the paired
    /// movie, so this is a list.
    private var pendingTemporaryURLs: [URL] = []
    /// `beginShare` and `cancelShare()` increment this token. A
    /// resolution task compares its captured token to this value. If the
    /// values differ, a newer share or a cancel replaced it, and the
    /// task changes no state.
    private var shareToken = 0

    init(library: PhotoLibraryService = .shared) {
        self.library = library
        Self.purgeShareDirectory()
    }

    deinit {
        shareTask?.cancel()
        calloutHideTask?.cancel()
    }

    private static var shareDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CloudfullShare", isDirectory: true)
    }

    /// Deletes `CloudfullShare/` each time a coordinator is created, so
    /// old temporary files do not stay on disk.
    private static func purgeShareDirectory() {
        try? FileManager.default.removeItem(at: shareDirectory)
    }

    // MARK: - Rail callout

    /// Shows a message, announces it one time, and clears it after 1.8
    /// seconds.
    func presentRailCallout(_ message: String) {
        calloutHideTask?.cancel()
        calloutMessage = message
        AccessibilityNotification.Announcement(message).post()
        calloutHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(1.8 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.calloutMessage = nil
        }
    }

    /// Shows a message that does not hide automatically, such as
    /// "Preparing…". Set `announce` to true to post a VoiceOver
    /// announcement.
    private func presentProgressCallout(_ message: String, announce: Bool) {
        calloutHideTask?.cancel()
        calloutMessage = message
        if announce {
            AccessibilityNotification.Announcement(message).post()
        }
    }

    /// Clears a short callout, such as "Added to Holidays", when the
    /// feed starts to scroll. The callout is on the feed, not on one
    /// page, so after a scroll it can seem to refer to the new page.
    /// While a download runs, the callout stays.
    func dismissCalloutForScroll() {
        guard calloutMessage != nil, download == nil else { return }
        calloutHideTask?.cancel()
        calloutMessage = nil
    }

    private func clearCallout() {
        calloutHideTask?.cancel()
        calloutMessage = nil
        download = nil
    }

    // MARK: - Share

    /// Returns immediately while a share resolves or shows, so a double
    /// tap cannot start two shares. `kind` defaults to `.still`. The
    /// video branch of `ShareItemResolver.resolve` ignores it, and a
    /// non-Live photo has only a still. Only the three items in the Live
    /// photo Share `Menu` (`PhotoPostView.shareButton`) set `kind`.
    func beginShare(assetID: String, kind: ShareKind = .still) {
        guard probeState == .idle else { return }
        Usage.shared.shareSheetOpened()   // `action.<mode>.share` counts only when the sheet finishes on a target.
        // Records the share kind. A video-feed share records "movie". A
        // Live Photo's clip shared as a movie (`.video`) records
        // "liveMovie". The other kinds record their own names.
        Usage.shared.shareKind(Usage.currentMode == .videos ? "movie" : kind == .video ? "liveMovie" : String(describing: kind))

        // Something removed the asset from the library after the page showed it.
        guard library.asset(for: assetID) != nil else {
            presentRailCallout("This video is no longer available.")
            return
        }

        // Blocks an iCloud download on an expensive or constrained
        // network. This is the same check, in the same order, as the
        // guard in `ShrinkService`.
        let mustDownload = !library.isOriginalLocallyAvailable(for: assetID)
        if mustDownload && library.isNetworkExpensiveOrConstrained {
            presentRailCallout("Connect to Wi-Fi to download this video before sharing.")
            return
        }

        probeState = .preparing
        let startedAt = Date()

        if mustDownload {
            download = Download(assetID: assetID, fraction: 0)
            AccessibilityNotification.Announcement("Downloading from iCloud").post()
        }

        // The task captures this token. When it resumes, it compares
        // the token to `self.shareToken`. A difference means that
        // `cancelShare()` or a newer `beginShare` replaced this share.
        shareToken += 1
        let token = shareToken

        shareTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let progressHandler: @MainActor (Double) -> Void = { [weak self] fraction in
                guard let self, mustDownload, token == self.shareToken else { return }
                self.download = Download(assetID: assetID, fraction: min(max(fraction, 0), 1))
            }

            // Shows "Preparing…" only when no download occurs and
            // resolution takes more than 0.4 s. The download path shows
            // a progress ring on the rail.
            let preparingTask: Task<Void, Never>? = mustDownload ? nil : Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(0.4))
                guard !Task.isCancelled, let self else { return }
                self.presentProgressCallout("Preparing…", announce: false)
            }

            do {
                // A task group runs the resolver against a 120 s timer.
                // When the timer finishes first, it throws
                // `Failure.timedOut` instead of a generic
                // `CancellationError`. `group.cancelAll()` stops the
                // other task. The resolver sees the cancel through
                // `Task.checkCancellation()` and the PhotoKit
                // cancellation handler.
                let result = try await withThrowingTaskGroup(of: ShareItemResolver.Resolved.self) { group in
                    group.addTask {
                        try await ShareItemResolver.resolve(assetID: assetID, kind: kind, allowNetwork: mustDownload, progress: progressHandler)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(120))
                        throw ShareItemResolver.Failure.timedOut
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else {
                        throw ShareItemResolver.Failure.unsupported
                    }
                    return first
                }
                preparingTask?.cancel()
                // Stores the temporary URLs before the guard. If a
                // cancel or a newer share replaced this task, the guard
                // can then delete the new copies, which can be several
                // GB.
                self.pendingTemporaryURLs = result.temporaryURLs
                guard !Task.isCancelled, token == self.shareToken else {
                    // A cancel or a newer `beginShare` replaced this
                    // task. Delete this task's temporary files, and do
                    // not change the state of the newer share.
                    self.purgePendingTemporaryURL()
                    self.clearCallout()
                    // Set `.idle` only if no newer share started. Do
                    // not overwrite the state of a newer share.
                    if token == self.shareToken { self.probeState = .idle }
                    return
                }
                if mustDownload || Date().timeIntervalSince(startedAt) > 0.4 {
                    self.clearCallout()
                }
                self.probeState = .presented
                self.presentedShare = PresentedShare(
                    assetID: assetID,
                    url: result.url,
                    isTemporaryCopy: result.isTemporaryCopy,
                    additionalURLs: result.additionalURLs,
                    activityItemsOverride: result.activityItemsOverride
                )
                #if DEBUG
                self.presentedShareCount += 1
                #endif
            } catch {
                preparingTask?.cancel()
                self.purgePendingTemporaryURL()
                // A newer `beginShare` replaced this task. This failure
                // is not for the current share, so do nothing.
                guard token == self.shareToken else { return }
                self.clearCallout()
                self.probeState = .idle
                // A cancel by the user shows no callout. The cancel
                // arrives as `CancellationError` or as
                // `Failure.cancelled` from the resolver. Other errors
                // show a failure callout.
                if !(error is CancellationError), !Self.isCancelledFailure(error) {
                    Usage.shared.shareFailed()
                    self.presentRailCallout("Couldn't prepare this video to share.")
                }
            }
        }
    }

    func cancelShare() {
        // Increment the token before the cancel. Then the task's token
        // check fails on its next resume, from the `catch` block or
        // from the success path.
        shareToken += 1
        shareTask?.cancel()
        shareTask = nil
        clearCallout()
        probeState = .idle
        presentedShare = nil
        purgePendingTemporaryURL()
    }

    /// Returns true for `ShareItemResolver.Failure.cancelled`. The
    /// resolver's cancel checks can throw this error instead of
    /// `CancellationError`. Treat it as a cancel and show no callout.
    private static func isCancelledFailure(_ error: Error) -> Bool {
        if case ShareItemResolver.Failure.cancelled = error { return true }
        return false
    }

    /// Deletes the files in `pendingTemporaryURLs` and clears the list.
    /// `cancelShare()`, a replaced or cancelled task, and
    /// `shareSheetFinished` all call this method.
    private func purgePendingTemporaryURL() {
        for url in pendingTemporaryURLs {
            // Each temporary file or bundle is in its own UUID directory
            // (see `ShareItemResolver.writeResourceCopy` and
            // `LivePhotoBundle.make`). Delete the directory, not only
            // the item.
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        pendingTemporaryURLs = []
    }

    /// `ActivityViewControllerHost` calls this from
    /// `completionWithItemsHandler`.
    func shareSheetFinished(activityType: UIActivity.ActivityType?) {
        let assetID = presentedShare?.assetID
        // Where the share went. Usage.shared.shareFinished records both
        // the family and Apple's own raw activity identifier.
        Usage.shared.shareFinished(Usage.shareTarget(for: activityType?.rawValue, albumType: AddToAlbumActivity.activityType.rawValue), raw: activityType?.rawValue)
        probeState = .idle
        presentedShare = nil
        purgePendingTemporaryURL()
        guard activityType == AddToAlbumActivity.activityType, let assetID else { return }
        // Set `albumPickerTarget` on the next main run-loop turn.
        // `presentedShare = nil` only starts the dismissal of the
        // activity controller. If the picker presents in the same turn,
        // SwiftUI can drop the picker. Waiting one turn lets the
        // dismissal commit first.
        DispatchQueue.main.async { [weak self] in
            self?.albumPickerTarget = AlbumPickerTarget(id: assetID)
        }
    }

    // MARK: - Album picker actions

    /// Adds `assetID` to an existing album. Re-resolves `assetID`
    /// against the library before writing. This stops the method from
    /// reporting success when the asset vanished between the sheet
    /// opening and the row tap.
    func addToAlbum(assetID: String, albumID: String) async -> Bool {
        guard library.asset(for: assetID) != nil else { return false }
        // Check for the asset in the album first. `performChanges`
        // ignores Swift cancellation, so a write that timed out can
        // still complete. A second add would make a duplicate.
        if await PhotoLibraryService.album(albumID, contains: assetID) {
            Usage.shared.action(.album, source: .rail, mode: Usage.currentMode)
            let count = library.assetCount(inAlbumWithIdentifier: albumID)
            didAdd(assetID: assetID, albumID: albumID, count: count, albumTitle: albumTitle(for: albumID))
            return true
        }
        let ok = await library.addAsset(assetID, toAlbumWithIdentifier: albumID)
        guard ok else { return false }
        Usage.shared.action(.album, source: .rail, mode: Usage.currentMode)   // Counted only after a successful add.
        let count = library.assetCount(inAlbumWithIdentifier: albumID)
        didAdd(assetID: assetID, albumID: albumID, count: count, albumTitle: albumTitle(for: albumID))
        return true
    }

    /// Returns the new album's identifier, or nil on failure.
    ///
    /// `AlbumListCache` needs the id to put the new album at the top of
    /// its list. Without it, `AlbumListCache` would have to refetch
    /// every album to learn about one new row.
    @discardableResult
    func createAlbumAndAdd(assetID: String, title: String) async -> String? {
        guard library.asset(for: assetID) != nil else { return nil }
        guard let albumID = await library.createAlbum(named: title, addingAssetID: assetID) else { return nil }
        let count = library.assetCount(inAlbumWithIdentifier: albumID)
        didAdd(assetID: assetID, albumID: albumID, count: count, albumTitle: title)
        return albumID
    }

    private func albumTitle(for albumID: String) -> String? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject?.localizedTitle
    }

    /// Plays `Haptics.tap()` and shows "Added to <album>" after a
    /// successful write to the photo library. A queued delete uses the
    /// same haptic.
    private func didAdd(assetID: String, albumID: String, count: Int, albumTitle: String?) {
        Haptics.tap()
        presentRailCallout("Added to \(albumTitle ?? "Album")")
        #if DEBUG
        lastAlbumAdd = (assetID: assetID, albumID: albumID, count: count)
        #endif
    }
}
