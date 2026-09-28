//
//  PhotoMetadata.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Photos
import ImageIO
import UniformTypeIdentifiers
import Foundation
import CoreLocation
import os

/// PhotoMetadata loads photo metadata in two tiers, off the main actor.
/// Each tier runs a nonisolated static function inside `Task.detached`
/// and returns one `Sendable` value. Its strings are already formatted.
///
/// Tier 1 (`tier1`) reads cheap, in-memory `PHAsset` properties plus
/// exactly one `PHAssetResource.assetResources(for:)` call. Do not call
/// that method twice for the same asset. Tier 2 (`tier2`) reads EXIF
/// through ImageIO from local data only; it never sets
/// `isNetworkAccessAllowed` to `true` on the scroll path. It also reads
/// albums and the burst count. The caller decides which posts to load:
/// the current post (`PhotoPostView`) and a prefetch window
/// (`PhotoMetadataPrefetcher`).
enum PhotoMetadata {
    struct Coordinate: Sendable, Equatable {
        let latitude: Double
        let longitude: Double
    }

    enum Badge: String, Sendable {
        case live, screenshot, portrait, panorama, hdr, raw, favorite, burst, edited
    }

    struct Tier1: Sendable, Equatable {
        let assetID: String
        let dateText: String
        let timeSinceText: String
        let dimensionsText: String
        /// Raw pixel size, used to report freed storage after a delete. The
        /// SwiftData-cached copy rebuilds this value from `dimensionsText`.
        var pixelWidth: Int = 0
        var pixelHeight: Int = 0

        /// Parses "4032 × 3024" into (4032, 3024). Returns (0, 0) for any
        /// other format.
        static func pixels(from dimensionsText: String) -> (Int, Int) {
            let parts = dimensionsText.split(separator: "×").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            return parts.count == 2 ? (parts[0], parts[1]) : (0, 0)
        }
        let formatText: String
        let sizeText: String
        let badges: [Badge]
        let coordinate: Coordinate?
        let isLivePhoto: Bool
        let isOriginalLocal: Bool
        let voiceOverLabel: String
    }

    struct Tier2: Sendable, Equatable {
        let assetID: String
        let cameraText: String?
        let lensText: String?
        let exposureText: String?
        let albumsText: String?
        let burstCount: Int?
        let needsICloud: Bool
    }

    /// Priority `.userInitiated` is for the current post and the posts
    /// next to it. `PhotoMetadataPrefetcher` passes `.utility` for the
    /// other posts in its window, so a prefetch does not take the
    /// threads that scrolling needs.
    static func tier1(for assetID: String, priority: TaskPriority = .userInitiated) async -> Tier1? {
        await Task.detached(priority: priority) {
            Self.loadTier1(assetID)
        }.value
    }

    /// `isOriginalLocal` is the tier 1 value. When it is `false`, the
    /// function skips `requestContentEditingInput`, returns no EXIF
    /// fields, and sets `needsICloud`. That call can hold a caption on
    /// "…" while it waits for an iCloud-only original. When it is
    /// `nil`, the function reads EXIF.
    static func tier2(
        for assetID: String,
        priority: TaskPriority = .userInitiated,
        isOriginalLocal: Bool? = nil
    ) async -> Tier2? {
        await Task.detached(priority: priority) {
            Self.loadTier2(assetID, isOriginalLocal: isOriginalLocal)
        }.value
    }

    // MARK: - Timing (debug only)

    /// The `-cloudfull-log-meta` launch argument logs one line per
    /// `loadTier1`/`loadTier2` call, for example "tier1_ms_12.3_<assetID>".
    /// Filter the simulator's `log stream` output for these lines. The
    /// same line also goes to `DiagnosticsLog.shared`. This code is
    /// DEBUG-only and off by default.
    #if DEBUG
    private static let timingLog = Logger(subsystem: "com.cloudfull.app", category: "PhotoMetaTiming")

