//
//  SyncObserver.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftData
import CoreData
import CloudKit
import os

/// Reacts to CloudKit's own sync activity: an import landing another
/// device's data, an export finishing, or the signed-in account
/// changing. SwiftData's CloudKit mirroring writes new rows directly to
/// disk; nothing here moves data. This type only tells the rest of the
/// app to re-read the store after that happens.
///
/// `AssetKeyResolver`, `TrashService`, and `DeckViewModel`/`PhotoDeck`
/// each already refresh after a *local* change (a tap, a PhotoKit
/// notification). This type is the remote-change twin: the same
/// refresh, triggered by a CloudKit import instead.
@MainActor
final class SyncObserver: ObservableObject {
    static let shared = SyncObserver()

    /// `SettingsView`'s "iCloud sync" row reads this. `nil` until the
    /// first `accountStatus()` call returns. Only meaningful when
    /// `CloudfullModelContainer.mode == .cloudKit`; `SettingsView` does
    /// not read it otherwise.
    @Published private(set) var accountAvailable: Bool?

    private weak var trash: TrashService?
    private weak var deck: DeckViewModel?
    private var didAttach = false

    private var eventObserver: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?

    private static let log = Logger(subsystem: "com.cloudfull.app", category: "Sync")

    private init() {}

    deinit {
        if let eventObserver { NotificationCenter.default.removeObserver(eventObserver) }
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    /// Registers the two observers once per process. `AuthorizedSession`
    /// calls this at the end of its own `init`, every time it builds a
    /// session, but `didAttach` makes only the first call actually
    /// register anything. Weak references to `trash` and `deck` mean a
    /// discarded session's services do not leak through this singleton;
    /// a later `attach(trash:deck:)` call simply replaces them.
    func attach(trash: TrashService, deck: DeckViewModel) {
        self.trash = trash
        self.deck = deck
        guard !didAttach else { return }
        didAttach = true

        refreshAccountStatus()

        // `NSPersistentCloudKitContainer.eventChangedNotification` fires
        // for every setup, import, and export, finished or not. `object:
        // nil` matches every poster; SwiftData gives no handle to the
        // specific `NSPersistentCloudKitContainer` it builds internally.
        eventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // `queue: .main` above guarantees this closure runs on the
            // main queue, so it is safe to assume MainActor isolation
            // here. Same pattern as `OrientationMonitor.start()` and
            // `MainThreadWatchdog.start()`: the closure itself is plain,
            // not `@MainActor`, so it cannot call an isolated method
            // directly without this.
            MainActor.assumeIsolated {
                self?.handleEventNotification(notification)
            }
        }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRefresh()
                self?.refreshAccountStatus()
            }
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(CloudfullApp.simulateRemoteKeepArgument) {
            SyncTestHarness.simulateRemoteKeepAfterDelay()
        }
        #endif
    }

    // MARK: - CloudKit account status

    func refreshAccountStatus() {
        guard CloudfullModelContainer.mode == .cloudKit,
              let containerID = CloudfullModelContainer.cloudContainerID else {
            accountAvailable = nil
            return
        }
        Task {
            let status = try? await CKContainer(identifier: containerID).accountStatus()
            accountAvailable = (status == .available)
        }
    }

    // MARK: - CloudKit import/export events

    private func handleEventNotification(_ notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
        guard event.endDate != nil else { return }   // still running; nothing to react to yet

        #if DEBUG
        // These lines are the sync proof (Step G2): `ck_setup_ok`, then
        // `ck_export_ok`/`ck_import_ok` as CloudKit actually moves data.
        let kind: String
        switch event.type {
        case .setup: kind = "setup"
        case .import: kind = "import"
        case .export: kind = "export"
        @unknown default: kind = "unknown"
        }
        DiagnosticsLog.shared.log("Sync", "ck_\(kind)_\(event.succeeded ? "ok" : "fail")")
        if !event.succeeded, let error = event.error {
            Self.log.error("\(error.localizedDescription, privacy: .public)")
        }
        #endif

        guard event.type == .import, event.succeeded else { return }
        scheduleRefresh()
    }

    // MARK: - Coalesced refresh

    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false

    /// Coalesces a burst of import events and account-change
    /// notifications into one refresh: one task, sleep 2 s, then
    /// `refresh()`. A request that lands while a refresh is already
    /// scheduled or running sets a flag that runs exactly one more pass
    /// afterward, the same shape `TrashService.scheduleReconciliation`
    /// uses.
    func scheduleRefresh() {
        guard refreshTask == nil else { refreshAgain = true; return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            await self.refresh()
            self.refreshTask = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.scheduleRefresh()
            }
        }
    }

    /// Liked/Trash row counts as of the last pass that actually ran the
    /// trash/deck refresh below. `-1` guarantees the first pass runs it.
    private var lastRefreshedLikedCount = -1
    private var lastRefreshedTrashCount = -1

    /// (1) Re-resolves rotation candidates and shield/queue membership;
    /// (2) tells `TrashService` a remote change landed, so a remote
    /// Keep can pull its asset back out of the bin; (3) tells both
    /// decks to recompute their pool counts. In that order, so the
    /// resolver's shield set is current before `TrashService` reads it.
    ///
    /// (2) always runs. A row count alone cannot stand in for "the bin
    /// needs to reload": an import that only fills a `cloudKey` on an
    /// already-queued row, or merges a remote delete of a row this
    /// session still holds a stale reference to, changes nothing this
    /// method could count, and skipping `handleRemoteChange()` would
    /// leave `TrashService.entries` holding what could be a dead
    /// `TrashEntry`. `handleRemoteChange()`'s own `load()` rebuilds
    /// `entriesByLiveKey` from a fresh fetch regardless, so this call is
    /// never wasted even when nothing actually changed.
    ///
    /// (3) runs only when the Liked or Trash row count actually changed
    /// since the last pass. An import that only touched
    /// `SeenEntry`/`PhotoSeenEntry` rows — the common case while two
    /// devices are both active — needs neither the resolver's `.pending`
    /// detour (see `refreshAfterRemoteChange()`) nor a pool-count
    /// reload, so this check keeps the decks from reloading for no
    /// visible change.
    private func refresh() async {
        await AssetKeyResolver.shared.refreshAfterRemoteChange()

        let context = CloudfullModelContainer.shared.mainContext
        let liked = (try? context.fetchCount(FetchDescriptor<LikedEntry>())) ?? 0
        let trashCount = (try? context.fetchCount(FetchDescriptor<TrashEntry>())) ?? 0
        let likedOrTrashChanged = liked != lastRefreshedLikedCount || trashCount != lastRefreshedTrashCount
        lastRefreshedLikedCount = liked
        lastRefreshedTrashCount = trashCount

        trash?.handleRemoteChange()
        if likedOrTrashChanged {
            deck?.refreshPoolAfterExternalChange()
            PhotoDeck.shared.refreshPoolAfterExternalChange()
        }

        #if DEBUG
        DiagnosticsLog.shared.log("Sync", "sync_refresh_\(liked)_\(trashCount)")
        #endif
    }
}
