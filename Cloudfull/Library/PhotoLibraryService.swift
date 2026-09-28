//
//  PhotoLibraryService.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
import Photos
import AVFoundation
import Combine
import UIKit
import CoreLocation
import Network
import os

/// The facts the filter predicate and the sorted list need about one
/// video, read once per library scan.
///
/// This type holds no file size. The app keeps no size index. Reading
/// `PHAssetResource` for each asset costs several seconds per few
/// thousand videos.
///
/// This type stays top-level, not nested inside `PhotoLibraryService`.
/// `FeedFilters` (`Cloudfull/Deck/FeedOptions.swift`) reads this type,
/// so that file needs no other PhotoKit type.
struct VideoFacts: Equatable, Sendable {
    let id: String
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let mediaSubtypes: PHAssetMediaSubtype
    let creationDate: Date?
}

/// The facts one feed page's caption and rail need, read off one
/// `PHAsset` on a background executor and handed back as a value type.
///
/// Code on the main actor must never wait on PhotoKit. This type, not a
/// `PHAsset`, is what crosses back to `FeedPageContent`.
///
/// This type stays top-level, not nested inside `PhotoLibraryService`,
/// like `VideoFacts`. The feed reads this type and needs no other
/// PhotoKit type.
struct PageFacts: Sendable, Equatable {

    // MARK: Display strings
    //
    // The code formats these strings here, on the background thread that
    // read the asset. It does not format them later on the main actor.
    //
    // `Fmt` (Cloudfull/Design/DesignSystem.swift) is an enum of pure
    // static functions with no actor isolation. `Date.formatted(_:)` is
    // nonisolated. Both are safe to call from this executor.
    //
    // `ByteCountFormatter` allocates memory on each call. The first use of
    // `Date.FormatStyle` initializes ICU. Neither task belongs on the main
    // thread.

    /// Example: "June 12, 2021 · 3:47 PM". Reads "Unknown date" when the
    /// asset has no creation date.
    let dateText: String
    /// Example: "4K · 1:12 · 428 MB". The parts join with " · ".
    let detailText: String
    /// Example: "June 12, 2021 · 3:47 PM. 4K, 1:12, 428 MB."
    let voiceOverLabel: String

    // MARK: Raw facts
    //
    // These fields stay raw values, not formatted strings, because a UI
    // test probe reads them directly. Do not make a test assertion
    // compare against a formatted display string.

    let pixelWidth: Int
    let pixelHeight: Int
    let durationMs: Int
    let subtypeRaw: Int
    /// Reads -1 when the asset has no creation date.
    let createdMs: Int64

    /// The result of `Fmt.isAboveShrinkThreshold` for the asset's own
    /// pixel size. This is the same rule the caption uses, computed once
    /// here.
    let isAboveShrinkThreshold: Bool

    /// `PHAsset.location`'s coordinate, flattened into two `Double`
    /// values.
    ///
    /// This is not a `CLLocation`. `CLLocation` is a reference type, and
    /// this value crosses an isolation boundary. Two `Double` values are
    /// copied, so no other code can change them after the copy is made.
    /// `FeedPageContent` rebuilds the `CLLocation` for `PlaceLookup` on
    /// the main actor at no extra cost.
    let coordinate: Coordinate?

    struct Coordinate: Sendable, Equatable {
        let latitude: Double
        let longitude: Double
    }
}

/// Wraps PhotoKit access for the app. It handles authorization, video
/// enumeration, asset lookup, and streaming AVPlayerItems, including
/// iCloud originals.
@MainActor
final class PhotoLibraryService: NSObject, ObservableObject {

    static let shared = PhotoLibraryService()

    @Published private(set) var authStatus: PHAuthorizationStatus

    /// Every handler registered through `addLibraryChangeObserver`, keyed
    /// by the token that registration returned. The service invokes each
    /// handler on the main queue whenever PhotoKit reports a library
    /// change, once the service registers as an observer after
    /// authorization.
    ///
    /// This is a dictionary, not an array a caller could only append to.
    /// `DeckViewModel` and `TrashService` are per-session objects that
    /// `AuthorizedSession` builds. They are not singletons. `FeedView`'s
    /// `.task` calls their `start()` method again on every remount, for
    /// example after an access downgrade and restore in Settings. If a
    /// caller does not remove its handler, each remount adds a live
    /// handler that keeps a released deck or queue in memory.
    private var libraryChangeHandlers: [LibraryObserverToken: () -> Void] = [:]

    /// Registers a handler to run on every PhotoKit change notification.
    /// Returns a token. Pass the token to `removeLibraryChangeObserver`
    /// when the caller finishes, or is replaced, so its handler stops
    /// firing.
    @discardableResult
    func addLibraryChangeObserver(_ handler: @escaping () -> Void) -> LibraryObserverToken {
        let token = LibraryObserverToken()
        libraryChangeHandlers[token] = handler
        return token
    }

    /// Unregisters a handler.
    ///
    /// This method is `nonisolated` and hops to the main queue internally,
    /// rather than a `@MainActor` method that needs an isolation
    /// assertion at every call site. This lets `deinit` on a `@MainActor`
    /// caller, such as `DeckViewModel` or `TrashService`, call this
    /// method directly.
    nonisolated func removeLibraryChangeObserver(_ token: LibraryObserverToken) {
        DispatchQueue.main.async { [weak self] in
            self?.libraryChangeHandlers.removeValue(forKey: token)
        }
    }

    private var isObservingChanges = false

    /// True once `NWPathMonitor` reports the current network path as
    /// expensive (cellular or a personal hotspot) or constrained (Low
    /// Data Mode). iCloud originals download over Wi-Fi only by default.
    ///
    /// The value starts `false`. The first monitor callback usually
    /// arrives soon after `start()`. Do not block a caller until the
    /// device reports a metered path.
    @Published private(set) var isNetworkExpensiveOrConstrained = false
    private let pathMonitor = NWPathMonitor()

