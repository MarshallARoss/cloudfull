//
//  PhotoImagePipeline.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import Photos
import os

/// Progressive image loader for the photo feed.
///
/// A `PHCachingImageManager` prefetches images for a window of assets.
/// The prefetch runs ahead of the visible cells. An image is normally
/// already loading when its cell mounts.
///
/// PhotoKit returns a lazy image that decodes at first draw. This type
/// decodes every image off the main thread before it publishes it.
///
/// Every asset gets a still image, including a Live Photo. `LivePhotoStage`
/// draws the live content over the still when the asset is near.
///
/// Every full-size request and full-size caching call use one target
/// size: a box of `width × 2·width` at `.aspectFit`. The thumbnail lane
/// uses its own fixed box, `thumbTargetSize`, instead.
/// `PHCachingImageManager` serves a cached result only when a later
/// request's target size, content mode, and options match the caching
/// call exactly. One size fits every ordinary aspect by its width. A
/// per-asset size could differ between the caching call and the
/// request, and then miss the cache with no error.
@MainActor
final class PhotoImagePipeline {
    static let shared = PhotoImagePipeline()

    /// One event from an asset's load.
    ///
    /// `image` can arrive twice: first the degraded frame, then the
    /// full-quality frame. The degraded frame comes from the on-device
    /// thumbnail cache, so it arrives in milliseconds even when the
    /// original is in iCloud. The pipeline decodes both frames before
    /// they arrive here.
    enum Event: Sendable {
        case image(UIImage, isDegraded: Bool)
        /// iCloud download progress, from 0 to 1. Does not fire on a
        /// simulator or for an original that is already on the device.
        case progress(Double)
        /// The original lives in iCloud and a download is running for it.
        case remote
        /// PhotoKit will not produce an image for this asset.
        case failed
    }

    /// Apple documents `PHCachingImageManager` as thread-safe. Caching
    /// calls and per-post requests must run off the main actor: no
    /// synchronous PhotoKit call may run on the main thread. For this
    /// reason the property is outside the actor isolation, so callers do
    /// not switch to the main actor to use it.
    ///
    /// This type does not set `allowsCachingHighQualityImages`. The
    /// property is deprecated and unused in iOS 26; setting it only
    /// produces a warning.
    nonisolated(unsafe) private static let manager = PHCachingImageManager()

    /// A second manager, used only for the small local thumbnail.
    ///
    /// A request manager serialises its own work, so a full-size request
    /// queued on `manager` can delay a thumbnail request behind it.
    /// `manager` runs full-size `.opportunistic` requests with network
    /// access allowed for the whole prefetch window. A large iCloud
    /// download can sit in front of a tiny local thumbnail the user is
    /// waiting to see. A separate manager does not share that queue.
    ///
    /// Every request on this manager is for the same ~200 px box
    /// (`thumbTargetSize`), regardless of the stage `requestThumb`
    /// reaches. No full-size request can ever queue ahead of the frame
    /// the user is waiting for.
    nonisolated(unsafe) private static let thumbManager = PHCachingImageManager()

    /// Prepared (decoded) images, keyed by asset id. An `NSCache`, like
    /// `PosterCache`, evicts under memory pressure on its own. A cell
    /// that shows an image holds its own strong reference in `@State`,
    /// so an eviction never blanks a post that is on screen.
    private let cache = NSCache<NSString, UIImage>()

    /// Prepared small thumbnails, keyed by asset id. This cache holds
    /// many more entries than the full-size cache. A thumbnail is about
    /// 0.21 MB and a full frame is about 8 MB. When the user scrolls
    /// back to a post, the post shows its thumbnail from this cache at
    /// once. It requests the full frame again only if the cache evicted
    /// it.
    private let thumbCache = NSCache<NSString, UIImage>()

    /// Height-to-width ratio per asset id, from `noteAspects` and from
    /// the `setWindow` fetch. A post uses it to size its placeholder
    /// before tier-1 metadata arrives, so the row does not resize while
    /// the user scrolls.
    private var aspectByID: [String: CGFloat] = [:]

    /// Asset ids currently handed to `startCachingImages`. Lets
    /// `setWindow` compute the exact ids to start and stop, instead of
    /// restarting every caching call.
    private var cachedIDs: Set<String> = []

