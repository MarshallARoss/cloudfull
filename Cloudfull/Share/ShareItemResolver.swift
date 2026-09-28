//
//  ShareItemResolver.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Photos
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// The file a photo share sends. `.still` and `.video` only make sense
/// for a Live Photo's two components, but both are harmless for a
/// non-Live asset too. `.still` is exactly what a non-Live photo already
/// shares as. `.video` and `.live` throw `Failure.unsupported` for a
/// non-Live photo, since neither finds a paired video resource. Callers
/// never need to check `isLivePhoto` before picking a kind.
enum ShareKind: Sendable, Hashable {
    /// The original HEIC/JPEG alone. No live object, no AirDrop file pair.
    case still
    /// A Live Photo's paired movie alone, as a plain video file.
    case video
    /// A Live Photo as the `.pvt` bundle (`LivePhotoBundle`), handed to the
    /// sheet through `LivePhotoBundleItemSource`. This is the only way to
    /// deliver a real Live Photo through the normal share sheet.
    case live
}

/// Resolves a URL suitable for `UIActivityViewController`. Lives here, not
/// in `PhotoLibraryService`, because this work must run off the main
/// actor, and `PhotoLibraryService` is `@MainActor`.
enum ShareItemResolver {

    enum Failure: Error {
        case missingAsset, needsWiFi, cancelled, timedOut, unsupported
    }

    /// What one share resolves to. `additionalURLs` holds every other file
    /// this resolution wrote to disk beyond `url` itself. The share sheet
    /// does not receive these files. `ShareCoordinator` deletes them when
    /// the share ends. A `.live` resolution writes the still, the paired
    /// movie, and the `.pvt` bundle it built from both.
    struct Resolved: @unchecked Sendable {
        let url: URL
        /// `false` only when `url` points at the user's own original inside
        /// the Photos container. The caller must never delete that file.
        let isTemporaryCopy: Bool
        let additionalURLs: [URL]
        /// Non-nil only for `ShareKind.live`. Hand `UIActivityViewController`
        /// the `LivePhotoBundleItemSource` instead of a bare `url`.
        /// `nil` everywhere else, in which case
        /// `PresentedShare.activityItems` falls back to `[url]`.
        let activityItemsOverride: [Any]?

        /// Everything this resolution wrote into the share temp directory.
        var temporaryURLs: [URL] { (isTemporaryCopy ? [url] : []) + additionalURLs }
    }

    /// This function calls `progress` on the main actor with 0...1 while an
    /// iCloud original downloads. `kind` selects the file for a photo share; a
    /// video ignores it. Returns a `Resolved` whose `url` the caller must
    /// treat as read-only, and must not delete unless `isTemporaryCopy`
    /// is true. A `false` value means the URL points at the user's
    /// original inside the Photos container.
    static func resolve(
        assetID: String,
        kind: ShareKind = .still,
        allowNetwork: Bool,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> Resolved {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw Failure.missingAsset
        }

        // `requestAVURLAsset` returns a non-nil `AVURLAsset` for a Live
        // Photo's paired movie, not nil as it does for an ordinary photo.
        // This function sends an image asset to `resolveImage` before
        // this call, so a Live Photo's still never resolves to its
        // paired movie.
        if asset.mediaType == .image {
            return try await resolveImage(asset, kind: kind, allowNetwork: allowNetwork, progress: progress)
        }

        if let fastURL = try await requestAVURLAsset(asset, allowNetwork: allowNetwork, progress: progress) {
            return Resolved(url: fastURL, isTemporaryCopy: false, additionalURLs: [], activityItemsOverride: nil)
        }

        // PhotoKit resumes a cancelled `requestAVURLAsset` request with a
        // nil `AVAsset`. Without this check, the code then starts a full
        // copy of the original in `writeResourceCopy`. The copy sees the
        // cancellation only after it completes.
        try Task.checkCancellation()

        let videoResources = PHAssetResource.assetResources(for: asset)
        guard let resource = videoResources.first(where: { $0.type == .video })
            ?? videoResources.first(where: { $0.type == .fullSizeVideo }) else {
            throw Failure.unsupported
        }
        let fallbackURL = try await writeResourceCopy(resource, allowNetwork: allowNetwork, progress: progress)
        return Resolved(url: fallbackURL, isTemporaryCopy: true, additionalURLs: [], activityItemsOverride: nil)
    }

