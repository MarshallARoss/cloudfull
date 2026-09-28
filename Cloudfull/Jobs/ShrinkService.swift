//
//  ShrinkService.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import AVFoundation
import Photos
import Combine
import UIKit
import CoreLocation
import os

/// This is the background pipeline behind the shrink action. It exports the
/// original to HEVC 1080p. HDR passes through automatically at this preset
/// on iOS 15 and later, when the source is HDR. The pipeline adds no custom
/// color processing. It saves the export as a new asset. The new asset
/// carries the original's creation date and location. After that, the
/// pipeline gives the original to the trash queue.
///
/// Safety rule: the original is queued for deletion only after
/// `PhotoLibraryService.saveVideo` returns a new asset id. A failure at any
/// stage, in export, save, or an unexpected error in between, leaves the
/// original untouched. The pipeline then marks the job `.failed` and
/// deletes the temp export file. Three guards run after a successful
/// export. The original must still exist, the original must not be liked,
/// and the export must be smaller than 90% of the original size. A failed
/// guard ends the job with a reason that states the cause, such as
/// "already efficiently compressed". After the save, the trash queue may
/// refuse to accept the original, for example because the user liked the
/// asset after the last like check. That refusal ends the job in
/// `.doneOriginalKept`, never in a false `.done`.
///
/// The service keeps no persistence. Jobs live only in `jobs`, in memory. An
/// app kill mid-job loses the job entirely. The original is not changed
/// before the save completes, so the lost job causes no damage. `init`
/// deletes the temp export file on the next launch. A
/// brief background-task assertion around the pipeline gives an
/// almost-finished export a chance to complete instead of being killed
/// the instant the app backgrounds. See `beginBackgroundTaskIfNeeded`.
@MainActor
final class ShrinkService: ObservableObject {

    enum JobState: Equatable {
        case pending
        case exporting(Double)
        case saving
        case done(newAssetID: String, savedBytes: Int64)
        /// The 1080p replacement saved successfully, but the original was not
        /// queued for deletion. The original stays exactly as it was. The
        /// replacement is an extra copy, not a swap. `reason` gives the
        /// cause, so the toast can show the correct message.
        case doneOriginalKept(newAssetID: String, reason: KeptReason)
        case failed(String)

        /// See `doneOriginalKept`.
        enum KeptReason: String, Equatable {
            /// The user liked the asset after the last like check and
            /// before `onOriginalReadyToTrash` ran.
            case liked
            /// The user cancelled the job after the replacement had already
            /// saved. `PHPhotoLibrary.performChanges` does not observe Swift
            /// cooperative cancellation, so the save cannot be undone. The
            /// code keeps the original file unchanged in this case.
            case cancelled
            /// The trash queue refused the transfer for a reason other than
            /// a like on the asset. The most common cause is
            /// `AssetKeyResolver.isDestructiveActionSafe` being `false` at
            /// that exact moment.
            case queueRefused
        }
    }

    struct ShrinkJob: Identifiable {
        let id: String // the original asset's id
        var state: JobState
        let originalBytes: Int64
        /// The date and location are read at enqueue time. The original
        /// can be deleted during the export. A later read would give
        /// `nil` for both values.
        let creationDate: Date?
        let location: CLLocationWrapper?
    }

    @Published private(set) var jobs: [ShrinkJob] = []

    /// This closure fires only after the pipeline confirms the shrunk
    /// replacement is saved. It passes the original asset's id and the
    /// replacement's byte size. `AuthorizedSession` connects this closure to
    /// `TrashService.queue(assetID:replacementBytes:)`. The pipeline then
    /// uses the existing trash features (bin badge, space chip, deck
    /// exclusion) instead of duplicating them. The return value states
    /// whether the trash queue actually queued the original. `false` means
    /// the queue refused it, for example because the user liked the asset
    /// after the last like check. `runJob` must then report
    /// `.doneOriginalKept`, never a false `.done`.
    var onOriginalReadyToTrash: ((String, Int64) -> Bool)?
    /// This closure lets `ShrinkService` check whether an asset is currently
    /// liked, without the service owning any like or deck state itself. The
    /// pipeline consults it before starting an export, and again immediately
    /// before the irreversible save. This stops a video liked mid-export
    /// from becoming a duplicate copy. The `onOriginalReadyToTrash` return
    /// value covers the short time that remains after this check.
    var isAssetLiked: ((String) -> Bool)?
    /// This closure serves the same purpose as `isAssetLiked`, for the
    /// trash queue instead of the like state. It lets a caller additionally
    /// refuse an asset that is already trash-queued. No caller currently
    /// sets this closure, because `isCurrentlyQueued` already consults
    /// `AssetKeyResolver.shared` directly. The check still matters: a retry
    /// action in `FeedView` can call `enqueue` directly, and skip the rail's
    /// own queued check.
    var isAssetQueued: ((String) -> Bool)?