    /// The last window given to `setWindow`. Lets `resume()` re-warm
    /// exactly what `suspend()` stopped.
    private var lastWindowIDs: [String] = []

    /// True while Photos is not the visible mode. No caching or request
    /// may start in this state. See `suspend()`.
    private var isSuspended = false

    /// Every live per-post request. Lets `suspend()` cancel all of them
    /// directly, instead of relying on each post's own task teardown to
    /// cancel its request first.
    nonisolated(unsafe) private static let liveRequests = PhotoImageRequestRegistry()

    /// The feed's post width, in pixels. Starts at a default value, so a
    /// `setWindow` call before the first layout pass still caches a
    /// usable size. `configure(widthPoints:scale:)` replaces it after
    /// first layout.
    private var widthPixels: CGFloat = 402 * 3

    private init() {
        // A prepared 1206 × 1608 image is about 7.8 MB. The 72 MB byte
        // cap holds about nine such images and is the limit that
        // applies first. The count limit of 16 applies only when images
        // are smaller.
        cache.countLimit = 16
        cache.totalCostLimit = 72 * 1024 * 1024
        // A prepared 200 × 267 thumbnail is about 0.21 MB.
        thumbCache.countLimit = 120
        thumbCache.totalCostLimit = 32 * 1024 * 1024
    }

    // MARK: - Geometry

    /// Called from `PhotoFeedView`'s root `GeometryReader`. Does nothing
    /// unless the width changed, from a rotation or the first real
    /// layout replacing the default width. A width change drops the
    /// cache, because every cached image was prepared for the old size.
    func configure(widthPoints: CGFloat, scale: CGFloat) {
        guard widthPoints > 0, scale > 0 else { return }
        let pixels = (widthPoints * scale).rounded()
        guard pixels != widthPixels else { return }
        widthPixels = pixels
        Self.manager.stopCachingImagesForAllAssets()
        cachedIDs.removeAll()
        cache.removeAllObjects()
        // The thumbnail box is a fixed size, independent of the post
        // width, so a rotation does not invalidate any thumbnail.
    }

    /// The one box every request and every caching call uses. See this
    /// type's doc comment for why the size is shared and not per asset.
    var targetSize: CGSize {
        CGSize(width: widthPixels, height: widthPixels * 2)
    }

    /// The fast local thumbnail's box: about 200 px wide, and not
    /// derived from the post width.
    ///
    /// The size must be small enough that PhotoKit answers it from the
    /// on-device thumbnail cache, in tens of milliseconds, without a
    /// network request. A constant size also means a rotation never
    /// invalidates a thumbnail. A rotated feed still shows the cached
    /// thumbnails for posts the user already saw.
    nonisolated static let thumbTargetSize = CGSize(width: 200, height: 400)

    /// `PHAsset.pixelHeight / pixelWidth`, if the window fetch has
    /// already seen this asset, else `nil`. Never fetches; a view body
    /// reads this.
    func aspectRatio(for assetID: String) -> CGFloat? {
        aspectByID[assetID]
    }

    // MARK: - Cache reads

    /// A prepared image for this asset, or `nil`. Never fetches and
    /// never suspends. `PhotoPostView` reads it on the first line of its
    /// load task. Scrolling back to a post it has already seen paints
    /// immediately, with no placeholder frame in between.
    func cachedImage(for assetID: String) -> UIImage? {
        cache.object(forKey: assetID as NSString)
    }

    /// The small prepared thumbnail for this asset, or `nil`. Follows
    /// the same rules as `cachedImage(for:)`: never fetches, never
    /// suspends. `PhotoPostView` reads this second, so a post whose full
    /// frame was evicted still paints something immediately instead of a
    /// blank cell.
    func cachedThumbnail(for assetID: String) -> UIImage? {
        thumbCache.object(forKey: assetID as NSString)
    }

    /// Seeds aspect ratios for a freshly dealt window (`PhotoDeck.dealWindow`).
    /// The deal already fetched each `PHAsset`, so reading its pixel size
    /// here is cheap. The ratio gives the placeholder the correct height
    /// on its first layout pass, before metadata or pixels arrive.
    func noteAspects(_ items: [PhotoWindowItem]) {
        var aspects: [String: CGFloat] = [:]
        for item in items where item.pixelWidth > 0 && item.pixelHeight > 0 {
            aspects[item.id] = CGFloat(item.pixelHeight) / CGFloat(item.pixelWidth)
        }
        guard !aspects.isEmpty else { return }
        mergeAspects(aspects)
    }

