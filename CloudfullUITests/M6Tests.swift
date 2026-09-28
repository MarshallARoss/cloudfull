//
//  M6Tests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
import CoreFoundation

/// UI tests for landscape fullscreen playback.
///
/// The tests prove: landscape fullscreen engages on the centered page only
/// when the video is landscape by presentation size and the device is
/// physically sideways. Playback continues through the transition without
/// a reload (durationMs stays constant and currentMs increases). Rotating
/// back restores the 9:16 stage and paging. A portrait video never reacts.
/// The probe confirms the app received the rotation instead of missing it.
///
/// Paging stays disabled while fullscreen is active. The dismiss button
/// works independently of the device orientation.
///
/// This class has exactly 4 `func test…` methods. External scripts compare
/// the `Executed N tests` count in the output. Keep exactly 4 test methods.
///
/// This class defines its own helpers, like `M4Tests` and `M5Tests`.
final class M6Tests: FeedUITestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Reset to portrait at setup, because a crashed earlier run can
        // leave the device in landscape. Register the teardown before any
        // rotation so that it runs when a test fails partway. No simctl
        // command resets a leaked orientation.
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    // MARK: - 1. Landscape video goes fullscreen on rotation

    func testLandscapeVideoGoesFullscreenOnRotation() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }
        guard let landscapePage = scrollToAsset(in: Set(landscapeFixtureIDs()), from: startPage(), budget: searchBudget(poolTotal: poolTotal)) else {
            XCTFail("Never reached a seeded landscape 4K clip (CLOUDFULL_SHRINKABLE_ASSET_IDS / CLOUDFULL_HDR_ASSET_ID / CLOUDFULL_INCOMPRESSIBLE_ASSET_ID)")
            return
        }
        let assetID = landscapePage.assetID

        guard let baseline = scrubberReading(timeout: 10) else {
            XCTFail("scrubber_probe_ never appeared on the seeded landscape clip")
            return
        }

        guard let engageMs = rotateMeasuringEngageMs(to: .landscapeLeft) else {
            return // rotateMeasuringEngageMs already called XCTFail
        }

        guard let state = fullscreenState(timeout: 8) else {
            XCTFail("fullscreen_state_ probe never appeared after rotating to landscapeLeft")
            return
        }
        XCTAssertTrue(state.active, "fullscreen_state_ did not read active after rotating a landscape video")
        XCTAssertEqual(state.stance, "landscapeLeft", "fullscreen_state_ stance did not read landscapeLeft")
        XCTAssertEqual(state.assetID, assetID, "fullscreen_state_ reports a different asset than the one on the stage before rotating")
        ProbeLog.emit("fullscreen_engage_ms", engageMs)

        XCTAssertTrue(element("fullscreen_overlay").exists, "fullscreen_overlay does not exist while fullscreen is active")

        // `fullscreen_state_`, confirmed above, reads `PlayerPageView`'s own
        // local `isFullscreen` value directly, so test 3's negative check
        // also reads that value directly. The five identifiers below
        // depend on a second, separate hop. `PlayerPageView.onFullscreenChanged`
        // mirrors that local value into `FeedView`'s own `@State
        // isFullscreen`. Only that state drives `overlayControls`,
        // `bottomScrim`, and `FeedPageContent`'s `.opacity` and
        // `.accessibilityHidden`.
        //
        // Confirming the first hop settled does not guarantee the second
        // hop commits at the same time. An immediate `.exists` check here
        // can still find `feed_caption` present even after the probe reads
        // `active`. `waitForAbsence` polls instead of reading once, the
        // same polling `fullscreenState()` and `centeredPage()` use
        // elsewhere in this suite.
        XCTAssertTrue(waitForAbsence(element("feed_caption")), "feed_caption still resolves while fullscreen is active")
        XCTAssertTrue(waitForAbsence(app.buttons["rail_like"]), "rail_like still resolves while fullscreen is active")
        XCTAssertTrue(waitForAbsence(app.buttons["rail_trash"]), "rail_trash still resolves while fullscreen is active")
        XCTAssertTrue(waitForAbsence(app.buttons["bin_open"]), "bin_open still resolves while fullscreen is active")
        // `feed_filter_button` is gated on `isFullscreen` the same way as
        // `feed_mute_toggle`, which sits to its left. This assertion proves
        // the filter button hides correctly, independent of the mute
        // toggle's own visibility.
        XCTAssertTrue(waitForAbsence(app.buttons["feed_filter_button"]), "feed_filter_button still resolves while fullscreen is active")

        // Playback continuity: durationMs must stay constant across every
        // sample. A reload sets durationMs to 0, so this value works as the
        // reload detector. currentMs must strictly increase at least once,
        // to prove the player is still playing and not stalled. The test
        // does not compare currentMs with baseline.currentMs. The seeded
        // fixtures are 4 seconds long and loop. The playhead can return to
        // 0 during the 1 to 2 second rotation.
        var samples: [(scrubbing: Bool, currentMs: Int, durationMs: Int)] = []
        for _ in 0..<3 {
            guard let reading = scrubberReading(timeout: 5) else {
                XCTFail("scrubber_probe_ did not produce a reading while fullscreen")
                return
            }
            samples.append(reading)
            Thread.sleep(forTimeInterval: 0.7)
        }
        XCTAssertTrue(
            samples.allSatisfy { $0.durationMs == baseline.durationMs },
            "durationMs changed during the fullscreen spell (\(samples.map(\.durationMs)) vs baseline \(baseline.durationMs)) — this is the reload detector"
        )
        var sawIncrease = false
        for i in 1..<samples.count {
            if samples[i].currentMs > samples[i - 1].currentMs {
                sawIncrease = true
                break
            }
        }
        XCTAssertTrue(sawIncrease, "currentMs never increased across three samples ~0.7s apart — playback looks stalled: \(samples)")

        XCTAssertFalse(app.staticTexts["player_retry"].exists, "player_retry appeared during the fullscreen spell")
        XCTAssertFalse(app.buttons["player_retry"].exists, "player_retry appeared during the fullscreen spell")
    }

    // MARK: - 2. Rotating back restores the stage and paging

    func testRotatingBackRestoresStageAndPaging() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }
        guard let landscapePage = scrollToAsset(in: Set(landscapeFixtureIDs()), from: startPage(), budget: searchBudget(poolTotal: poolTotal)) else {
            XCTFail("Never reached a seeded landscape 4K clip")
            return
        }
        let assetID = landscapePage.assetID

        rotate(to: .landscapeLeft)
        guard let active = fullscreenState(timeout: 8) else {
            XCTFail("fullscreen_state_ probe never appeared after rotating to landscapeLeft")
            return
        }
        XCTAssertTrue(active.active, "fullscreen_state_ did not read active before testing the rotate-back path")
        XCTAssertEqual(active.assetID, assetID)

        rotate(to: .portrait)
        guard let inactive = fullscreenState(timeout: 8) else {
            XCTFail("fullscreen_state_ probe never appeared after rotating back to portrait")
            return
        }
        XCTAssertFalse(inactive.active, "fullscreen_state_ still reads active after rotating back to portrait")
        XCTAssertEqual(inactive.stance, "portrait", "fullscreen_state_ stance did not read portrait after rotating back")
        XCTAssertEqual(inactive.assetID, assetID, "fullscreen_state_ reports a different asset after rotating back")

        XCTAssertFalse(element("fullscreen_overlay").exists, "fullscreen_overlay is still present after rotating back to portrait")

        // The feed caption, rail buttons, bin button, and filter button
        // return with the same element types after rotation.
        XCTAssertTrue(element("feed_caption").waitForExistence(timeout: 5), "feed_caption did not return after rotating back")
        XCTAssertTrue(app.buttons["rail_like"].waitForExistence(timeout: 5), "rail_like did not return after rotating back")
        XCTAssertTrue(app.buttons["rail_share"].waitForExistence(timeout: 5), "rail_share did not return after rotating back")
        XCTAssertTrue(app.buttons["rail_shrink"].waitForExistence(timeout: 5), "rail_shrink did not return after rotating back")
        XCTAssertTrue(app.buttons["rail_trash"].waitForExistence(timeout: 5), "rail_trash did not return after rotating back")
        XCTAssertTrue(app.buttons["bin_open"].waitForExistence(timeout: 5), "bin_open did not return after rotating back")
        // See the note in test 1 about `feed_mute_toggle` not affecting
        // this assertion.
        XCTAssertTrue(app.buttons["feed_filter_button"].waitForExistence(timeout: 5), "feed_filter_button did not return after rotating back")

        guard let centered = centeredPage(timeout: 10) else {
            XCTFail("No centered page_ element found after rotating back")
            return
        }
        XCTAssertEqual(centered.slot, landscapePage.slot, "centeredPage() reports a different slot after rotating back")
        XCTAssertEqual(centered.assetID, landscapePage.assetID, "centeredPage() reports a different asset after rotating back")

        // This checks that paging works again. It uses `recordPages` and
        // not a plain `swipeUp()`.
        let paged = recordPages(swipes: 1, from: centered)
        XCTAssertEqual(paged.count, 2, "recordPages did not record a page for the post-rotation swipe")
    }

    // MARK: - 3. Portrait video ignores rotation

    func testPortraitVideoIgnoresRotation() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }
        guard let portraitPage = scrollToAsset(in: known1080pAssetIDs(), from: startPage(), budget: searchBudget(poolTotal: poolTotal)) else {
            XCTFail("Never reached a seeded 1080p portrait clip (CLOUDFULL_KNOWN_1080P_ASSET_IDS)")
            return
        }
        let assetID = portraitPage.assetID

        rotate(to: .landscapeLeft)
        guard let declined = fullscreenState(timeout: 8) else {
            XCTFail("fullscreen_state_ probe never appeared after rotating a portrait video")
            return
        }
        // The stance field proves the rotation reached the app and the app
        // declined fullscreen, rather than the rotation never arriving.
        XCTAssertFalse(declined.active, "fullscreen_state_ read active for a portrait video")
        XCTAssertEqual(declined.stance, "landscapeLeft", "fullscreen_state_ stance did not read landscapeLeft — the rotation may never have reached the app")
        XCTAssertEqual(declined.assetID, assetID)

        XCTAssertFalse(element("fullscreen_overlay").exists, "fullscreen_overlay exists for a portrait video")
        XCTAssertTrue(element("feed_caption").exists, "feed_caption disappeared for a portrait video's rotation")
        XCTAssertTrue(app.buttons["rail_like"].exists, "rail_like disappeared for a portrait video's rotation")

        guard let centered = centeredPage(timeout: 5) else {
            XCTFail("No centered page_ element found while rotated")
            return
        }
        XCTAssertEqual(centered.slot, portraitPage.slot, "centeredPage() moved during a portrait video's rotation")
        XCTAssertEqual(centered.assetID, portraitPage.assetID, "centeredPage() changed asset during a portrait video's rotation")

        rotate(to: .portrait)
        guard let backToPortrait = fullscreenState(timeout: 8) else {
            XCTFail("fullscreen_state_ probe never appeared after rotating back to portrait")
            return
        }
        XCTAssertFalse(backToPortrait.active)
        XCTAssertEqual(backToPortrait.stance, "portrait")
        XCTAssertEqual(backToPortrait.assetID, assetID)
    }

    // MARK: - 4. Fullscreen disables paging, and the dismiss button exits

    func testFullscreenDisablesPagingAndDismissButtonExits() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }
        guard let landscapePage = scrollToAsset(in: Set(landscapeFixtureIDs()), from: startPage(), budget: searchBudget(poolTotal: poolTotal)) else {
            XCTFail("Never reached a seeded landscape 4K clip")
            return
        }
        let assetID = landscapePage.assetID

        rotate(to: .landscapeLeft)
        guard let active = fullscreenState(timeout: 8) else {
            XCTFail("fullscreen_state_ probe never appeared after rotating to landscapeLeft")
            return
        }
        XCTAssertTrue(active.active)
        XCTAssertEqual(active.assetID, assetID)

        guard let centeredBeforeSwipes = centeredPage(timeout: 5) else {
            XCTFail("No centered page_ element found while fullscreen")
            return
        }

        // Paging is disabled. Two swipes, half a second apart, must not
        // move the centered slot or change the fullscreen asset.
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.5)
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.5)

        guard let centeredAfterSwipes = centeredPage(timeout: 5) else {
            XCTFail("No centered page_ element found after the swipes")
            return
        }
        XCTAssertEqual(centeredAfterSwipes.slot, centeredBeforeSwipes.slot, "Paging moved the centered slot while fullscreen was active")

        guard let stillActive = fullscreenState(timeout: 5) else {
            XCTFail("fullscreen_state_ probe missing after the swipes")
            return
        }
        XCTAssertTrue(stillActive.active, "fullscreen_state_ stopped reading active after two no-op swipes")
        XCTAssertEqual(stillActive.assetID, assetID, "fullscreen_state_ reports a different asset after the swipes")

        // Tap the stage center to show the chrome. If `fullscreen_dismiss`
        // does not appear in 5 s, tap once more and wait again.
        let dismissButton = app.buttons["fullscreen_dismiss"]
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if !dismissButton.waitForExistence(timeout: 5) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(dismissButton.waitForExistence(timeout: 5), "fullscreen_dismiss did not appear after tapping the stage twice")
        }

        // The stage tap also toggles mute, the same as in the feed. This
        // test isolates one deliberate tap here, after the chrome is
        // already confirmed visible, instead of combining it with the
        // reveal-chrome taps above. That step can take one or two taps,
        // depending on the same auto-hide race described below. Two taps
        // toggle mute twice, back to its starting value. A before/after
        // comparison spanning that step is unreliable.
        let fullscreenMuteToggle = app.buttons["fullscreen_mute_toggle"]
        XCTAssertTrue(fullscreenMuteToggle.waitForExistence(timeout: 2), "fullscreen_mute_toggle did not appear alongside the revealed chrome")
        let mutedLabelBeforeTap = fullscreenMuteToggle.label
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(fullscreenMuteToggle.exists, "fullscreen_mute_toggle disappeared — the stage tap hid the chrome instead of keeping it revealed")
        // The app waits about 0.3 s for a possible double tap (the keep
        // gesture) before it handles a single tap. Poll for the label
        // change.
        XCTAssertTrue(
            waitFor(timeout: 2) { fullscreenMuteToggle.exists && fullscreenMuteToggle.label != mutedLabelBeforeTap },
            "Tapping the fullscreen stage did not toggle mute (label stayed '\(mutedLabelBeforeTap)')"
        )

        // The stage tap above restarted the chrome's 3-second auto-hide.
        // The chrome can reveal. This check can see it. The chrome can
        // still auto-hide again before `dismissButton.tap()` lands below.
        //
        // `.exists` reads instantly, so it avoids extra delay that can
        // land the tap inside the hide animation. If the chrome has
        // already hidden, one more stage tap brings it back. This also
        // toggles mute again, which is harmless because the mute assertion
        // is already done.
        if !dismissButton.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(dismissButton.waitForExistence(timeout: 2), "fullscreen_dismiss did not come back after re-revealing the chrome")
        }
        dismissButton.tap()

        guard let dismissed = fullscreenState(timeout: 8) else {
            XCTFail("fullscreen_state_ probe missing after tapping fullscreen_dismiss")
            return
        }
        XCTAssertFalse(dismissed.active, "fullscreen_state_ still reads active after tapping fullscreen_dismiss")
        // The device is still in landscapeLeft, so the stance reads
        // landscapeLeft. The `dismissedThisSpell` latch keeps fullscreen
        // off and stops it from engaging again.
        XCTAssertEqual(dismissed.stance, "landscapeLeft", "device stance changed on its own after tapping fullscreen_dismiss")
        XCTAssertEqual(dismissed.assetID, assetID)

        XCTAssertFalse(element("fullscreen_overlay").exists, "fullscreen_overlay is still present after tapping fullscreen_dismiss")
        XCTAssertTrue(app.buttons["rail_like"].waitForExistence(timeout: 5), "rail_like did not return after dismissing fullscreen")
        XCTAssertTrue(element("feed_caption").waitForExistence(timeout: 5), "feed_caption did not return after dismissing fullscreen")

        rotate(to: .portrait)
        guard let backToPortrait = fullscreenState(timeout: 8) else {
            XCTFail("fullscreen_state_ probe missing after rotating back to portrait")
            return
        }
        XCTAssertFalse(backToPortrait.active)
        XCTAssertEqual(backToPortrait.stance, "portrait")
    }

    // MARK: - Shared harness

    /// Finds any accessibility element by identifier, not only controls.
    /// Elements such as `fullscreen_overlay` and `feed_caption` are plain
    /// views, not buttons, matching the same choice `M5Tests`' own
    /// `element(_:)` helper makes.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Polls for an element's absence instead of reading `.exists` once.
    /// See the call site in test 1 for why this matters for the
    /// FeedView-mirrored-state identifiers. It is the opposite of
    /// `XCUIElement.waitForExistence(timeout:)`, which XCTest does not
    /// provide.
    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return !element.exists
    }

    private func startPage() -> Page {
        guard let page = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return Page(slot: -1, assetID: "")
        }
        return page
    }

    private func searchBudget(poolTotal: Int) -> Int {
        poolTotal + max(10, poolTotal / 4)
    }

    // MARK: - Test-side rotation through the DEBUG Darwin hook
    //
    // XCUIDevice.shared.orientation does not reach the app process on the
    // iOS simulator. Setting it alone produces no orientation change
    // inside the app. No `orientation_landscapeLeft` line appears in the
    // device log, and a probe read afterward still reports portrait.
    //
    // `OrientationMonitor`'s DEBUG Darwin hook exists for exactly this
    // case. This helper posts the three notification names that the hook
    // listens for. Driving the hook from the test side, not from the app,
    // is deliberate. `XCUIDevice.shared.orientation` is still set first on
    // every call.
    //
    // If a future runtime delivers the orientation change correctly, the
    // app already sees the real rotation before this hook ever posts.
    // Behavior stays correct either way. Only this class uses the hook.
    //
    // Driving the hook exercises all code that reads `stance` publishing
    // in the app. That code includes `isFullscreen`, the rotated canvas,
    // `FullscreenPlayerChrome`, hiding the global chrome, disabling
    // paging, and the dismiss latch. Each goes through the same code path
    // a real rotation drives. These tests do not prove that a
    // physical rotation reaches the app on the simulator.
    private func postDarwinOrientationStance(_ stance: String) {
        let name: String
        switch stance {
        case "landscapeLeft": name = "com.cloudfull.app.debug.orientationStance.landscapeLeft"
        case "landscapeRight": name = "com.cloudfull.app.debug.orientationStance.landscapeRight"
        default: name = "com.cloudfull.app.debug.orientationStance.portrait"
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    /// Sets `XCUIDevice.shared.orientation` and posts the matching DEBUG
    /// Darwin notification, described in the section comment above. Every
    /// `rotate(to:)` and `rotateMeasuringEngageMs(to:)` call performs this
    /// action before polling. Returns the stance string that the probe
    /// reports for the orientation.
    private func applyDeviceStance(_ orientation: UIDeviceOrientation) -> String {
        let wantStance: String
        switch orientation {
        case .landscapeLeft: wantStance = "landscapeLeft"
        case .landscapeRight: wantStance = "landscapeRight"
        default: wantStance = "portrait"
        }
        XCUIDevice.shared.orientation = orientation
        postDarwinOrientationStance(wantStance)
        return wantStance
    }

    /// Sets the device stance, using `applyDeviceStance(_:)` above, then
    /// polls `fullscreenState()` until the probe's stance field reports
    /// the requested stance, up to `timeout` seconds (default 8). Fails
    /// the test if the stance never arrives, so a rotation that never
    /// reached the app cannot read as the app declining fullscreen.
    private func rotate(to orientation: UIDeviceOrientation, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        let wantStance = applyDeviceStance(orientation)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let reading = fullscreenState(timeout: 1), reading.stance == wantStance {
                return
            }
        } while Date() < deadline
        XCTFail("fullscreen_state_ never reported stance '\(wantStance)' within \(timeout)s of setting the device stance — the rotation may not have reached the app", file: file, line: line)
    }

    /// Used only by test 1. Measures `fullscreen_engage_ms`: the
    /// milliseconds between setting `XCUIDevice.shared.orientation` and
    /// `fullscreen_state_` first reading active. This differs from the
    /// time `rotate(to:)` takes to return. That call includes
    /// `fullscreenState()`'s own 0.3 second debounce sleep. It also stops
    /// on the stance matching, not on `active` ever reading true.
    ///
    /// This method polls the raw, undebounced probe snapshot in its own
    /// loop instead. The two-reads-0.3-seconds-apart check in
    /// `fullscreenState()` avoids acting on a transient value. That check
    /// is correct for every other caller, but it inflates this latency
    /// number if used here.
    private func rotateMeasuringEngageMs(to orientation: UIDeviceOrientation, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> Int? {
        let start = Date()
        let wantStance = applyDeviceStance(orientation)
        let deadline = start.addingTimeInterval(timeout)
        repeat {
            if let reading = sampleFullscreenStateRaw(), reading.active, reading.stance == wantStance {
                return Int(Date().timeIntervalSince(start) * 1000)
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        XCTFail("fullscreen_state_ never read active with stance '\(wantStance)' within \(timeout)s of setting the device stance", file: file, line: line)
        return nil
    }

    /// Reads a single, undebounced
    /// "fullscreen_state_<active|inactive>_<stance>_<assetID>" identifier
    /// through `elementSnapshots(withPrefix:)`. Shared by
    /// `fullscreenState(timeout:)`, which debounces two reads 0.3 seconds
    /// apart, and `rotateMeasuringEngageMs(to:)`, which deliberately does
    /// not, so its latency number stays accurate.
    private func sampleFullscreenStateRaw() -> (active: Bool, stance: String, assetID: String)? {
        let prefix = "fullscreen_state_"
        guard let identifier = elementSnapshots(withPrefix: prefix).first?.identifier else { return nil }
        let body = identifier.dropFirst(prefix.count)
        let parts = body.split(separator: "_", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        let activeToken = parts[0]
        guard activeToken == "active" || activeToken == "inactive" else { return nil }
        return (activeToken == "active", String(parts[1]), String(parts[2]))
    }

    /// Reads "fullscreen_state_<active|inactive>_<stance>_<assetID>".
    /// Returns the value when two reads 0.3 s apart agree, like
    /// `centeredPage`, `poolTotal`, and `expectedNextSlot`. Returns nil
    /// after `timeout`.
    private func fullscreenState(timeout: TimeInterval = 8) -> (active: Bool, stance: String, assetID: String)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let firstRead = sampleFullscreenStateRaw() {
                Thread.sleep(forTimeInterval: 0.3)
                if let secondRead = sampleFullscreenStateRaw(),
                   secondRead.active == firstRead.active,
                   secondRead.stance == firstRead.stance,
                   secondRead.assetID == firstRead.assetID {
                    return secondRead
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline

        return nil
    }

    /// Reads "scrubber_probe_<isScrubbing>_<currentMs>_<durationMs>" as a
    /// single parsed sample, not debounced. Same parsing as
    /// `M5Tests.scrubberProbe`. `currentMs` republishes at the periodic
    /// time observer's rate of about 4Hz for a playing video. Requiring
    /// two samples to match can never succeed against a continuously
    /// moving playhead.
    private func scrubberReading(timeout: TimeInterval = 5) -> (scrubbing: Bool, currentMs: Int, durationMs: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let identifier = elementSnapshots(withPrefix: "scrubber_probe_").first?.identifier {
                let body = identifier.dropFirst("scrubber_probe_".count)
                let parts = body.split(separator: "_")
                if parts.count == 3,
                   let scrubbing = Bool(String(parts[0])),
                   let currentMs = Int(parts[1]),
                   let durationMs = Int(parts[2]) {
                    return (scrubbing, currentMs, durationMs)
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }

    /// The same `recordPages`-driven full-cycle search `M3ShrinkTests` and
    /// `M5Tests` use to find a seeded fixture. Swipes forward up to
    /// `budget` times, stopping once the centered page's asset is in
    /// `targets`.
    private func scrollToAsset(in targets: Set<String>, from start: Page, budget: Int) -> Page? {
        guard !targets.isEmpty else { return nil }
        var current = start
        if targets.contains(current.assetID) { return current }
        for _ in 0..<budget {
            let advanced = recordPages(swipes: 1, from: current)
            guard advanced.count == 2, let next = advanced.last else { return nil }
            current = next
            if targets.contains(current.assetID) { return current }
        }
        return nil
    }

    /// `xcodebuild` forwards any `TEST_RUNNER_`-prefixed variable to the
    /// test runner with the prefix stripped. Returns the comma-separated
    /// asset IDs in the environment variable `name`, trimmed, without
    /// empty entries. `M3ShrinkTests` and `M5Tests` each define this same
    /// helper.
    private func environmentAssetIDs(_ name: String) -> [String] {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The union of the three seeded 4K-landscape fixture groups:
    /// `hi_4k_1/2/3`, `hi_4k_hdr`, `lo_4k_efficient`. Five candidate assets
    /// give a single full-cycle search a wide margin. The test reads the
    /// IDs from the environment and does not hard-code them, because the
    /// seeded library can change.
    private func landscapeFixtureIDs() -> [String] {
        environmentAssetIDs("CLOUDFULL_SHRINKABLE_ASSET_IDS")
            + environmentAssetIDs("CLOUDFULL_HDR_ASSET_ID")
            + environmentAssetIDs("CLOUDFULL_INCOMPRESSIBLE_ASSET_ID")
    }

    private func known1080pAssetIDs() -> Set<String> {
        Set(environmentAssetIDs("CLOUDFULL_KNOWN_1080P_ASSET_IDS"))
    }
}
