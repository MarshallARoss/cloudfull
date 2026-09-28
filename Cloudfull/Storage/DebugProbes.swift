//
//  DebugProbes.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftUI
import SwiftData
import Photos
import os

// Every type in this file is DEBUG-only.
#if DEBUG
/// What the feed is playing right now, for the on-screen readout. The feed
/// requests `.mediumQualityFormat` and expects Photos to return the smaller
/// copy on the device. This type shows whether it does, by putting the
/// size being played next to the asset's own size.
@MainActor
final class PlaybackReadout: ObservableObject {
    static let shared = PlaybackReadout()
    /// The player item's `presentationSize` — the picture on screen.
    @Published private(set) var played: CGSize = .zero
    /// `PHAsset.pixelWidth/Height` — what the original actually is.
    @Published private(set) var asset: CGSize = .zero

    private init() {}

    func notePlayed(_ size: CGSize) { if played != size { played = size } }
    func noteAsset(width: Int, height: Int) {
        let size = CGSize(width: width, height: height)
        if asset != size { asset = size }
    }

    /// Example: `played 1920x1080 · asset 3840x2160 · SMALLER`. The last
    /// word is `SMALLER`, `bigger`, or `FULL SIZE` and compares the pixel
    /// counts.
    var line: String {
        guard played != .zero else { return "played —" }
        var text = "played \(Int(played.width))x\(Int(played.height))"
        guard asset != .zero else { return text }
        text += " · asset \(Int(asset.width))x\(Int(asset.height))"
        let playedPixels = played.width * played.height, assetPixels = asset.width * asset.height
        text += playedPixels < assetPixels ? " · SMALLER" : playedPixels > assetPixels ? " · bigger" : " · FULL SIZE"
        return text
    }
}

/// The one switch behind every on-device diagnostic readout: the stall
/// counter, the per-post load badges, and the place badge.
///
/// A launch argument alone does not persist. It only lasts for the run
/// that Xcode or `devicectl` started, so reopening the app from the home
/// screen would drop every readout.
///
/// The state lives in `UserDefaults` under `debug.diagnostics`. A Settings
/// row (`settings_diagnostics`) sets the value. A launch argument writes
/// `true` into the key. The readouts then stay on at each later cold
/// start until the Settings row turns them off.
///
/// `-cloudfull-reset-stalls` is a separate flag. It only resets the
/// watchdog's measuring window. It does not affect which readouts show.
@MainActor
final class DiagnosticsSwitch: ObservableObject {
    static let shared = DiagnosticsSwitch()
    static let storageKey = "debug.diagnostics"

    /// The launch arguments that turn diagnostics on and keep them on at later launches.
    static let launchArguments = ["-cloudfull-show-stalls", "-cloudfull-show-loads", "-cloudfull-diagnostics"]
    /// Writes `false` into `debug.diagnostics`, so diagnostics stay off at
    /// later launches. Use it to start a build with diagnostics off
    /// without a change in Settings.
    static let offLaunchArgument = "-cloudfull-diagnostics-off"

    @Published var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: Self.storageKey)
            Self.isOnMirror = isOn
        }
    }

    /// A lock-free copy of `isOn` that any thread can read without
    /// `await`. `DiagnosticsGate.isOn(_:)` and the `nonisolated` logging
    /// call sites in `PhotoImagePipeline` read this mirror instead of the
    /// main-actor `isOn` property above.
    ///
    /// A torn read of a `Bool` is not possible on any platform this app
    /// ships to. `FetchCounters` relies on the same fact for its own
    /// lock-free reads.
    nonisolated(unsafe) static var isOnMirror = false

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        // The off argument wins over the on arguments. Passing both is
        // never ambiguous.
        if arguments.contains(Self.offLaunchArgument) {
            UserDefaults.standard.set(false, forKey: Self.storageKey)
        } else if Self.launchArguments.contains(where: arguments.contains) {
            UserDefaults.standard.set(true, forKey: Self.storageKey)
        }
        // This assignment happens in `init`, so it does not trigger
        // `didSet`. The read loads the stored value; it does not write a
        // new one.
        isOn = UserDefaults.standard.bool(forKey: Self.storageKey)
        Self.isOnMirror = isOn
    }
}