    // MARK: - Window prefetch

    /// Sets the asset ids to prefetch (from
    /// `PhotoDeck.triggerImagePrefetch`, the same range the metadata
    /// prefetcher uses). Starts caching every id newly named and stops
    /// caching every id that dropped out. A cell that left the window
    /// no longer occupies PhotoKit's decode queue ahead of the cell the
    /// user is looking at.
    ///
    /// Does not wait for its work: the `PHAsset` fetch and both caching
    /// calls run off the main thread.
    func setWindow(_ assetIDs: [String]) {
        lastWindowIDs = assetIDs
        // Nothing warms while Photos is off screen. Without this guard,
        // a late prefetch trigger could restart the downloads
        // `suspend()` just stopped.
        guard !isSuspended else { return }
        let wanted = Set(assetIDs)
        let toStart = wanted.subtracting(cachedIDs)
        let toStop = cachedIDs.subtracting(wanted)
        guard !toStart.isEmpty || !toStop.isEmpty else { return }
        cachedIDs = wanted

        let size = targetSize
        Task.detached(priority: .utility) {
            let options = Self.makeRequestOptions()
            let thumbOptions = Self.makeThumbRequestOptions(stage: 0)
            let thumbSize = Self.thumbTargetSize
            let stopAssets = Self.assets(for: Array(toStop))
            if !stopAssets.isEmpty {
                Self.manager.stopCachingImages(
                    for: stopAssets, targetSize: size, contentMode: .aspectFit, options: options
                )
                Self.thumbManager.stopCachingImages(
                    for: stopAssets, targetSize: thumbSize, contentMode: .aspectFit, options: thumbOptions
                )
            }
            let startAssets = Self.assets(for: Array(toStart))
            if !startAssets.isEmpty {
                // Start the thumbnails first, on their own manager. If a
                // full-size request queues first, the degraded frame
                // arrives after the download.
                Self.thumbManager.startCachingImages(
                    for: startAssets, targetSize: thumbSize, contentMode: .aspectFit, options: thumbOptions
                )
                Self.manager.startCachingImages(
                    for: startAssets, targetSize: size, contentMode: .aspectFit, options: options
                )
            }
            let aspects = startAssets.reduce(into: [String: CGFloat]()) { table, asset in
                guard asset.pixelWidth > 0 else { return }
                table[asset.localIdentifier] = CGFloat(asset.pixelHeight) / CGFloat(asset.pixelWidth)
            }
            guard !aspects.isEmpty else { return }
            await MainActor.run { PhotoImagePipeline.shared.mergeAspects(aspects) }
        }
    }

    private func mergeAspects(_ aspects: [String: CGFloat]) {
        for (id, ratio) in aspects { aspectByID[id] = ratio }
        // When the table grows past 2000 entries, keep only the newest
        // batch. A long session must not grow the table without limit.
        //
        // The cap is generous, because a `String: CGFloat` pair is tiny.
        // Dropping the table is still visible to the user. A post whose
        // aspect is forgotten re-measures its placeholder, and the feed
        // reflows while the user watches.
        if aspectByID.count > 2000 {
            aspectByID = aspects
        }
    }

    // MARK: - Mode suspend / resume