    private let library: PhotoLibraryService
    private let logger = Logger(subsystem: "com.cloudfull.app", category: "ShrinkService")

    /// This is a FIFO of asset ids waiting their turn. `isProcessing`
    /// guarantees that only one export-and-save pipeline runs at a time. A
    /// second `enqueue` call, while a job is running, only appends here and
    /// waits.
    private var pendingQueue: [String] = []
    private var isProcessing = false
    /// This holds the `Task` for whichever job is currently running. A
    /// queued job that has not started yet has no entry here.
    /// This lets `cancel(assetID:)` cancel a running job, not only one that
    /// is still waiting.
    private var runningTask: (assetID: String, task: Task<Void, Never>)?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// This is a dedicated subdirectory of `temporaryDirectory`, not loose
    /// files in it directly. A dedicated subdirectory keeps the startup
    /// cleanup in `init` safe to run unconditionally. The startup cleanup
    /// can never touch a temp file that another part of the app, or iOS
    /// itself, placed in the shared root.
    private static let tempDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloudfull-shrink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// This is the time bound on the download-and-export pipeline for one
    /// job. The limit is large because an iCloud download of several
    /// gigabytes can take minutes. The limit is finite, so a PhotoKit
    /// completion handler that never fires cannot block the queue. This
    /// mirrors the race-against-`Task.sleep` pattern in
    /// `PlayerHolder.waitUntilReady`, for the same class of hang.
    private static let jobTimeoutNanoseconds: UInt64 = 600_000_000_000 // 10 minutes

    /// This counts jobs still doing work: queued behind another job,
    /// mid-export, or mid-save. It excludes every terminal state.
    var activeCount: Int {
        jobs.reduce(0) { count, job in
            switch job.state {
            case .pending, .exporting, .saving: return count + 1
            case .done, .doneOriginalKept, .failed: return count
            }
        }
    }

    /// This is the sum of `savedBytes` over every job that finished
    /// successfully this session. Nothing persists across launches; see the
    /// type comment above.
    var sessionSavedBytes: Int64 {
        jobs.reduce(0) { total, job in
            if case .done(_, let savedBytes) = job.state {
                return total + savedBytes
            }
            return total
        }
    }

    init(library: PhotoLibraryService) {
        self.library = library
        Self.sweepStaleTempFiles()
    }