/// Returns true when the launch arguments contain `argument`, or when
/// `DiagnosticsSwitch` is on. Use it for the log flags
/// (`-cloudfull-log-place`, `-cloudfull-log-thumbs`, `-cloudfull-log-meta`),
/// not the on-screen readouts.
///
/// To copy the unified system log from a device, you need root access.
/// Each DEBUG diagnostic call site uses this check to decide whether to
/// also write to `DiagnosticsLog`, which needs no such access.
enum DiagnosticsGate {
    static func isOn(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument) || DiagnosticsSwitch.isOnMirror
    }
}

/// The app's own diagnostics file, at `Documents/diagnostics.log`. Copy
/// it from a device over USB with `xcrun devicectl device copy from …
/// --domain-type appDataContainer … --source Documents/diagnostics.log`.
/// The unified system log needs root access to copy; this file needs
/// none, because the app writes it.
///
/// Each call writes one line, in the form `HH:mm:ss.SSS <tag> <message>`.
/// Every write runs on `queue`, a private serial background queue, so
/// `log(_:_:)` never blocks its caller and the file IO never touches the
/// main thread.
///
/// After each write, if the file is larger than about 2 MB, the log
/// moves it to `diagnostics.log.1` and starts a new `diagnostics.log`.
/// When `-cloudfull-reset-stalls` is present, the first use of the log
/// truncates the file.
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    private static let capBytes: UInt64 = 2 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.cloudfull.app.diagnosticsLog", qos: .utility)
    private let formatter: DateFormatter
    private let fileURL: URL
    private let rotatedURL: URL
    private var handle: FileHandle?

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        // The locale is fixed to POSIX so this debug timestamp format
        // never changes with the user's region. A human reads this next
        // to a `simctl`/`devicectl` timestamp; nothing parses it back.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.formatter = formatter

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("diagnostics.log")
        rotatedURL = documents.appendingPathComponent("diagnostics.log.1")

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let opened = try? FileHandle(forWritingTo: fileURL)
        if ProcessInfo.processInfo.arguments.contains(CloudfullApp.resetStallsArgument) {
            try? opened?.truncate(atOffset: 0)
        }
        opened?.seekToEndOfFile()
        handle = opened
    }

    /// Appends one line to the log. Safe to call from any thread or actor,
    /// including the main thread. This method only captures `now` and
    /// enqueues the work; the format and the write both happen on `queue`.
    func log(_ tag: String, _ message: String) {
        let now = Date()
        queue.async { [weak self] in
            self?.write(now: now, tag: tag, message: message)
        }
    }

    /// Runs only on `queue`. `DateFormatter` is not safe to call from more
    /// than one thread at once, so formatting happens here, not in
    /// `log(_:_:)` on the caller's own thread.
    private func write(now: Date, tag: String, message: String) {
        guard let handle else { return }
        let line = "\(formatter.string(from: now)) \(tag) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        handle.write(data)
        rotateIfNeeded()
    }

    /// Runs only on `queue`. Called after every write.
    private func rotateIfNeeded() {
        guard let handle, handle.offsetInFile > Self.capBytes else { return }
        try? handle.close()
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.handle = try? FileHandle(forWritingTo: fileURL)
    }
}

/// Counts every PhotoKit fetch (`PHAsset`, `PHAssetCollection`) and every
/// SwiftData `fetch`/`fetchCount` call. This makes "zero PhotoKit work and
/// zero SwiftData work on the render path" a fact a test can check.
///
/// `PhotoLibraryService` and `PhotoLibraryIndex` call `bumpPhotoKit()`
/// before each PhotoKit fetch. `DeckViewModel`, `TrashService`,
/// `AssetKeyResolver`, and `CloudKeyBackfiller` increment `swiftData` at
/// each `fetch`/`fetchCount` call.
///
/// `GateProbes` renders these counts as the `libfetch_` accessibility
/// identifier. This type only holds the counts.
enum FetchCounters {
    nonisolated(unsafe) static var photoKit = 0
    nonisolated(unsafe) static var swiftData = 0

