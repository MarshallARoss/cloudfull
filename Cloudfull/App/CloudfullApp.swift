//
//  CloudfullApp.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import SwiftData
import AVFoundation
import Photos
import os

@main
struct CloudfullApp: App {
    /// Installs `CloudfullAppDelegate`, which names `CloudfullSceneDelegate`
    /// as the scene delegate. A SwiftUI-lifecycle app receives home-screen
    /// quick actions only through a scene delegate. See `QuickActions`.
    @UIApplicationDelegateAdaptor(CloudfullAppDelegate.self) private var appDelegate

    #if DEBUG
    /// Launch argument that erases persisted deck state before the
    /// SwiftData container opens. Used by a UI test only. This code is
    /// compiled out of release builds, so no shipped binary carries a way
    /// to erase user data.
    static let resetStateArgument = "-cloudfull-reset-deck-state"

    /// Deletes every regular Photos album whose title begins with
    /// `"Cloudfull UITest "` (trailing space included). Used by the
    /// album-creation UI test, so repeated test runs do not add more test
    /// albums to the library each time. Fired from
    /// `CloudKeyBackfillLauncher`, not here, once photo library
    /// authorization exists.
    static let purgeTestAlbumsArgument = "-cloudfull-purge-test-albums"

    /// Skips `CloudKeyBackfillLauncher.runIfNeeded` entirely for this
    /// process. Used only by the cloud-key-seeding UI test's launch, so
    /// the rows it writes are guaranteed to still read `cloudKey == nil`
    /// when that process terminates. Without this, the seeding launch's
    /// own backfill fires 2 s after launch, the same as any other launch.
    /// It could then resolve one or two of the seeded rows before
    /// `app.terminate()`. That would make the relaunch that asserts the
    /// backfill's row count non-deterministic.
    static let suppressBackfillArgument = "-cloudfull-suppress-backfill"

    /// Rewrites one `LikedEntry` and one `TrashEntry`'s stored `assetKey`
    /// to a dead placeholder, keeping `cloudKey`. This simulates the
    /// local-identifier rotation a device restore or migration causes, so
    /// the key-rotation UI test can prove `AssetKeyResolver` survives it.
    /// This is DEBUG-only, like every other launch argument in this file:
    /// no release binary carries a way to corrupt its own store this way.
    static let rotateKeysArgument = "-cloudfull-rotate-keys"

    /// Logs `auth_report_<PHAuthorizationStatus>` and exits immediately.
    /// Used by `scripts/gate_all.sh`'s round-start authorization check.
    /// Nothing else checks or restores Photos access between rounds. An
    /// intermittent failure in the Limited-access UI test's flow can
    /// remove access. `simctl privacy grant` does not work on this
    /// runtime, so it cannot restore access. This argument lets the gate
    /// report that failure at once.
    static let reportAuthArgument = "-cloudfull-report-auth"

    /// Logs `pool_report_<libraryCount>_<pooledCount>` then exits.
    /// `DeckViewModel.start()` reads this argument at its end. Declared
    /// here, beside the other DEBUG launch arguments, even though
    /// `DeckViewModel` is what reads it. This matches the pattern used
    /// for every other `-cloudfull-*` argument.
    static let reportPoolArgument = "-cloudfull-report-pool"

    /// Writes the shrink replacement of `$CLOUDFULL_HDR_ORIGINAL_ID` to
    /// `Documents/hdr_probe.mov` and exits. Fired from
    /// `CloudKeyBackfillLauncher.runIfNeeded`, once photo authorization
    /// exists.
    static let exportReplacementArgument = "-cloudfull-export-newest-replacement"

    /// Zeroes `MainThreadWatchdog`'s counters and restarts its settle
    /// window when the feed appears, so the scrolling-stall UI test
    /// measures scrolling rather than launch. The counters are
    /// process-local, so they are already zero at launch. This argument
    /// restarts the settle window when the feed appears, so the measured
    /// window starts at a known point.
    static let resetStallsArgument = "-cloudfull-reset-stalls"

    /// Delays every `PhotoLibraryService.playerItem(for:)` call by N
    /// seconds. N is the next launch argument. In the simulator, a
    /// seeded clip resolves in milliseconds. The delay lets a test run
    /// the real load sequence. Only the player item is delayed.
    /// The poster thumbnail is not, or the poster assertion in the
    /// player-load-timing UI test would measure this hook instead of the
    /// app. This is DEBUG-only, like every other launch argument in this
    /// file.
    static let slowLoadArgument = "-cloudfull-slow-load"

    /// Delays every `PhotoImagePipeline.events(for:)` delivery, both the
    /// fast thumbnail lane and the full-size request, by the number of
    /// seconds given as the next launch argument. The seeded library has
    /// no iCloud downloads. So `stillImage` is not `nil` for longer than
    /// the 0.6 s threshold in `PhotoPostView`, and the loading ring never
    /// shows. Delaying only the full-size frame is not enough: the fast
    /// thumbnail arrives on time and sets `stillImage`, which hides the
    /// ring for a non-remote asset. This is DEBUG-only, like every other
    /// launch argument in this file.
    static let slowPhotoArgument = "-cloudfull-slow-photo"