    private static func logTiming(_ label: StaticString, assetID: String, since start: Date) {
        guard DiagnosticsGate.isOn("-cloudfull-log-meta") else { return }
        let ms = Date().timeIntervalSince(start) * 1000
        let msText = String(format: "%.1f", ms)
        timingLog.notice("\(label, privacy: .public)_ms_\(msText, privacy: .public)_\(assetID, privacy: .public)")
        DiagnosticsLog.shared.log("PhotoMetaTiming", "\(label)_ms_\(msText)_\(assetID)")
    }
    #endif

    /// The synchronous body of `tier1(for:)`. It blocks, so call it
    /// only from a detached task, as `tier1(for:)` does.
    nonisolated static func loadTier1(_ assetID: String) -> Tier1? {
        #if DEBUG
        let start = Date()
        defer { logTiming("tier1", assetID: assetID, since: start) }
        #endif
        guard let asset = PhotoLibraryService.fetchAsset(assetID) else { return nil }

        // This is the only resource fetch this tier makes. Format, size,
        // whether the original is local, and the raw-photo badge all come
        // from it below. Do not call `assetResources(for:)` a second time
        // for this asset.
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
            ?? resources.first
        let isRaw = resources.contains { isRawResource($0) }

        let isLocal = (primary?.value(forKey: "locallyAvailable") as? Bool) ?? false
        let sizeText = Self.sizeText(primary: primary, isLocal: isLocal, asset: asset)
        let formatText = Self.formatText(primary: primary, isRaw: isRaw)
        let dimensionsText = (asset.pixelWidth > 0 && asset.pixelHeight > 0)
            ? "\(asset.pixelWidth) × \(asset.pixelHeight)"
            : ""

        let dateText = asset.creationDate.map {
            $0.formatted(.dateTime.month(.abbreviated).day().year()) + " · " + $0.formatted(.dateTime.hour().minute())
        } ?? "Unknown date"
        let timeSinceText = asset.creationDate.map {
            $0.formatted(.relative(presentation: .named))
        } ?? ""

        let isLivePhoto = asset.playbackStyle == .livePhoto
        var badges: [Badge] = []
        if isLivePhoto { badges.append(.live) }
        if asset.mediaSubtypes.contains(.photoScreenshot) { badges.append(.screenshot) }
        if asset.mediaSubtypes.contains(.photoDepthEffect) { badges.append(.portrait) }
        if asset.mediaSubtypes.contains(.photoPanorama) { badges.append(.panorama) }
        if asset.mediaSubtypes.contains(.photoHDR) { badges.append(.hdr) }
        if isRaw { badges.append(.raw) }
        if asset.isFavorite { badges.append(.favorite) }
        if asset.representsBurst { badges.append(.burst) }
        if asset.hasAdjustments { badges.append(.edited) }

        let coordinate = asset.location.map {
            Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }

        let details = [dimensionsText, formatText, sizeText].filter { !$0.isEmpty }.joined(separator: ", ")
        let voiceOverLabel = details.isEmpty ? dateText : "\(dateText). \(details)."

        return Tier1(
            assetID: assetID,
            dateText: dateText,
            timeSinceText: timeSinceText,
            dimensionsText: dimensionsText,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            formatText: formatText,
            sizeText: sizeText,
            badges: badges,
            coordinate: coordinate,
            isLivePhoto: isLivePhoto,
            isOriginalLocal: isLocal,
            voiceOverLabel: voiceOverLabel
        )
    }