    /// PhotoKit fetches run on background executors, so more than one
    /// thread writes this counter. `CounterProbe` reads the plain
    /// `photoKit` property without a lock: a torn read of an `Int` is not
    /// possible on any platform this ships to. A read that is one
    /// increment late does not change a test result.
    private static let photoKitLock = NSLock()

    static func bumpPhotoKit(_ n: Int = 1) {
        photoKitLock.lock(); photoKit += n; photoKitLock.unlock()
    }
}
/// Counts the work the deck's persistence helpers do, so "a tap writes
/// O(1), independent of library size" is a fact a test can check.
///
/// Only the persistence helpers in `DeckViewModel` increment these
/// counts, by the exact number of elements each write touches. The
/// counts report work done, not calls made.
///
/// `GateProbes` renders these counts as the `deckwrites_` accessibility
/// identifier. This type only holds the counts.
enum DeckWriteCounters {
    /// ID strings written into a SwiftData attribute.
    nonisolated(unsafe) static var idStrings = 0
    /// `Int`/`Int64`/`Bool` values written into a SwiftData attribute.
    nonisolated(unsafe) static var ints = 0
    /// `modelContext.save()` calls made from the deck's persistence helpers.
    nonisolated(unsafe) static var saves = 0
}

/// Measures the time from launch to the first playing frame.
/// `processStart` is the system uptime when `CloudfullApp.init()` runs.
/// `firstPlayingFrame` is the moment a page's player item reaches
/// `.readyToPlay` and starts playing, not merely the moment the view
/// appears.
///
/// The first call to each `mark` method sets the value. Later calls do
/// nothing.
///
/// `GateProbes` renders the elapsed time as the `launch_ms_` accessibility
/// identifier. This type only holds the state.
@MainActor
final class LaunchProbe: ObservableObject {
    static let shared = LaunchProbe()

    @Published private(set) var processStart: TimeInterval?
    @Published private(set) var firstPlayingFrame: TimeInterval?

    private init() {}

    /// Called once, from `CloudfullApp.init()`. Every later call is ignored.
    func markProcessStart() {
        guard processStart == nil else { return }
        processStart = ProcessInfo.processInfo.systemUptime
    }

    /// Called from `PlayerPageView.load()`, at the same point it calls
    /// `viewModel.markSeen(assetID)`. This happens only when `ready ==
    /// true`, only after the item reaches `.readyToPlay`, and only for a
    /// page the holder plays. Every later call is ignored.
    func markFirstPlayingFrame() {
        guard firstPlayingFrame == nil else { return }
        firstPlayingFrame = ProcessInfo.processInfo.systemUptime
    }

    /// The gap between `processStart` and `firstPlayingFrame`, in
    /// milliseconds, or `nil` before the first frame plays.
    var elapsedMilliseconds: Int? {
        guard let processStart, let firstPlayingFrame else { return nil }
        return Int((firstPlayingFrame - processStart) * 1000)
    }
}

/// Publishes the outcome of `KeyRotationHarness.rotate(container:)`, so a
/// UI test can assert that a rotation happened rather than trust a silent
/// no-op.
///
/// `GateProbes` renders this state as the `rotation_probe_` accessibility
/// identifier. `KeyRotationHarness` (in the Storage folder) writes its
/// result here, so it does not depend on `FeedView`.
@MainActor
final class RotationProbe: ObservableObject {
    static let shared = RotationProbe()

    /// The live local identifier of the asset a rotated `LikedEntry`
    /// names. This resolves through the entry's `cloudKey` before the
    /// harness rewrites its stored `assetKey`. `nil` means the harness
    /// found no eligible row, or the row's cloud key did not resolve. Both
    /// cases are a failed rotation, and both must read as `nil`, never as
    /// a silent success.
    @Published private(set) var likedLiveID: String?
    /// The same value, for a rotated `TrashEntry`.
    @Published private(set) var trashLiveID: String?

