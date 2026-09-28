//
//  Models.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftData
import Foundation

// CloudKit-ready: every property has a default value, no #Unique, no #Index constraints.

@Model
final class DeckState {
    /// Superseded by `DeckOrder.cycleSeeds`, which is the seed the deck
    /// actually replays from. The model can sync through CloudKit, and
    /// dropping a stored property forces a live-container migration. The
    /// deck keeps this field and writes the newest cycle's seed to it.
    var seed: Int64 = 0
    /// An absolute slot number (`DeckEntry.position`), not an index into an
    /// id array. This is a value that only goes up: a backward swipe
    /// never moves it.
    var cursor: Int = 0

    init() {}
}

/// The deck's replay plan: a compact cycle log. Each shuffle cycle is
/// stored as the seed that produced it plus the slot range it claimed. A
/// tap appends only the slot it removed. This keeps a like or a trash tap
/// from becoming a write whose cost scales with library size.
@Model
final class DeckOrder {
    /// Legacy storage (schemaVersion 0). The v1 migration empties this
    /// array, and nothing writes to it again. The model can sync through
    /// CloudKit, and dropping a stored property forces a live-container
    /// migration.
    var ids: [String] = []

    /// 0 = legacy `ids` blob. 1 = the compact cycle log below.
    var schemaVersion: Int = 0

    // --- v1: the cycle log. Only a small number of cycles are ever live;
    //     see `DeckViewModel.pruneConsumedCycles`. ---

    /// Seed that produced each cycle's permutation. 0 marks a literal cycle
    /// (see `cycleIsLiteral`).
    var cycleSeeds: [Int64] = []
    /// Absolute slot number of each cycle's element 0.
    var cycleBaseSlots: [Int] = []
    /// Element count of each cycle.
    var cycleCounts: [Int] = []
    /// The FNV-1a 64 hex digest of the input array for each permutation
    /// (see `ShuffleEngine.digest(of:)`). A replay compares this digest and
    /// does not trust a changed order.
    var cycleDigests: [String] = []
    /// The seam guard's rearrangement, replayable: "3>17,5>21" per cycle, ""
    /// when it did nothing.
    var cycleSwaps: [String] = []
    /// True for a cycle whose ids cannot be regenerated from a seed.
    /// `start()`'s import merge and `handleLibraryChange` produce these
    /// small append cycles. Their ids live in `literalIDs`.
    var cycleIsLiteral: [Bool] = []
    /// Flattened ids of every literal cycle, in cycle order. Bounded by
    /// imports since the deal, not by library size.
    var literalIDs: [String] = []

    /// The absolute slots removed since their cycle was dealt (liked,
    /// queued, already seen at deal time, or vanished), ascending. The
    /// list is append-only while the app runs. `pruneConsumedCycles`
    /// removes a slot only when it removes that slot's cycle.
    var exceptionSlots: [Int] = []
    /// The asset id each exception removed, parallel to `exceptionSlots`.
    /// The deck uses these ids to rebuild a cycle's deal-time input.
    /// Duplicates are allowed and cause no harm.
    var exceptionIDs: [String] = []

    /// Slots below this were trimmed at launch and never return.
    var trimmedBeforeSlot: Int = 0
    /// Next unused absolute slot number. This value persists, so it does
    /// not restart at 0 on every launch.
    var nextSlot: Int = 0

    init() {}
}

@Model
final class SeenEntry {
    var assetKey: String = ""
    var seenAt: Date = Date()
    /// The `PHCloudIdentifier.stringValue`, set when iCloud Photos was on
    /// at insert time. `assetKey`, the local identifier, is per-device and
    /// can rotate across a restore or a device migration. `cloudKey` is the
    /// fallback that lets a row survive that. The field is optional and
    /// defaulted, so adding it needs no live-container migration.
    var cloudKey: String? = nil

    init(assetKey: String, cloudKey: String? = nil) {
        self.assetKey = assetKey
        self.cloudKey = cloudKey
    }
}

@Model
final class LikedEntry {
    var assetKey: String = ""
    var likedAt: Date = Date()
    /// See `SeenEntry.cloudKey`.
    var cloudKey: String? = nil

    init(assetKey: String, cloudKey: String? = nil) {
        self.assetKey = assetKey
        self.cloudKey = cloudKey
    }
}

/// The kind of each row queued in the bin. The bin's queue holds both
/// videos and photos, so a row needs to say which kind it is.
/// `TrashEntry` stores this as a plain `String` raw value, not a
/// SwiftData-native enum, so the field is a lightweight, additive
/// migration.
enum TrashMediaKind: String {
    case video
    case photo
}

/// A video or a photo the user queued for deletion. Sitting in the trash
/// queue is app-side state only: the underlying `PHAsset` stays untouched
/// until `TrashService.emptyBin()` runs one batch, system-confirmed delete.
/// This row is both the queue entry and the undo record.
@Model
final class TrashEntry {
    var assetKey: String = ""
    var queuedAt: Date = Date()
    var bytes: Int64 = 0
    /// True when `bytes` came from the pixel/duration estimate in
    /// `PhotoLibraryService.fileSize(for:)` rather than a real resource size
    /// (for example an iCloud original that has not downloaded yet). Lets
    /// the UI show "About X" instead of implying an exact figure.
    var isEstimatedBytes: Bool = false
    /// See `SeenEntry.cloudKey`.
    var cloudKey: String? = nil
    /// Bytes the shrink replacement asset occupies, set when this entry is
    /// the original half of a shrink job. Zero for an ordinary trash entry.
    /// `TrashService.totalBytes` subtracts this value from `bytes`. This
    /// gives the space chip the true net reclaim. The net reclaim is the
    /// original's full size minus the 1080p copy, which now occupies its
    /// own space in the library. Without this subtraction, the original
    /// would count as fully reclaimable space, which it is not.
    var replacementBytes: Int64 = 0
    /// An authoritative reconcile pass needs `authStatus == .authorized`,
    /// `resolver.isDestructiveActionSafe`, and a non-empty enumeration.
    /// This value is the first time such a pass could not resolve this
    /// row through `AssetKeyResolver.currentLocalIdentifier`. A later pass
    /// that resolves the row again, or a restore or re-queue, clears this
    /// value. Reconcile deletes the row only on the second consecutive
    /// failing pass, 60 seconds or more later. This two-failure rule keeps
    /// a transient PhotoKit miss, an iCloud sync tick, or an access
    /// downgrade from ever destroying a pending delete. Additive,
    /// defaulted, and safe for CloudKit.
    var dormantSince: Date? = nil
    /// `TrashMediaKind.rawValue`: "video" or "photo". Additive, and
    /// defaults to "video". Every row queued before this field existed was
    /// a video. The bin held only videos before photos gained their own
    /// delete path into this same shared queue.
    var mediaKind: String = TrashMediaKind.video.rawValue

    init(
        assetKey: String,
        bytes: Int64,
        isEstimatedBytes: Bool = false,
        cloudKey: String? = nil,
        replacementBytes: Int64 = 0,
        mediaKind: TrashMediaKind = .video
    ) {
        self.assetKey = assetKey
        self.bytes = bytes
        self.isEstimatedBytes = isEstimatedBytes
        self.cloudKey = cloudKey
        self.replacementBytes = replacementBytes
        self.mediaKind = mediaKind.rawValue
    }
}