    /// The synchronous body of `tier2(for:)`. The caller must run it
    /// off the main actor; `tier2(for:)` does this with
    /// `Task.detached`. EXIF comes from `loadEXIF(for:)`, which reads
    /// the file header first and loads the full image data only as a
    /// fallback (see that function's own comment). Albums come from
    /// `fetchAssetCollectionsContainingAsset`. A field that cannot be
    /// read renders as `"—"` in the UI, never as a blank. This layer
    /// returns `nil` and leaves that choice to the caller. This
    /// function never sets the network-access flag to `true`.
    nonisolated static func loadTier2(_ assetID: String, isOriginalLocal: Bool? = nil) -> Tier2? {
        #if DEBUG
        let start = Date()
        defer { logTiming("tier2", assetID: assetID, since: start) }
        #endif
        guard let asset = PhotoLibraryService.fetchAsset(assetID) else { return nil }

        // When tier 1 reports that the original is not on the device,
        // EXIF needs a download. This layer never downloads, so it
        // returns no camera fields at once. A call to `loadEXIF` gives
        // the same result more slowly and can hold a caption on "…".
        let (cameraText, lensText, exposureText, needsICloud): (String?, String?, String?, Bool) =
            (isOriginalLocal == false) ? (nil, nil, nil, true) : loadEXIF(for: asset)

        var albumsText: String?
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var titles: [String] = []
        collections.enumerateObjects { collection, _, _ in
            if let title = collection.localizedTitle, !title.isEmpty { titles.append(title) }
        }
        if !titles.isEmpty { albumsText = titles.joined(separator: ", ") }

        var burstCount: Int?
        if asset.representsBurst, let burstIdentifier = asset.burstIdentifier {
            burstCount = PHAsset.fetchAssets(withBurstIdentifier: burstIdentifier, options: nil).count
        }

        return Tier2(
            assetID: assetID,
            cameraText: cameraText,
            lensText: lensText,
            exposureText: exposureText,
            albumsText: albumsText,
            burstCount: burstCount,
            needsICloud: needsICloud
        )
    }

    /// A header-only EXIF read. It asks PhotoKit for the on-disk file
    /// URL (`PHContentEditingInput.fullSizeImageURL`, local originals
    /// only; `isNetworkAccessAllowed` stays `false`). It passes that
    /// URL to `CGImageSourceCreateWithURL` with
    /// `kCGImageSourceShouldCache: false`, so
    /// `CGImageSourceCopyPropertiesAtIndex` reads only the header from
    /// disk and no pixels ever decode. It falls back to
    /// `loadEXIFViaFullImageData` below when there is no URL, no image
    /// source, or no properties. A photo with no EXIF dictionary is a
    /// valid, cheap answer from the header read, not a reason to fall
    /// back.
    private static func loadEXIF(for asset: PHAsset) -> (camera: String?, lens: String?, exposure: String?, needsICloud: Bool) {
        let editOptions = PHContentEditingInputRequestOptions()
        editOptions.isNetworkAccessAllowed = false

        // The callback runs on a PhotoKit thread and this thread waits
        // on a semaphore. `ContentEditingResultBox` uses a lock because
        // the callback can arrive after the wait times out.
        let box = ContentEditingResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        asset.requestContentEditingInput(with: editOptions) { input, info in
            box.set(
                url: input?.fullSizeImageURL,
                needsICloud: (info[PHContentEditingInputResultIsInCloudKey] as? Bool) ?? false
            )
            semaphore.signal()
        }
        // Do not wait without a limit. PhotoKit can call back late for
        // some assets, and the task then holds a cooperative thread.
        // After 2 seconds, the function returns no fields. The lock in
        // the box makes a late callback safe.
        if semaphore.wait(timeout: .now() + 2.0) == .timedOut {
            return (nil, nil, nil, false)
        }

        let (boxURL, boxNeedsICloud) = box.read()
        if boxNeedsICloud { return (nil, nil, nil, true) }

        if let url = boxURL,
           let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let (camera, lens, exposure) = extractEXIF(properties)
            return (camera, lens, exposure, false)
        }