    /// Resolves an image asset for the given `kind`. `.still` is the
    /// default for a non-Live photo's ordinary share tap
    /// (`ShareCoordinator.beginShare`'s own default).
    private static func resolveImage(
        _ asset: PHAsset,
        kind: ShareKind,
        allowNetwork: Bool,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> Resolved {
        let resources = PHAssetResource.assetResources(for: asset)
        // `.fullSizePhoto` is the full-size edited version, if one
        // exists. `.photo` is the unedited original, and
        // `.alternatePhoto` is the JPEG beside a RAW. A `.pairedVideo`
        // is deliberately unreachable here.
        guard let still = resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .alternatePhoto }) else {
            throw Failure.unsupported
        }

        switch kind {
        case .still:
            let stillURL = try await writeResourceCopy(still, allowNetwork: allowNetwork, progress: progress)
            return Resolved(url: stillURL, isTemporaryCopy: true, additionalURLs: [], activityItemsOverride: nil)

        case .video:
            guard let paired = pairedVideoResource(in: resources) else { throw Failure.unsupported }
            let movieURL = try await writeResourceCopy(paired, allowNetwork: allowNetwork, progress: progress)
            return Resolved(url: movieURL, isTemporaryCopy: true, additionalURLs: [], activityItemsOverride: nil)

        case .live:
            return try await resolveLiveBundle(still: still, resources: resources, allowNetwork: allowNetwork, progress: progress)
        }
    }

    private static func pairedVideoResource(in resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first(where: { $0.type == .fullSizePairedVideo })
            ?? resources.first(where: { $0.type == .pairedVideo })
    }

    /// `ShareKind.live` copies the still and its paired movie out of the
    /// Photos container byte-for-byte. This preserves the Apple content
    /// identifier that pairs them. It then builds the `.pvt` bundle from
    /// both (`LivePhotoBundle.make`). Hands `PresentedShare.activityItems`
    /// a `LivePhotoBundleItemSource` instead of a bare `url`. The still's
    /// own copy is silent (`progress: { _ in }`). The movie's copy is the
    /// larger file and the last step before `LivePhotoBundle.make` builds
    /// the bundle. It alone drives the visible download ring, so the pair
    /// still reads as one download.
    private static func resolveLiveBundle(
        still: PHAssetResource,
        resources: [PHAssetResource],
        allowNetwork: Bool,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> Resolved {
        guard let paired = pairedVideoResource(in: resources) else { throw Failure.unsupported }

        let stillURL = try await writeResourceCopy(still, allowNetwork: allowNetwork, progress: { _ in })
        try Task.checkCancellation()
        let movieURL = try await writeResourceCopy(paired, allowNetwork: allowNetwork, progress: progress)
        try Task.checkCancellation()

        let base = (stillURL.lastPathComponent as NSString).deletingPathExtension
        guard let bundleURL = LivePhotoBundle.make(
            still: stillURL,
            movie: movieURL,
            baseName: base.isEmpty ? "LivePhoto" : base
        ) else {
            throw Failure.unsupported
        }

        let itemSource = LivePhotoBundleItemSource(pvtURL: bundleURL, stillURL: stillURL)
        return Resolved(
            url: stillURL,
            isTemporaryCopy: true,
            additionalURLs: [movieURL, bundleURL],
            activityItemsOverride: [itemSource]
        )
    }

    /// The common, cheap path: `requestAVAsset` on an ordinary camera video
    /// hands back an `AVURLAsset` pointing straight at the original inside
    /// the Photos container. Sharing it then copies nothing. Bridged with the
    /// same `ResumeGuard`, `RequestIDBox`, and `withTaskCancellationHandler`
    /// pattern `PhotoLibraryService.playerItem(for:)` uses. Those types are
    /// file-private to that file, so this file carries its own copies
    /// instead of a second bridging style.
    private static func requestAVURLAsset(
        _ asset: PHAsset,
        allowNetwork: Bool,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.progressHandler = { fraction, _, _, _ in
            Task { @MainActor in progress(fraction) }
        }

        let requestBox = RequestIDBox()

        let avAsset: AVAsset? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AVAsset?, Never>) in
                let hasResumed = ResumeGuard()
                let requestID = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                    guard hasResumed.markResumed() else { return }
                    continuation.resume(returning: avAsset)
                }
                requestBox.id = requestID
            }
        } onCancel: {
            let requestID = requestBox.id
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }

        guard let urlAsset = avAsset as? AVURLAsset else { return nil }
        return urlAsset.url
    }

    /// Copies one `PHAssetResource`, the original bytes, whatever kind of
    /// asset they belong to, into a temp file the caller
    /// (`ShareCoordinator`) owns and purges. This is the video path's
    /// fallback for slow-motion compositions and some edited assets, and
    /// the only path a photo takes.
    ///
    /// Cancellable end to end via
    /// `PHAssetResourceManager.requestData(for:options:dataReceivedHandler:completionHandler:)`,
    /// not `writeData(for:toFile:options:completionHandler:)`. `writeData`
    /// returns no request ID, so `cancelDataRequest` cannot stop it.
    /// `requestData` returns a `PHAssetResourceDataRequestID`.
    /// `ResourceDataWriter` appends each chunk to `destination`, bridged
    /// with the same `ResumeGuard`, request-id-box, and
    /// `withTaskCancellationHandler` pattern `requestAVURLAsset` above
    /// uses.
    private static func writeResourceCopy(
        _ resource: PHAssetResource,
        allowNetwork: Bool,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        // Its own directory, named by a UUID, holds the resource under its
        // real filename. The share sheet's header shows the file name, so
        // "IMG_4821.HEIC" is what should appear there. A UUID name does
        // not tell the user if the photo or the movie is being sent. The
        // per-share directory keeps two shares of identically-named
        // originals from colliding.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudfullShare", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The extension comes from the resource's own uniform type, not a
        // fixed value. `UIActivityViewController` and any app it hands off
        // to, such as Photos' own "Save Image" or Mail, read the file's
        // extension to decide how to treat it. The bytes do not matter.
        let fileExtension = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "dat"
        let name = Self.filename(for: resource, fallbackExtension: fileExtension)
        let destination = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let fileHandle = try? FileHandle(forWritingTo: destination) else {
            throw Failure.unsupported
        }
        let writer = ResourceDataWriter(fileHandle: fileHandle)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.progressHandler = { fraction in
            Task { @MainActor in progress(fraction) }
        }

        let requestBox = ResourceRequestIDBox()

        let writeError: Error? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
                let hasResumed = ResumeGuard()
                let requestID = PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { data in
                        writer.append(data)
                    },
                    completionHandler: { error in
                        guard hasResumed.markResumed() else { return }
                        continuation.resume(returning: error)
                    }
                )
                requestBox.id = requestID
            }
        } onCancel: {
            let requestID = requestBox.id
            if requestID != PHInvalidAssetResourceDataRequestID {
                PHAssetResourceManager.default().cancelDataRequest(requestID)
            }
        }
        writer.close()

        if let writeError {
            try? FileManager.default.removeItem(at: directory)
            throw writeError
        }
        if Task.isCancelled {
            // Do not return the file if the task was cancelled. A
            // cancelled request can complete without an error.
            try? FileManager.default.removeItem(at: directory)
            throw Failure.cancelled
        }
        return destination
    }

    /// Replaces "/" and ":" with "_". Returns "Shared.<ext>" if the name
    /// is empty, starts with a dot, or has no extension.
    private static func filename(for resource: PHAssetResource, fallbackExtension: String) -> String {
        let raw = resource.originalFilename
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.hasPrefix("."), (cleaned as NSString).pathExtension.isEmpty == false else {
            return "Shared.\(fallbackExtension)"
        }
        return cleaned
    }
}

