//
//  M2TrashTests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// Tests for the trash flow: queue deletes, restore some, empty the bin
/// with exactly one system confirmation, and never show a liked video
/// again.
///
/// Emptying the bin really deletes simulator videos through PhotoKit. That
/// is the point of the test, not a side effect to work around. Every
/// count here comes live from the app's "pool_total_<n>" probe; the test
/// never assumes a count. If the pool ever falls below this suite's
/// minimum, reseed the simulator library with more videos through
/// `simctl addmedia` instead of lowering the minimum.
final class M2TrashTests: FeedUITestCase {

    /// `testTrashQueueRestoreEmpty` queues 20 and needs headroom left over
    /// afterward, so it refuses to run against a thin library rather than
    /// silently asserting something weaker.
    private static let minimumPoolForTrashTest = 25

    func testTrashQueueRestoreEmpty() throws {
        launch(resettingState: true)

        guard let initialPool = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }
        guard initialPool >= Self.minimumPoolForTrashTest else {
            XCTFail(
                "Pool below floor (\(initialPool) < \(Self.minimumPoolForTrashTest)): reseed the " +
                "simulator library before gating (scratchpad/videos + reseed.sh)"
            )
            return
        }

        guard var current = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        // Trash 20 different pages. Record each asset ID before the tap,
        // and check that the pager advances, as `recordPages` does for
        // swipes.
        var trashedIDs: [String] = []
        for tapIndex in 0..<20 {
            let beforeID = current.assetID
            guard let next = advance(from: current, afterPerforming: {
                self.app.buttons["rail_trash"].tap()
            }) else {
                XCTFail("Pager did not advance after tapping rail_trash on tap #\(tapIndex) (asset \(beforeID))")
                return
            }
            trashedIDs.append(beforeID)
            current = next
        }

        XCTAssertEqual(trashedIDs.count, 20, "Did not complete 20 trash taps")
        XCTAssertEqual(Set(trashedIDs).count, 20, "Trash taps did not land on 20 distinct pages: \(trashedIDs)")

        // Bin badge and space counter, still on the feed.
        let binButton = app.buttons["bin_open"]
        XCTAssertTrue(binButton.waitForExistence(timeout: 5), "bin_open control not found")
        XCTAssertTrue(
            binButton.label.contains("20"),
            "Bin badge did not show 20 queued items; label was '\(binButton.label)'"
        )
        XCTAssertTrue(
            app.staticTexts["space_counter"].exists,
            "space_counter chip did not appear once items were queued"
        )

        binButton.tap()
        XCTAssertTrue(app.buttons["trash_empty"].waitForExistence(timeout: 5), "Trash sheet did not open")
        XCTAssertEqual(restoreCellCount(), 20, "Trash grid did not show 20 queued cells")

        // Restore 3 specific assets: first, middle, and last of the ones
        // queued, to prove restore is not order-dependent.
        let toRestore = [trashedIDs[0], trashedIDs[9], trashedIDs[19]]
        for assetID in toRestore {
            let restoreButton = app.buttons["trash_restore_\(assetID)"]
            XCTAssertTrue(restoreButton.waitForExistence(timeout: 5), "Missing trash_restore_ cell for \(assetID)")
            restoreButton.tap()
            XCTAssertTrue(
                waitFor(timeout: 5) { !restoreButton.exists },
                "\(assetID) still shows a restore cell after restoring it"
            )
        }
        XCTAssertEqual(restoreCellCount(), 17, "Trash grid did not drop to 17 cells after 3 restores")

        // Empty the bin. SpringBoard owns the confirmation, a real system
        // dialog, not the app.
        app.buttons["trash_empty"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "No system delete confirmation appeared")
        XCTAssertEqual(
            springboard.alerts.count, 1,
            "Expected exactly one system confirm dialog, found \(springboard.alerts.count)"
        )

        let deleteButton = alert.buttons.matching(NSPredicate(format: "label CONTAINS 'Delete'")).firstMatch
        XCTAssertTrue(deleteButton.exists, "No destructive 'Delete' button found in the confirm dialog")
        deleteButton.tap()

        // Exactly one dialog for the whole 17-item batch. The app must
        // show one system confirmation total, not one per asset, so
        // nothing should reappear after this tap.
        XCTAssertFalse(
            springboard.alerts.firstMatch.waitForExistence(timeout: 3),
            "A second system dialog appeared — batch delete should show exactly one confirmation"
        )