        return loadEXIFViaFullImageData(for: asset)
    }

    /// The fallback when `loadEXIF` finds no file URL, no image source,
    /// or no properties. It loads the full image data without network
    /// access, then reads the same EXIF fields with
    /// `CGImageSourceCreateWithData`. `Tier2ResultBox` uses a lock
    /// because the callback can arrive after the 2-second wait times
    /// out.
    private static func loadEXIFViaFullImageData(for asset: PHAsset) -> (camera: String?, lens: String?, exposure: String?, needsICloud: Bool) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.version = .current

        let box = Tier2ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
            box.set(data: data, needsICloud: (info?[PHImageResultIsInCloudKey] as? Bool) ?? false)
            semaphore.signal()
        }
        // Bounded for the same reason as the wait in `loadEXIF` above.
        if semaphore.wait(timeout: .now() + 2.0) == .timedOut {
            return (nil, nil, nil, false)
        }

        let (boxData, boxNeedsICloud) = box.read()
        guard !boxNeedsICloud, let data = boxData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil, nil, boxNeedsICloud)
        }
        let (camera, lens, exposure) = extractEXIF(properties)
        return (camera, lens, exposure, false)
    }

    /// Shared by both EXIF paths above. Reads `kCGImagePropertyTIFFModel`
    /// for the camera, and `kCGImagePropertyExifFocalLength`,
    /// `kCGImagePropertyExifFNumber`, `kCGImagePropertyExifExposureTime`,
    /// and `kCGImagePropertyExifISOSpeedRatings` for lens and exposure.
    private static func extractEXIF(_ properties: [CFString: Any]) -> (camera: String?, lens: String?, exposure: String?) {
        var cameraText: String?
        var lensText: String?
        var exposureText: String?

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let model = tiff[kCGImagePropertyTIFFModel] as? String {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            cameraText = trimmed.isEmpty ? nil : trimmed
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let focalLength = numeric(exif[kCGImagePropertyExifFocalLength]), focalLength > 0 {
                lensText = "\(Int(focalLength.rounded())) mm"
            }
            var exposureParts: [String] = []
            if let fNumber = numeric(exif[kCGImagePropertyExifFNumber]), fNumber > 0 {
                exposureParts.append("ƒ/" + trimmedNumberText(fNumber))
            }
            if let exposureTime = numeric(exif[kCGImagePropertyExifExposureTime]), exposureTime > 0 {
                exposureParts.append(exposureTimeText(exposureTime))
            }
            if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any],
               let iso = numeric(isoArray.first) {
                exposureParts.append("ISO \(Int(iso.rounded()))")
            }
            exposureText = exposureParts.isEmpty ? nil : exposureParts.joined(separator: " · ")
        }
        return (cameraText, lensText, exposureText)
    }

    // MARK: - Private helpers

    private static func isRawResource(_ resource: PHAssetResource) -> Bool {
        guard let type = UTType(resource.uniformTypeIdentifier) else { return false }
        return type.conforms(to: .rawImage)
    }

    private static func formatText(primary: PHAssetResource?, isRaw: Bool) -> String {
        if isRaw { return "RAW" }
        guard let primary, let type = UTType(primary.uniformTypeIdentifier) else { return "" }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "HEIC" }
        if type.conforms(to: .jpeg) { return "JPEG" }
        if type.conforms(to: .png) { return "PNG" }
        if type.conforms(to: .gif) { return "GIF" }
        return type.preferredFilenameExtension?.uppercased() ?? ""
    }

    /// Returns the `fileSize` value, for example "2.4 MB", when the
    /// resource's `fileSize` KVC key is readable. If not, returns an
    /// estimate ("About 2.4 MB") for a local original with known pixel
    /// dimensions; this mirrors `PhotoLibraryService.assetSize`'s own
    /// resource-then-estimate fallback for video. Returns "…" when
    /// there is no size and the original is not local.
    private static func sizeText(primary: PHAssetResource?, isLocal: Bool, asset: PHAsset) -> String {
        if let size = primary?.value(forKey: "fileSize") as? Int64, size > 0 {
            return Fmt.bytes(size)
        }
        guard isLocal, asset.pixelWidth > 0, asset.pixelHeight > 0 else { return "…" }
        // A rough compressed-photo estimate, about 0.35 bytes per pixel,
        // in the HEIC/JPEG range for a typical camera photo. This is the
        // pixel-count equivalent of `PhotoLibraryService.assetSize`'s
        // bits-per-pixel video estimate.
        let estimate = Int64(Double(asset.pixelWidth * asset.pixelHeight) * 0.35)
        return "About " + Fmt.bytes(max(estimate, 0))
    }

    private static func numeric(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// Formats with up to two decimal places and removes trailing
    /// zeros and a trailing point, for example "1.78", "1.8", "2".
    private static func trimmedNumberText(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Formats an exposure time below one second as a fraction, for
    /// example "1/120 s". Formats one second or more as a decimal, for
    /// example "1.5 s".
    private static func exposureTimeText(_ seconds: Double) -> String {
        guard seconds < 1 else { return trimmedNumberText(seconds) + " s" }
        let denominator = (1 / seconds).rounded()
        guard denominator > 0 else { return trimmedNumberText(seconds) + " s" }
        return "1/\(Int(denominator)) s"
    }
}

/// Passes a result from PhotoKit's callback thread to the waiting task
/// in `loadEXIFViaFullImageData`. The wait has a 2-second timeout, so
/// the callback can run after the reader returns. The lock makes that
/// write safe.
private final class Tier2ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var needsICloud = false

    func set(data: Data?, needsICloud: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.data = data
        self.needsICloud = needsICloud
    }

    func read() -> (Data?, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (data, needsICloud)
    }
}