    private init() {}

    func record(likedLiveID: String?, trashLiveID: String?) {
        self.likedLiveID = likedLiveID
        self.trashLiveID = trashLiveID
    }
}

/// Store-derived probe values. Reads
/// `CloudfullModelContainer.shared.mainContext` directly, so it works in
/// every authorization state, including `.limited` and `.denied`, where
/// `AuthorizedSession`, and therefore `TrashService`, does not exist.
/// Refreshes on a 1 Hz timer. Only `reclaimedBytes` checks for a change
/// before it publishes. Computes `pendingBytes` and `dormantCount` with
/// the same expressions `TrashService` uses, so the probe and the UI
/// never disagree.
///
/// `dormantCount` counts the fetched `TrashEntry` rows that have a
/// `dormantSince` value. It reads only SwiftData, not `AssetKeyResolver`.
/// This keeps it correct under `.limited`, where no resolver and no
/// `TrashService` exist. It is also why this type never adds to
/// `FetchCounters.photoKit`.
@MainActor
final class RowCountProbe: ObservableObject {
    static let shared = RowCountProbe()

    @Published private(set) var seen = 0
    @Published private(set) var liked = 0
    @Published private(set) var trash = 0
    @Published private(set) var seenNil = 0
    @Published private(set) var likedNil = 0
    @Published private(set) var trashNil = 0
    @Published private(set) var pendingBytes: Int64 = 0
    @Published private(set) var dormantCount = 0
    @Published private(set) var newestEntry: (key: String, bytes: Int64, replacement: Int64)?

    /// Bytes a completed `TrashService.emptyBin()` freed this session.
    /// This is session state with no row of its own, so `refresh()` has
    /// nothing to fetch it from. `emptyBin()` writes this static in DEBUG
    /// builds. `refresh()` copies it into `reclaimedBytes`. `CounterProbe`
    /// uses the same method. The copy is what makes SwiftUI re-render: a
    /// bare static mutation is invisible to SwiftUI, so `space_probe_`
    /// would keep showing its last value without it.
    nonisolated(unsafe) static var lastReclaimed: Int64 = 0

    /// `lastReclaimed` as of the last `refresh()`. Publishing this value
    /// makes `GateProbes` re-render `space_probe_` when `emptyBin()`
    /// completes.
    @Published private(set) var reclaimedBytes: Int64 = 0

    private let context: ModelContext
    private var timer: Timer?

    private init() {
        // `mainContext` is the container's one framework-managed main-actor
        // context. It is the same context SwiftUI's `.modelContainer()`
        // environment gives to `TrashService` when that type exists. The
        // probe and the UI read the same context.
        //
        // Note: a Photos access change makes `tccd` stop the app. The
        // relaunch can replay `-cloudfull-reset-deck-state`, which deletes
        // `default.store`. A test that causes this relaunch must expect an
        // empty store.
        context = CloudfullModelContainer.shared.mainContext
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        refresh()
    }

