//
//  KeyRotationHarness.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftData

#if DEBUG
/// The surface `LikedEntry` and `TrashEntry` share, so `KeyRotationHarness`
/// can rewrite either type's `assetKey` through one generic function
/// instead of two near-identical copies.
protocol RotatableAssetEntry: PersistentModel {
    var assetKey: String { get set }
    var cloudKey: String? { get }
}
extension LikedEntry: RotatableAssetEntry {}
extension TrashEntry: RotatableAssetEntry {}

/// Test-only harness that simulates a device restore or migration.
/// PhotoKit then gives an asset a new local identifier, and a stored row
/// keeps the old one.
///
/// It rewrites one `LikedEntry` row and one `TrashEntry` row so their
/// stored `assetKey` can no longer resolve directly, while leaving
/// `cloudKey` untouched. A UI test uses this to prove that
/// `AssetKeyResolver` still finds the asset through `cloudKey`. A like or
/// trash tap cannot test this, because the raw key does not change
/// during one run.
///
/// `#if DEBUG` encloses this whole file, so a release build cannot
/// rewrite its own store this way.
enum KeyRotationHarness {
    @MainActor
    static func rotate(container: ModelContainer) {
        let context = ModelContext(container)

        let likedLiveID = rotateNewestCandidate(
            of: LikedEntry.self,
            in: context,
            sortDescriptor: SortDescriptor(\LikedEntry.likedAt, order: .reverse)
        )
        let trashLiveID = rotateNewestCandidate(
            of: TrashEntry.self,
            in: context,
            sortDescriptor: SortDescriptor(\TrashEntry.queuedAt, order: .reverse)
        )

        try? context.save()
        RotationProbe.shared.record(likedLiveID: likedLiveID, trashLiveID: trashLiveID)
    }

    /// Rewrites the `assetKey` of the newest row that has a `cloudKey`,
    /// and returns that row's live id.
    ///
    /// Resolves its current live id first. The probe then reads the id
    /// the deck shows, not the stored one this method is about to
    /// overwrite.
    ///
    /// Then it rewrites `assetKey` to a placeholder prefixed `DEAD-`. A
    /// reader of the store, a log, or the probe can then see that the
    /// key is a test placeholder.
    ///
    /// Returns the resolved live id, or `nil` if there was no eligible
    /// row, or its cloud key does not resolve. `rotate` records a `nil`
    /// in `RotationProbe`, so the UI test fails when no row rotates.
    private static func rotateNewestCandidate<T: RotatableAssetEntry>(
        of type: T.Type,
        in context: ModelContext,
        sortDescriptor: SortDescriptor<T>
    ) -> String? {
        let descriptor = FetchDescriptor<T>(sortBy: [sortDescriptor])
        guard let rows = try? context.fetch(descriptor) else { return nil }
        guard let target = rows.first(where: { $0.cloudKey != nil }) else { return nil }
        guard let cloudKey = target.cloudKey else { return nil }

        let mapping = PhotoLibraryService.localIdentifierMappings(forCloudIdentifiers: [cloudKey])
        guard let liveID = mapping[cloudKey] else { return nil }

        target.assetKey = "DEAD-\(UUID().uuidString)/L0/001"
        return liveID
    }
}
#endif