/// Passes a result from PhotoKit's callback thread to the waiting task in
/// `loadEXIF`. Same locking reasoning as `Tier2ResultBox`.
private final class ContentEditingResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var needsICloud = false

    func set(url: URL?, needsICloud: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.url = url
        self.needsICloud = needsICloud
    }

    func read() -> (URL?, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (url, needsICloud)
    }
}

// MARK: - Cache

/// An in-memory `Tier1`/`Tier2` cache, keyed by asset id, with an LRU
/// limit of 200 entries. This cache holds data for the current session
/// only. `PhotoMetaStore` (Cloudfull/Storage/PhotoMetaStore.swift) holds
/// data that survives a relaunch. `resolvedTier1` and `resolvedTier2`
/// read from `PhotoMetaStore` on a miss. `store` writes to it unless
/// `alsoPersist` is false.
///
/// This class runs on the main actor only.
/// Every write reaches it from an `await` resumption inside a view's
/// own `.task`, or from `PhotoMetadataPrefetcher` below, never from
/// inside a `Task.detached` body. The PhotoKit and ImageIO load itself
/// runs off the main actor, in `loadTier1` and `loadTier2`. A plain
/// dictionary read or write is cheap enough to run on the main actor.
@MainActor
final class PhotoMetadataCache {
    static let shared = PhotoMetadataCache()
    private init() {}

    private struct Entry {
        var tier1: PhotoMetadata.Tier1?
        var tier2: PhotoMetadata.Tier2?
    }

    private var storage: [String: Entry] = [:]
    /// Orders entries least-recently-used first. A read or a write
    /// touches an entry.
    private var order: [String] = []
    private let capacity = 200