    private override init() {
        self.authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        if authStatus == .authorized || authStatus == .limited {
            registerChangeObserverIfNeeded()
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.status == .satisfied && (path.isExpensive || path.isConstrained)
            DispatchQueue.main.async {
                self?.isNetworkExpensiveOrConstrained = expensive
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.cloudfull.app.pathmonitor"))
    }

    /// Requests read/write access to the photo library and updates
    /// `authStatus`.
    @discardableResult
    func requestAccess() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authStatus = status
        if status == .authorized || status == .limited {
            registerChangeObserverIfNeeded()
        }
        return status
    }

    /// Re-reads the system authorization status.
    ///
    /// PhotoKit never notifies the app of an access change made in
    /// Settings. Callers must call this method themselves, for example
    /// when the scene returns to `.active`. This catches an upgrade or a
    /// downgrade, such as a switch to Limited access.
    func refreshAuthStatus() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status != authStatus else { return }
        authStatus = status
        if status == .authorized || status == .limited {
            registerChangeObserverIfNeeded()
        }
        // A downgrade observed mid-session must not leave
        // `AssetKeyResolver` reporting a stale `.clean` or `.resolved`
        // state from before the narrowing. This method is the only place
        // that catches a downgrade, since PhotoKit posts no notification
        // for a Settings-made access change. `DeckViewModel` and
        // `TrashService` prime the resolver again on the next library
        // change. This call makes the resolver correct before that
        // change arrives.
        if status == .limited {
            AssetKeyResolver.shared.handleAuthDowngradeToLimited()
        }
    }

    /// All videos in the library, oldest first, as stable local
    /// identifiers.
    func fetchAllVideoIDs() -> [String] {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        return Self.allVideoIDsOffMain()
    }