    /// Stops all photo image work. Called when Photos stops being the
    /// visible mode (`PhotoFeedView.onDisappear`).
    ///
    /// A `PHCachingImageManager` keeps prefetching whatever it was last
    /// told to cache, until something tells it to stop. This pipeline
    /// warms a window of full-size requests with network access
    /// allowed. Leaving this call out would let iCloud photo downloads
    /// keep running after `PhotoFeedView` unmounts, competing with other
    /// network or decode work.
    ///
    /// Keeps both caches. The caches let Photos show images at once
    /// when it becomes visible again. They cost nothing while idle, and
    /// `NSCache` evicts entries under memory pressure.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        Self.manager.stopCachingImagesForAllAssets()
        Self.thumbManager.stopCachingImagesForAllAssets()
        cachedIDs.removeAll()
        let cancelled = Self.liveRequests.cancelAll()
        #if DEBUG
        Self.pipelineLog.notice(
            "photo_pipeline_suspend_cancelled_\(cancelled, privacy: .public)_window_\(self.lastWindowIDs.count, privacy: .public)"
        )
        #endif
    }

    /// Re-warms exactly the window `suspend()` stopped. Called when
    /// Photos becomes the visible mode again. Per-post requests restart
    /// on their own, as each post's `.task` reruns on mount.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        let window = lastWindowIDs
        #if DEBUG
        Self.pipelineLog.notice("photo_pipeline_resume_window_\(window.count, privacy: .public)")
        #endif
        guard !window.isEmpty else { return }
        setWindow(window)
    }

    /// How many per-post image requests are live now. The DEBUG
    /// `photo_inflight_<n>` probe reads this.
    nonisolated var inFlightRequestCount: Int { Self.liveRequests.count }

    // MARK: - Per-post load

    /// Delivers this asset's image progressively. The degraded frame
    /// arrives as soon as PhotoKit has one, then the full-quality frame,
    /// both already decoded off the main thread. Also reports iCloud
    /// download progress and failure, so a cell is never left blank with
    /// no explanation.
    ///
    /// Cancelling the consuming task cancels the PhotoKit request,
    /// matching `PhotoLibraryService.posterImages(for:side:)`.
    nonisolated func events(for assetID: String) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let requestBox = PhotoImageRequestBox(manager: PhotoImagePipeline.manager)
            let thumbBox = PhotoImageRequestBox(manager: PhotoImagePipeline.thumbManager)
            // Registered so `suspend()` can cancel this directly. A
            // post's own `.task` teardown usually cancels the request
            // first. A missed cancellation would leave an iCloud
            // download running against video playback the user is
            // watching.
            let token = PhotoImagePipeline.liveRequests.register(thumbBox, requestBox)
            continuation.onTermination = { _ in
                PhotoImagePipeline.liveRequests.unregister(token)
                thumbBox.cancel()
                requestBox.cancel()
            }
            Task.detached(priority: .userInitiated) {
                #if DEBUG
                // `-cloudfull-slow-photo <seconds>` delays the whole
                // per-post delivery, not only the full-size frame; see
                // `CloudfullApp.slowPhotoArgument`'s doc comment for why.
                // The delay runs before either request starts. If the
                // user scrolls the post away during the delay, its
                // `.task` teardown cancels the stream before any
                // PhotoKit call.
                if let delay = PhotoImagePipeline.slowPhotoDelay {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                }
                #endif
                let size = await PhotoImagePipeline.shared.targetSize
                guard let asset = PhotoLibraryService.fetchAsset(assetID) else {
                    continuation.yield(.failed)
                    continuation.finish()
                    return
                }
                let options = PhotoImagePipeline.makeRequestOptions()
                let gate = PhotoImageDeliveryGate()

                // The fast lane: its own request, on its own manager,
                // before any full-size request goes out. The fast lane
                // requests `.fastFormat` at about 200 px, local first.
                // PhotoKit answers from the device's own thumbnail cache
                // in tens of milliseconds, even when the original is in
                // iCloud. Not awaited, and never finishes the stream on
                // its own: it only yields an early frame.
                PhotoImagePipeline.requestThumb(
                    asset: asset,
                    assetID: assetID,
                    stage: 0,
                    box: thumbBox,
                    gate: gate,
                    continuation: continuation
                )

                options.progressHandler = { progress, error, _, _ in
                    guard error == nil else {
                        continuation.yield(.failed)
                        return
                    }
                    continuation.yield(.remote)
                    continuation.yield(.progress(progress))
                }
                requestBox.id = PhotoImagePipeline.manager.requestImage(
                    for: asset,
                    targetSize: size,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        continuation.finish()
                        return
                    }
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                        continuation.yield(.remote)
                    }
                    guard let image else {
                        // No image, and no better image follows. PhotoKit
                        // cannot produce an image for this asset.
                        if !isDegraded {
                            continuation.yield(.failed)
                            continuation.finish()
                        }
                        return
                    }
                    guard gate.allow(isDegraded: isDegraded) else {
                        if !isDegraded { continuation.finish() }
                        return
                    }
                    // PhotoKit returns a lazy image, so the caller must
                    // decode it. Decode it here, on a detached task off
                    // the main thread, so the scroll does not drop
                    // frames for each new cell.
                    Task.detached(priority: .userInitiated) {
                        let prepared = Self.preparedForDelivery(image, asset: asset, targetWidth: size.width)
                        if !isDegraded {
                            await MainActor.run {
                                PhotoImagePipeline.shared.store(prepared, for: assetID)
                            }
                        }
                        continuation.yield(.image(prepared, isDegraded: isDegraded))
                        if !isDegraded { continuation.finish() }
                    }
                }
            }
        }
    }

    /// Resizes the full-size image to the exact size the row draws.
    /// The width is `targetWidth`, the post width in pixels. The
    /// height follows the asset's aspect ratio. `.exact` already gives
    /// most photos this size, because their width fills the request
    /// box first. A very tall panorama can still arrive narrower,
    /// because the box is `width × 2·width`. If
    /// `preparingThumbnail(of:)` fails, `preparingForDisplay()` decodes
    /// the image.
    nonisolated private static func preparedForDelivery(
        _ image: UIImage, asset: PHAsset, targetWidth: CGFloat
    ) -> UIImage {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0, targetWidth > 0 else {
            return image.preparingForDisplay() ?? image
        }
        let aspect = CGFloat(asset.pixelHeight) / CGFloat(asset.pixelWidth)
        let exactSize = CGSize(width: targetWidth, height: (targetWidth * aspect).rounded())
        return image.preparingThumbnail(of: exactSize) ?? image.preparingForDisplay() ?? image
    }

    private func store(_ image: UIImage, for assetID: String) {
        cache.setObject(image, forKey: assetID as NSString, cost: Self.cost(of: image))
    }

    private func storeThumb(_ image: UIImage, for assetID: String) {
        thumbCache.setObject(image, forKey: assetID as NSString, cost: Self.cost(of: image))
    }

    // MARK: - Shared request options
    //
    // `startCachingImages` and `requestImage` must pass equal options for
    // the cache to be consulted at all, so both go through this one
    // factory. `.opportunistic` delivers a degraded frame first and a
    // sharp frame after it. Network access is allowed, because an
    // original can live only in iCloud; with network access off,
    // PhotoKit can return only the tiny degraded thumbnail.

    nonisolated private static func makeRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        // `.fast` lets PhotoKit return a bitmap only near `targetSize`,
        // so CoreGraphics resamples it (`argb32_sample_argb32`) on every
        // draw inside the CA commit. `.exact` makes PhotoKit do that
        // resize itself, off this actor, before the image reaches
        // `PhotoPostView`, so the draw becomes a direct copy with no
        // resampling.
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return options
    }

    /// The fast lane's options. They use `.fast` resize mode, not
    /// `.exact`. Stages 0 and 1 use `.fastFormat`, which returns the
    /// image PhotoKit already has instead of the best image it can
    /// make.
    ///
    /// `isNetworkAccessAllowed` is `false` for the window caching call
    /// and for a post's first attempt. The local thumbnail is the goal,
    /// and a network-off request is the only way to be sure PhotoKit
    /// does not turn it into a download. The caching call and that first
    /// request must pass equal options, or `PHCachingImageManager` will
    /// not serve the cached result at all. Each higher `stage` costs
    /// more and is more likely to return an image. See `requestThumb`.
    nonisolated private static func makeThumbRequestOptions(stage: Int) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.resizeMode = .fast
        options.isSynchronous = false
        switch stage {
        case 0:
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
        case 1:
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = true
        default:
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
        }
        return options
    }

    /// The last stage `requestThumb` tries. `nonisolated`, because
    /// `requestThumb` itself is nonisolated and runs off the main actor.
    nonisolated private static let thumbLastStage = 2

    /// Asks for one small frame, walking three stages until PhotoKit
    /// gives one. Always the same small box, always on `thumbManager`,
    /// so no stage can queue behind the full-size lane.
    ///
    /// * stage 0 — `.fastFormat`, network off. The intended path, and
    ///   the one the window caching call warms: the device's own
    ///   thumbnail, in tens of milliseconds, with no data used.
    /// * stage 1 — `.fastFormat`, network on. For an asset with no
    ///   on-device thumbnail at all.
    /// * stage 2 — `.opportunistic`, network on. PhotoKit can decode an
    ///   image to answer. At 200 px this costs much less than the
    ///   full-size request. This is the last stage.
    ///
    /// Three stages exist because a `.fastFormat` request can fail with
    /// `PHPhotosError.networkAccessRequired` (3303), even when network
    /// access is allowed. A fast lane that silently produces nothing for
    /// those assets is worse than no fast lane. The post then sits on
    /// its placeholder until the full-size request lands.
    nonisolated private static func requestThumb(
        asset: PHAsset,
        assetID: String,
        stage: Int,
        box: PhotoImageRequestBox,
        gate: PhotoImageDeliveryGate,
        continuation: AsyncStream<Event>.Continuation
    ) {
        box.id = thumbManager.requestImage(
            for: asset,
            targetSize: thumbTargetSize,
            contentMode: .aspectFit,
            options: makeThumbRequestOptions(stage: stage)
        ) { image, info in
            #if DEBUG
            logThumb(assetID: assetID, stage: stage, image: image, info: info)
            #endif
            guard (info?[PHImageCancelledKey] as? Bool) != true else { return }
            guard let image else {
                if stage < thumbLastStage {
                    requestThumb(
                        asset: asset, assetID: assetID, stage: stage + 1,
                        box: box, gate: gate, continuation: continuation
                    )
                }
                return
            }
            Task.detached(priority: .userInitiated) {
                let prepared = image.preparingForDisplay() ?? image
                await MainActor.run {
                    PhotoImagePipeline.shared.storeThumb(prepared, for: assetID)
                }
                // `allow` keeps the delivery order correct: once the
                // sharp frame has landed, this thumbnail is dropped
                // instead of blurring a post that has already
                // sharpened.
                guard gate.allow(isDegraded: true) else { return }
                continuation.yield(.image(prepared, isDegraded: true))
            }
        }
    }

    nonisolated private static func assets(for ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Decoded byte count. `totalCostLimit` is accurate only if the cost
    /// reflects real memory use, not the compressed source size, the
    /// same reasoning `PosterCache.cost(of:)` uses.
    nonisolated private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    #if DEBUG
    /// Seconds to delay every per-post `events(for:)` delivery, set by
    /// `-cloudfull-slow-photo <seconds>`. See
    /// `CloudfullApp.slowPhotoArgument`'s doc comment for why. A
    /// `nonisolated static let`, read once at first use, the same
    /// pattern as `PhotoLibraryService.slowLoadDelay`. `nil` on every
    /// launch except a deliberately slow-photo one, and costs only one
    /// already-computed optional check.
    nonisolated static let slowPhotoDelay: TimeInterval? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: CloudfullApp.slowPhotoArgument),
              arguments.index(after: flag) < arguments.endIndex,
              let seconds = TimeInterval(arguments[arguments.index(after: flag)]),
              seconds > 0 else { return nil }
        return seconds
    }()

    /// `-cloudfull-log-thumbs`: one line per fast-lane result, giving
    /// PhotoKit's own reply instead of a guess about why a frame is
    /// still missing. Off by default. Read with
    /// `log stream --predicate 'category == "PhotoThumbLane"'`. Also
    /// written to `DiagnosticsLog` (Documents/diagnostics.log) when the
    /// flag is on; see `logThumb(assetID:stage:image:info:)` below.
    nonisolated private static let thumbLog = Logger(subsystem: "com.cloudfull.app", category: "PhotoThumbLane")
    /// Always on in DEBUG, with no flag. `suspend()` and `resume()`
    /// each write one line. When Photos is off screen, its UI probes
    /// are unmounted, so this log is the only way to confirm that photo
    /// downloads stopped.
    nonisolated fileprivate static let pipelineLog = Logger(subsystem: "com.cloudfull.app", category: "PhotoPipeline")

    nonisolated static func logThumb(assetID: String, stage: Int, image: UIImage?, info: [AnyHashable: Any]?) {
        guard DiagnosticsGate.isOn("-cloudfull-log-thumbs") else { return }
        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
        let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
        let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
        let error = (info?[PHImageErrorKey] as? NSError)?.localizedDescription ?? "none"
        let size = image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil"
        let line = "thumb_s\(stage)_\(size)_deg_\(degraded)_cloud_\(inCloud)_cancel_\(cancelled)_err_\(error)_\(assetID)"
        thumbLog.notice("\(line, privacy: .public)")
        DiagnosticsLog.shared.log("PhotoThumbLane", line)
    }

    /// Stops all caching and clears every cache and table. Intended for
    /// the `-cloudfull-reset-deck-state` launch path.
    func resetForTesting() {
        Self.manager.stopCachingImagesForAllAssets()
        Self.thumbManager.stopCachingImagesForAllAssets()
        cachedIDs.removeAll()
        aspectByID.removeAll()
        cache.removeAllObjects()
        thumbCache.removeAllObjects()
    }
    #endif
}