    /// Lets a mounted row react when its metadata arrives after the row
    /// is already on screen. `store(tier1:)` and `store(tier2:)` below
    /// call `notifyWatchers(_:)` after writing, so a listening row can
    /// re-read both synchronous getters the instant either value changes.
    /// The outer key is the asset id. The inner key is a UUID token for
    /// each stream from `changes(for:)`. `PhotoPostView` mounts at most
    /// one row per asset at a time, but this code does not depend on
    /// that.
    private var watchers: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]

    /// A stream of "something changed for this asset" signals. The
    /// signal has no payload. The listener reads both tiers again. The
    /// stream keeps only the newest signal because the listener only
    /// needs to know that a value changed.
    func changes(for assetID: String) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let token = UUID()
            watchers[assetID, default: [:]][token] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in
                    PhotoMetadataCache.shared.watchers[assetID]?.removeValue(forKey: token)
                    if PhotoMetadataCache.shared.watchers[assetID]?.isEmpty == true {
                        PhotoMetadataCache.shared.watchers[assetID] = nil   // Removes the empty entry so the dictionary does not grow forever.
                    }
                }
            }
        }
    }

    private func notifyWatchers(_ assetID: String) {
        guard let listeners = watchers[assetID] else { return }
        for continuation in listeners.values { continuation.yield() }
    }

    func tier1(for assetID: String) -> PhotoMetadata.Tier1? {
        guard let value = storage[assetID]?.tier1 else { return nil }
        touch(assetID)
        return value
    }

    func tier2(for assetID: String) -> PhotoMetadata.Tier2? {
        guard let value = storage[assetID]?.tier2 else { return nil }
        touch(assetID)
        return value
    }

    /// `alsoPersist` is `false` only when `resolvedTier1` or
    /// `resolvedTier2` stores a value that it read from disk. That
    /// value is already on disk, so the write is not necessary. Every
    /// other caller keeps the default and gets the write-through.
    func store(tier1: PhotoMetadata.Tier1?, for assetID: String, alsoPersist: Bool = true) {
        guard let tier1 else { return }
        storage[assetID, default: Entry()].tier1 = tier1
        touch(assetID)
        notifyWatchers(assetID)
        guard alsoPersist else { return }
        // A plain `Task {}` created inside this `@MainActor` class keeps
        // the `ModelActor` hop, and the SQLite write behind it, on the
        // main actor. `.detached` guarantees this closure starts on no
        // actor at all.
        Task.detached(priority: .utility) {
            await PhotoMetaStore.shared.writeTier1(tier1, assetID: assetID)
        }
    }

    func store(tier2: PhotoMetadata.Tier2?, for assetID: String, alsoPersist: Bool = true) {
        guard let tier2 else { return }
        storage[assetID, default: Entry()].tier2 = tier2
        touch(assetID)
        notifyWatchers(assetID)
        guard alsoPersist else { return }
        // See `store(tier1:for:alsoPersist:)` above. Same reasoning.
        Task.detached(priority: .utility) {
            await PhotoMetaStore.shared.writeTier2(tier2, assetID: assetID)
        }
    }

    /// Reads tier 1 from memory, then from disk. `nil` means no fresh
    /// value in memory or on disk. The caller then calls
    /// `PhotoMetadata.tier1(for:)` and stores the result. This function
    /// never touches PhotoKit itself. `PhotoMetaStore.fetchIfFresh` runs
    /// the one cheap local-identifier fetch that confirms the disk row
    /// is still current, off the main actor, on its own actor.
    func resolvedTier1(for assetID: String) async -> PhotoMetadata.Tier1? {
        if let hit = tier1(for: assetID) { return hit }
        guard let disk = await PhotoMetaStore.shared.fetchIfFresh(assetID: assetID) else { return nil }
        // The row that carries tier 1 also carries the place this asset
        // resolved to last time. Seed it here instead of reading the
        // store again, since the read has already happened.
        if let place = disk.place { PlaceLookup.shared.seed(assetID: assetID, place: place) }
        guard let tier1 = disk.tier1 else { return nil }
        store(tier1: tier1, for: assetID, alsoPersist: false)
        return tier1
    }

    /// Reads tier 2 from memory, then from disk. Same contract as
    /// `resolvedTier1`.
    func resolvedTier2(for assetID: String) async -> PhotoMetadata.Tier2? {
        if let hit = tier2(for: assetID) { return hit }
        guard let disk = await PhotoMetaStore.shared.fetchIfFresh(assetID: assetID) else { return nil }
        if let place = disk.place { PlaceLookup.shared.seed(assetID: assetID, place: place) }
        guard let tier2 = disk.tier2 else { return nil }
        store(tier2: tier2, for: assetID, alsoPersist: false)
        return tier2
    }

    /// Persists a resolved place for a photo asset. `PlaceLookup` itself
    /// is shared with the video side and knows nothing about
    /// `PhotoMetaRecord`, so the write-through lives here, on the photo
    /// side.
    func persistPlace(_ place: String?, for assetID: String) {
        // Runs detached so that the SwiftData write does not run on
        // the main actor. See `store(tier1:for:alsoPersist:)` above.
        Task.detached(priority: .utility) {
            await PhotoMetaStore.shared.writePlace(place, assetID: assetID)
        }
    }

    private func touch(_ assetID: String) {
        if let index = order.firstIndex(of: assetID) {
            order.remove(at: index)
        }
        order.append(assetID)
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}

/// Drives tier 1 and tier 2 prefetch for a window around the current
/// post. The window is the two posts before it and the six posts
/// after it, not the current post itself. `PhotoDeck.triggerMetadataPrefetch` calls
/// `updateWindow` when the deck loads and when the current index
/// changes. It cancels tasks for ids that are not in the window.
@MainActor
final class PhotoMetadataPrefetcher {
    static let shared = PhotoMetadataPrefetcher()
    private init() {}

