//
//  M12PaywallTests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// UI tests for the 1.1 free-download paywall: scrolling stays free, the
/// first rail tap under locked access raises a dismissable paywall, every
/// later rail tap or double tap (video or photo) reopens it, restoring or
/// un-queuing a video stays free even when locked, a lifetime unlock lets
/// every rail action through with no paywall, the Settings "Cloudfull"
/// section shows only the rows that apply to the current access state,
/// and Settings' own Unlock row raises the same paywall the rail does.
///
/// This class has exactly nine `func test…` methods. `scripts/gate_all.sh`
/// parses `Executed N tests` from the output, so this count is a
/// contract; adding or removing a method without updating that script's
/// expected count fails the gate.
///
/// Every test here fixes `Entitlements.access` for its own launch with the
/// DEBUG-only `-cloudfull-access=<token>` launch argument
/// (`CloudfullApp.accessArgument`), never the Settings "Access override"
/// picker (`settings_debug_access`), so each test is self-contained and
/// independent of whatever a previous test left behind.
///
/// `testLockedEmptyBinGates` proves the free-restore path through the
/// bin's own Restore button, not a second `rail_trash` tap on the queued
/// video in the feed. Once a video is queued for trash,
/// `DeckViewModel.removeFromFuture` records that video's own slot as a
/// drop exception immediately, before this test ever terminates the app.
/// Its own doc comment says why: "a relaunch resumes on the next video,
/// rather than on the one the user just shielded, which is the correct
/// outcome." So after the relaunch this test performs, the queued video
/// is never dealt into the feed again, and `rail_trash` can never land on
/// it there. `TrashService.restore(assetID:)` is the one function both
/// the bin's Restore button and the feed's own un-queue tap call — see
/// `FeedView.handleTrashTap`'s "Ungated: a lapsed subscriber may still
/// un-queue" comment — so proving the bin's Restore button is free proves
/// the same thing the feed's second tap would have.
final class M12PaywallTests: FeedUITestCase {

    // MARK: - 1. Locked scroll is free; the first rail tap gates

    func testLockedScrollIsFreeAndFirstRailTapShowsPaywall() throws {
        launch(resettingState: true, extraArguments: ["-cloudfull-access=none"])

        guard let first = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        // Scrolling itself is never gated.
        let pages = recordPages(swipes: 2, from: first)
        XCTAssertEqual(pages.count, 3, "The locked feed did not page normally for 2 free swipes")
        XCTAssertFalse(element("paywall_root").exists, "paywall_root appeared from scrolling alone, with no rail tap")

        // The first rail tap raises the paywall.
        app.buttons["rail_like"].tap()
        XCTAssertTrue(
            element("paywall_root").waitForExistence(timeout: 5),
            "paywall_root did not appear after the first rail_like tap under locked access"
        )
        let paywallShot = XCTAttachment(screenshot: app.screenshot())
        paywallShot.name = "paywall_locked_trial_eligible"
        paywallShot.lifetime = .keepAlways
        add(paywallShot)
        for id in ["paywall_monthly", "paywall_lifetime", "paywall_restore", "paywall_terms", "paywall_privacy", "paywall_close"] {
            XCTAssertTrue(element(id).waitForExistence(timeout: 5), "\(id) does not exist on the paywall")
        }

        closePaywall()
        XCTAssertNotNil(centeredPage(timeout: 5), "No centered feed page after closing the paywall")

        // The tap that raised the paywall never ran the wrapped action.
        XCTAssertFalse(
            app.buttons["rail_like"].isSelected,
            "rail_like reads kept even though the paywall was only closed, never bought through"
        )

        // Every later rail tap reopens it.
        app.buttons["rail_like"].tap()
        XCTAssertTrue(element("paywall_root").waitForExistence(timeout: 5), "paywall_root did not reappear on a second rail_like tap")
        closePaywall()
    }

    // MARK: - 2. Every rail action gates under locked access

