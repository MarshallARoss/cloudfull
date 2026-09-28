//
//  M3ShrinkTests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// UI tests for the video shrink feature.
///
/// The tests prove: the shrink rail button is enabled only on above-1080p
/// videos, and stays present at all times. Cancel on its confirm sheet
/// starts no job. Confirming it queues the 4K original for deletion only after
/// the 1080p replacement is saved. The feed keeps scrolling while the export
/// runs in the background.
///
/// The suite needs seeded 4K clips, and one HDR clip, in the simulator's
/// Photos library. `rail_shrink` is never enabled on a library that holds
/// only 1080p-or-smaller video. Run `scripts/seed_m3.sh` before the suite.
/// The script adds the fixtures and prints the `TEST_RUNNER_CLOUDFULL_*` asset
/// ids this suite reads.
final class M3ShrinkTests: FeedUITestCase {

    /// `testShrinkQueuesOriginalAndKeepsScrolling` scrolls a full deck cycle
    /// to find a 4K page. `testShrinkDisabledForLiked` needs the same
    /// headroom afterward. `M2TrashTests` uses this same floor, for the same
    /// reason.
    private static let minimumPoolForShrinkTest = 25

    /// How long the shrink-success tests wait for the bin badge to increase
    /// by 1 after confirming a shrink. The wait covers the HEVC export, the
    /// PhotoKit save, the trash queue, and the badge refresh.
    ///
    /// Export time depends heavily on host load. The seeded fixture is a
    /// 4-second 4K H.264 clip (13,352,994 bytes, 26.7 Mbps). The export
    /// gives a 5,640,016-byte HEVC 1080p file. The export takes about 27 s
    /// on a quiet host and 34-38 s under moderate load. Under heavy
    /// contention — for example Chrome, a stuck `fileproviderd` iCloud sync,
    /// and Spotlight running together — the app can drop to about 0.6 of a
    /// core. The export temp file then grows at 3.4 KB/s instead of about
    /// 200 KB/s, and the same export can take roughly 20 minutes.
    ///
    /// 720s equals `ShrinkService.jobTimeoutNanoseconds` (600s) plus 120s of
    /// margin for the save, the queue, and the badge update. The app itself
    /// abandons an export after 10 minutes and marks the job `.failed`,
    /// which the `shrink_done` toast reports. A wait longer than this
    /// ceiling can never turn a failing run into a passing one. It can only
    /// make a failing run take longer to fail.
    ///
    /// A long wait does not hide a regression. Each refusal ends the job in
    /// `.doneOriginalKept` or `.failed`. Refusals include: a liked
    /// (shielded) asset, a resolver where `isDestructiveActionSafe` is
    /// false, an id already in the queue, a failed save, or a cancel.
    /// Each path reports through the toast and probe within seconds. Only a
    /// slow encode needs the extra time.
    private static let binQueueWaitSeconds: TimeInterval = 720

    /// Two 1080x1920 assets used to spot-check that `rail_shrink` is never
    /// enabled on a video that is already 1080p-or-smaller. `scripts/seed_m3.sh`
    /// adds them again before each run and supplies their ids through the
    /// environment, not as fixed UUIDs, because `M2TrashTests` can delete
    /// either asset. A fixed UUID
    /// for a deleted asset would make the spot check impossible to satisfy.
    private static var known1080pAssetIDs: Set<String> {
        let seeded = environmentAssetIDs("CLOUDFULL_KNOWN_1080P_ASSET_IDS")
        guard seeded.isEmpty else { return Set(seeded) }
        return [
            "AB606586-C412-4106-B579-62C50DEE8CAA/L0/001",
            "84C3F58D-5107-4533-8C55-94923149E6F6/L0/001",
        ]
    }

    /// The seeded HDR clip (libx265 10-bit HLG). `testShrinkHDRClipForVerification`
    /// uses it so the shell-level HDR-passthrough check (ffprobe on the saved
    /// replacement) always inspects this known asset, not the first 4K clip
    /// in the shuffled feed order.
    private static var knownHDRAssetID: String {
        environmentAssetIDs("CLOUDFULL_HDR_ASSET_ID").first
            ?? "36602F7D-CB54-4BAA-BAB6-40C9A4DB07B6/L0/001"
    }