    private var tasks: [String: Task<Void, Never>] = [:]
    /// This limiter lets 2 tier-2 loads (EXIF, albums, burst count) run
    /// at the same time. Tier 1 has no such limit. It reads cheap,
    /// in-memory `PHAsset` properties plus one resource fetch, so it
    /// can run unbounded across the whole window in parallel. The
    /// current post's tier-2 task in `PhotoPostView` does not use it.
    /// Fewer prefetch loads running beside it means the caption the
    /// user is looking at resolves sooner.
    private let tier2Limiter = AsyncSemaphore(limit: 2)

    /// `ids` is the whole prefetch window. `nearIDs` are the posts next
    /// to the current post. Their task and tier 1 load use
    /// `.userInitiated`. The other ids use `.utility`. Tier 2 always
    /// uses `.utility`.
    func updateWindow(ids: [String], nearIDs: Set<String>) {
        let idSet = Set(ids)
        for (id, task) in tasks where !idSet.contains(id) {
            task.cancel()
            tasks.removeValue(forKey: id)
        }
        for id in ids where tasks[id] == nil {
            let priority: TaskPriority = nearIDs.contains(id) ? .userInitiated : .utility
            tasks[id] = Task(priority: priority) { [weak self] in
                await self?.load(id: id, priority: priority)
            }
        }
    }

    /// Loads tier 1, then starts the place lookup in a separate task
    /// when tier 1 has a coordinate, then loads tier 2 through
    /// `tier2Limiter`. Both tiers try the disk cache first
    /// (`resolvedTier1`/`resolvedTier2`) before using PhotoKit.
    /// `PlaceLookup.prefetch` deduplicates by asset id and never
    /// touches the current page's own in-flight lookup.
    private func load(id: String, priority: TaskPriority) async {
        var resolvedTier1: PhotoMetadata.Tier1?
        if let cached = await PhotoMetadataCache.shared.resolvedTier1(for: id) {
            resolvedTier1 = cached
        } else {
            let tier1 = await PhotoMetadata.tier1(for: id, priority: priority)
            if Task.isCancelled { tasks.removeValue(forKey: id); return }
            PhotoMetadataCache.shared.store(tier1: tier1, for: id)
            resolvedTier1 = tier1
        }
        if Task.isCancelled { tasks.removeValue(forKey: id); return }

        // The place lookup starts here, the instant tier 1 is known, in
        // its own task.
        //
        // Tier 2 can wait for a limiter slot and then for up to 2
        // seconds for PhotoKit. The place lookup needs only the
        // coordinate from tier 1, so it does not wait for tier 2.
        var placeTask: Task<Void, Never>?
        if let coordinate = resolvedTier1?.coordinate {
            placeTask = Task(priority: .utility) {
                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                await PlaceLookup.shared.prefetch(assetID: id, location: location)
                if let resolved = await PlaceLookup.shared.cachedPlace(for: id) {
                    await PhotoMetadataCache.shared.persistPlace(resolved, for: id)
                }
            }
        }

        if await PhotoMetadataCache.shared.resolvedTier2(for: id) == nil {
            await tier2Limiter.wait()
            if Task.isCancelled {
                await tier2Limiter.signal()
                tasks.removeValue(forKey: id)
                return
            }
            // Tier 2 always uses `.utility`, also for the posts next to
            // the current post. The code passes `isOriginalLocal` so
            // that an iCloud-only original returns no fields without a
            // PhotoKit call. The current post's own caption must not
            // wait behind a neighbour's EXIF read.
            let tier2 = await PhotoMetadata.tier2(
                for: id,
                priority: .utility,
                isOriginalLocal: resolvedTier1?.isOriginalLocal
            )
            await tier2Limiter.signal()
            if Task.isCancelled { tasks.removeValue(forKey: id); return }
            PhotoMetadataCache.shared.store(tier2: tier2, for: id)
        }

        // Waits for the place task, if there is one. It started after
        // tier 1 and runs at the same time as tier 2.
        await placeTask?.value
        tasks.removeValue(forKey: id)
    }
}

/// A counting semaphore for async code. `PhotoMetadataPrefetcher` uses
/// it to let 2 tier-2 loads run at the same time, so that prefetch
/// does not take the threads that scrolling needs.
private actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