/// Thread-safe latch that ensures a completion handler PhotoKit may invoke
/// more than once resumes its continuation only once. A local copy of
/// `PhotoLibraryService`'s file-private helper of the same name and shape.
/// See the note on `requestAVURLAsset` above.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didResume { return false }
        didResume = true
        return true
    }
}

/// Thread-safe box for the `PHImageRequestID` a PhotoKit request hands back
/// synchronously. A local copy of `PhotoLibraryService`'s file-private
/// helper of the same name and shape.
private final class RequestIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: PHImageRequestID = PHInvalidImageRequestID

    var id: PHImageRequestID {
        get { lock.lock(); defer { lock.unlock() }; return _id }
        set { lock.lock(); defer { lock.unlock() }; _id = newValue }
    }
}

/// Sibling of `RequestIDBox` for `PHAssetResourceManager.requestData`'s
/// `PHAssetResourceDataRequestID`. It starts at
/// `PHInvalidAssetResourceDataRequestID`, as `RequestIDBox` starts at
/// `PHInvalidImageRequestID`.
private final class ResourceRequestIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: PHAssetResourceDataRequestID = PHInvalidAssetResourceDataRequestID

    var id: PHAssetResourceDataRequestID {
        get { lock.lock(); defer { lock.unlock() }; return _id }
        set { lock.lock(); defer { lock.unlock() }; _id = newValue }
    }
}

/// Appends `PHAssetResourceManager.requestData`'s incremental chunks to a
/// temp file in the order they arrive. See the note on
/// `writeResourceCopy` above. PhotoKit calls `dataReceivedHandler` on one
/// serial queue. The lock is an extra safety measure. The class is
/// `@unchecked Sendable`, as `ResumeGuard` and `RequestIDBox` are.
private final class ResourceDataWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let fileHandle: FileHandle
    private var isClosed = false

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        fileHandle.write(data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        try? fileHandle.close()
    }
}