    /// This removes anything left behind in the dedicated shrink-temp
    /// subdirectory from a previous process. An app kill — jetsam, a force
    /// quit, or a crash — mid-export leaves a partially written
    /// `shrink-<uuid>.mov` file that nothing else ever cleans up. Apple only
    /// guarantees that the system may purge `temporaryDirectory` while the
    /// app is not running, not that it will. Users of this app are more
    /// likely than most to be in the low-storage state where that purge is
    /// least likely to have happened yet.
    private static func sweepStaleTempFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil) else { return }
        for file in contents {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// This returns true when the asset is bigger than the 1080p class. It
    /// returns false when PhotoKit has no dimensions for the asset: an
    /// unknown size must never read as safe to shrink and show the rail
    /// button for a video that might already be small. This method defers
    /// to `Fmt.isAboveShrinkThreshold` rather than keeping its own copy of
    /// the short-side check. The feed rail does not call this method; see
    /// `FeedPageContent.RailState`. It calls `Fmt.isAboveShrinkThreshold`
    /// so both use the same threshold.
    func canShrink(assetID: String) -> Bool {
        let size = library.pixelSize(for: assetID)
        guard size.width > 0, size.height > 0 else { return false }
        return Fmt.isAboveShrinkThreshold(size)
    }

    /// This returns the asset's current on-disk size. It also returns an
    /// estimate of the 1080p export size. The estimate uses the bitrate
    /// formula from `PhotoLibraryService.fileSize` at 1920x1080 and 30 fps.
    /// Both numbers are built the same way, so they stay comparable.
    /// Duration comes from the `PHAsset`, through the existing
    /// `asset(for:)` accessor.
    func estimate(assetID: String) -> (currentBytes: Int64, estimatedBytes: Int64) {
        let current = library.fileSize(for: assetID)
        guard let duration = library.asset(for: assetID)?.duration,
              duration.isFinite, duration > 0 else {
            return (current.bytes, current.bytes)
        }
        let fps = 30.0
        let width = 1920.0
        let height = 1080.0
        let estimatedBitsPerSecond = width * height * fps * 0.1
        let estimatedBytes = Int64((estimatedBitsPerSecond * duration) / 8)
        // Never claim the shrink would grow the file. A low-bitrate source
        // that sits above the 1080p-class cutoff could otherwise estimate
        // larger than its own current size.
        return (current.bytes, min(estimatedBytes, current.bytes))
    }

    /// This returns true for a job currently running — queued, exporting,
    /// or saving. It also returns true for one that already finished,
    /// whether or not the original was kept. It excludes `.failed` on
    /// purpose. A failed job must not permanently block a retry, so the
    /// rail's shrink button reappears and `enqueue` accepts the id again.
    func isJobbed(_ assetID: String) -> Bool {
        guard let job = jobs.first(where: { $0.id == assetID }) else { return false }
        switch job.state {
        case .pending, .exporting, .saving, .done, .doneOriginalKept:
            return true
        case .failed:
            return false
        }
    }

    /// This returns true while the asset is currently liked, or while
    /// `AssetKeyResolver.isDestructiveActionSafe` is false. That can happen,
    /// for example, because rotation resolution is not complete, or access
    /// is Limited. It is safer to exclude too many assets than to delete a
    /// protected original. This method consults `AssetKeyResolver.shared`
    /// directly, rather than relying only on the injected `isAssetLiked`
    /// closure. The fail-safe gate holds even before a session connects
    /// that closure.
    private func isCurrentlyLiked(_ assetID: String) -> Bool {
        guard AssetKeyResolver.shared.isDestructiveActionSafe else { return true }
        if AssetKeyResolver.shared.isShielded(assetID) { return true }
        return isAssetLiked?(assetID) == true
    }

    /// This returns true while the asset is already sitting in the trash
    /// queue. It consults `AssetKeyResolver.shared` directly, in addition
    /// to the optional injected closure; see the note on `isAssetQueued`.
    private func isCurrentlyQueued(_ assetID: String) -> Bool {
        if AssetKeyResolver.shared.isQueued(assetID) { return true }
        return isAssetQueued?(assetID) == true
    }

    /// This queues a shrink job. It does nothing if `isJobbed` is true, if
    /// the asset is liked, or if the asset is in the trash queue. Starting
    /// a job for a liked asset would only ever end in `.doneOriginalKept`,
    /// so refusing it up front saves the export entirely. The trash-queued
    /// check stops a retry from bypassing the rail's own queued check. It
    /// also stops the retry from enqueuing a duplicate job for an asset
    /// already queued for removal. This method first removes an old
    /// `.failed` row for the same id. Two rows with one id would break the
    /// lookup in `updateJob`.
    func enqueue(assetID: String) {
        guard !isJobbed(assetID), !isCurrentlyLiked(assetID), !isCurrentlyQueued(assetID) else { return }
        Usage.shared.action(.shrink, source: .rail, mode: .videos)
        jobs.removeAll { $0.id == assetID }
        let originalBytes = library.fileSize(for: assetID).bytes
        let meta = library.assetMeta(for: assetID)
        jobs.append(ShrinkJob(
            id: assetID,
            state: .pending,
            originalBytes: originalBytes,
            creationDate: meta.creationDate,
            location: meta.location.map(CLLocationWrapper.init)
        ))
        pendingQueue.append(assetID)
        processQueueIfNeeded()
    }

    /// This cancels a job that has not started yet, by dropping it from
    /// the FIFO. It cancels a job that is currently exporting or saving
    /// by cancelling its `Task`. Cancelling the `Task` also cancels its
    /// child tasks: the PhotoKit requests with timeouts and the export.
    /// This method does nothing for a job that already reached a terminal
    /// state.
    func cancel(assetID: String) {
        guard let job = jobs.first(where: { $0.id == assetID }) else { return }
        switch job.state {
        case .pending:
            pendingQueue.removeAll { $0 == assetID }
            updateJob(assetID) { $0.state = .failed("Canceled.") }
        case .exporting, .saving:
            if runningTask?.assetID == assetID {
                runningTask?.task.cancel()
            }
        case .done, .doneOriginalKept, .failed:
            break
        }
    }

    // MARK: - Pipeline

    private func processQueueIfNeeded() {
        guard !isProcessing, !pendingQueue.isEmpty else { return }
        isProcessing = true
        let assetID = pendingQueue.removeFirst()
        let task = Task { @MainActor [weak self] in
            await self?.runJob(for: assetID)
            self?.runningTask = nil
            self?.isProcessing = false
            self?.processQueueIfNeeded()
        }
        runningTask = (assetID, task)
    }

    /// This runs one job end to end. Every early return before the save
    /// completes must leave the original asset unchanged.
    private func runJob(for assetID: String) async {
        guard let job = jobs.first(where: { $0.id == assetID }) else { return }

        // Do not download an iCloud original on an expensive or
        // constrained network. A local original needs no network, so this
        // check skips it.
        if !library.isOriginalLocallyAvailable(for: assetID) && library.isNetworkExpensiveOrConstrained {
            fail(assetID, reason: "Waiting for Wi-Fi to download the original.")
            return
        }

        // Check for a like before the export starts. This check is less
        // expensive than finding the like after a long export. A video
        // liked while only queued behind another job never gets exported
        // at all. This also refuses to start while
        // `AssetKeyResolver.isDestructiveActionSafe` is false: no export
        // starts, and no original is ever queued, until rotation
        // resolution is complete.
        if isCurrentlyLiked(assetID) {
            fail(assetID, reason: "The video was liked before the shrink could start.")
            return
        }

        beginBackgroundTaskIfNeeded()
        defer { endBackgroundTaskIfNeeded() }

        guard let session = await requestExportSessionWithTimeout(for: assetID) else {
            fail(assetID, reason: Task.isCancelled ? "Canceled." : "Could not prepare the export.")
            return
        }
        guard !Task.isCancelled else {
            fail(assetID, reason: "Canceled.")
            return
        }

        let tempURL = Self.tempDirectory
            .appendingPathComponent("shrink-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        updateJob(assetID) { $0.state = .exporting(0) }

        // This polls `session.progress` separately while the export runs.
        // `AVAssetExportSession.progress` is documented as not key-value
        // observable, so polling is the only way to surface progress
        // alongside the `export(to:as:)` call. The task publishes only
        // when the rounded percent changes. Five writes each second would
        // make every observer, such as the feed body and the confirm
        // sheet, update without need.
        let progressTask = Task { @MainActor [weak self] in
            var lastPercent = -1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
                let progress = Double(session.progress)
                let percent = Int((progress * 100).rounded())
                guard percent != lastPercent else { continue }
                lastPercent = percent
                self?.updateJob(assetID) { job in
                    if case .exporting = job.state {
                        job.state = .exporting(progress)
                    }
                }
            }
        }

        if let error = await exportWithTimeout(session, to: tempURL) {
            progressTask.cancel()
            try? FileManager.default.removeItem(at: tempURL)
            fail(assetID, reason: Task.isCancelled ? "Canceled." : error.localizedDescription)
            return
        }
        progressTask.cancel()
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: tempURL)
            fail(assetID, reason: "Canceled.")
            return
        }

        updateJob(assetID) { $0.state = .saving }

        // Read the export size before the save. The value stays correct
        // if `saveVideo` ever moves the file instead of copying it.
        let newBytes = fileSizeOnDisk(at: tempURL)

        // The original can vanish during a long export: deleted in the
        // Photos app, or trashed and emptied through this app's own bin
        // while the export ran. A job in progress disables the rail's
        // trash button, but that only closes the in-app path; the Photos
        // app is still reachable. The code re-checks right before the
        // irreversible save, rather than trusting the check that ran when
        // the export session started.
        guard library.asset(for: assetID) != nil else {
            try? FileManager.default.removeItem(at: tempURL)
            fail(assetID, reason: "The original was deleted during the shrink.")
            return
        }

        // This is the second, narrower half of the like check at the top
        // of this method. The `Bool` return from `onOriginalReadyToTrash`
        // covers the short gap between this check and the save
        // completing.
        if isCurrentlyLiked(assetID) {
            try? FileManager.default.removeItem(at: tempURL)
            fail(assetID, reason: "The video was liked during the shrink.")
            return
        }

        // Re-read the original's real on-disk size now. The original may
        // have downloaded from iCloud since `enqueue`, so this reading is
        // more trustworthy than the estimate captured then. The export
        // must be less than 90% of the original size. A low-bitrate 4K
        // source can re-encode larger at this preset's fixed target rate.
        // That result uses more storage and deletes the only full-quality
        // copy.
        let freshOriginalBytes = library.fileSize(for: assetID).bytes
        let referenceBytes = freshOriginalBytes > 0 ? freshOriginalBytes : job.originalBytes
        let requiredCeiling = Int64(Double(referenceBytes) * 0.9)
        guard referenceBytes > 0, newBytes < requiredCeiling else {
            try? FileManager.default.removeItem(at: tempURL)
            fail(assetID, reason: "This video is already efficiently compressed.")
            return
        }

        guard let newAssetID = await library.saveVideo(
            fileURL: tempURL,
            creationDate: job.creationDate,
            location: job.location?.location
        ) else {
            try? FileManager.default.removeItem(at: tempURL)
            fail(assetID, reason: "Could not save the shrunk video.")
            return
        }

        try? FileManager.default.removeItem(at: tempURL)
        let savedBytes = max(referenceBytes - newBytes, 0)

        // Every stage above this point re-checks cancellation. After the
        // save, cancellation needs a separate check: the save has already
        // committed, because `PHPhotoLibrary.performChanges` does not
        // observe Swift cooperative cancellation. The replacement cannot
        // be removed here. The code keeps the original and ends the job
        // in `.doneOriginalKept(.cancelled)`.
        guard !Task.isCancelled else {
            updateJob(assetID) { $0.state = .doneOriginalKept(newAssetID: newAssetID, reason: .cancelled) }
            Task { @MainActor in Usage.shared.shrinkOutcome("originalKept.cancelled") }
            return
        }

        // The shrunk replacement is confirmed saved as of the line above.
        // The pipeline now gives the original to the trash queue. The
        // queue may refuse it, for example because the user liked the
        // asset after the last like check. The code reads the outcome
        // from the queue's return value, rather than assuming success.
        let wasQueued = onOriginalReadyToTrash?(assetID, newBytes) ?? false
        if wasQueued {
            updateJob(assetID) { $0.state = .done(newAssetID: newAssetID, savedBytes: savedBytes) }
            // Bytes count as freed only here. When the original is kept,
            // the phone holds both files, and nothing was actually saved.
            Task { @MainActor in Usage.shared.shrinkOutcome("done"); Usage.shared.shrinkSaved(bytes: savedBytes) }
        } else {
            // Find which of the two remaining reasons applies.
            // `FeedView.handleShrinkJobsChanged` uses it for the toast.
            // The toast must not say "liked" for a video that is not
            // liked. The check calls `AssetKeyResolver.isShielded`
            // directly, not `isCurrentlyLiked`. That wrapper also returns
            // `true` when `isDestructiveActionSafe` is false, which would
            // mislabel a queue refusal from a pending rotation as
            // `.liked`.
            let reason: JobState.KeptReason = AssetKeyResolver.shared.isShielded(assetID) ? .liked : .queueRefused
            updateJob(assetID) { $0.state = .doneOriginalKept(newAssetID: newAssetID, reason: reason) }
            Task { @MainActor in Usage.shared.shrinkOutcome("originalKept.\(reason.rawValue)") }
        }
    }

    /// This runs `PhotoLibraryService.requestExportSession` against
    /// `Self.jobTimeoutNanoseconds`. A PhotoKit completion handler that
    /// never fires then cannot block `isProcessing` and the jobs after it.
    /// This mirrors the race-against-`Task.sleep` shape of
    /// `PlayerHolder.waitUntilReady`. Cancelling the losing branch through
    /// `group.cancelAll()` also cancels the PhotoKit request, because
    /// `requestExportSession` connects its own cancellation handler to
    /// this structured child task.
    private func requestExportSessionWithTimeout(for assetID: String) async -> AVAssetExportSession? {
        await withTaskGroup(of: AVAssetExportSession?.self) { group in
            group.addTask { [library] in
                await library.requestExportSession(for: assetID, preset: AVAssetExportPresetHEVC1920x1080)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.jobTimeoutNanoseconds)
                return nil
            }
            guard let firstResult = await group.next() else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return firstResult
        }
    }

    /// This runs `session.export(to:as:)` against the same timeout. On a
    /// timeout it calls `cancelExport()`, because `export(to:as:)` does
    /// not reliably stop on `Task` cancellation. It returns `nil` on
    /// success, or an `Error` describing why it did not succeed. A
    /// timeout returns a dedicated `ShrinkTimeoutError`, so the resulting
    /// `.failed` reason states what actually happened.
    private func exportWithTimeout(_ session: AVAssetExportSession, to url: URL) async -> Error? {
        enum Outcome {
            case success
            case failure(Error)
            case timedOut
        }
        let outcome = await withTaskGroup(of: Outcome.self) { group -> Outcome in
            group.addTask {
                do {
                    try await session.export(to: url, as: .mov)
                    return .success
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.jobTimeoutNanoseconds)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        switch outcome {
        case .success:
            return nil
        case .failure(let error):
            return error
        case .timedOut:
            session.cancelExport()
            return ShrinkTimeoutError()
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "com.cloudfull.shrink") { [weak self] in
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func fail(_ assetID: String, reason: String) {
        logger.error("ShrinkService job \(assetID, privacy: .private) failed: \(reason, privacy: .public)")
        updateJob(assetID) { $0.state = .failed(reason) }
        Task { @MainActor in Usage.shared.shrinkOutcome("failed") }   // The reason text stays in the log, not in the analytics record.
    }

    private func fileSizeOnDisk(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    private func updateJob(_ assetID: String, _ mutate: (inout ShrinkJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == assetID }) else { return }
        mutate(&jobs[index])
        #if DEBUG
        // This stores which replacement belongs to which original. Store
        // the replacement id in `UserDefaults` under a key that contains
        // the original id. The value stays after the process ends, so
        // `-cloudfull-export-newest-replacement` can read it on a later
        // launch. This check is centralized here, rather than duplicated
        // at each of `runJob`'s three `.done` and `.doneOriginalKept` call
        // sites. That way, a later fourth call site will not miss it.
        switch jobs[index].state {
        case .done(let newAssetID, _), .doneOriginalKept(let newAssetID, _):
            UserDefaults.standard.set(newAssetID, forKey: "cloudfull.debug.replacementFor.\(assetID)")
        case .pending, .exporting, .saving, .failed:
            break
        }
        #endif
    }
}

/// `CLLocation` is a class, so it cannot sit directly in `ShrinkJob` — a
/// `struct` consumed across actor-isolated code — without importing
/// `CoreLocation`'s own Sendability rules. This is a simple `Sendable`
/// wrapper. It lets `ShrinkJob` carry the location captured at enqueue time,
/// without deriving it again later from a `PHAsset` that may be stale or
/// deleted by then.
struct CLLocationWrapper: @unchecked Sendable {
    let location: CLLocation
}

/// `exportWithTimeout` returns this error when it stops a stalled export.
/// The resulting `.failed` job then carries a message that states what
/// happened, instead of a generic cancellation string.
private struct ShrinkTimeoutError: LocalizedError {
    var errorDescription: String? { "The export timed out." }
}