    /// Delays `LivePairedMovieStore`'s already-running paired-movie write
    /// by the number of seconds given as the next launch argument, right
    /// before it returns the URL. This is the same as `slowPhotoArgument`,
    /// but for the Live Photo motion clip. `-cloudfull-slow-photo` affects
    /// only `PhotoImagePipeline`. In the simulator, the paired video
    /// resolves too fast to capture the ring during
    /// `LiveReadiness.fetching`. This is DEBUG-only, like every other
    /// launch argument in this file.
    static let slowLiveArgument = "-cloudfull-slow-live"
    #endif

    init() {
        // Copies `settings.openMuted` into `feed.isMuted` at every launch.
        // Do not rename the `feed.isMuted` key. Mute is per launch:
        // tap-to-mute works until the app quits. `settings.openMuted`
        // defaults to false, so the app starts unmuted. The Settings row
        // shows "Open unmuted", which is the inverse of this value.
        UserDefaults.standard.set(
            UserDefaults.standard.bool(forKey: "settings.openMuted"),
            forKey: "feed.isMuted"
        )
        #if DEBUG
        // This is the earliest point where Swift code runs in this
        // process. It is the start of the launch measurement. It is the
        // first line of init(), before anything else, so no branch below
        // can make this measurement start late.
        LaunchProbe.shared.markProcessStart()
        // Forces `DiagnosticsLog`'s `init()`, and therefore its
        // `-cloudfull-reset-stalls` truncation, to run before any probe
        // below can append a line to `Documents/diagnostics.log`.
        _ = DiagnosticsLog.shared
        if ProcessInfo.processInfo.arguments.contains(Self.resetStateArgument) {
            Self.eraseLocalStore()
            // Onboarding is a one-time full-screen cover. A UI test that
            // relaunches without the reset flag
            // (`testResumesSavedPositionAfterRelaunch`) would otherwise
            // show onboarding on the second launch and find no
            // `page_` elements. Marking onboarding complete here keeps the
            // flag's contract across the relaunch: with the reset flag,
            // the process shows only the feed, also after a relaunch.
            UserDefaults.standard.set(true, forKey: OnboardingGate.storageKey)
        }
        // Rotate the keys here, before any view exists. The rotated rows
        // are then in place before `DeckViewModel.start()` deals the
        // deck.
        if ProcessInfo.processInfo.arguments.contains(Self.rotateKeysArgument) {
            KeyRotationHarness.rotate(container: CloudfullModelContainer.shared)
        }
        // This check needs no view, no session, and no SwiftData
        // container beyond what PhotoKit already tracks. It answers and
        // exits before anything else in this process does any work.
        if ProcessInfo.processInfo.arguments.contains(Self.reportAuthArgument) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            // `PHAuthorizationStatus` is an `@objc` enum. Calling
            // `String(describing:)` on it reports the type name,
            // "PHAuthorizationStatus", not the case name, so this maps
            // each case by hand.
            let name: String
            switch status {
            case .notDetermined: name = "notDetermined"
            case .restricted: name = "restricted"
            case .denied: name = "denied"
            case .authorized: name = "authorized"
            case .limited: name = "limited"
            @unknown default: name = "unknown"
            }
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.cloudfull.app", category: "AuthReport")
                .log("auth_report_\(name, privacy: .public)")
            exit(0)
        }
        #endif
        // Delete any `.pvt` Live Photo bundle that a Messages or AirDrop
        // share kept open while the app was in the background.
        // `ShareCoordinator.purgeShareDirectory()` already empties the
        // whole `tmp/CloudfullShare/` tree on every launch, so this
        // normally finds nothing. This call is not DEBUG-gated:
        // `LivePhotoBundle` ships in every configuration. Every build
        // deletes stale files.
        LivePhotoBundle.cleanupStaleBundles()
        configureAudioSessionCategory()
    }

    var body: some Scene {
        WindowGroup {
            PermissionGateView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(CloudfullModelContainer.shared)
    }

    #if DEBUG
    /// Removes the SwiftData store from disk before `modelContainer(for:)`
    /// opens it, so the app comes up on a fresh deck at position 0.
    ///
    /// The deck shows no video twice until it shows every video once,
    /// then it reshuffles. A test can check this rule only from the
    /// start of a pass. The saved position survives a restart, so a test
    /// must erase the store first.
    private static func eraseLocalStore() {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            try? fileManager.removeItem(at: support.appendingPathComponent(name))
        }
    }
    #endif

    /// Sets only the session category at launch. Activation
    /// (`setActive`) waits until a page starts playing (see
    /// `PlayerHolder.setActive`). This keeps Cloudfull from interrupting
    /// audio the user already plays elsewhere. For example, the app never
    /// activates the session while it shows only the permission gate.
    private func configureAudioSessionCategory() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
        } catch {
            Self.log.error("Failed to configure audio session category: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.cloudfull.app", category: "audio")
}