        // The bin does not auto-dismiss after Empty. It stays open,
        // showing the freed message and the reclaimed pill, until Done or
        // a swipe closes it (`TrashView.performEmpty`). Wait for the grid
        // to report empty inside the still-open sheet. Then dismiss it
        // explicitly, the same way `M5Tests` does after a restore. Do
        // this before reading anything that lives behind the sheet.
        XCTAssertTrue(
            app.descendants(matching: .any)["trash_empty_state"].waitForExistence(timeout: 25),
            "trash_empty_state did not appear in the bin sheet after emptying"
        )
        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        } else {
            app.swipeDown()
        }
        XCTAssertTrue(
            waitFor(timeout: 10) { !self.app.buttons["trash_empty"].exists },
            "Bin sheet did not dismiss after Done"
        )

        // Bin count reaches 0: the space chip (gated on the same count)
        // disappears once the sheet closes.
        XCTAssertTrue(
            waitFor(timeout: 10) { !self.app.staticTexts["space_counter"].exists },
            "space_counter chip did not disappear after emptying the bin"
        )

        // pool_total must drop by exactly 17 (20 queued, 3 restored). This
        // checks the count only. The disappearing `trash_restore_<id>`
        // cells already proved which assets the test restored. Wait for
        // the count because PhotoKit deletes asynchronously.
        let expectedPool = initialPool - 17
        let finalPool = waitForPoolTotal(toEqual: expectedPool, timeout: 25)
        XCTAssertEqual(
            finalPool, expectedPool,
            "pool_total did not settle at \(expectedPool) (started at \(initialPool)) after emptying the bin"
        )
    }

    /// Proves that a like removes the video from the pool, disables trash
    /// on it, and keeps it out of the feed for more than one full
    /// reshuffle.
    func testLikeShieldsAndExcludes() throws {
        launch(resettingState: true)

        guard let start = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }
        let likedID = start.assetID

        guard let poolBeforeLike = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }

        app.buttons["rail_like"].tap()

        let poolAfterLike = poolBeforeLike - 1
        let observedPool = waitForPoolTotal(toEqual: poolAfterLike, timeout: 10)
        XCTAssertEqual(observedPool, poolAfterLike, "pool_total did not drop by 1 after liking \(likedID)")

        // A like shields the page: the trash rail is off on this very
        // page, so a tap on it must queue nothing.
        app.buttons["rail_trash"].tap()
        XCTAssertFalse(
            app.staticTexts["space_counter"].exists,
            "space_counter appeared — a liked video was queued for trash"
        )

        let binButton = app.buttons["bin_open"]
        XCTAssertTrue(binButton.waitForExistence(timeout: 5), "bin_open control not found")
        binButton.tap()
        XCTAssertTrue(app.buttons["trash_empty"].waitForExistence(timeout: 5), "Trash sheet did not open")
        XCTAssertEqual(restoreCellCount(), 0, "Trash grid is not empty after tapping trash on a liked, shielded video")
        app.buttons["Done"].tap()
        XCTAssertTrue(
            waitFor(timeout: 5) { !self.app.buttons["trash_empty"].exists },
            "Trash sheet did not dismiss"
        )

        guard let stillCurrent = centeredPage(timeout: 5) else {
            XCTFail("Lost the centered page after checking the shield")
            return
        }
        XCTAssertEqual(stillCurrent.assetID, likedID, "Liked page moved after a disabled trash tap")

        // Swipe through poolAfterLike + 3 pages: comfortably more than one
        // full reshuffle cycle at the new, smaller pool size. If the liked
        // video were still in rotation, it would have reappeared by now.
        let pages = recordPages(swipes: poolAfterLike + 3, from: stillCurrent)
        let subsequent = pages.dropFirst() // pages[0] is the liked page itself, not a reappearance.
        XCTAssertFalse(
            subsequent.contains { $0.assetID == likedID },
            "Liked video \(likedID) reappeared in the feed: \(subsequent.map(\.assetID))"
        )
    }

    // MARK: - Helpers

    /// Number of `trash_restore_<id>` cells currently in the accessibility
    /// tree — the trash grid's own count, independent of any label text.
    private func restoreCellCount() -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'trash_restore_'"))
            .count
    }
}