    func testLockedEveryRailButtonGates() throws {
        launch(resettingState: true, extraArguments: ["-cloudfull-access=none"])

        guard var current = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }
        guard let poolTotal = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }

        func binLabel() -> String { app.buttons["bin_open"].label }

        // --- rail_share: no system share sheet. ---
        let binBeforeShare = binLabel()
        app.buttons["rail_share"].tap()
        XCTAssertTrue(element("paywall_root").waitForExistence(timeout: 5), "paywall_root did not appear after rail_share under locked access")
        closePaywall()
        // Lets the close animation fully settle before checking for a
        // share sheet that should never have been triggered at all —
        // otherwise this absence check can race the dismissal.
        _ = waitFor(timeout: 2) { false }
        XCTAssertFalse(app.otherElements["ActivityListView"].exists, "Share sheet (ActivityListView) appeared despite being locked")
        XCTAssertFalse(app.otherElements["share_sheet"].exists, "Share sheet (share_sheet) appeared despite being locked")
        XCTAssertFalse(app.collectionViews["ActivityListView"].exists, "Share sheet (collectionViews/ActivityListView) appeared despite being locked")
        XCTAssertEqual(binLabel(), binBeforeShare, "bin_open label changed after a gated rail_share tap")

        // --- rail_album: no album picker. ---
        let binBeforeAlbum = binLabel()
        app.buttons["rail_album"].tap()
        XCTAssertTrue(element("paywall_root").waitForExistence(timeout: 5), "paywall_root did not appear after rail_album under locked access")
        closePaywall()
        XCTAssertFalse(app.otherElements["album_picker_root"].exists, "album_picker_root appeared despite being locked")
        XCTAssertEqual(binLabel(), binBeforeAlbum, "bin_open label changed after a gated rail_album tap")

        // --- rail_shrink: no shrink confirm sheet. ---
        // Uses the same seeded 4K fixture ids `M3ShrinkTests` and
        // `M5Tests` key off (`CLOUDFULL_SHRINKABLE_ASSET_IDS`, forwarded
        // by `scripts/seed_m3.sh` through `gate_all.sh`), not a blind
        // "is rail_shrink enabled" scan: a page landed on by chance
        // could be a video just under the 4K threshold, which disables
        // the button for a reason unrelated to this gate. If the pool
        // truly holds none of the seeded ids, this fails loudly instead
        // of silently skipping the sub-check.
        // Outside the gate (a run by hand, with no
        // `CLOUDFULL_SHRINKABLE_ASSET_IDS` in the environment) the fallback
        // is the first page whose `rail_shrink` is enabled, which is the
        // app's own "this video can shrink" verdict.
        let shrinkCandidate = shrinkableAssetIDs().isEmpty
            ? findEnabledShrinkPage(from: current, poolTotal: poolTotal)
            : findSeededShrinkablePage(from: current, poolTotal: poolTotal)
        guard let shrinkPage = shrinkCandidate else {
            if shrinkableAssetIDs().isEmpty {
                // A run by hand on a pool whose shrinkable fixtures earlier
                // suites already shrank or deleted. Visible as a skip in the
                // result, never a silent pass. The gate always seeds first
                // and sets the env var, so it never takes this branch.
                throw XCTSkip("No shrinkable clip in this pool and no CLOUDFULL_SHRINKABLE_ASSET_IDS — reseed via scripts/seed_m3.sh to exercise the rail_shrink gate")
            }
            XCTFail(
                "Never reached a seeded shrinkable 4K clip (CLOUDFULL_SHRINKABLE_ASSET_IDS) — reseed via " +
                "scripts/seed_m3.sh before gating, or this run cannot exercise the rail_shrink gate"
            )
            return
        }
        current = shrinkPage
        let binBeforeShrink = binLabel()
        app.buttons["rail_shrink"].tap()
        XCTAssertTrue(element("paywall_root").waitForExistence(timeout: 5), "paywall_root did not appear after rail_shrink under locked access")
        closePaywall()
        XCTAssertFalse(app.buttons["shrink_confirm"].exists, "shrink_confirm sheet appeared despite being locked")
        XCTAssertEqual(binLabel(), binBeforeShrink, "bin_open label changed after a gated rail_shrink tap")

        // --- rail_trash: nothing gets queued. ---
        let binBeforeTrash = binLabel()
        app.buttons["rail_trash"].tap()
        XCTAssertTrue(element("paywall_root").waitForExistence(timeout: 5), "paywall_root did not appear after rail_trash under locked access")
        closePaywall()
        XCTAssertEqual(binLabel(), binBeforeTrash, "bin_open label changed after a gated rail_trash tap — a video was queued despite being locked")

        // --- photo_rail_trash: the same gate in Photos mode. ---
        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")
        XCTAssertTrue(element("photo_rail_trash").waitForExistence(timeout: 15), "No photo_rail_trash found in Photos — is a photo library seeded (scripts/seed_photos.sh)?")
        element("photo_rail_trash").tap()
        XCTAssertTrue(element("paywall_root").waitForExistence(timeout: 5), "paywall_root did not appear after photo_rail_trash under locked access")
        closePaywall()
    }

    // MARK: - 3. Emptying the bin gates while locked; restoring stays free

    func testLockedEmptyBinGates() throws {
        launch(resettingState: true)

        guard let first = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }
        let queuedID = first.assetID

        guard advance(from: first, afterPerforming: { self.app.buttons["rail_trash"].tap() }) != nil else {
            XCTFail("Pager did not advance after queuing \(queuedID) for trash")
            return
        }
        XCTAssertTrue(
            waitFor(timeout: 5) { self.app.buttons["bin_open"].label.contains("1") },
            "bin_open does not read 1 after queuing a video for trash"
        )

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before the locked relaunch")
        launch(resettingState: false, extraArguments: ["-cloudfull-access=none"])

        XCTAssertNotNil(centeredPage(timeout: 20), "Feed did not come back after the locked relaunch")
        XCTAssertTrue(
            waitFor(timeout: 10) { self.app.buttons["bin_open"].label.contains("1") },
            "bin_open does not still read 1 after the locked relaunch — the queued video did not survive"
        )

        app.buttons["bin_open"].tap()
        XCTAssertTrue(element("trash_empty").waitForExistence(timeout: 5), "Bin sheet did not open under locked access (opening the bin is not gated)")
        let restoreCell = app.buttons["trash_restore_\(queuedID)"]
        XCTAssertTrue(restoreCell.waitForExistence(timeout: 5), "Missing trash_restore_ cell for \(queuedID) after the locked relaunch")

        // --- Emptying the bin gates. ---
        app.buttons["trash_empty"].tap()
        XCTAssertTrue(
            element("paywall_root").waitForExistence(timeout: 5),
            "paywall_root did not appear after tapping trash_empty under locked access"
        )
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(
            springboard.alerts.buttons.matching(NSPredicate(format: "label CONTAINS 'Delete'")).firstMatch.waitForExistence(timeout: 2),
            "A system delete confirmation appeared even though access is locked — emptyBin() must never reach PhotoKit while gated"
        )
        closePaywall()

        // The bin sheet survives underneath the paywall's own full-screen cover.
        XCTAssertTrue(restoreCell.waitForExistence(timeout: 5), "Bin sheet lost its queued cell after closing the paywall")

        // --- Restoring stays free. See this file's own header comment for
        // why this uses the bin's Restore button rather than a second
        // rail_trash tap in the feed. ---
        restoreCell.tap()
        XCTAssertTrue(waitFor(timeout: 5) { !restoreCell.exists }, "\(queuedID) still shows a restore cell after restoring it")
        XCTAssertFalse(element("paywall_root").exists, "paywall_root appeared for a free restore")

        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        } else {
            app.swipeDown()
        }
        XCTAssertTrue(waitFor(timeout: 10) { !self.app.navigationBars["Bin"].exists }, "Bin sheet did not dismiss after restoring")
        XCTAssertTrue(
            waitFor(timeout: 10) { !self.app.buttons["bin_open"].label.contains("1") },
            "bin_open still reads 1 after restoring the only queued video"
        )
    }

    // MARK: - 4. Lifetime access: every rail action works, no paywall

    func testLifetimeRailWorks() throws {
        launch(resettingState: true, extraArguments: ["-cloudfull-access=lifetime"])

        guard centeredPage(timeout: 20) != nil else {
            XCTFail("No centered page_ element found at start")
            return
        }

        let likeButton = app.buttons["rail_like"]
        XCTAssertFalse(likeButton.isSelected, "Test precondition: the current video is already kept")

        likeButton.tap()
        XCTAssertTrue(waitFor(timeout: 5) { self.app.buttons["rail_like"].isSelected }, "rail_like did not become kept under lifetime access")
        XCTAssertFalse(element("paywall_root").exists, "paywall_root appeared for a lifetime-access keep")

        likeButton.tap()
        XCTAssertTrue(waitFor(timeout: 5) { !self.app.buttons["rail_like"].isSelected }, "rail_like did not return to unkept under lifetime access")
        XCTAssertFalse(element("paywall_root").exists, "paywall_root appeared for a lifetime-access unkeep")
    }

    // MARK: - 5. Settings shows only the rows that apply to each access state

    func testSettingsRowsPerState() throws {
        assertSettingsRows(
            accessToken: "none",
            mustExist: ["settings_access_status", "settings_unlock", "settings_restore", "settings_terms"],
            mustNotExist: ["settings_manage_subscription", "settings_buy_lifetime"]
        )
        assertSettingsRows(
            accessToken: "trial",
            // `settings_manage_subscription` depends on `hasLiveSubscription`,
            // real StoreKit subscription-status facts, not the debug
            // override, so this intentionally does not assert on it either
            // way under `trial`.
            mustExist: ["settings_buy_lifetime"],
            mustNotExist: ["settings_unlock"]
        )
        assertSettingsRows(
            accessToken: "lifetime",
            mustExist: ["settings_restore", "settings_terms"],
            mustNotExist: ["settings_unlock", "settings_buy_lifetime"]
        )
    }

    // MARK: - 6. Locked photo keep and double-tap-to-keep both gate

    func testLockedPhotoKeepAndDoubleTapGate() throws {
        launch(resettingState: true, extraArguments: ["-cloudfull-access=none"])

        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")
        XCTAssertTrue(element("photo_rail_like").waitForExistence(timeout: 15), "No photo_rail_like found in Photos — is a photo library seeded (scripts/seed_photos.sh)?")

        element("photo_rail_like").tap()
        XCTAssertTrue(element("paywall_root").waitForExistence(timeout: 5), "paywall_root did not appear after photo_rail_like under locked access")
        closePaywall()
        XCTAssertFalse(element("photo_rail_like").isSelected, "photo_rail_like reads kept after a gated tap")

        doubleTapCurrentPhotoPost()
        XCTAssertTrue(element("paywall_root").waitForExistence(timeout: 5), "paywall_root did not appear after double-tapping the current photo under locked access")
        closePaywall()
        XCTAssertFalse(element("photo_rail_like").isSelected, "photo_rail_like reads kept after a gated double tap")
    }

    // MARK: - 7. Locked video double-tap-to-keep gates

    func testLockedVideoDoubleTapGates() throws {
        launch(resettingState: true, extraArguments: ["-cloudfull-access=none"])

        guard centeredPage(timeout: 20) != nil else {
            XCTFail("No centered page_ element found at start")
            return
        }
        XCTAssertFalse(app.buttons["rail_like"].isSelected, "Test precondition: the current video is already kept")

        // Same stage point `M5Tests.testScrubSeeksWithoutBreakingTapToMute`
        // taps for tap-to-mute: the video player fills this point, and a
        // double tap there is the only way to trigger
        // `FeedView.keepFromDoubleTap()`.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).doubleTap()

        XCTAssertTrue(element("paywall_root").waitForExistence(timeout: 5), "paywall_root did not appear after a double tap under locked access")
        closePaywall()
        XCTAssertFalse(app.buttons["rail_like"].isSelected, "rail_like reads kept after a gated double tap")
    }

    // MARK: - 8. Settings' own Unlock row opens the paywall

    func testSettingsUnlockOpensPaywall() throws {
        launch(resettingState: true, extraArguments: ["-cloudfull-access=none"])

        selectChinNavTab("chin_nav_settings")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_settings") }, "mode_settings did not appear")
        XCTAssertTrue(scrollUntilVisible("settings_unlock"), "settings_unlock does not exist in Settings under locked access")

        element("settings_unlock").tap()
        XCTAssertTrue(element("paywall_root").waitForExistence(timeout: 5), "paywall_root did not appear after tapping settings_unlock")
        let paywallShot = XCTAttachment(screenshot: app.screenshot())
        paywallShot.name = "paywall_from_settings"
        paywallShot.lifetime = .keepAlways
        add(paywallShot)
        closePaywall()
        XCTAssertTrue(element("settings_root").waitForExistence(timeout: 5), "settings_root did not reappear after closing the paywall raised from Settings")
    }

    // MARK: - 9. The paywall at the largest accessibility text size

    /// Proves the paywall survives Dynamic Type at its largest
    /// accessibility size: the price rows, the purchase buttons, the
    /// close button and the link row all exist, and the screen scrolls to
    /// reach the link row. The screenshot attachment is the evidence for
    /// the price-prominence check.
    func testPaywallAtLargestAccessibilityTextSize() throws {
        launch(resettingState: true, extraArguments: [
            "-cloudfull-access=none",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        XCTAssertNotNil(centeredPage(timeout: 10), "No centered feed page")
        app.buttons["rail_like"].tap()
        XCTAssertTrue(element("paywall_root").waitForExistence(timeout: 5), "paywall_root did not appear at AX text size")
        for id in ["paywall_close", "paywall_monthly", "paywall_lifetime"] {
            XCTAssertTrue(element(id).waitForExistence(timeout: 5), "\(id) does not exist at AX text size")
        }
        let top = XCTAttachment(screenshot: app.screenshot())
        top.name = "paywall_ax_top"
        top.lifetime = .keepAlways
        add(top)
        var swipes = 6
        while !element("paywall_restore").exists && swipes > 0 {
            element("paywall_root").swipeUp()
            swipes -= 1
        }
        XCTAssertTrue(element("paywall_restore").waitForExistence(timeout: 3), "paywall_restore not reachable by scrolling at AX text size")
        XCTAssertTrue(element("paywall_support_page").exists, "paywall_support_page missing at AX text size")
        let bottom = XCTAttachment(screenshot: app.screenshot())
        bottom.name = "paywall_ax_bottom"
        bottom.lifetime = .keepAlways
        add(bottom)
        swipes = 6
        while !element("paywall_close").isHittable && swipes > 0 {
            element("paywall_root").swipeDown()
            swipes -= 1
        }
        closePaywall()
    }

    // MARK: - Photo double-tap helpers

    /// The current photo post's own frame, in screen coordinates — the
    /// same containment-or-largest-visible rule `M11Tests`'s identical
    /// private `currentPhotoPostFrame`/`centeredPhotoPage` use, trimmed to
    /// what this file needs: a point to double-tap, not a parsed page.
    private func currentPhotoPostFrame() -> CGRect? {
        let centerY = app.frame.midY
        let candidates = elementSnapshots(withPrefix: "photo_page_").filter { $0.frame.height > 0 }
        if let containing = candidates.first(where: { $0.frame.minY <= centerY && centerY <= $0.frame.maxY }) {
            return containing.frame
        }
        return candidates.max(by: { photoVisibleHeight($0.frame) < photoVisibleHeight($1.frame) })?.frame
    }

    private func photoVisibleHeight(_ frame: CGRect) -> CGFloat {
        let screenTop = app.frame.minY
        let screenBottom = app.frame.maxY
        return max(0, min(frame.maxY, screenBottom) - max(frame.minY, screenTop))
    }

    /// Double-taps the current photo post in its middle band, below the
    /// header and above the caption — the same band
    /// `M11Tests.tapCurrentPhoto(fraction:)` uses for its own default
    /// single tap.
    private func doubleTapCurrentPhotoPost() {
        guard let frame = currentPhotoPostFrame() else {
            XCTFail("Could not find the current photo_page_ frame to double-tap")
            return
        }
        let point = CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.4)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).doubleTap()
    }

    // MARK: - Settings helpers

    private func assertSettingsRows(accessToken: String, mustExist: [String], mustNotExist: [String]) {
        launch(resettingState: true, extraArguments: ["-cloudfull-access=\(accessToken)"])

        selectChinNavTab("chin_nav_settings")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_settings") }, "mode_settings did not appear for access=\(accessToken)")
        XCTAssertTrue(element("settings_root").waitForExistence(timeout: 5), "settings_root does not exist for access=\(accessToken)")

        let settingsShot = XCTAttachment(screenshot: app.screenshot())
        settingsShot.name = "settings_\(accessToken)"
        settingsShot.lifetime = .keepAlways
        add(settingsShot)

        // Absence checks run first, each its own top-to-bottom sweep. A
        // row that does not exist anywhere must be asserted while
        // scrolling past every position it could have rendered at, not
        // only once at the final scroll position — see
        // `assertNeverVisibleWhileScrollingToBottom`'s own comment.
        for id in mustNotExist {
            scrollSettingsToTop()
            assertNeverVisibleWhileScrollingToBottom(id, context: "access=\(accessToken)")
        }

        // Existence checks run afterward, in top-to-bottom layout order, so
        // one forward-only scroll pass finds each in turn without ever
        // needing to scroll back up.
        scrollSettingsToTop()
        for id in mustExist {
            XCTAssertTrue(scrollUntilVisible(id), "\(id) does not exist in Settings for access=\(accessToken)")
        }
    }

    /// Scrolls `settings_root` back toward the top in bounded steps. Safe
    /// to call when already at the top; a `List` simply stops moving.
    private func scrollSettingsToTop() {
        let root = element("settings_root")
        for _ in 0..<10 {
            root.swipeDown()
        }
    }

    /// Scrolls `settings_root` down in bounded steps until `id` appears, or
    /// gives up. Mirrors `M11Tests.testSettingsOpensFromChinNav`'s own
    /// `settings_version` scroll loop: an off-screen row in a scroll view
    /// reports as not existing, so a row below the fold needs this instead
    /// of one plain `waitForExistence`.
    @discardableResult
    private func scrollUntilVisible(_ id: String, maxSwipes: Int = 8) -> Bool {
        let target = element(id)
        var swipesLeft = maxSwipes
        while !target.waitForExistence(timeout: 1) && swipesLeft > 0 {
            element("settings_root").swipeUp()
            swipesLeft -= 1
        }
        return target.waitForExistence(timeout: 2)
    }

    /// Scrolls `settings_root` from the top down to the bottom
    /// (`settings_version`), asserting at every step that `id` never
    /// exists. A single check at the final scroll position cannot tell "
    /// this row never renders" apart from "this row rendered earlier and
    /// then scrolled out of view" — an off-screen row in a scroll view
    /// also reports as not existing. Scrolling in from the top and
    /// checking after every step rules that confusion out.
    private func assertNeverVisibleWhileScrollingToBottom(_ id: String, maxSwipes: Int = 10, context: String) {
        let target = element(id)
        XCTAssertFalse(target.exists, "\(id) exists in Settings for \(context)")
        let version = element("settings_version")
        var swipesLeft = maxSwipes
        while !version.waitForExistence(timeout: 1) && swipesLeft > 0 {
            element("settings_root").swipeUp()
            swipesLeft -= 1
            XCTAssertFalse(target.exists, "\(id) appeared partway through scrolling Settings for \(context)")
        }
    }

    // MARK: - Paywall helpers

    /// Taps `paywall_close` and waits for `paywall_root` to dismiss.
    private func closePaywall() {
        let close = element("paywall_close")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "paywall_close did not appear")
        close.tap()
        XCTAssertTrue(waitFor(timeout: 5) { !self.element("paywall_root").exists }, "paywall_root did not dismiss after tapping paywall_close")
    }

    // MARK: - Rail-shrink search

    /// Swipes one page forward, using `recordPages`'s own retry and settle
    /// discipline. Mirrors `M5Tests`'s own private helper of the same
    /// name — each class defines its own copy, the pattern `M5Tests`'s
    /// header comment describes, so `FeedUITestCase` keeps a small shared
    /// surface.
    private func stepForward(from current: Page) -> Page? {
        let pages = recordPages(swipes: 1, from: current)
        guard pages.count == 2 else { return nil }
        return pages[1]
    }

    /// `CLOUDFULL_SHRINKABLE_ASSET_IDS`, comma-separated — the same
    /// env var `M3ShrinkTests` and `M5Tests` read. Empty outside
    /// `scripts/gate_all.sh` (a standalone `xcodebuild test` invocation
    /// never sets it), in which case `findSeededShrinkablePage` below
    /// returns `nil` and the caller fails with a clear message, per this
    /// file's own instructions — not a silent skip.
    private func shrinkableAssetIDs() -> [String] {
        guard let raw = ProcessInfo.processInfo.environment["CLOUDFULL_SHRINKABLE_ASSET_IDS"] else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Searches forward from `start` for one of the seeded shrinkable 4K
    /// clips, swiping up to a full pool cycle. Mirrors
    /// `M5Tests.findSeededShrinkablePage` exactly.
    private func findSeededShrinkablePage(from start: Page, poolTotal: Int) -> Page? {
        let targets = Set(shrinkableAssetIDs())
        guard !targets.isEmpty else { return nil }
        if targets.contains(start.assetID) { return start }
        var current = start
        let budget = poolTotal + max(10, poolTotal / 4)
        for _ in 0..<budget {
            guard let next = stepForward(from: current) else { return nil }
            current = next
            if targets.contains(current.assetID) { return current }
        }
        return nil
    }

    /// Fallback for a run outside the gate: the first page, from `start`
    /// forward, whose `rail_shrink` button is enabled.
    private func findEnabledShrinkPage(from start: Page, poolTotal: Int) -> Page? {
        var current = start
        let budget = poolTotal + max(10, poolTotal / 4)
        for _ in 0..<budget {
            let shrink = app.buttons["rail_shrink"]
            if shrink.waitForExistence(timeout: 2), shrink.isEnabled { return current }
            guard let next = stepForward(from: current) else { return nil }
            current = next
        }
        return nil
    }

    // MARK: - Chin nav (own copy — see `M11Tests`'s identical private helpers)

    /// Any accessibility element by identifier, not only a `.buttons[]`
    /// one. Several controls this suite reads (the paywall's `Link`-backed
    /// rows, the chin nav markers, `photo_rail_trash`) are not guaranteed
    /// to be `Button`s.
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// Existence read off one atomic `snapshot()`, not a live query. See
    /// `FeedUITestCase.elementSnapshots`'s own doc comment.
    private func snapshotExists(_ id: String) -> Bool {
        elementSnapshots(withPrefix: id).contains { $0.identifier == id }
    }

    private func expandChinNav() {
        guard !snapshotExists("chin_nav_expanded") else { return }
        element("chin_nav_button").tap()
        _ = waitFor(timeout: 5) { self.snapshotExists("chin_nav_expanded") }
    }

    private func selectChinNavTab(_ id: String) {
        expandChinNav()
        let tab = element(id)
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(id) did not appear in the expanded chin nav")
        tab.tap()
        _ = waitFor(timeout: 5) { !self.snapshotExists("chin_nav_expanded") }
    }
}
