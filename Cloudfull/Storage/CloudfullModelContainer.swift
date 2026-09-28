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
        let schema = Schema([DeckState.self, DeckOrder.self, SeenEntry.self, LikedEntry.self, TrashEntry.self,
                             PhotoDeckState.self, PhotoSeenEntry.self, PhotoMetaRecord.self])

        if let containerID = declaredCloudContainerIdentifier, !isForcedLocalByTestHarness {
            // `.automatic` reads the entitlement itself, so the container id
            // above acts as a gate, not a parameter.
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            if let container = try? ModelContainer(for: schema, configurations: config) {
                mode = .cloudKit
                log.notice("SwiftData store mode: cloudKit (declared container \(containerID, privacy: .public))")
                return container
            }
            log.error("SwiftData store mode: local-only — CloudKit container \(containerID, privacy: .public) declared but failed to open")
        }

        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        mode = .localOnly
        if declaredCloudContainerIdentifier == nil {
            log.notice("SwiftData store mode: local-only (no CloudKit container declared)")
        }
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Cloudfull cannot open its local SwiftData store: \(error)")
        }
    }
}
