//
//  PhotoModels.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftData
import Foundation

// The photo deck's own table. `PhotoDeckState` merges what `DeckState` and
// `DeckOrder` split into two models, since the photo deck has no legacy
// `ids` blob to migrate. The table holds the seed, the cursor, `nextSlot`,
// and `trimmedBeforeSlot`. The cycle-log and exception properties below are
// legacy data. `PhotoDeck.purgeLegacyCycleLog` emptied them once, and they
// stay only because dropping a stored property forces a migration.
// CloudKit-ready: every property has a default value, no #Unique, no #Index.
@Model
final class PhotoDeckState {
    /// The seed of the newest dealt window.
    var seed: Int64 = 0
    /// The highest absolute slot the user has reached (`PhotoDeckEntry.position`).
    var cursor: Int = 0
    /// 1 = the legacy cycle log may hold data. 2 =
    /// `PhotoDeck.purgeLegacyCycleLog` emptied the legacy arrays.
    var schemaVersion: Int = 1

    // --- Legacy cycle log. `PhotoDeck.purgeLegacyCycleLog` emptied these
    //     fields once. Nothing reads them now. ---

    /// The seed that produced each cycle's permutation. 0 marks a literal
    /// cycle (see `cycleIsLiteral`).
    var cycleSeeds: [Int64] = []
    /// The absolute slot number of each cycle's element 0.
    var cycleBaseSlots: [Int] = []
    /// The element count of each cycle.
    var cycleCounts: [Int] = []
    /// The FNV-1a 64 hex digest of the input array for each permutation
    /// (see `ShuffleEngine.digest(of:)`).
    var cycleDigests: [String] = []
    /// The seam guard's rearrangement, replayable: "3>17,5>21" per cycle, ""
    /// when it did nothing.
    var cycleSwaps: [String] = []
    /// True for a cycle whose ids cannot be regenerated from a seed: the
    /// small append cycles a launch-time import merge produced. Their ids
    /// live in `literalIDs`.
    var cycleIsLiteral: [Bool] = []
    /// The flattened ids of every literal cycle, in cycle order.
    var literalIDs: [String] = []

    /// The absolute slots removed since their cycle was dealt: kept,
    /// queued, already seen at deal time, or vanished.
    var exceptionSlots: [Int] = []
    /// The asset id each exception removed, parallel to `exceptionSlots`.
    var exceptionIDs: [String] = []

    /// Slots below this were trimmed at launch and never return.
    var trimmedBeforeSlot: Int = 0
    /// Next unused absolute slot number.
    var nextSlot: Int = 0

    init() {}
}

@Model
final class PhotoSeenEntry {
    var assetKey: String = ""
    var seenAt: Date = Date()
    /// The `PHCloudIdentifier.stringValue`, set when iCloud Photos was on
    /// at insert time. It gives a stable key across a restore or a device
    /// migration. See `SeenEntry.cloudKey` in Cloudfull/Storage/Models.swift.
    var cloudKey: String? = nil

    init(assetKey: String, cloudKey: String? = nil) {
        self.assetKey = assetKey
        self.cloudKey = cloudKey
    }
}

/// The disk half of the tier-1/tier-2 metadata cache. `PhotoMetadataCache`
/// in Cloudfull/Photos/PhotoMetadata.swift holds the in-memory half, which
/// lasts for the current run. This table holds the half that survives a
/// relaunch. `PhotoMetaStore` in Cloudfull/Storage/PhotoMetaStore.swift is
/// the `@ModelActor` that reads and writes it off the main actor.
/// One row exists per asset that has loaded tier 1 at least once.
/// `modificationDate` mirrors `PHAsset.modificationDate` at write time. An
/// edit is the most common reason an asset changes. Then
/// `PhotoMetaStore.fetchIfFresh` returns nil for a stale row, so the
/// caller reloads the metadata from PhotoKit. `hasTier1` and `hasTier2`
/// distinguish a row that loaded and came back empty from a row that was
/// never attempted. Both look like an empty row otherwise, and only the
/// first case is a real cache hit.
@Model
final class PhotoMetaRecord {
    @Attribute(.unique) var assetID: String = ""
    var modificationDate: Date?
    var fetchedAt: Date = Date()

    var hasTier1: Bool = false
    // Tier 1 fields, matching `PhotoMetadata.Tier1` field for field.
    var dateText: String = ""
    var timeSinceText: String = ""
    var dimensionsText: String = ""
    var formatText: String = ""
    var sizeText: String = ""
    var badgeRawValues: [String] = []
    var latitude: Double?
    var longitude: Double?
    var isLivePhoto: Bool = false
    var isOriginalLocal: Bool = false
    var voiceOverLabel: String = ""

    var hasTier2: Bool = false
    // Tier 2 fields, matching `PhotoMetadata.Tier2` field for field.
    var cameraText: String?
    var lensText: String?
    var exposureText: String?
    var albumsText: String?
    var burstCount: Int?
    var needsICloud: Bool = false

    // The reverse-geocoded place, cached on disk so a second sighting of
    // the same photo costs nothing. `hasPlace` distinguishes a lookup that
    // found no place from a lookup that never ran, the same distinction
    // `hasTier1` and `hasTier2` make above. MapKit returns no place for
    // many real photos, so asking again on every launch would waste calls.
    var hasPlace: Bool = false
    var placeText: String?

    init(assetID: String) {
        self.assetID = assetID
    }

    func apply(tier1: PhotoMetadata.Tier1) {
        hasTier1 = true
        dateText = tier1.dateText
        timeSinceText = tier1.timeSinceText
        dimensionsText = tier1.dimensionsText
        formatText = tier1.formatText
        sizeText = tier1.sizeText
        badgeRawValues = tier1.badges.map(\.rawValue)
        latitude = tier1.coordinate?.latitude
        longitude = tier1.coordinate?.longitude
        isLivePhoto = tier1.isLivePhoto
        isOriginalLocal = tier1.isOriginalLocal
        voiceOverLabel = tier1.voiceOverLabel
    }

    func apply(tier2: PhotoMetadata.Tier2) {
        hasTier2 = true
        cameraText = tier2.cameraText
        lensText = tier2.lensText
        exposureText = tier2.exposureText
        albumsText = tier2.albumsText
        burstCount = tier2.burstCount
        needsICloud = tier2.needsICloud
    }

    var tier1: PhotoMetadata.Tier1? {
        guard hasTier1 else { return nil }
        let coordinate: PhotoMetadata.Coordinate? = {
            guard let latitude, let longitude else { return nil }
            return PhotoMetadata.Coordinate(latitude: latitude, longitude: longitude)
        }()
        let pixels = PhotoMetadata.Tier1.pixels(from: dimensionsText)
        return PhotoMetadata.Tier1(
            assetID: assetID,
            dateText: dateText,
            timeSinceText: timeSinceText,
            dimensionsText: dimensionsText,
            pixelWidth: pixels.0,
            pixelHeight: pixels.1,
            formatText: formatText,
            sizeText: sizeText,
            badges: badgeRawValues.compactMap(PhotoMetadata.Badge.init(rawValue:)),
            coordinate: coordinate,
            isLivePhoto: isLivePhoto,
            isOriginalLocal: isOriginalLocal,
            voiceOverLabel: voiceOverLabel
        )
    }

    var tier2: PhotoMetadata.Tier2? {
        guard hasTier2 else { return nil }
        return PhotoMetadata.Tier2(
            assetID: assetID,
            cameraText: cameraText,
            lensText: lensText,
            exposureText: exposureText,
            albumsText: albumsText,
            burstCount: burstCount,
            needsICloud: needsICloud
        )
    }
}