/// Every live per-post request pair, so the pipeline can cancel all of
/// them at once when Photos stops being the visible mode. Has its own
/// lock and no reference to the pipeline, because PhotoKit's callback
/// threads touch it, as well as the main actor.
private final class PhotoImageRequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var boxes: [Int: [PhotoImageRequestBox]] = [:]
    private var nextToken = 0

    func register(_ entries: PhotoImageRequestBox...) -> Int {
        lock.lock()
        nextToken += 1
        boxes[nextToken] = entries
        let count = boxes.count
        lock.unlock()
        #if DEBUG
        // This diagnostics log is touched from PhotoKit's own callback
        // threads as well as the main actor, so the gate reads
        // `isOnMirror`, never the main-actor
        // `DiagnosticsSwitch.shared.isOn`.
        if DiagnosticsSwitch.isOnMirror {
            DiagnosticsLog.shared.log("PhotoInflight", "photo_inflight_\(count)")
        }
        #endif
        return nextToken
    }

    func unregister(_ token: Int) {
        lock.lock()
        boxes.removeValue(forKey: token)
        let count = boxes.count
        lock.unlock()
        #if DEBUG
        if DiagnosticsSwitch.isOnMirror {
            DiagnosticsLog.shared.log("PhotoInflight", "photo_inflight_\(count)")
        }
        #endif
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return boxes.count
    }

    /// Cancels everything live and returns how many request pairs it cancelled.
    @discardableResult
    func cancelAll() -> Int {
        lock.lock()
        let live = boxes
        boxes.removeAll()
        lock.unlock()
        // Outside the lock: `cancel()` calls into PhotoKit.
        for entry in live.values {
            for box in entry { box.cancel() }
        }
        return live.count
    }
}