    /// 4K clips seeded with high-entropy content, so a 1080p HEVC re-encode
    /// is far smaller and `ShrinkService`'s net-savings guard passes.
    private static var shrinkableAssetIDs: [String] {
        environmentAssetIDs("CLOUDFULL_SHRINKABLE_ASSET_IDS")
    }

    /// A 4K HEVC 10-bit clip of about 13.5 KB for 4 seconds. A 1080p
    /// re-encode of it is larger, so this asset tests the net-savings
    /// refusal path.
    private static var incompressibleAssetID: String? {
        environmentAssetIDs("CLOUDFULL_INCOMPRESSIBLE_ASSET_ID").first
    }

    /// The seed script supplies the asset ids. They are not hard-coded
    /// because `M2TrashTests` deletes 17 assets each run. Every fixture
    /// this suite uses is reseeded before the run and gets a fresh local
    /// identifier each time. `xcodebuild` forwards any `TEST_RUNNER_`-prefixed
    /// environment variable to the test runner, with the prefix stripped.
    private static func environmentAssetIDs(_ name: String) -> [String] {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Confirm / cancel / progress / exclusion

    func testShrinkQueuesOriginalAndKeepsScrolling() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }
        guard poolTotal >= Self.minimumPoolForShrinkTest else {
            XCTFail(
                "Pool below floor (\(poolTotal) < \(Self.minimumPoolForShrinkTest)): reseed the " +
                "simulator library (scripts/seed_m3.sh) and re-add the 4K/HDR seed clips before gating"
            )
            return
        }

        guard let start = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        var checkedKnown1080pIDs: Set<String> = []

        // A full deck cycle covers every pooled asset exactly once. The
        // search budget is the pool size plus at least 10 pages, the same
        // as `M1ExitTests`'s `recordingBudget`. If the feature works, the
        // search finds a seeded 4K clip.
        let searchBudget = poolTotal + max(10, poolTotal / 4)
        var current = start
        var swiped = 0
        var shrinkPage: Page?

        // Target a seeded high-entropy 4K clip, not the first page with
        // rail_shrink enabled. `ShrinkService` refuses a 4K clip whose
        // bitrate is already below the 1080p re-encode.
        // `testShrinkRefusesAlreadyEfficientClip` tests that refusal.
        let targets = Set(Self.shrinkableAssetIDs)
        guard !targets.isEmpty else {
            XCTFail("No CLOUDFULL_SHRINKABLE_ASSET_IDS supplied — reseed via scripts/seed_m3.sh before gating")
            return
        }

        spotCheckKnown1080p(current, into: &checkedKnown1080pIDs)
        if targets.contains(current.assetID) {
            shrinkPage = current
        }

        while shrinkPage == nil && swiped < searchBudget {
            guard let next = stepForward(from: current) else {
                XCTFail("Pager did not advance while searching for a seeded 4K clip (swipe #\(swiped))")
                return
            }
            current = next
            swiped += 1
            spotCheckKnown1080p(current, into: &checkedKnown1080pIDs)
            if targets.contains(current.assetID) {
                shrinkPage = current
            }
        }

        guard let shrinkPage else {
            XCTFail(
                "Never reached a seeded shrinkable 4K clip after \(swiped) swipes (pool \(poolTotal)) — " +
                "expected one of \(targets)"
            )
            return
        }
        let seededShrinkButton = app.buttons["rail_shrink"]
        XCTAssertTrue(
            seededShrinkButton.waitForExistence(timeout: 5),
            "rail_shrink is missing on seeded 4K clip \(shrinkPage.assetID)"
        )
        XCTAssertTrue(
            seededShrinkButton.isEnabled,
            "rail_shrink is not enabled on seeded 4K clip \(shrinkPage.assetID)"
        )
        let originalAssetID = shrinkPage.assetID
        let binLabelBeforeAnyAction = app.buttons["bin_open"].label