    /// The same enumeration, callable from any thread.
    ///
    /// `TrashService` calls this from a detached task to prime
    /// `AssetKeyResolver`. A full library walk on the main actor can
    /// block it for seconds.
    nonisolated static func allVideoIDsOffMain() -> [String] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .video, options: options)

        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    /// Every asset in the library, of any media type, as stable local
    /// identifiers. Callable from any thread, with the same contract as
    /// `allVideoIDsOffMain()`.
    ///
    /// An existence check for the bin must include every media type,
    /// because photos and videos share the `TrashEntry` table. A
    /// video-only existence check would treat every live, still-queued
    /// photo as a row whose asset no longer exists. Two consecutive
    /// reconcile passes would then delete that photo's `TrashEntry` row,
    /// without touching the actual asset in the photo library.
    nonisolated static func allAssetIDsOffMain() -> [String] {
        let result = PHAsset.fetchAssets(with: PHFetchOptions())

        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    /// Which of `ids` still name a live asset of any media type, and
    /// whether the library holds any asset at all.
    ///
    /// Checks only the ids in the bin, not the whole library.
    ///
    /// `allAssetIDsOffMain()` answers "does this row's asset still exist"
    /// by materializing every id in the library. On a large library, this
    /// costs tens of megabytes and seconds of work. The reconcile path
    /// runs it on every entry into Photos and on every PhotoKit change
    /// notice. The reconcile only ever asks about the handful of ids
    /// already in the bin, so this method asks about exactly those ids.
    ///
    /// `libraryIsEmpty` is a safety check. `PHFetchResult.count` does not
    /// load the assets, so the check is cheap. Without it, a spot check
    /// that comes back empty because PhotoKit is temporarily unresponsive
    /// would read as every row missing.
    nonisolated static func existingIdentifiers(among ids: [String]) -> (found: Set<String>, libraryIsEmpty: Bool) {
        #if DEBUG
        FetchCounters.bumpPhotoKit(2)
        #endif
        let libraryIsEmpty = PHAsset.fetchAssets(with: PHFetchOptions()).count == 0
        guard !ids.isEmpty else { return ([], libraryIsEmpty) }
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var out = Set<String>()
        found.enumerateObjects { asset, _, _ in out.insert(asset.localIdentifier) }
        return (out, libraryIsEmpty)
    }

    // MARK: - Filter and sort

    /// All videos in the library as `VideoFacts`, in the order `sort`
    /// asks for, read off the main actor.
    ///
    /// This method issues one `PHAsset.fetchAssets` call and one
    /// enumeration, the same PhotoKit cost as `fetchAllVideoIDs()`. Every
    /// property read inside the enumeration is an in-memory read off the
    /// already-materialized `PHAsset`, so none of them is a second round
    /// trip.
    ///
    /// Keep `.random` in ascending creation-date order.
    /// `DeckViewModel.rebuildDeck` reconstructs a cycle's deal-time input
    /// as `libraryIDs.filter { … }` and checks it against a stored
    /// digest, so the enumeration order is part of that contract.
    /// Changing the order silently forces a full deck rebuild on every
    /// launch.
    ///
    /// This method uses `Task.detached`, not a bare `nonisolated func …
    /// async`. Under Swift 6.2's `NonisolatedNonsendingByDefault`, a
    /// nonisolated async function runs on the caller's executor, which
    /// for this method would be the main actor. `Task.detached` always
    /// runs off the caller's executor, whatever that setting is, and
    /// matches the pattern in `AssetKeyResolver.resolveCandidates`
    /// (AssetKeyResolver.swift).
    nonisolated func loadVideoIndex(sort: FeedSort) async -> [VideoFacts] {
        await Task.detached(priority: .userInitiated) {
            Self.videoIndex(sort: sort)
        }.value
    }

    /// The synchronous body of `loadVideoIndex(sort:)`. This method is
    /// `nonisolated static`. Do not call it from the main actor; it
    /// makes synchronous PhotoKit calls.
    nonisolated static func videoIndex(sort: FeedSort) -> [VideoFacts] {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        let options = PHFetchOptions()
        let ascending = (sort != .dateNewest)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
        let result = PHAsset.fetchAssets(with: .video, options: options)

        var facts: [VideoFacts] = []
        facts.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            facts.append(VideoFacts(
                id: asset.localIdentifier,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.duration,
                mediaSubtypes: asset.mediaSubtypes,
                creationDate: asset.creationDate
            ))
        }
        return facts
    }

    /// One page's caption and rail facts, read off the main actor.
    /// Returns `nil` when the asset no longer resolves, so the caller
    /// renders the same empty caption it renders for any other vanished
    /// asset.
    ///
    /// This makes two PhotoKit calls, neither on the main thread:
    /// one `PHAsset.fetchAssets` call, and one
    /// `PHAssetResource.assetResources` call inside the size read.
    /// `pageFacts(for:)` passes the fetched asset to `assetSize(for:)`,
    /// so the asset is fetched once.
    nonisolated func loadPageMeta(for id: String) async -> PageFacts? {
        await Task.detached(priority: .userInitiated) {
            Self.pageFacts(for: id)
        }.value
    }

    /// The synchronous body of `loadPageMeta(for:)`. This method is
    /// `nonisolated static`. Do not call it from the main actor; it
    /// makes synchronous PhotoKit calls.
    nonisolated static func pageFacts(for id: String) -> PageFacts? {
        guard let asset = fetchAsset(id) else { return nil }
        let size = assetSize(for: asset)

        let date = asset.creationDate.map {
            $0.formatted(.dateTime.month(.wide).day().year()) + " · " + $0.formatted(.dateTime.hour().minute())
        } ?? "Unknown date"
        let resolution = Fmt.resolution(CGSize(width: asset.pixelWidth, height: asset.pixelHeight))
        let duration = Fmt.duration(asset.duration)
        let bytes = (size.isEstimated ? "About " : "") + Fmt.bytes(size.bytes)
        let pixelSize = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)

        return PageFacts(
            dateText: date,
            detailText: [resolution, duration, bytes].filter { !$0.isEmpty }.joined(separator: " · "),
            voiceOverLabel: "\(date). \(resolution), \(duration), \(bytes).",
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            durationMs: Int((asset.duration * 1000).rounded()),
            subtypeRaw: Int(asset.mediaSubtypes.rawValue),
            createdMs: asset.creationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? -1,
            isAboveShrinkThreshold: Fmt.isAboveShrinkThreshold(pixelSize),
            coordinate: asset.location.map {
                PageFacts.Coordinate(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude
                )
            }
        )
    }

    /// The `PHAsset` fetch, callable from any executor.
    ///
    /// `asset(for:)` is a main-actor wrapper over this method. Callers
    /// in Trash/, Jobs/, Share/, and Storage/ use that wrapper.
    nonisolated static func fetchAsset(_ id: String) -> PHAsset? {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Looks up a single asset by local identifier, if it still exists.
    func asset(for id: String) -> PHAsset? { Self.fetchAsset(id) }

    // MARK: - Cross-device identity

    /// A best-effort `PHCloudIdentifier` for a local asset. Store this
    /// alongside a local-identifier-keyed row so the row can still be
    /// found after a restore or a device migration rotates local
    /// identifiers.
    ///
    /// Returns `nil` when iCloud Photos is off, the asset has no cloud
    /// identifier yet, or PhotoKit cannot resolve it. Every caller must
    /// treat `nil` as "no cloud key available", not as an error.
    func cloudIdentifier(forLocalIdentifier id: String) -> String? {
        let mapping = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [id])
        guard case .success(let cloudID)? = mapping[id] else { return nil }
        return cloudID.stringValue
    }

    /// Limits a PhotoKit call to 20 seconds. Without a limit, a
    /// completion handler that never runs leaves a page spinner or a
    /// grid placeholder on screen until the app quits.
    /// `ShrinkService`'s `requestExportSessionWithTimeout` documents the
    /// same class of hang.
    ///
    /// This value matches `PlayerHolder.waitUntilReady`'s own 20 second
    /// sleep. A stalled page then reaches its Retry card within one 20
    /// second budget, not two stacked budgets.
    private static let photoKitContinuationTimeout: UInt64 = 20_000_000_000

    private nonisolated func withPhotoKitTimeout<T>(_ operation: @escaping () async -> T?) async -> T? {
        await Self.withPhotoKitTimeout(operation)
    }

    /// The same bound, reachable from the `nonisolated static` album
    /// primitives below. Without this bound, one hung `performChanges`
    /// call blocks every later Keep and Unkeep for the session, because
    /// they all queue behind it.
    nonisolated static func withPhotoKitTimeout<T>(_ operation: @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.photoKitContinuationTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll() // This cancels the PhotoKit request through its own cancellation handler.
            return first
        }
    }

    /// Resolves a playable `AVPlayerItem` for the given asset id,
    /// streaming from iCloud if needed. Returns `nil` if the asset is
    /// gone, PhotoKit cannot produce a player item, or the request does
    /// not finish within `withPhotoKitTimeout`'s bound.
    ///
    /// The underlying PhotoKit request is cancellable. If the calling
    /// task is cancelled, the request is cancelled too. This can happen
    /// because the page scrolled away before this method returned. The
    /// request does not continue to download in the background for a
    /// page nobody is watching.
    nonisolated func playerItem(for id: String, onProgress: (@Sendable (Double) -> Void)? = nil) async -> AVPlayerItem? {
        #if DEBUG
        // This delay runs outside `withPhotoKitTimeout`, so the real
        // request keeps its full 20 second budget instead of spending
        // part of it here. `Task.sleep` suspends the task without
        // blocking the main actor. The cancellation check after the
        // sleep stops a page that scrolled away during the delay from
        // issuing a request nobody wants.
        if let delay = Self.slowLoadDelay {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return nil }
        }
        #endif
        return await withPhotoKitTimeout { [weak self] in
            await self?.requestPlayerItem(for: id, onProgress: onProgress)
        }
    }

    #if DEBUG
    /// Seconds to delay `playerItem(for:)` by, from the
    /// `-cloudfull-slow-load <seconds>` launch argument.
    ///
    /// This is a `nonisolated static let`, read once at first use, since
    /// it must be readable from whichever isolation `playerItem(for:)`
    /// runs in. Only the slow-load UI test sets this argument. For all
    /// other runs the value is `nil`.
    nonisolated static let slowLoadDelay: TimeInterval? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: CloudfullApp.slowLoadArgument),
              arguments.index(after: flag) < arguments.endIndex,
              let seconds = TimeInterval(arguments[arguments.index(after: flag)]),
              seconds > 0 else { return nil }
        return seconds
    }()
    #endif

    private nonisolated func requestPlayerItem(for id: String, onProgress: (@Sendable (Double) -> Void)? = nil) async -> AVPlayerItem? {
        guard let asset = Self.fetchAsset(id) else { return nil }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        // The feed's loader is the Photos cloud ring, so it needs the
        // real download fraction. PhotoKit delivers this fraction on an
        // arbitrary thread, and only while it is actually fetching from
        // iCloud. A copy already on the phone reports nothing, and the
        // ring handles that case by sweeping instead of filling.
        if let onProgress {
            options.progressHandler = { fraction, _, _, _ in onProgress(fraction) }
        }
        // `PHImageManager.h` documents `.automatic` and
        // `.mediumQualityFormat` for an `AVPlayerItem` or `AVAsset`
        // request:
        //
        //   Automatic: for a streamed AVPlayerItem or AVAsset, PhotoKit
        //   typically delivers medium quality; for an
        //   AVAssetExportSession, it typically delivers high quality.
        //   Medium: supported only when streaming AVPlayerItem or AVAsset
        //   from iCloud (typically 720p); PhotoKit falls back to high
        //   quality when the asset is already available locally.
        //
        // For this path, which requests an `AVPlayerItem`, the two modes
        // are close to equivalent:
        //
        //   * For an iCloud-only asset, `.automatic` already picks medium
        //     quality, the same result `.mediumQualityFormat` would give.
        //   * For an asset already on the device, both modes deliver the
        //     full original. `.mediumQualityFormat` cannot make PhotoKit
        //     serve a smaller copy of a local file.
        //
        // No delivery mode used here caps resolution. The only PhotoKit
        // option below medium quality is `.fastFormat` (typically 360p),
        // and it carries the same local-file fallback to full quality.
        // Capping the resolution of a local 4K clip needs a separate
        // transcode, which is what shrink already provides.
        //
        // The one real difference applies only to an iCloud-streamed
        // clip: `.mediumQualityFormat` pins the resolution to 720p, while
        // `.automatic` lets PhotoKit choose and may deliver a larger
        // frame on a fast connection.
        //
        // Share and shrink are unaffected either way.
        // `requestExportSession` requests `.highQualityFormat` on its own
        // path and always receives the original.
        options.deliveryMode = .automatic

        let requestBox = RequestIDBox()

        let item = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AVPlayerItem?, Never>) in
                let hasResumed = ResumeGuard()
                let requestID = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
                    guard hasResumed.markResumed() else { return }
                    continuation.resume(returning: playerItem)
                }
                requestBox.id = requestID
            }
        } onCancel: {
            let requestID = requestBox.id
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }

        // `AVPlayer.replaceCurrentItem(with:)` parses the item's asset
        // if nobody has yet, on the main thread's next turn, at the
        // exact moment the person is swiping. Parsing the asset here, on
        // this background executor, moves that cost off the main thread
        // entirely. It is the same work, done in a better place, not
        // extra work.
        //
        // This step is bounded, so a stalled iCloud asset can never make
        // the poster wait on it. The method always returns the item,
        // pre-parsed or not.
        if let item { await Self.warmUp(item) }
        return item
    }

    /// Best effort, bounded at 3 seconds. This method never throws and
    /// never reports failure. An item that is not pre-parsed still plays.
    /// Its asset parse then runs on the main thread.
    private nonisolated static func warmUp(_ item: AVPlayerItem) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await item.asset.load(.isPlayable, .duration) }
            group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            await group.next()
            group.cancelAll()
        }
    }

    /// The bytes the asset's underlying file or files occupy on disk,
    /// plus whether that figure is a real resource size or a rough
    /// estimate.
    ///
    /// The explicit `Sendable` shows that this value crosses executors.
    struct AssetSize: Sendable {
        let bytes: Int64
        let isEstimated: Bool
    }

    /// The bytes the asset's underlying file or files occupy on disk,
    /// for the trash queue's "space you'll get back" counter. This
    /// method prefers the video resource and falls back to any resource
    /// that reports a size.
    ///
    /// `PHAssetResource` has no public size property. The primary path
    /// reads the undocumented `fileSize` key, which can come back empty
    /// for an iCloud original that has not downloaded. Silently
    /// reporting zero would read as "zero KB back" for a non-empty
    /// queue. Instead, this method falls back to a pixel-dimension and
    /// duration estimate. It returns a true zero only when the asset is
    /// gone entirely, or PhotoKit has no dimensions or duration for it
    /// either.
    func fileSize(for id: String) -> AssetSize {
        guard let asset = Self.fetchAsset(id) else { return AssetSize(bytes: 0, isEstimated: false) }
        return Self.assetSize(for: asset)
    }

    /// The resource-size read, split out of `fileSize(for:)` so it can
    /// run off the main actor. A caller that already has the asset can
    /// also pass it directly, instead of triggering a second
    /// `PHAsset.fetchAssets` call.
    nonisolated static func assetSize(for asset: PHAsset) -> AssetSize {
        let resources = PHAssetResource.assetResources(for: asset)
        let videoResources = resources.filter { $0.type == .video || $0.type == .fullSizeVideo }
        let candidates = videoResources.isEmpty ? resources : videoResources
        for resource in candidates {
            if let size = resource.value(forKey: "fileSize") as? Int64, size > 0 {
                return AssetSize(bytes: size, isEstimated: false)
            }
        }

        let width = Double(asset.pixelWidth)
        let height = Double(asset.pixelHeight)
        let duration = asset.duration
        guard width > 0, height > 0, duration > 0 else {
            return AssetSize(bytes: 0, isEstimated: true)
        }
        // Estimates 0.1 bits per pixel per frame, a rough H.264/HEVC
        // rate, at 30 fps.
        //
        // `PHAsset` exposes no synchronous frame-rate property, so this
        // value defaults to 30 fps, a reasonable stand-in for the common
        // case. An async `AVAsset` load would give an exact rate.
        // `TrashService` recomputes this estimate from the real
        // resource the moment it downloads, so the extra call is not
        // worth making here.
        let fps = 30.0
        let estimatedBitsPerSecond = width * height * fps * 0.1
        let estimatedBytes = Int64((estimatedBitsPerSecond * duration) / 8)
        return AssetSize(bytes: max(estimatedBytes, 0), isEstimated: true)
    }

    /// True when the asset's primary video resource is already
    /// downloaded to this device, so exporting it needs no iCloud fetch.
    ///
    /// This reads `PHAssetResource`'s undocumented `locallyAvailable`
    /// key, the same approach `fileSize(for:)` uses for its `fileSize`
    /// key above. When the key cannot be read, this method assumes the
    /// asset is not local. Do not treat an unknown state as local. The
    /// download can use cellular data.
    func isOriginalLocallyAvailable(for id: String) -> Bool {
        guard let asset = asset(for: id) else { return false }
        let resources = PHAssetResource.assetResources(for: asset)
        let videoResources = resources.filter { $0.type == .video || $0.type == .fullSizeVideo }
        let candidates = videoResources.isEmpty ? resources : videoResources
        guard let resource = candidates.first else { return false }
        return (resource.value(forKey: "locallyAvailable") as? Bool) ?? false
    }

    /// Resolves a square thumbnail for the trash grid. `side` is a
    /// point size. PhotoKit fills that target and crops the image, so
    /// callers do not need to crop the result themselves.
    ///
    /// `contentMode` defaults to `.aspectFill`, for the trash grid's own
    /// need. Pass `.aspectFit` for a use like the feed's poster frame,
    /// where a cropped fill would mismatch the player's own aspect-fit
    /// video layer underneath it.
    ///
    /// This method resumes on the first full-quality image. If only a
    /// degraded frame has arrived after 1.5 seconds, it takes that frame
    /// instead. A blurred frame is better than an empty cell for the
    /// rest of `withPhotoKitTimeout`'s 20 second budget. A sharp frame
    /// that arrives before 1.5 seconds is always used.
    ///
    /// The underlying PhotoKit request is cancellable. If the calling
    /// task is cancelled, for example because the grid cell scrolled
    /// offscreen before this method returned, the request is cancelled
    /// too, matching `playerItem(for:)`.
    nonisolated func thumbnail(for id: String, side: CGFloat, contentMode: PHImageContentMode = .aspectFill) async -> UIImage? {
        await withPhotoKitTimeout { [weak self] in
            await self?.requestThumbnail(for: id, side: side, contentMode: contentMode)
        }
    }

    private nonisolated func requestThumbnail(for id: String, side: CGFloat, contentMode: PHImageContentMode) async -> UIImage? {
        guard let asset = Self.fetchAsset(id) else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let targetSize = CGSize(width: side, height: side)
        let requestBox = RequestIDBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                let hasResumed = ResumeGuard()
                let degraded = DegradedLatch()
                let requestID = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if let image, isDegraded {
                        // A sharp follow-up is still coming. Stash this
                        // frame as the 1.5 second fallback below, instead
                        // of resuming on it directly.
                        degraded.store(image)
                        return
                    }
                    guard hasResumed.markResumed() else { return }
                    continuation.resume(returning: image)
                }
                requestBox.id = requestID
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard hasResumed.markResumed() else { return }
                    continuation.resume(returning: degraded.load())
                }
            }
        } onCancel: {
            let requestID = requestBox.id
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
    }

    /// Progressive thumbnail delivery for the feed's poster frame. This
    /// method yields PhotoKit's degraded frame the instant one arrives,
    /// then the full-quality frame if a better one arrives, then
    /// finishes.
    ///
    /// This method does not reuse `thumbnail(for:side:contentMode:)`
    /// above. That method's rule is: prefer a sharp frame, but fall
    /// back to the degraded one after 1.5 seconds. This rule is correct
    /// for the trash grid. There, a blurred cell that becomes sharp
    /// later is worse than a cell that arrives sharp a moment later.
    /// That rule is wrong for a poster, which exists to cover the first
    /// frame of a swipe. The two use cases need two separate methods.
    ///
    /// This method returns an `AsyncStream`, not a completion handler or
    /// an `AsyncPublisher`. `PlayerHolder.statusUpdates(for:)`
    /// (Cloudfull/Feed/PlayerPageView.swift) uses the same approach for
    /// the same reason: an `AsyncStream` buffers, so a frame delivered
    /// between iterations is never dropped.
    ///
    /// Cancelling the consuming task cancels the PhotoKit request,
    /// matching `thumbnail(for:side:contentMode:)` and `playerItem(for:)`.
    /// `contentMode` is always `.aspectFit`, matching `PlayerLayerView`'s
    /// `.resizeAspect` gravity, so the poster never crops relative to
    /// the video it replaces.
    nonisolated func posterImages(for id: String, side: CGFloat) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let requestBox = RequestIDBox()
            // The code installs this handler before the detached task
            // starts. A termination that arrives before the task assigns
            // `requestBox.id` must still cancel the request once the
            // assignment happens. `RequestIDBox.cancel()` handles both
            // orderings.
            continuation.onTermination = { _ in
                requestBox.cancel()
            }
            // Synchronous PhotoKit calls must never run on the main
            // actor. `AsyncStream.init`'s build closure runs
            // synchronously inside the initializer, and `PosterCache`,
            // the only caller, is `@MainActor`. Without
            // `Task.detached`, `Self.fetchAsset(id)` and the
            // `requestImage` setup below would run on the main thread on
            // every prefetch that keeps nearby pages ready.
            // `Task.detached` moves both off the main thread.
            Task.detached(priority: .userInitiated) {
                guard let asset = Self.fetchAsset(id) else {
                    continuation.finish()
                    return
                }

                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true
                options.isSynchronous = false

                let targetSize = CGSize(width: side, height: side)

                requestBox.id = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if let image {
                        continuation.yield(image)
                    }
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if !isDegraded {
                        // Either the sharp frame just landed, or
                        // PhotoKit's final callback carried no image at
                        // all. Either way, no more frames are coming.
                        continuation.finish()
                    }
                }
            }
        }
    }

    /// Deletes the assets among `ids` that PhotoKit can still find, in a
    /// single request. The system shows one confirmation dialog for the
    /// whole batch, so the trash queue empties with exactly one prompt.
    ///
    /// Returns the subset of `ids` PhotoKit actually matched and
    /// deleted, never all of `ids` unconditionally. This lets a caller
    /// tell "these ids are gone" apart from "none of these ids exist
    /// here anymore". A stale or rotated local identifier, for example
    /// after a device restore, must never be treated as deleted just
    /// because nothing matched.
    ///
    /// Returns `nil` only when the person cancels the confirmation, or
    /// PhotoKit reports an error. In that case nothing happened, and
    /// every id should stay exactly as it was.
    func deleteAssets(ids: [String]) async -> Set<String>? {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        guard !ids.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else {
            // None of these ids resolve to a real asset anymore. This
            // is not a completed deletion. The empty result tells the
            // caller to leave the corresponding rows in place as
            // dormant, instead of reporting them freed.
            return []
        }

        var matchedIDs = Set<String>()
        assets.enumerateObjects { asset, _, _ in
            matchedIDs.insert(asset.localIdentifier)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return matchedIDs
        } catch {
            // `PHPhotosError.userCancelled` fires when the person taps
            // Cancel on the system delete confirmation. Any other error
            // also leaves the assets in place, so both cases report
            // failure the same way.
            return nil
        }
    }

    // MARK: - Shrink

    /// The asset's native pixel dimensions, for
    /// `ShrinkService.canShrink`'s "already at or below 1080p" gate.
    ///
    /// Returns `.zero` when the asset is gone, or PhotoKit has no
    /// dimensions for it. Callers must treat `.zero` as "cannot tell",
    /// never as "small enough to skip".
    func pixelSize(for id: String) -> CGSize {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        guard let asset = asset(for: id) else { return .zero }
        let width = asset.pixelWidth
        let height = asset.pixelHeight
        guard width > 0, height > 0 else { return .zero }
        return CGSize(width: width, height: height)
    }

    /// The asset's creation date and location, read straight off the
    /// `PHAsset`, so `ShrinkService` can stamp the same values onto the
    /// shrunk replacement. This keeps the new file's place in the
    /// timeline the same as the original's.
    ///
    /// Either value, or both, may be `nil`. A video with no location, or
    /// an asset that has vanished, is not an error here. The caller
    /// passes whatever comes back straight to `saveVideo`.
    func assetMeta(for id: String) -> (creationDate: Date?, location: CLLocation?) {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        guard let asset = asset(for: id) else { return (nil, nil) }
        return (asset.creationDate, asset.location)
    }

    /// Resolves an `AVAssetExportSession` pre-configured for `preset`
    /// against the given asset, downloading the iCloud original if
    /// needed. This mirrors `playerItem(for:)`: network access is
    /// allowed, and the same cancel-on-task-cancellation wiring applies.
    ///
    /// The `.highQualityFormat` delivery mode matches the export use
    /// case. This is not a scrub preview. Returns `nil` if the asset is
    /// gone, or PhotoKit cannot produce a session for this preset. This
    /// can happen when the preset does not fit the asset.
    /// `ShrinkService` treats `nil` as a failed job, with the original
    /// left untouched.
    func requestExportSession(for id: String, preset: String) async -> AVAssetExportSession? {
        guard let asset = asset(for: id) else { return nil }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        let requestBox = RequestIDBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AVAssetExportSession?, Never>) in
                let hasResumed = ResumeGuard()
                let requestID = PHImageManager.default().requestExportSession(
                    forVideo: asset,
                    options: options,
                    exportPreset: preset
                ) { exportSession, _ in
                    guard hasResumed.markResumed() else { return }
                    continuation.resume(returning: exportSession)
                }
                requestBox.id = requestID
            }
        } onCancel: {
            let requestID = requestBox.id
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
    }

    /// Saves an exported video file as a brand-new asset. It is stamped
    /// with `creationDate` and `location` so it sits at the original's
    /// spot in the camera roll timeline. Returns the new asset's local
    /// identifier.
    ///
    /// `shouldMoveFile` stays `false`, so this copies the file rather
    /// than moving it. `ShrinkService` reads the exported file's size
    /// and deletes the file itself once this call resolves, on both the
    /// success and the failure path. The temp file must exist at that
    /// point on both paths. A moved file exists only on the failure
    /// path.
    ///
    /// Returns `nil` on any failure, including the person declining a
    /// permissions prompt PhotoKit might raise. On `nil`, nothing was
    /// created. `ShrinkService` must only treat the original as safe to
    /// trash when this method returns a non-nil value.
    ///
    /// The placeholder id from `performChanges` is not proof of a
    /// commit. It is non-nil even when the commit fails. PhotoKit sets
    /// it on its change-block queue, so `IdentifierBox` guards it with a
    /// lock.
    ///
    /// Nothing downstream may treat the original as safe to trash until
    /// PhotoKit hands the asset back on a fresh fetch. This method
    /// confirms by re-fetching the candidate id before returning it,
    /// with one 300 millisecond retry. The commit can become visible
    /// asynchronously, a moment after `performChanges` returns.
    func saveVideo(fileURL: URL, creationDate: Date?, location: CLLocation?) async -> String? {
        let box = IdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                let resourceOptions = PHAssetResourceCreationOptions()
                resourceOptions.shouldMoveFile = false
                creationRequest.addResource(with: .video, fileURL: fileURL, options: resourceOptions)
                creationRequest.creationDate = creationDate
                creationRequest.location = location
                box.id = creationRequest.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            return nil
        }

        guard let candidate = box.id else { return nil }
        if asset(for: candidate) != nil { return candidate }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard asset(for: candidate) != nil else { return nil }
        return candidate
    }

    private func registerChangeObserverIfNeeded() {
        guard !isObservingChanges else { return }
        isObservingChanges = true
        PHPhotoLibrary.shared().register(self)
    }

    // MARK: - Albums

    /// One row in the album picker. `keyAssetID` is the collection's
    /// newest asset, used only for the row thumbnail. It is `nil` for an
    /// empty album.
    struct AlbumSummary: Identifiable, Equatable {
        let id: String            // The PHAssetCollection's local identifier.
        let title: String
        let count: Int
        let keyAssetID: String?
        /// The creation date of the album's newest asset, or `nil` for
        /// an empty album. Used to sort the album list by how recently
        /// it changed.
        ///
        /// This is the closest date PhotoKit can offer.
        /// `PHAssetCollection` carries `startDate` and `endDate` and no
        /// other date property. Those dates describe the date range of
        /// the album's contents. They do not describe when anything
        /// filed an item into the album. No level of the PhotoKit model
        /// carries an album modification date. `PHObject` has none
        /// either.
        ///
        /// iOS 26 adds `PHAsset.addedDate`, the date the asset entered
        /// the library. This date is still not album-specific, but it
        /// is a better recency signal than `creationDate` alone. A
        /// photo taken years ago and imported recently should not sort
        /// as old. This property takes whichever of the two dates is
        /// later.
        ///
        /// `AlbumListCache` applies its own record of albums the app
        /// added to. That record is exact for those albums.
        let newestAssetDate: Date?
    }

    /// The person's own regular albums, alphabetically by title, with
    /// their asset counts. This excludes smart albums, shared albums,
    /// and moments, matching what Photos' own "Add to Album" picker
    /// offers: only albums the person can write to.
    ///
    /// This makes one `PHAsset` fetch per album, not two.
    /// `PHFetchResult.count` is a cheap property backed by the result
    /// set's own metadata. The same fetch that finds the newest asset,
    /// for the thumbnail, also supplies the row's count without a
    /// second call.
    ///
    /// This method is `nonisolated static`, the same treatment as
    /// `cloudIdentifierMappings(forLocalIdentifiers:)` below. One
    /// `PHAsset.fetchAssets(in:options:)` call per album means the cost
    /// of this method grows with the album count. `AlbumListCache` runs
    /// it from a detached task, so a large album list never blocks the
    /// main thread while the sheet is up.
    nonisolated static func userAlbums() -> [AlbumSummary] {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var summaries: [AlbumSummary] = []
        summaries.reserveCapacity(collections.count)
        let assetOptions = PHFetchOptions()
        assetOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: assetOptions)
            // This fetch is already sorted by creationDate descending
            // for the thumbnail, so the newest asset is the same
            // `firstObject`, with no extra fetch needed.
            let newest = assets.firstObject
            let newestDate: Date? = {
                guard let newest else { return nil }
                let added = newest.addedDate
                guard let created = newest.creationDate else { return added }
                return max(created, added)
            }()
            summaries.append(AlbumSummary(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "",
                count: assets.count,
                keyAssetID: newest?.localIdentifier,
                newestAssetDate: newestDate
            ))
        }
        return summaries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: - Album primitives
    //
    // All album reads and writes are here, as `nonisolated static`
    // methods, so a tap never waits on the main actor. The `@MainActor`
    // methods below call these: one implementation, with two callers,
    // the album picker and `KeepsAlbum`.

    /// The id of the user album with this exact name, if one exists.
    nonisolated static func albumID(named title: String) async -> String? {
        await Task.detached(priority: .utility) {
            #if DEBUG
            FetchCounters.bumpPhotoKit()
            #endif
            let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            var match: String?
            albums.enumerateObjects { collection, _, stop in
                if collection.localizedTitle == title {
                    match = collection.localIdentifier
                    stop.pointee = true
                }
            }
            return match
        }.value
    }

    /// False once the person deletes the album in Photos.
    nonisolated static func albumExists(_ albumID: String) async -> Bool {
        await Task.detached(priority: .utility) {
            #if DEBUG
            FetchCounters.bumpPhotoKit()
            #endif
            return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject != nil
        }.value
    }

    /// Creates an album, optionally with one asset already in it.
    /// Returns `nil` when `assetID` does not resolve, PhotoKit refuses
    /// the change, or the call times out. Limited access cannot create
    /// albums.
    nonisolated static func makeAlbum(named title: String, addingAssetID assetID: String? = nil) async -> String? {
        await withPhotoKitTimeout {
        await Task.detached(priority: .utility) {
            #if DEBUG
            FetchCounters.bumpPhotoKit()
            #endif
            let asset = assetID.flatMap {
                PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject
            }
            if assetID != nil && asset == nil { return nil }
            var placeholder: PHObjectPlaceholder?
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                    if let asset { request.addAssets([asset] as NSArray) }
                    placeholder = request.placeholderForCreatedAssetCollection
                }
            } catch {
                return nil
            }
            return placeholder?.localIdentifier
        }.value
        }
    }

    /// Adds an asset to an album.
    nonisolated static func attach(_ assetID: String, toAlbum albumID: String) async -> AlbumChange {
        await changeAlbum(albumID, assetID: assetID) { request, asset in
            request.addAssets([asset] as NSArray)
        }
    }

    nonisolated static func detach(_ assetID: String, fromAlbum albumID: String) async -> AlbumChange {
        await changeAlbum(albumID, assetID: assetID) { request, asset in
            request.removeAssets([asset] as NSArray)
        }
    }

    nonisolated static func album(_ albumID: String, contains assetID: String) async -> Bool {
        await Task.detached(priority: .utility) {
            #if DEBUG
            FetchCounters.bumpPhotoKit()
            #endif
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return false }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "localIdentifier == %@", assetID)
            return PHAsset.fetchAssets(in: collection, options: options).count > 0
        }.value
    }

    /// This method tracks `requestSucceeded` explicitly, rather than
    /// inferring success from `performChanges` not throwing.
    /// `PHAssetCollectionChangeRequest(for:)` can itself return `nil`
    /// inside the block, if the collection vanished between the fetch
    /// and the change actually running. In that case the block does
    /// nothing, and `performChanges` still resolves without an error.
    /// This silent no-op must not read as success.
    private nonisolated static func changeAlbum(
        _ albumID: String, assetID: String,
        _ mutate: @escaping @Sendable (PHAssetCollectionChangeRequest, PHAsset) -> Void
    ) async -> AlbumChange {
        // This call is bounded. A `performChanges` call that never
        // calls back would otherwise block every later Keep behind it.
        return await withPhotoKitTimeout { () async -> AlbumChange? in
        await Task.detached(priority: .utility) { () async -> AlbumChange in
            #if DEBUG
            FetchCounters.bumpPhotoKit(); FetchCounters.bumpPhotoKit()   // This counts the two fetches below.
            #endif
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
            else { return .albumMissing }   // Only this outcome may clear the cached album id.
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
            else { return .failed }
            var requestSucceeded = false
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                    mutate(request, asset)
                    requestSucceeded = true
                }
            } catch {
                return .failed
            }
            return requestSucceeded ? .done : .albumMissing   // The change request itself refused the collection.
        }.value
        } ?? .failed   // The timeout fired.
    }

    /// Why an album write ended. `albumMissing` is the only outcome
    /// that may clear a cached album id. Any other outcome, such as
    /// Limited access, a deleted asset, or a timeout, must leave the
    /// cached id alone. Otherwise a later write creates a second album
    /// with the same name.
    enum AlbumChange: Sendable { case done, albumMissing, failed }


    /// Creates an album and adds `assetID` to it in one `performChanges`
    /// block, so a failure can never leave a named but empty album
    /// behind. Returns the new collection's local identifier, or `nil`
    /// if anything failed, including `assetID` no longer resolving.
    func createAlbum(named title: String, addingAssetID assetID: String) async -> String? {
        await Self.makeAlbum(named: title, addingAssetID: assetID)
    }

    /// Adds `assetID` to an existing album. Returns `false` when the
    /// album or the asset no longer resolves, or PhotoKit refuses the
    /// change.
    ///
    /// Calls `attach(_:toAlbum:)` and returns `true` only for `.done`.
    func addAsset(_ assetID: String, toAlbumWithIdentifier albumID: String) async -> Bool {
        await Self.attach(assetID, toAlbum: albumID) == .done
    }

    /// The live count of assets in an album, re-fetched from PhotoKit.
    /// This exists so the DEBUG `album_verify_` probe reports a real
    /// reading from the database, not an echo of the write request.
    func assetCount(inAlbumWithIdentifier albumID: String) -> Int {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else {
            return 0
        }
        return PHAsset.fetchAssets(in: collection, options: nil).count
    }

    #if DEBUG
    private static let purgeLog = Logger(subsystem: "com.cloudfull.app", category: "AlbumPurge")

    /// Deletes every regular album whose title begins with `prefix`.
    /// Deleting a collection never deletes the assets inside it. This
    /// method supports UI tests only.
    ///
    /// `deleteAssetCollections` makes PhotoKit present a system
    /// confirmation dialog, asking to allow the app to delete the
    /// matching albums. `performChanges` suspends until that alert is
    /// answered. A caller with nobody to tap the dialog, such as a bare
    /// `xcrun simctl launch`, hangs here indefinitely instead of
    /// failing.
    ///
    /// `gate_all.sh`'s purge step taps "Delete" through `idb ui tap`.
    /// The method logs `album_purge_done_<N>` or `album_purge_failed_…`,
    /// so a test can see if the purge ran.
    func deleteAlbums(titledWithPrefix prefix: String) async {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var toDelete: [PHAssetCollection] = []
        collections.enumerateObjects { collection, _, _ in
            if let title = collection.localizedTitle, title.hasPrefix(prefix) {
                toDelete.append(collection)
            }
        }
        guard !toDelete.isEmpty else {
            Self.purgeLog.log("album_purge_done_0")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest.deleteAssetCollections(toDelete as NSArray)
            }
            Self.purgeLog.log("album_purge_done_\(toDelete.count, privacy: .public)")
        } catch {
            Self.purgeLog.error("album_purge_failed_\(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    // MARK: - Cloud identity, batch

    /// Batch `PHCloudIdentifier` resolution for the launch-time
    /// backfill.
    ///
    /// This method is `nonisolated static` on purpose.
    /// `PhotoLibraryService` is `@MainActor`, and this call is slow and
    /// must run on `CloudKeyBackfiller`'s executor. Returns only the
    /// local identifiers that mapped. An absent key means "no cloud key
    /// available", never an error.
    nonisolated static func cloudIdentifierMappings(forLocalIdentifiers ids: [String]) -> [String: String] {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        guard !ids.isEmpty else { return [:] }
        let mapping = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: ids)
        var result: [String: String] = [:]
        result.reserveCapacity(mapping.count)
        for (localID, outcome) in mapping {
            if case .success(let cloudID) = outcome {
                result[localID] = cloudID.stringValue
            }
        }
        return result
    }

    /// The batched, reverse-direction sibling of
    /// `cloudIdentifierMappings(forLocalIdentifiers:)` just above. This
    /// method makes one PhotoKit call for every cloud identifier,
    /// instead of the one-call-per-row pattern a
    /// `localIdentifier(forCloudIdentifier:)` method would need.
    ///
    /// This method is `nonisolated static` for the same reason: callers
    /// run it off the main actor. Returns only the cloud identifiers
    /// that mapped to a current local identifier. An absent key means
    /// "does not resolve on this device right now", never an error.
    /// This lets `DeckViewModel`'s and `TrashService`'s per-row fallback
    /// lookups batch, instead of each one calling PhotoKit on the main
    /// actor.
    nonisolated static func localIdentifierMappings(forCloudIdentifiers ids: [String]) -> [String: String] {
        #if DEBUG
        FetchCounters.bumpPhotoKit()
        #endif
        guard !ids.isEmpty else { return [:] }
        let cloudIDs = ids.map { PHCloudIdentifier(stringValue: $0) }
        let mapping = PHPhotoLibrary.shared().localIdentifierMappings(for: cloudIDs)
        var result: [String: String] = [:]
        result.reserveCapacity(mapping.count)
        for (cloudID, outcome) in mapping {
            if case .success(let localID) = outcome {
                result[cloudID.stringValue] = localID
            }
        }
        return result
    }

}

