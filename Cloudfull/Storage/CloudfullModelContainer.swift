//
//  CloudfullModelContainer.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftData
import Foundation
import os

/// The app's one SwiftData container.
///
/// Opts into CloudKit only when this build carries an iCloud container
/// identifier, and falls back to a local-only store otherwise. This
/// includes any case where the CloudKit store fails to open.
///
/// To turn on CloudKit, add the Info.plist key below. No Swift change is
/// necessary.
///
/// Two `ModelConfiguration`s back the one container. `synced` holds
/// every model CloudKit mirrors (`syncedModels`), at the 1.0 file
/// `default.store`. `local` holds deck position and the recomputable
/// metadata cache (`localModels`), at the new `local.store`. Keeping the
/// local models out of the CloudKit config, with their own explicit
/// `schema:`, is what stops them from ever syncing: a config built
/// without an explicit schema gets the whole container's schema.
enum CloudfullModelContainer {

    enum Mode: String { case cloudKit, localOnly }

    /// Set by `make()`. Read only for logging and for the DEBUG probe.
    private(set) nonisolated(unsafe) static var mode: Mode = .localOnly

    /// Build-settings key to add alongside CODE_SIGN_ENTITLEMENTS once a
    /// developer account with the entitlement exists:
    ///   INFOPLIST_KEY_CloudfullCloudKitContainerIdentifier = iCloud.com.cloudfull.app
    ///
    /// When the key is absent, `declaredCloudContainerIdentifier` is nil
    /// and the CloudKit branch does not run. Reading a declaration the
    /// app controls is the only entitlement check available on iOS
    /// without a private API. Add this key in the same change that adds
    /// the capability. If the CloudKit store still fails to open,
    /// `make()` uses the local-only store.
    private static let containerIDInfoKey = "CloudfullCloudKitContainerIdentifier"

    /// Every model CloudKit mirrors. `make()` and `StoreSplitMigrator`
    /// both build their schemas from this list and `localModels`, so the
    /// two can never drift apart.
    static let syncedModels: [any PersistentModel.Type] = [SeenEntry.self, LikedEntry.self, TrashEntry.self, PhotoSeenEntry.self]
    /// Every model that stays on this device: deck position and the
    /// metadata cache. The cache is large (tens of megabytes) and
    /// recomputable; deck position is per-device by nature.
    static let localModels: [any PersistentModel.Type] = [DeckState.self, DeckOrder.self, PhotoDeckState.self, PhotoMetaRecord.self]

    /// The 1.0 file. Every install before M7 has every model in this one
    /// file, under this same name. `StoreSplitMigrator` moves the local
    /// models out of it before `make()` ever opens it with the narrower,
    /// synced-only schema below.
    static var syncedStoreURL: URL { URL.applicationSupportDirectory.appending(path: "default.store") }
    /// New in M7. Holds `localModels` only. Never opened with a CloudKit
    /// database, so it never syncs regardless of `mode`.
    static var localStoreURL: URL { URL.applicationSupportDirectory.appending(path: "local.store") }

    static let shared: ModelContainer = make()

    private static let log = Logger(subsystem: "com.cloudfull.app", category: "Storage")

    private static var declaredCloudContainerIdentifier: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: containerIDInfoKey) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static var isForcedLocalByTestHarness: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(CloudfullApp.resetStateArgument)
        #else
        return false
        #endif
    }

    private static func make() -> ModelContainer {
        // Must run before either `ModelContainer` below opens
        // `syncedStoreURL`. See `StoreSplitMigrator` for why the order
        // matters: a 1.0 file still carries the local models' rows until
        // this call moves them out.
        StoreSplitMigrator.runIfNeeded()

        let syncedSchema = Schema(syncedModels)
        let localSchema = Schema(localModels)
        let fullSchema = Schema(syncedModels + localModels)
        #if DEBUG
        assertModelSplitIsDisjointAndComplete(syncedSchema: syncedSchema, localSchema: localSchema, fullSchema: fullSchema)
        #endif

        // Every model is in exactly one config, and every config below
        // passes both `schema:` and `cloudKitDatabase:` explicitly.
        let local = ModelConfiguration("local", schema: localSchema, url: localStoreURL, cloudKitDatabase: .none)

        if let containerID = declaredCloudContainerIdentifier, !isForcedLocalByTestHarness {
            // `.automatic` reads the entitlement itself, so the container id
            // above acts as a gate, not a parameter.
            let synced = ModelConfiguration("default", schema: syncedSchema, url: syncedStoreURL, cloudKitDatabase: .automatic)
            if let container = try? ModelContainer(for: fullSchema, configurations: synced, local) {
                mode = .cloudKit
                log.notice("SwiftData store mode: cloudKit (declared container \(containerID, privacy: .public))")
                return container
            }
            log.error("SwiftData store mode: local-only — CloudKit container \(containerID, privacy: .public) declared but failed to open")
        }

        let synced = ModelConfiguration("default", schema: syncedSchema, url: syncedStoreURL, cloudKitDatabase: .none)
        mode = .localOnly
        if declaredCloudContainerIdentifier == nil {
            log.notice("SwiftData store mode: local-only (no CloudKit container declared)")
        }
        do {
            return try ModelContainer(for: fullSchema, configurations: synced, local)
        } catch {
            fatalError("Cloudfull cannot open its local SwiftData store: \(error)")
        }
    }

    #if DEBUG
    /// Every model belongs to exactly one of `syncedModels`/`localModels`,
    /// and their union is the whole container schema. A config built
    /// without this explicit `schema:` split would mirror the deck and
    /// cache tables into CloudKit by accident. This is a build-time
    /// invariant, not a condition a release build needs to recover from,
    /// so it only runs in DEBUG.
    private static func assertModelSplitIsDisjointAndComplete(syncedSchema: Schema, localSchema: Schema, fullSchema: Schema) {
        let syncedNames = Set(syncedSchema.entities.map(\.name))
        let localNames = Set(localSchema.entities.map(\.name))
        let fullNames = Set(fullSchema.entities.map(\.name))
        assert(syncedNames.isDisjoint(with: localNames), "syncedModels and localModels overlap: \(syncedNames.intersection(localNames))")
        assert(syncedNames.union(localNames) == fullNames, "syncedModels + localModels does not equal the full container schema")
    }
    #endif
}
