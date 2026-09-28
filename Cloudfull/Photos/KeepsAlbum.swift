//
//  KeepsAlbum.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A keep also adds the item to a real Photos album, so a user's keeps
/// exist outside this app. An unkeep removes it again.
///
/// This file holds only the policy: the setting, which album, when to
/// create it, what to count. Every PhotoKit call lives in
/// `PhotoLibraryService`'s `nonisolated` album primitives, the same set the
/// album picker uses.
///
/// Three rules shape this policy.
///
/// 1. **The tap stays instant.** Nothing the user touches waits on this. A
///    keep is recorded locally first, in `KeepStore` or `DeckViewModel`.
///    The album write follows as a side effect, off the main actor.
/// 2. **One album, ever.** Two fast keeps must not each create their own
///    "Cloudfull keeps" album. Every operation chains onto one serial task,
///    so the find-or-create step runs once and later operations reuse its
///    result.
/// 3. **Silence on refusal.** Limited Photos access cannot create an album
///    or add an arbitrary asset. That failure is not an error the user
///    needs to see, since their keep already worked. It is counted, not
///    shown.
@MainActor
final class KeepsAlbum {

    static let shared = KeepsAlbum()

    /// The album's name in Photos.
    static let title = "Cloudfull keeps"

    /// The Settings switch. On by default, since the album is the point of
    /// this feature. The switch exists because this app writes to the
    /// user's real Photos library, and some people will not expect that.
    static let settingKey = "settings.keepsAlbum"

    /// The album's local identifier once resolved, so the common path is a
    /// single add with no lookup. UserDefaults keeps the id because the
    /// album outlives the process. `resolveAlbumID` replaces a stale id,
    /// and the `.albumMissing` path removes it. The user can delete the
    /// album in Photos at any time.
    private static let albumIDKey = "keepsAlbum.localIdentifier"

    private let defaults = UserDefaults.standard

    /// Every operation chains onto this one task. This ordering is what
    /// makes the find-or-create race in rule 2 impossible.
    private var work: Task<Void, Never> = Task {}

    private init() {}

    /// Off under XCTest. The UI test suite must not leave a "Cloudfull
    /// keeps" album behind in the real library. Its purge step only
    /// recognizes the "Cloudfull UITest " prefix.
    var isOn: Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        return defaults.object(forKey: Self.settingKey) as? Bool ?? true
    }

    // MARK: - What the feeds call

    func add(_ assetID: String) {
        guard isOn else { return }
        // When this keep creates the album, `seed` adds the asset at
        // creation time. This takes one round trip instead of three.
        enqueue(seed: assetID) { albumID, seeded in
            if seeded {   // The album was created with the asset already in it.
                Usage.shared.keepAlbumAdded(alreadyThere: false)
                return .done
            }
            // The asset is already in the album: succeed without adding it again.
            if await PhotoLibraryService.album(albumID, contains: assetID) {
                Usage.shared.keepAlbumAdded(alreadyThere: true)
                return .done
            }
            let outcome = await PhotoLibraryService.attach(assetID, toAlbum: albumID)
            if outcome == .done { Usage.shared.keepAlbumAdded(alreadyThere: false) }
            return outcome
        }
    }

    func remove(_ assetID: String) {
        // No cached-id guard runs here. The `enqueue` chain serializes
        // every keep and unkeep. A pending keep that creates the album
        // runs first. `resolveAlbumID(creatingIfNeeded: false)` returns
        // nil when no album exists.
        guard isOn else { return }
        enqueue(creatingIfNeeded: false) { albumID, _ in
            let outcome = await PhotoLibraryService.detach(assetID, fromAlbum: albumID)
            if outcome == .done { Usage.shared.keepAlbumRemoved() }
            return outcome
        }
    }

    // MARK: - The serial chain

    /// Resolves the album once, then runs `body`. Chained onto `work`, so
    /// operations never overlap and the album is created at most once.
    private func enqueue(creatingIfNeeded: Bool = true, seed: String? = nil,
                         _ body: @escaping @MainActor (String, Bool) async -> PhotoLibraryService.AlbumChange) {
        let previous = work
        work = Task { @MainActor [weak self] in
            _ = await previous.value
            guard let self else { return }
            let resolved = await self.resolveAlbumID(creatingIfNeeded: creatingIfNeeded, seed: seed)
            guard let albumID = resolved.id else {
                if creatingIfNeeded { Usage.shared.keepAlbumFailed() }   // No album and none wanted: this is not a failure.
                return
            }
            switch await body(albumID, resolved.seeded) {
            case .done:
                return
            case .failed:
                // Limited access, a deleted asset, or a timeout. The album
                // itself is fine, so the cached id stays. Clearing it would
                // make the next write create a second album with the same
                // name.
                Usage.shared.keepAlbumFailed()
            case .albumMissing:
                // The one case worth retrying: the album was deleted in
                // Photos since this id was cached. Forget the cached id and
                // resolve again.
                self.defaults.removeObject(forKey: Self.albumIDKey)
                let fresh = await self.resolveAlbumID(creatingIfNeeded: creatingIfNeeded, seed: seed)
                guard let freshID = fresh.id, await body(freshID, fresh.seeded) == .done else {
                    Usage.shared.keepAlbumFailed()
                    return
                }
            }
        }
    }

    /// Returns the cached id, else the album Photos already has under that
    /// name, else a newly created one.
    /// `seeded` is true when this call just created the album with `seed`
    /// already in it, so the caller can skip its own add.
    private func resolveAlbumID(creatingIfNeeded: Bool, seed: String?) async -> (id: String?, seeded: Bool) {
        if let cached = defaults.string(forKey: Self.albumIDKey),
           await PhotoLibraryService.albumExists(cached) {
            return (cached, false)
        }
        if let found = await PhotoLibraryService.albumID(named: Self.title) {
            defaults.set(found, forKey: Self.albumIDKey)
            return (found, false)
        }
        guard creatingIfNeeded,
              let made = await PhotoLibraryService.makeAlbum(named: Self.title, addingAssetID: seed)
        else { return (nil, false) }
        defaults.set(made, forKey: Self.albumIDKey)
        return (made, seed != nil)
    }
}