    func refresh() {
        // `fetchCount` materializes no rows. `SeenEntry` holds one row for
        // each video the user watched. This refresh runs once a second on
        // the main thread, so materializing every row here would scale
        // with library size.
        seen      = (try? context.fetchCount(FetchDescriptor<SeenEntry>())) ?? 0
        liked     = (try? context.fetchCount(FetchDescriptor<LikedEntry>())) ?? 0
        seenNil   = (try? context.fetchCount(FetchDescriptor<SeenEntry>(predicate: #Predicate { $0.cloudKey == nil }))) ?? 0
        likedNil  = (try? context.fetchCount(FetchDescriptor<LikedEntry>(predicate: #Predicate { $0.cloudKey == nil }))) ?? 0

        // `TrashEntry` is the bin, bounded by what the user queues.
        // Three of the published values below need real rows:
        // `pendingBytes` sums two fields, `dormantCount` counts a marker,
        // and `newestEntry` reports one row. This fetches that one small
        // table once.
        let trashDescriptor = FetchDescriptor<TrashEntry>(sortBy: [SortDescriptor(\.queuedAt, order: .reverse)])
        let trashAll = (try? context.fetch(trashDescriptor)) ?? []
        trash        = trashAll.count
        trashNil     = trashAll.filter { $0.cloudKey == nil }.count
        pendingBytes = trashAll.reduce(Int64(0)) { $0 + max($1.bytes - $1.replacementBytes, 0) }
        dormantCount = trashAll.filter { $0.dormantSince != nil }.count
        newestEntry  = trashAll.first.map { ($0.assetKey, $0.bytes, $0.replacementBytes) }

        if reclaimedBytes != Self.lastReclaimed { reclaimedBytes = Self.lastReclaimed }
    }
}

/// Polls `FetchCounters` and `DeckWriteCounters` at 2 Hz and republishes
/// only on a changed value, so the probe itself does not cause extra view
/// updates. It performs no fetches of its own.
@MainActor
final class CounterProbe: ObservableObject {
    static let shared = CounterProbe()

    @Published private(set) var photoKit = 0
    @Published private(set) var swiftData = 0
    @Published private(set) var deckIDs = 0
    @Published private(set) var deckInts = 0
    @Published private(set) var deckSaves = 0

    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func refresh() {
        if photoKit != FetchCounters.photoKit { photoKit = FetchCounters.photoKit }
        if swiftData != FetchCounters.swiftData { swiftData = FetchCounters.swiftData }
        if deckIDs != DeckWriteCounters.idStrings { deckIDs = DeckWriteCounters.idStrings }
        if deckInts != DeckWriteCounters.ints { deckInts = DeckWriteCounters.ints }
        if deckSaves != DeckWriteCounters.saves { deckSaves = DeckWriteCounters.saves }
    }
}

/// Mounts every DEBUG probe that must be readable independent of
/// `AuthorizedSession`. `space_probe_`, `trash_rows_`, `trash_entry_`,
/// `rowcount_`, and `rowcountnil_` read the store directly through
/// `RowCountProbe`, never through `TrashService`, because
/// `M5Tests.testLimitedAccessKeepsQueueIntact` reads them while `FeedView`
/// is not mounted at all. `PermissionGateView.body` mounts this view next
/// to the `Group` in every authorization state. It takes no parameters
/// and reads no session, so it works when no session exists.
struct GateProbes: View {
    @ObservedObject private var rotation = RotationProbe.shared
    @ObservedObject private var launch = LaunchProbe.shared
    @ObservedObject private var counters = CounterProbe.shared
    @ObservedObject private var rows = RowCountProbe.shared
    @ObservedObject private var resolver = AssetKeyResolver.shared

    var body: some View {
        ZStack {
            probe("rotation_probe_\(rotation.likedLiveID ?? "none")_\(rotation.trashLiveID ?? "none")")
            // The deck removes a rotated shielded or queued video when
            // resolution completes (`removeResolvedExclusionsFromFuture`). A
            // pager scroll to find it is not reliable. This probe reads
            // `AssetKeyResolver` directly for the IDs in `RotationProbe`.
            probe(rotationSafetyIdentifier)
            probe(launchProbeIdentifier)
            probe("space_probe_\(rows.pendingBytes)_\(rows.reclaimedBytes)")
            probe("trash_rows_\(rows.trash)_\(rows.dormantCount)")
            // `RootView` removes `FeedView` in `.photos` mode. A
            // `main_stalls_` probe in `FeedView` is then unreachable. This
            // view keeps its own watchdog observation, so a stall does not
            // re-render the other probes.
            MainStallProbeView()
            probe(trashEntryIdentifier)
            probe("libfetch_\(counters.photoKit)_\(counters.swiftData)")
            probe("deckwrites_\(counters.deckIDs)_\(counters.deckInts)_\(counters.deckSaves)")
            probe("rowcount_\(rows.seen)_\(rows.liked)_\(rows.trash)")
            probe("rowcountnil_\(rows.seenNil)_\(rows.likedNil)_\(rows.trashNil)")
            // `RootView` unmounts `FeedView` outright while the mode is
            // `.photos`, so a probe living inside `FeedView` would be
            // unreachable in that mode.
            // `testPhotoDoubleTapKeepDisablesDelete` reads `pool_total_`
            // in both modes in the same run. Both values come from
            // `resolver`. They need no `DeckViewModel` and are correct
            // when no feed shows.
            probe("pool_total_\(resolver.pooledCount)")
            probe("pool_filtered_\(resolver.filteredPooledCount)")
        }
        .frame(width: 1, height: 1)
        .accessibilityHidden(false)
        // `PermissionGateView` mounts `GateProbes` in every authorization
        // state, so the watchdog runs for the whole process, not only
        // while the feed is up. Its 2-second settle window has normally
        // elapsed by the time the first page reaches the screen.
        .task { MainThreadWatchdog.shared.start() }
    }

    private var rotationSafetyIdentifier: String {
        let likedPart = rotation.likedLiveID.map { resolver.isShielded($0) ? "true" : "false" } ?? "none"
        let trashPart = rotation.trashLiveID.map { resolver.isQueued($0) ? "true" : "false" } ?? "none"
        return "rotation_safety_\(likedPart)_\(trashPart)"
    }

    /// `"launch_ms_<n>"` once the first frame plays, or
    /// `"launch_ms_pending"` before that.
    private var launchProbeIdentifier: String {
        if let ms = launch.elapsedMilliseconds {
            return "launch_ms_\(ms)"
        }
        return "launch_ms_pending"
    }

    private var trashEntryIdentifier: String {
        guard let entry = rows.newestEntry else { return "trash_entry_none" }
        return "trash_entry_\(entry.key)_\(entry.bytes)_\(entry.replacement)"
    }

    private func probe(_ id: String) -> some View {
        Color.clear.frame(width: 1, height: 1).accessibilityIdentifier(id)
    }
}

/// Backs the `-cloudfull-export-newest-replacement` launch argument.
/// Writes the shrink replacement of `$CLOUDFULL_HDR_ORIGINAL_ID` to
/// `Documents/hdr_probe.mov`, as a byte-exact copy of the PhotoKit
/// resource, never a re-encode. A re-encode would make
/// `scripts/gate_all.sh`'s ffprobe measure this encoder, not the saved
/// replacement. The HDR passthrough check would then be not valid.
enum ReplacementExporter {
    private static let log = Logger(subsystem: "com.cloudfull.app", category: "HDRProbe")

    @MainActor
    static func run() async {
        guard let originalID = ProcessInfo.processInfo.environment["CLOUDFULL_HDR_ORIGINAL_ID"] else {
            log.error("hdr_export_failed_no_original_env")
            return
        }
        guard let newID = UserDefaults.standard.string(forKey: "cloudfull.debug.replacementFor.\(originalID)") else {
            log.error("hdr_export_failed_no_replacement")
            return
        }
        guard let asset = PhotoLibraryService.shared.asset(for: newID) else {
            log.error("hdr_export_failed_asset_missing")
            return
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let videoResources = resources.filter { $0.type == .video || $0.type == .fullSizeVideo }
        guard let resource = (videoResources.isEmpty ? resources : videoResources).first else {
            log.error("hdr_export_failed_no_resource")
            return
        }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            log.error("hdr_export_failed_no_documents_dir")
            return
        }

        let destination = documents.appendingPathComponent("hdr_probe.mov")
        try? FileManager.default.removeItem(at: destination)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    Self.log.error("hdr_export_failed_\(error.localizedDescription, privacy: .public)")
                } else {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
                    let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                    Self.log.log("hdr_export_done_\(bytes, privacy: .public)")
                }
                continuation.resume()
            }
        }
    }
}
#endif
