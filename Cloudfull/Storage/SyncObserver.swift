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
            self?.handleEventNotification(notification)
        }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
            self?.refreshAccountStatus()
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

    /// (1) Re-resolves rotation candidates and shield/queue membership;
    /// (2) tells `TrashService` a remote change landed, so a remote
    /// Keep can pull its asset back out of the bin; (3) tells both
    /// decks to recompute their pool counts. In that order, so the
    /// resolver's shield set is current before `TrashService` reads it.
    private func refresh() async {
        // M7-QUESTION: the spec says only "SyncObserver re-requests once
        // after 2 s" for the `.pending` case, not the exact mechanism.
        // Conservative reading: detect that `refreshAfterRemoteChange()`
        // took its no-op `.pending` branch (state is still `.pending`
        // after it returns, since every other branch leaves state
        // `.resolved`, `.clean`, `.partial`, or unchanged at `.unprimed`),
        // then wait 2 s and ask exactly once more.
        await AssetKeyResolver.shared.refreshAfterRemoteChange()
        if AssetKeyResolver.shared.state == .pending {
            // `refreshAfterRemoteChange()` found a resolution already in
            // flight and did nothing. Ask again once, after the window
            // an ordinary resolution needs to land.
            try? await Task.sleep(for: .seconds(2))
            await AssetKeyResolver.shared.refreshAfterRemoteChange()
        }

        trash?.handleRemoteChange()
        deck?.refreshPoolAfterExternalChange()
        PhotoDeck.shared.refreshPoolAfterExternalChange()

        #if DEBUG
        let context = CloudfullModelContainer.shared.mainContext
        let liked = (try? context.fetchCount(FetchDescriptor<LikedEntry>())) ?? 0
        let trashCount = (try? context.fetchCount(FetchDescriptor<TrashEntry>())) ?? 0
        DiagnosticsLog.shared.log("Sync", "sync_refresh_\(liked)_\(trashCount)")
        #endif
    }
}