extension PhotoLibraryService: PHPhotoLibraryChangeObserver {
    // This handler does not invalidate the album cache. On a large
    // library, PhotoKit change notices fire continuously. Any
    // invalidation tied to them would never let the cached list survive
    // long enough to be useful. The cache instead refreshes only when
    // the app returns from the background; see `AlbumListCache`.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // This snapshots the handlers into an array first. A
            // handler can unregister itself during dispatch, for
            // example a `DeckViewModel` or `TrashService` racing its own
            // `deinit` against a burst of change notifications. Such a
            // handler must not mutate `libraryChangeHandlers`
            // mid-iteration.
            for handler in Array(self.libraryChangeHandlers.values) { handler() }
        }
    }
}

/// A handle for a registered library-change handler. See
/// `PhotoLibraryService.addLibraryChangeObserver`'s documentation for
/// why registration is not append-only.
final class LibraryObserverToken: Hashable {
    private let id = UUID()
    static func == (lhs: LibraryObserverToken, rhs: LibraryObserverToken) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A thread-safe latch that ensures a completion handler PhotoKit may
/// invoke more than once resumes its continuation only once.
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

/// A thread-safe box for the `PHImageRequestID` a PhotoKit request
/// hands back synchronously. A task cancellation handler can race with
/// the request actually being issued. This box reads and writes the
/// id under a lock, rather than as a plain captured `var`.
private final class RequestIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: PHImageRequestID = PHInvalidImageRequestID
    // `posterImages(for:side:)` assigns `id` from a detached task, so a
    // caller that cancels the consuming task before that assignment
    // happens must not lose its cancel. The `id` setter checks this flag
    // and cancels immediately when it is already set.
    private var _cancelled = false