        // --- Cancel path: nothing changes. ---
        app.buttons["rail_shrink"].tap()
        XCTAssertTrue(app.buttons["shrink_confirm"].waitForExistence(timeout: 5), "Shrink confirm sheet did not appear")
        XCTAssertTrue(app.buttons["shrink_cancel"].exists, "Shrink confirm sheet is missing its cancel button")
        app.buttons["shrink_cancel"].tap()
        XCTAssertTrue(
            waitFor(timeout: 5) { !self.app.buttons["shrink_confirm"].exists },
            "Shrink confirm sheet did not dismiss after cancel"
        )
        XCTAssertFalse(element("shrink_progress").exists, "shrink_progress appeared after cancel — nothing should have started")
        XCTAssertEqual(
            app.buttons["bin_open"].label, binLabelBeforeAnyAction,
            "Bin badge changed after canceling the shrink sheet"
        )
        guard let stillCurrent = centeredPage(timeout: 5), stillCurrent.assetID == originalAssetID else {
            XCTFail("Page moved after canceling the shrink sheet")
            return
        }

        // --- Confirm path. ---
        // Read both baselines before the confirm tap. A short clip can
        // finish its export during the swipes below. A later read would
        // already include the queued original, so the +1 checks would
        // fail.
        let binCountBefore = binQueuedCount()
        guard let poolBefore = self.poolTotal(timeout: 15) else {
            XCTFail("poolTotal baseline read returned nil — the pool-recovery proof cannot be skipped")
            return
        }
        app.buttons["rail_shrink"].tap()
        XCTAssertTrue(app.buttons["shrink_confirm"].waitForExistence(timeout: 5), "Shrink confirm sheet did not reappear")
        app.buttons["shrink_confirm"].tap()

        XCTAssertTrue(
            element("shrink_progress").waitForExistence(timeout: 10),
            "shrink_progress badge did not appear after confirming the shrink"
        )

        // The feed must scroll while the export runs in the background.
        var duringJobPages: [Page] = [shrinkPage]
        var duringJobCurrent = shrinkPage
        for swipeIndex in 0..<3 {
            guard let next = stepForward(from: duringJobCurrent) else {
                XCTFail("Pager did not advance at swipe #\(swipeIndex) while the shrink job was running")
                return
            }
            duringJobCurrent = next
            duringJobPages.append(next)
            spotCheckKnown1080p(next, into: &checkedKnown1080pIDs)
        }
        XCTAssertEqual(duringJobPages.count, 4, "Did not record a page for every swipe while the shrink job ran")

        // The bin badge increases by 1 when the app queues the original.
        XCTAssertTrue(
            waitFor(timeout: Self.binQueueWaitSeconds) { self.binQueuedCount() == binCountBefore + 1 },
            "Bin count did not increment by 1 within \(Int(Self.binQueueWaitSeconds))s of confirming the shrink " +
            "(stuck at \(binQueuedCount()), expected \(binCountBefore + 1))"
        )

        // The bin badge alone does not prove a replacement was created. An
        // implementation that called the trash hand-off directly, without
        // exporting anything, would also satisfy the assertion above. The
        // pool count (library minus liked minus trash-queued) drops by 1
        // when the original is queued. It must return to the baseline when
        // the 1080p asset is saved. A skipped export leaves the count
        // permanently short by one.
        let recovered = waitForPoolTotal(toEqual: poolBefore, timeout: 30)
        XCTAssertEqual(
            recovered, poolBefore,
            "Pool total never returned to its pre-shrink baseline (\(poolBefore)) — " +
            "no replacement asset appears to have been created"
        )

        // The replacement must be a 1080p-class copy stamped with the
        // original's creation date, not merely some new asset. See
        // `FeedView`'s `shrinkVerificationProbe` doc comment for the
        // encoding.
        guard let verification = shrinkVerification(timeout: 15) else {
            XCTFail("shrink_verify_ probe never reported a completed job")
            return
        }
        XCTAssertEqual(verification.originalAssetID, originalAssetID, "shrink_verify_ probe reported a different job than the one this test triggered")
        assertExactShrinkDimensions(verification)
        XCTAssertTrue(verification.dateMatches, "Replacement asset's creationDate does not match the original's")