/// Holds a `PHImageRequestID` across the gap between the stream's
/// termination handler, installed first, and the detached task that
/// starts the request. Solves the same ordering problem as
/// `PhotoLibraryService`'s own `RequestIDBox`, kept as a separate type
/// so neither one owns the other's lifetime rules.
private final class PhotoImageRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHImageRequestID = PHInvalidImageRequestID
    private var isCancelled = false
    /// The manager the request was made on. A `PHImageRequestID` is
    /// meaningful only to its own manager. Cancelling this pipeline's
    /// `PHCachingImageManager` request through `PHImageManager.default()`
    /// would silently cancel nothing, or cancel a different request.
    private let manager: PHImageManager

    init(manager: PHImageManager) {
        self.manager = manager
    }

    var id: PHImageRequestID {
        get {
            lock.lock(); defer { lock.unlock() }
            return requestID
        }
        set {
            lock.lock()
            requestID = newValue
            let shouldCancelNow = isCancelled
            lock.unlock()
            if shouldCancelNow, newValue != PHInvalidImageRequestID {
                manager.cancelImageRequest(newValue)
            }
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let pending = requestID
        lock.unlock()
        if pending != PHInvalidImageRequestID {
            manager.cancelImageRequest(pending)
        }
    }
}

/// Keeps the degraded-then-sharp order correct. Each image is prepared
/// on its own detached task. Without this gate, a slow degraded decode
/// could land after the sharp one and blur a cell that had already
/// sharpened.
private final class PhotoImageDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var sharpDelivered = false

    func allow(isDegraded: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if sharpDelivered { return false }
        if !isDegraded { sharpDelivered = true }
        return true
    }
}