    var id: PHImageRequestID {
        get { lock.lock(); defer { lock.unlock() }; return _id }
        set {
            lock.lock()
            _id = newValue
            let shouldCancelNow = _cancelled
            lock.unlock()
            if shouldCancelNow, newValue != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(newValue)
            }
        }
    }

    /// Marks the box cancelled, and cancels whatever request id it
    /// already holds, if any. Safe to call before `id` is ever assigned.
    func cancel() {
        lock.lock()
        _cancelled = true
        let requestID = _id
        lock.unlock()
        if requestID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(requestID)
        }
    }
}

/// A thread-safe box for the candidate asset id `saveVideo` reads out
/// of a `PHPhotoLibrary.performChanges` block. This mirrors
/// `RequestIDBox`: the block runs on PhotoKit's own private
/// change-block queue. This box reads and writes the id under a
/// lock, rather than as a plain captured `var`.
private final class IdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: String?

    var id: String? {
        get { lock.lock(); defer { lock.unlock() }; return _id }
        set { lock.lock(); defer { lock.unlock() }; _id = newValue }
    }
}

/// A thread-safe holder for the newest degraded, low-quality thumbnail
/// frame `requestThumbnail` has seen. The 1.5 second fallback task
/// reads whatever arrived here, without racing the PhotoKit completion
/// handler that writes it.
private final class DegradedLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var image: UIImage?

    func store(_ image: UIImage) {
        lock.lock(); defer { lock.unlock() }
        self.image = image
    }

    func load() -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return image
    }
}