        // Keep scrolling. The shrunk original must never show again, and
        // the 2 known 1080p assets must still never have rail_shrink
        // enabled. This budget covers the rest of the first deck cycle.
        // Together with the search loop, every pooled asset appears once,
        // so the spot check sees both pinned 1080p ids.
        let remainingBudget = max(searchBudget - swiped, 10)
        var futurePages: [Page] = []
        var futureCurrent = duringJobCurrent
        for swipeIndex in 0..<remainingBudget {
            guard let next = stepForward(from: futureCurrent) else {
                XCTFail("Pager did not advance at swipe #\(swipeIndex) while confirming trash-exclusion")
                break
            }
            futureCurrent = next
            futurePages.append(next)
            spotCheckKnown1080p(next, into: &checkedKnown1080pIDs)
            // Do not exit early. Both 1080p ids can already be checked
            // before this loop starts. An early exit would shorten
            // futurePages, so the never-reappears assertion below would
            // check fewer pages.
        }

        XCTAssertFalse(
            futurePages.contains { $0.assetID == originalAssetID },
            "Shrunk original \(originalAssetID) reappeared in the feed after being queued: " +
            "\(futurePages.map(\.assetID))"
        )
        XCTAssertTrue(
            checkedKnown1080pIDs.isSuperset(of: Self.known1080pAssetIDs),
            "Never scrolled past both known 1080p pages to spot-check rail_shrink's disabled state " +
            "(saw \(checkedKnown1080pIDs), needed \(Self.known1080pAssetIDs))"
        )
    }

    // MARK: - Disabled for liked

    func testShrinkDisabledForLiked() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }
        guard poolTotal >= Self.minimumPoolForShrinkTest else {
            XCTFail(
                "Pool below floor (\(poolTotal) < \(Self.minimumPoolForShrinkTest)): reseed the " +
                "simulator library before gating"
            )
            return
        }

        guard let shrinkPage = findShrinkEligiblePage(poolTotal: poolTotal) else {
            XCTFail("rail_shrink never became enabled while searching for a 4K page to like")
            return
        }

        app.buttons["rail_like"].tap()
        XCTAssertTrue(
            waitFor(timeout: 5) {
                let button = self.app.buttons["rail_shrink"]
                return button.exists && !button.isEnabled
            },
            "rail_shrink is still enabled on \(shrinkPage.assetID) after liking it"
        )
    }

    // MARK: - Refusal path

    /// A 4K clip can already be smaller than any 1080p re-encode of it — for
    /// example, a static shot at a low bitrate. `ShrinkService` re-encodes
    /// the clip, finds the result is not at least 10% smaller, and refuses.
    /// It deletes the replacement and does not change the original. Saving
    /// the export and queuing the original for deletion would make the
    /// library larger and delete the better copy.
    func testShrinkRefusesAlreadyEfficientClip() throws {
        guard let targetID = Self.incompressibleAssetID else {
            XCTFail("No CLOUDFULL_INCOMPRESSIBLE_ASSET_ID supplied — reseed via scripts/seed_m3.sh before gating")
            return
        }

        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }
        guard var current = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        let budget = poolTotal + max(10, poolTotal / 4)
        var swiped = 0
        while current.assetID != targetID && swiped < budget {
            guard let next = stepForward(from: current) else {
                XCTFail("Pager did not advance while searching for the incompressible seed clip")
                return
            }
            current = next
            swiped += 1
        }
        guard current.assetID == targetID else {
            XCTFail("Never reached the incompressible seed clip (\(targetID)) after \(swiped) swipes")
            return
        }

        // The clip is above the 1080p class, so the button is enabled. The
        // app cannot know that the export gives no savings until it runs
        // the export.
        let incompressibleShrinkButton = app.buttons["rail_shrink"]
        XCTAssertTrue(
            incompressibleShrinkButton.waitForExistence(timeout: 5),
            "rail_shrink missing on the 4K incompressible seed clip"
        )
        XCTAssertTrue(
            incompressibleShrinkButton.isEnabled,
            "rail_shrink is not enabled on the 4K incompressible seed clip"
        )

        let binCountBefore = binQueuedCount()
        guard let poolBefore = self.poolTotal(timeout: 15) else {
            XCTFail("poolTotal baseline read returned nil — the pool-recovery proof cannot be skipped")
            return
        }

        app.buttons["rail_shrink"].tap()
        XCTAssertTrue(app.buttons["shrink_confirm"].waitForExistence(timeout: 5), "Shrink confirm sheet did not appear")
        app.buttons["shrink_confirm"].tap()

        // The failure must reach the user, not only the log.
        guard let message = shrinkToastMessage(timeout: 120) else {
            XCTFail("No shrink_done toast appeared within 120s — the refusal never surfaced in the UI")
            return
        }
        XCTAssertTrue(
            message.contains("already efficiently compressed"),
            "Expected the net-savings refusal, got: \(message)"
        )

        // The original must stay exactly as it was: not queued for
        // deletion, still pooled, still in the feed, and still offering
        // its own shrink button.
        XCTAssertEqual(
            binQueuedCount(), binCountBefore,
            "Bin count changed after a refused shrink — the original must not be queued"
        )
        XCTAssertEqual(
            self.poolTotal(timeout: 10), poolBefore,
            "Pool total changed after a refused shrink — nothing should have been added or removed"
        )
        guard let stillCurrent = centeredPage(timeout: 10) else {
            XCTFail("Feed lost its page after a refused shrink")
            return
        }
        XCTAssertEqual(
            stillCurrent.assetID, targetID,
            "Feed moved off the original after a refused shrink"
        )
        XCTAssertTrue(
            waitFor(timeout: 5) {
                let button = self.app.buttons["rail_shrink"]
                return button.exists && button.isEnabled
            },
            "rail_shrink did not re-enable after a refused shrink — a failed job must be retryable"
        )
    }

    // MARK: - HDR-passthrough verification support

    /// Shrinks the known HDR seed clip on every run. The shell-level
    /// ffprobe check of the saved 1080p replacement then always inspects
    /// the same asset.
    func testShrinkHDRClipForVerification() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }
        guard var current = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        let targetID = Self.knownHDRAssetID
        let budget = poolTotal + max(10, poolTotal / 4)
        var swiped = 0
        while current.assetID != targetID && swiped < budget {
            guard let next = stepForward(from: current) else {
                XCTFail("Pager did not advance while searching for the known HDR1 seed clip")
                return
            }
            current = next
            swiped += 1
        }
        guard current.assetID == targetID else {
            XCTFail("Never reached the known HDR1 seed clip (\(targetID)) after \(swiped) swipes")
            return
        }

        let hdrShrinkButton = app.buttons["rail_shrink"]
        XCTAssertTrue(hdrShrinkButton.waitForExistence(timeout: 5), "rail_shrink missing on the HDR1 seed clip")
        XCTAssertTrue(hdrShrinkButton.isEnabled, "rail_shrink is not enabled on the HDR1 seed clip")

        // Read the baselines before the confirm tap, as in
        // `testShrinkQueuesOriginalAndKeepsScrolling`. A short clip can
        // finish its export before a later read.
        let binCountBefore = binQueuedCount()
        guard let poolBefore = self.poolTotal(timeout: 15) else {
            XCTFail("poolTotal baseline read returned nil — the pool-recovery proof cannot be skipped")
            return
        }

        app.buttons["rail_shrink"].tap()
        XCTAssertTrue(app.buttons["shrink_confirm"].waitForExistence(timeout: 5), "Shrink confirm sheet did not appear for the HDR1 clip")
        app.buttons["shrink_confirm"].tap()

        XCTAssertTrue(
            element("shrink_progress").waitForExistence(timeout: 10),
            "shrink_progress badge did not appear for the HDR1 clip"
        )

        XCTAssertTrue(
            waitFor(timeout: Self.binQueueWaitSeconds) { self.binQueuedCount() == binCountBefore + 1 },
            "Bin count did not increment by 1 within \(Int(Self.binQueueWaitSeconds))s of shrinking the HDR1 clip"
        )

        // Same two checks as the main scenario. The pool count must return
        // to the baseline. This proves that the app saved a replacement and
        // did not only queue the original. The replacement must also be a
        // 1080p-class copy stamped with the original's date.
        let recovered = waitForPoolTotal(toEqual: poolBefore, timeout: 30)
        XCTAssertEqual(
            recovered, poolBefore,
            "Pool total never returned to its pre-shrink baseline (\(poolBefore)) for the HDR1 clip"
        )
        guard let verification = shrinkVerification(timeout: 15) else {
            XCTFail("shrink_verify_ probe never reported a completed job for the HDR1 clip")
            return
        }
        XCTAssertEqual(verification.originalAssetID, targetID, "shrink_verify_ probe reported a different job than the one this test triggered")
        assertExactShrinkDimensions(verification, context: "HDR1 ")
        XCTAssertTrue(verification.dateMatches, "HDR1 replacement asset's creationDate does not match the original's")
    }

    // MARK: - Helpers

    /// Swipes forward one page with `recordPages`, which retries and waits
    /// for the page to settle. `recordPages` already calls `XCTFail` if the
    /// pager does not move. Return `nil` without a second failure.
    private func stepForward(from current: Page) -> Page? {
        let pages = recordPages(swipes: 1, from: current)
        guard pages.count == 2 else { return nil }
        return pages[1]
    }

    /// `rail_shrink` is always present on the rail. This reads whether it
    /// is also enabled, meaning currently offered.
    private func isRailShrinkEnabled() -> Bool {
        let button = app.buttons["rail_shrink"]
        return button.exists && button.isEnabled
    }

    /// Scrolls until a page has `rail_shrink` enabled. A full-deck-cycle
    /// budget bounds the search: every pooled asset appears at least once
    /// within `poolTotal` pages.
    private func findShrinkEligiblePage(poolTotal: Int) -> Page? {
        guard var current = centeredPage(timeout: 20) else { return nil }
        if isRailShrinkEnabled() { return current }

        let budget = poolTotal + max(10, poolTotal / 4)
        for _ in 0..<budget {
            guard let next = stepForward(from: current) else { return nil }
            current = next
            if isRailShrinkEnabled() { return current }
        }
        return nil
    }

    /// If `page` is a pinned 1080p asset, asserts that `rail_shrink` exists
    /// and is disabled, then records the page. Check it now: the rail state
    /// of this page is in the accessibility tree only while the page is
    /// centered.
    private func spotCheckKnown1080p(_ page: Page, into checked: inout Set<String>) {
        guard Self.known1080pAssetIDs.contains(page.assetID) else { return }
        let button = app.buttons["rail_shrink"]
        XCTAssertTrue(
            button.exists,
            "rail_shrink is missing on known 1080p asset \(page.assetID) — it must always be present"
        )
        XCTAssertFalse(
            button.isEnabled,
            "rail_shrink is enabled on known 1080p asset \(page.assetID)"
        )
        checked.insert(page.assetID)
    }

    /// Any accessibility element, not only buttons, found by identifier.
    /// The progress badge is a plain `HStack`, not a control.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Waits for the `shrink_done` toast and returns its message. The toast
    /// hides after about 2.5 seconds, so this function polls. It reads the
    /// label from an atomic snapshot, because the element can disappear
    /// between a `waitForExistence` call and a `.label` read.
    private func shrinkToastMessage(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let snapshot = try? app.descendants(matching: .any)["shrink_done"].snapshot(),
               !snapshot.label.isEmpty {
                return snapshot.label
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return nil
    }

    /// Parses the digits out of `bin_open`'s label ("Trash" -> 0, "Trash, 3
    /// queued" -> 3). `M2TrashTests` reads the same label for its own badge
    /// count, but as a substring check instead of a number.
    private func binQueuedCount() -> Int {
        let digits = app.buttons["bin_open"].label.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    /// What `FeedView`'s DEBUG-only `shrink_verify_` probe reports about the
    /// most recently completed shrink job. It gives the original asset id
    /// and the replacement's pixel dimensions. It also gives a flag for
    /// whether the replacement's `creationDate` matches the original's.
    /// This lets the suite verify
    /// that the app saved a real 1080p replacement with the original's
    /// creation date. A badge check alone passes even if the export is
    /// skipped.
    private struct ShrinkVerification: Equatable {
        /// The asset that was shrunk. A caller uses this to confirm the
        /// reading belongs to the job it triggered, not to an earlier one.
        let originalAssetID: String
        /// The 1080p replacement the job saved.
        let newAssetID: String
        let width: Int
        let height: Int
        let dateMatches: Bool
        /// The source asset's own pixel dimensions, so the test can compute
        /// the exact expected replacement size. A looser "≤1080p-class"
        /// check, such as `min(w,h) > 0 && min(w,h) <= 1080 && max(w,h) <=
        /// 1920`, would accept a 640x360 replacement as a pass.
        let origW: Int
        let origH: Int
    }

    /// Reads and parses
    /// "shrink_verify_<originalID>_<newID>_<w>_<h>_<dateMatches>_<origW>_<origH>".
    /// Returns nil for "shrink_verify_none". Like `poolTotal` and
    /// `centeredPage`, it needs two equal reads 0.3 s apart. One read can
    /// see the accessibility tree during an update.
    private func shrinkVerification(timeout: TimeInterval = 10) -> ShrinkVerification? {
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> ShrinkVerification? {
            guard let identifier = elementSnapshots(withPrefix: "shrink_verify_").first?.identifier else { return nil }
            let body = identifier.dropFirst("shrink_verify_".count)
            guard body != "none" else { return nil }
            // Asset local identifiers contain no underscore, the same fact
            // `Page.parse` relies on, so the body splits cleanly into
            // exactly 7 underscore-separated fields: originalID, newID, w,
            // h, dateMatches, origW, and origH.
            let parts = body.split(separator: "_")
            guard parts.count == 7,
                  let width = Int(parts[2]),
                  let height = Int(parts[3]),
                  let dateMatches = Bool(String(parts[4])),
                  let origW = Int(parts[5]),
                  let origH = Int(parts[6]) else { return nil }
            return ShrinkVerification(
                originalAssetID: String(parts[0]),
                newAssetID: String(parts[1]),
                width: width,
                height: height,
                dateMatches: dateMatches,
                origW: origW,
                origH: origH
            )
        }

        repeat {
            if let firstRead = sample() {
                Thread.sleep(forTimeInterval: 0.3)
                if let secondRead = sample(), secondRead == firstRead {
                    return firstRead
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline

        return nil
    }

    /// Checks the exact size a correct shrink of `origW`x`origH` into the
    /// 1920x1080 box must produce, within 2px for the encoder's
    /// even-dimension rounding. A looser "≤1080p-class" check — accepting
    /// any replacement with `min(w,h) <= 1080 && max(w,h) <= 1920` — would
    /// also accept a 640x360 replacement. For the 3840x2160 seed fixtures,
    /// this demands exactly 1920x1080.
    private func assertExactShrinkDimensions(
        _ v: ShrinkVerification,
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // The code below computes `expectedLong` and `expectedShort` from
        // `v.origW` and `v.origH`. If the probe reported the replacement
        // size in those fields, this check would always pass. Every
        // fixture is 3840x2160 (checked by `probe_fixture` in
        // `scripts/seed_m3.sh`), so assert the source size first.
        XCTAssertEqual(v.origW, 3840, "\(context)shrink_verify_ reported source width \(v.origW), expected the known 3840x2160 seed fixture", file: file, line: line)
        XCTAssertEqual(v.origH, 2160, "\(context)shrink_verify_ reported source height \(v.origH), expected the known 3840x2160 seed fixture", file: file, line: line)

        let longSide = max(v.origW, v.origH)
        let shortSide = min(v.origW, v.origH)
        XCTAssertGreaterThan(longSide, 0, "shrink_verify_ reported no source dimensions", file: file, line: line)
        guard longSide > 0, shortSide > 0 else { return }
        let scale = min(1920.0 / Double(longSide), 1080.0 / Double(shortSide))
        let expectedLong = Int((Double(longSide) * scale).rounded())
        let expectedShort = Int((Double(shortSide) * scale).rounded())
        XCTAssertLessThanOrEqual(
            abs(max(v.width, v.height) - expectedLong), 2,
            "\(context)Replacement long side is \(max(v.width, v.height)), expected \(expectedLong) " +
            "from a \(v.origW)x\(v.origH) source",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            abs(min(v.width, v.height) - expectedShort), 2,
            "\(context)Replacement short side is \(min(v.width, v.height)), expected \(expectedShort)",
            file: file, line: line
        )
    }
}
