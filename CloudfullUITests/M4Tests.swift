//
//  M4Tests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// Tests that the rail's share button opens the system share sheet
/// without disturbing the feed. Tests that "Add to Album" writes into
/// the photo library. Tests that a newly created album is pinned for
/// one open after creation. Tests that the "added to album" callout
/// clears on scroll. Tests that the launch-time `cloudKey` backfill
/// accounts for every row it sees, on this launch and on the next one.
///
/// No test hard-codes an asset id. `M2TrashTests` permanently deletes
/// videos on every run, so every asset this suite uses comes from
/// `centeredPage()`. The backfill test does not need an iCloud account.
/// It compares the backfill `total` with an independent store count and
/// checks `resolved + pending == total`. It does not assert a value for
/// `resolved`.
final class M4Tests: FeedUITestCase {

    /// None of these tests scroll a full deck cycle, so the floor can stay
    /// low. 5 gives enough headroom for three swipes, one like, and one
    /// trash tap. Below this floor, the test fails with an instruction to
    /// reseed the library instead of asserting something weaker.
    private static let minimumPoolForM4 = 5

    /// A seeding-only launch for `testCloudKeyBackfillAccountsForEveryRow`.
    /// Uses the same reset flag as `launch(resettingState: true)`, plus
    /// `-cloudfull-suppress-backfill`. This guarantees every `SeenEntry`,
    /// `LikedEntry`, and `TrashEntry` row this process writes still reads
    /// `cloudKey == nil` when the process terminates.
    ///
    /// This method duplicates the two lines of
    /// `FeedUITestCase.launch(resettingState:)`. That method replaces
    /// `app.launchArguments`, so this method sets the arguments itself.
    /// The app starts its backfill 2 seconds after launch. Without
    /// `-cloudfull-suppress-backfill`, that backfill can resolve seeded
    /// rows before termination, and the relaunch reads a
    /// non-deterministic row count.
    private func launchForBackfillSeeding() {
        app.launchArguments = ["-cloudfull-reset-deck-state", "-cloudfull-suppress-backfill"]
        app.launch()
        grantPhotoAccessIfAsked()
    }

    // MARK: - Share sheet appears and dismisses cleanly

    func testShareSheetAppearsAndDismisses() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }
        guard poolTotal >= Self.minimumPoolForM4 else {
            XCTFail(
                "Pool below floor (\(poolTotal) < \(Self.minimumPoolForM4)): reseed the " +
                "simulator library before gating"
            )
            return
        }

        guard let start = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        XCTAssertEqual(
            shareProbeReading(timeout: 5), "share_probe_idle",
            "share_probe_ did not read idle before tapping rail_share"
        )

        let binLabelBefore = app.buttons["bin_open"].label
        let presentedCountBefore = sharePresentationCount(timeout: 5)
        XCTAssertEqual(presentedCountBefore, 0, "The app had already presented a share sheet before this test tapped anything")

        app.buttons["rail_share"].tap()

        waitForSystemShareSheet(timeout: 20)

        dismissShareSheet()

        XCTAssertEqual(
            shareProbeReading(timeout: 10), "share_probe_idle",
            "share_probe_ never returned to idle after dismissing the share sheet"
        )

        // This is the second of two independent signals that the tap
        // worked. The system sheet was really on screen (checked above).
        // The app itself also reports presenting exactly one sheet for
        // that one tap (checked here). An app that lost the tap leaves
        // this count at 0. An app that only changed its own state, without
        // presenting anything, cannot also pass `waitForSystemShareSheet`.
        //
        // This check reads the count after the dismissal, off a latched
        // value. It does not poll `share_probe_` for a non-idle reading
        // while the sheet is up, because that reading is not observable.
        // Both non-idle readings occur in a short window after the
        // activity controller removes FeedView from the accessibility
        // tree.
        //
        // In instrumented runs, `.preparing` lasts about 17 ms because the
        // app resolves a local original without copying it. The app sets
        // `.presented` about 140 ms before UIKit starts the presentation.
        // `XCUIElement.tap()` does not return until the app is quiescent,
        // about 60 ms after the presentation begins. A poll at that moment
        // reads a snapshot with no `page_`, `rail_`, or `share_probe_`
        // element, so the probe appears to vanish instead of change.
        // Whether the 1x1-point probe is still in the tree at that moment
        // depends on a margin of about 20 ms.
        XCTAssertEqual(
            sharePresentationCount(timeout: 10), 1,
            "The app does not report presenting exactly one share sheet for the one rail_share tap"
        )
        XCTAssertTrue(
            app.buttons["rail_share"].isHittable,
            "rail_share is not hittable after dismissing the share sheet"
        )
        XCTAssertEqual(
            centeredPage(timeout: 10)?.assetID, start.assetID,
            "Sharing moved the pager off the page it was opened from"
        )
        XCTAssertEqual(
            app.buttons["bin_open"].label, binLabelBefore,
            "Sharing queued something into the bin"
        )
    }

    // MARK: - Add current video to a new album

    func testAddCurrentVideoToNewAlbum() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }
        guard poolTotal >= Self.minimumPoolForM4 else {
            XCTFail(
                "Pool below floor (\(poolTotal) < \(Self.minimumPoolForM4)): reseed the " +
                "simulator library before gating"
            )
            return
        }

        guard let page = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        // The name is unique on every run, so a leftover album from a
        // previous run never collides. `-cloudfull-purge-test-albums`
        // (handled in `CloudKeyBackfillLauncher`) deletes albums titled
        // "Cloudfull UITest ". `scripts/purge_albums.sh` launches the app
        // with that argument to clear leftover test albums.
        let albumName = "Cloudfull UITest " + String(UUID().uuidString.prefix(8))
        let binLabelBefore = app.buttons["bin_open"].label

        app.buttons["rail_share"].tap()
        waitForSystemShareSheet(timeout: 20)
        tapAddToAlbumActivity()

        XCTAssertTrue(
            app.otherElements["album_picker_root"].waitForExistence(timeout: 10),
            "album_picker_root did not appear after picking 'Add to Album'"
        )

        app.buttons["album_picker_new"].tap()
        guard let field = newAlbumNameField(timeout: 5) else {
            XCTFail("Neither album_picker_new_name_field nor a fallback alert text field appeared")
            return
        }
        field.tap()
        field.typeText(albumName)
        guard let saveButton = newAlbumSaveButton(timeout: 5) else {
            XCTFail("Neither album_picker_new_save nor a fallback 'Save' alert button appeared")
            return
        }
        saveButton.tap()

        XCTAssertTrue(
            waitFor(timeout: 20) { !self.app.otherElements["album_picker_root"].exists },
            "album_picker_root did not dismiss after saving the new album"
        )

        // UI-side proof: the rail callout carries the confirmation.
        XCTAssertTrue(
            waitFor(timeout: 10) {
                (try? self.app.descendants(matching: .any)["feed_coming_soon"].snapshot())?
                    .label.contains(albumName) == true
            },
            "No 'Added to \(albumName)' confirmation appeared over the rail"
        )

        // The probe reports a new PhotoKit fetch, not the result of the
        // write request. `albumVerification` returns nil while the probe
        // still reads "album_verify_none", so a non-nil result already
        // proves the add completed.
        guard let verification = albumVerification(timeout: 10) else {
            XCTFail("album_verify_ probe never reported a completed album add")
            return
        }
        XCTAssertEqual(
            verification.assetID, page.assetID,
            "album_verify_ probe reported a different asset than the one on screen when sharing began"
        )
        XCTAssertEqual(
            verification.count, 1,
            "Album does not contain exactly 1 asset after the add (re-fetched from PhotoKit)"
        )
        XCTAssertFalse(verification.albumID.isEmpty, "album_verify_ probe reported an empty albumID")

        // The flow does not move the pager or add to the bin.
        XCTAssertEqual(
            centeredPage(timeout: 10)?.assetID, page.assetID,
            "Adding to an album moved the pager off the page it was opened from"
        )
        XCTAssertEqual(
            app.buttons["bin_open"].label, binLabelBefore,
            "Adding to an album queued something into the bin"
        )
    }

    // MARK: - Album pin and callout behavior after creating an album

    /// Proves that a newly created album is pinned in its own section at
    /// the top of the album picker on the next open. Proves that the
    /// album is no longer pinned on the open after that.
    ///
    /// Creating an album also adds the current item and dismisses the
    /// sheet. This makes the next open the only time a user needs to
    /// find the new album quickly.
    func testNewAlbumIsPinnedOnTheNextOpenThenClears() throws {
        launch(resettingState: true)

        guard centeredPage(timeout: 20) != nil else {
            XCTFail("No centered page_ element found at start")
            return
        }

        let albumName = "ZZ Pin " + String(UUID().uuidString.prefix(6))

        // Create the album. The rail's Album button opens the picker
        // directly, without the share sheet.
        app.buttons["rail_album"].tap()
        XCTAssertTrue(
            app.otherElements["album_picker_root"].waitForExistence(timeout: 10),
            "album_picker_root did not appear from the rail's Album button"
        )
        app.buttons["album_picker_new"].tap()
        guard let field = newAlbumNameField(timeout: 5) else {
            XCTFail("No new-album name field appeared")
            return
        }
        field.tap()
        field.typeText(albumName)
        guard let save = newAlbumSaveButton(timeout: 5) else {
            XCTFail("No new-album Save button appeared")
            return
        }
        save.tap()

        // Creating dismisses the sheet.
        XCTAssertTrue(
            app.otherElements["album_picker_root"].waitForNonExistence(timeout: 10),
            "The picker should dismiss once the album is created"
        )

        // Open 1 after creation: pinned in its own section.
        app.buttons["rail_album"].tap()
        XCTAssertTrue(
            app.otherElements["album_picker_root"].waitForExistence(timeout: 10),
            "album_picker_root did not reappear"
        )
        let pinned = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "album_picker_pinned_")
        )
        XCTAssertTrue(
            pinned.firstMatch.waitForExistence(timeout: 5),
            "The just-created album should be pinned in its own section on the next open"
        )
        XCTAssertEqual(
            pinned.firstMatch.label, albumName,
            "The pinned row should be the album just created"
        )
        app.buttons["album_picker_cancel"].tap()
        XCTAssertTrue(app.otherElements["album_picker_root"].waitForNonExistence(timeout: 10))

        // Open 2: the pin is gone. The album is still in the ordinary
        // list.
        app.buttons["rail_album"].tap()
        XCTAssertTrue(app.otherElements["album_picker_root"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            pinned.firstMatch.waitForExistence(timeout: 3),
            "The pin should last exactly one presentation"
        )
        XCTAssertTrue(
            app.buttons.containing(NSPredicate(format: "label == %@", albumName)).firstMatch
                .waitForExistence(timeout: 5),
            "The album should still be listed normally once its pin has cleared"
        )
        app.buttons["album_picker_cancel"].tap()
    }

    /// Proves that the "added to album" callout clears as soon as the
    /// feed scrolls to a new page. This behavior stops the callout from
    /// staying visible and looking like a second add on that page.
    ///
    /// The callout is one value that the whole feed overlay shares. It
    /// does not belong to the page where it appeared.
    func testAlbumCalloutClearsWhenTheFeedScrolls() throws {
        launch(resettingState: true)

        guard centeredPage(timeout: 20) != nil else {
            XCTFail("No centered page_ element found at start")
            return
        }

        // An album to add to. Making one here keeps the test independent of
        // whatever the simulator library happens to hold.
        let albumName = "ZZ Callout " + String(UUID().uuidString.prefix(6))
        app.buttons["rail_album"].tap()
        XCTAssertTrue(app.otherElements["album_picker_root"].waitForExistence(timeout: 10))
        app.buttons["album_picker_new"].tap()
        guard let field = newAlbumNameField(timeout: 5) else {
            XCTFail("No new-album name field appeared")
            return
        }
        field.tap()
        field.typeText(albumName)
        guard let save = newAlbumSaveButton(timeout: 5) else {
            XCTFail("No new-album Save button appeared")
            return
        }
        save.tap()

        // Creating adds the current item, which is what raises the callout.
        let callout = app.descendants(matching: .any)["feed_coming_soon"]
        XCTAssertTrue(
            callout.waitForExistence(timeout: 5),
            "Adding to an album should raise the rail callout"
        )

        // Scroll before the callout's 1.8-second timer hides it.
        app.swipeUp()

        XCTAssertTrue(
            callout.waitForNonExistence(timeout: 3),
            "The callout should clear as soon as the feed starts moving, so it " +
            "cannot read as a second add on the next page"
        )
    }

    // MARK: - Cloud-key backfill accounts for every row

    func testCloudKeyBackfillAccountsForEveryRow() throws {
        launchForBackfillSeeding()

        guard let poolTotal = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }
        guard poolTotal >= Self.minimumPoolForM4 else {
            XCTFail(
                "Pool below floor (\(poolTotal) < \(Self.minimumPoolForM4)): reseed the " +
                "simulator library before gating"
            )
            return
        }

        guard let start = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        // Three swipes from the start page record 4 pages.
        // `DeckViewModel.markSeen` writes one `SeenEntry` row for each
        // page that becomes current.
        let seenPages = recordPages(swipes: 3, from: start)
        guard seenPages.count == 4, let likedPage = seenPages.last else {
            XCTFail("Did not record a page for every swipe while seeding SeenEntry rows")
            return
        }

        app.buttons["rail_like"].tap()   // 1 LikedEntry, on `likedPage`.

        // `handleTrashTap()` does nothing on a liked page, because a guard
        // clause in `FeedView.swift` skips the trash action there. The
        // trash tap below must land on a different, unliked page, so one
        // more swipe advances the pager and also seeds one more SeenEntry
        // row.
        let afterLike = recordPages(swipes: 1, from: likedPage)
        guard afterLike.count == 2, let unlikedPage = afterLike.last else {
            XCTFail("Pager did not advance past the liked page")
            return
        }

        guard advance(from: unlikedPage, afterPerforming: { self.app.buttons["rail_trash"].tap() }) != nil else {
            XCTFail("Pager did not advance after tapping rail_trash while seeding a TrashEntry row")
            return
        }
        // The expected row count is a floor of 7, not an exact count. 5
        // SeenEntry rows (the start page plus 4 swipes), 1 LikedEntry row,
        // and 1 TrashEntry row make up that floor. `recordPages` and
        // `advance` above retry their action when the pager is slow to
        // report settling on a new slot. A retried action can add one or
        // two real extra rows. The floor allows for them.
        //
        // `launchForBackfillSeeding()` suppresses the seeding launch's own
        // backfill. Without it, that backfill could resolve seeded rows
        // before `app.terminate()` and shrink the relaunch's `total` below
        // the seeded count. With the backfill suppressed, 7 is a floor the
        // test can rely on.

        // The probe `rowcountnil_` (a `GateProbes` probe backed by a
        // direct `fetchCount`) counts nil-keyed rows directly, straight
        // from the store. The test reads it before the seeding launch
        // terminates. `-cloudfull-suppress-backfill` guarantees nothing
        // has resolved yet, so every nil-keyed row read here is exactly
        // the population the backfill is about to see.
        guard let seedingNilCounts = rowCountNilReading(timeout: 10) else {
            XCTFail("rowcountnil_ probe never appeared on the seeding launch")
            return
        }
        let expectedTotal = seedingNilCounts.seen + seedingNilCounts.liked + seedingNilCounts.trash

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before the backfill relaunch")

        // The store survives the relaunch. The backfill now runs against a
        // stable population instead of racing the taps above.
        launch(resettingState: false)

        guard let firstReading = backfillReading(timeout: 45) else {
            XCTFail("backfill_ probe never reached 'done' within 45s on the first post-seed launch")
            return
        }
        // This check can fail. `CloudKeyBackfiller`'s own result type sets
        // `total` to `resolved + pending`, so comparing those three fields
        // to each other always holds. Comparing `total` to `expectedTotal`,
        // a count taken independently from the store, is the assertion
        // that actually proves the backfill saw every row.
        XCTAssertEqual(
            firstReading.total, expectedTotal,
            "Backfill accounted for \(firstReading.total) rows; \(expectedTotal) rows were nil-keyed " +
            "when the seeding launch terminated"
        )
        XCTAssertGreaterThanOrEqual(
            firstReading.total, 7,
            "Backfill total (\(firstReading.total)) is below the 7 rows this test seeded — " +
            "it may not have enumerated them all, or the seeding launch's own backfill was not " +
            "actually suppressed"
        )
        // The app builds `total` as `resolved + pending`, so this check
        // confirms the probe fields agree. The check above compares
        // `total` with an independent count.
        XCTAssertEqual(
            firstReading.resolved + firstReading.pending, firstReading.total,
            "resolved + pending != total on the first backfill run: \(firstReading)"
        )
        // No assertion requires `resolved == 0`. On this simulator,
        // `PHPhotoLibrary.cloudIdentifierMappings` resolves every
        // locally-created asset's identifier even with no iCloud account
        // signed in. A `PHCloudIdentifier` is a portable id PhotoKit
        // assigns locally, not proof of a completed upload, so `resolved`
        // can equal `total` on the very first pass.

        // The backfill keeps unmappable rows `nil` and tries them again
        // on the next launch.
        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before the retry relaunch")

        launch(resettingState: false)

        guard let secondReading = backfillReading(timeout: 45) else {
            XCTFail("backfill_ probe never reached 'done' within 45s on the retry launch")
            return
        }
        XCTAssertEqual(
            secondReading.resolved + secondReading.pending, secondReading.total,
            "resolved + pending != total on the retry backfill run: \(secondReading)"
        )
        // This does not assert `total >= firstReading.total`.
        // `CloudKeyBackfiller.run()` reports `(0, 0, 0)` once every row
        // already has a `cloudKey`, the steady state after a successful
        // pass. If the first run resolved every row
        // (`firstReading.pending == 0`, a real outcome here), that steady
        // state comes immediately, and the retry correctly reports 0. The
        // two relaunches do not interact, so the only rows still
        // unresolved on the retry are the ones the first run left
        // pending. The retry can never see more outstanding rows than
        // that. This proves the retry does not count a row twice or
        // invent a row, which matches the failure message below.
        XCTAssertLessThanOrEqual(
            secondReading.total, firstReading.pending,
            "Retry found more outstanding rows (\(secondReading.total)) than the first run left " +
            "pending (\(firstReading.pending)) — a row was double-counted or fabricated"
        )
        // This check reads a fresh `rowcountnil_` probe on the retry
        // launch itself. It does not depend on a figure derived from the
        // first launch's own report.
        guard let retryNilCounts = rowCountNilReading(timeout: 10) else {
            XCTFail("rowcountnil_ probe never appeared on the retry launch")
            return
        }
        let retryExpectedTotal = retryNilCounts.seen + retryNilCounts.liked + retryNilCounts.trash
        // The test reads `retryNilCounts` after the retry backfill
        // finishes (the `backfillReading(timeout: 45)` call above blocks
        // until `state == "done"`). The count equals
        // `secondReading.pending`, which is `total - resolved`.
        XCTAssertEqual(
            secondReading.total - secondReading.resolved, retryExpectedTotal,
            "Retry backfill's still-pending count (\(secondReading.total - secondReading.resolved)) " +
            "does not match the store's own nil-keyed row count (\(retryExpectedTotal)) taken right " +
            "after that run finished"
        )
    }

    // MARK: - Helpers: system share sheet

    /// Waits until the system share sheet appears, by any of its known
    /// identifiers. On failure, it lists the top-level containers it
    /// found, so a future iOS change reports that the sheet moved, not
    /// that something merely timed out.
    private func waitForSystemShareSheet(timeout: TimeInterval) {
        let candidates: [() -> XCUIElement] = [
            { self.app.otherElements["ActivityListView"] },
            { self.app.otherElements["share_sheet"] },
            { self.app.collectionViews["ActivityListView"] },
        ]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for make in candidates where make().exists { return }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        let seen = app.otherElements.allElementsBoundByIndex.prefix(40).map(\.identifier)
        XCTFail("System share sheet never appeared. Top-level otherElements: \(seen)")
    }

    /// Dismisses the system share sheet currently on screen, in at most 3
    /// attempts. Tries the "Close" button first. The current iOS share
    /// sheet shows no Close button for a video, so that check is a fast
    /// no-op here. Otherwise it taps the dimmed backdrop above the
    /// page-sheet's card, the standard iOS gesture for dismissing a
    /// `.pageSheet` presentation. On later attempts, it swipes down
    /// across the full app frame. This is not `swipeDown()` on the
    /// activity list: that gesture stays inside the list's own frame and
    /// only scrolls its content.
    ///
    /// Success is read off `rail_share.isHittable`, not off
    /// `ActivityListView` or `share_sheet` existence. Both identifiers
    /// keep resolving as existing after the sheet dismisses, because the
    /// element is detached and cached, not visible. A check on existence
    /// alone would report failure even when dismissal worked. Hittability
    /// requires FeedView to be on screen and unoccluded, which is only
    /// true once the modal is really gone.
    private func dismissShareSheet() {
        for attempt in 0..<3 {
            let close = app.buttons["Close"]
            if close.exists && close.isHittable {
                close.tap()
            } else if attempt == 0 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            } else {
                // A swipe scoped to `app` spans nearly the full screen
                // height at real drag speed, the gesture a page-sheet's
                // drag-to-dismiss recognizer expects. A swipe scoped to
                // `ActivityListView`'s smaller frame stays inside its
                // scrollable content and only scrolls it.
                app.swipeDown()
            }
            if waitFor(timeout: 6, condition: { self.app.buttons["rail_share"].isHittable }) {
                return
            }
        }
        let seen = app.buttons.allElementsBoundByIndex.prefix(30).map(\.label)
        XCTFail(
            "Could not dismiss the system share sheet after 3 attempts (rail_share never became " +
            "hittable again). Visible button labels: \(seen)"
        )
    }

    /// Reaches the "Add to Album" activity inside the system sheet's
    /// horizontally scrolling activity row. This is the most fragile step
    /// in the suite. Do not replace the bounded swipe loop with a longer
    /// timeout. Keep the failure message, which lists the labels on
    /// screen.
    private func tapAddToAlbumActivity() {
        let cell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Add to Album")).firstMatch
        for _ in 0..<4 {
            if cell.exists && cell.isHittable { cell.tap(); return }
            if cell.exists { cell.tap(); return }          // XCUITest scrolls it into view on its own
            app.collectionViews.firstMatch.swipeLeft()
            Thread.sleep(forTimeInterval: 0.4)
        }
        let seen = app.cells.allElementsBoundByIndex.prefix(30).map(\.label)
        XCTFail("'Add to Album' activity never became reachable. Activity row labels: \(seen)")
    }

    // MARK: - Helpers: album-name alert

    /// Resolves the alert's name field. Prefers
    /// `album_picker_new_name_field` and falls back to the one text field
    /// inside the one alert this flow ever shows.
    ///
    /// The fallback is required, not a defensive extra. SwiftUI's
    /// `.alert()` `TextField` does not carry its `.accessibilityIdentifier`
    /// onto the live `UITextField` it renders. `AlbumPickerView.swift`
    /// sets the identifier, but the field's `.identifier` reads back
    /// empty at runtime. This is a limitation of the SwiftUI-to-
    /// `UIAlertController` bridge, not a missing identifier in the
    /// source.
    private func newAlbumNameField(timeout: TimeInterval) -> XCUIElement? {
        // These two helpers use `.firstMatch`, not the singular `["..."]`
        // subscript. SwiftUI's bridge to `UIAlertController` sometimes
        // renders an identified alert control as a pair of nested elements
        // that both carry the same identifier. Tapping the
        // singular-subscript form then throws "Multiple matching elements
        // found". `.firstMatch` never throws that error.
        let identified = app.textFields.matching(identifier: "album_picker_new_name_field").firstMatch
        if identified.waitForExistence(timeout: min(2, timeout)) {
            return identified
        }
        let fallback = app.alerts.firstMatch.textFields.firstMatch
        return fallback.waitForExistence(timeout: timeout) ? fallback : nil
    }

    /// Resolves the alert's Save button, with the same identifier-then-
    /// fallback approach as `newAlbumNameField`, for the same reason:
    /// alert-hosted `Button`s can have the same identifier gap. A
    /// `UIAlertAction` button uses its title as its identifier, so the
    /// fallback matches the identifier "Save".
    private func newAlbumSaveButton(timeout: TimeInterval) -> XCUIElement? {
        let identified = app.buttons.matching(identifier: "album_picker_new_save").firstMatch
        if identified.waitForExistence(timeout: min(2, timeout)) {
            return identified
        }
        let fallback = app.alerts.firstMatch.buttons.matching(identifier: "Save").firstMatch
        return fallback.waitForExistence(timeout: timeout) ? fallback : nil
    }

    // MARK: - Helpers: probes

    /// Reads "share_probe_<state>" with debouncing: two reads 0.3 seconds
    /// apart must agree before either is trusted. `poolTotal` and
    /// `centeredPage` use the same approach, because a single sample can
    /// catch the accessibility tree mid-update.
    private func shareProbeReading(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> String? {
            elementSnapshots(withPrefix: "share_probe_").first?.identifier
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

    /// Reads "share_presented_count_<n>", the latched count of share
    /// sheets the app believes it has presented this launch. Uses the
    /// same two-agreeing-reads approach as `shareProbeReading`.
    ///
    /// Unlike that probe, this one is only ever read while FeedView is
    /// unoccluded. The debounce here guards against a torn snapshot, not
    /// a value that keeps changing on its own.
    private func sharePresentationCount(timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> Int? {
            guard let identifier = elementSnapshots(withPrefix: "share_presented_count_").first?.identifier else { return nil }
            return Int(identifier.dropFirst("share_presented_count_".count))
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

    private struct AlbumVerification: Equatable {
        let assetID: String
        let albumID: String
        let count: Int
    }

    /// Reads and parses "album_verify_<assetID>_<albumID>_<count>", or
    /// "album_verify_none" for no completed add yet, which `sample()`
    /// returns as `nil`. Debounced: two reads 0.3 seconds apart must
    /// agree. Asset and album local identifiers never contain an
    /// underscore, the same fact `Page.parse` and `shrinkVerification`
    /// rely on. The body always splits into exactly 3
    /// underscore-separated fields.
    private func albumVerification(timeout: TimeInterval) -> AlbumVerification? {
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> AlbumVerification? {
            guard let identifier = elementSnapshots(withPrefix: "album_verify_").first?.identifier else { return nil }
            let body = identifier.dropFirst("album_verify_".count)
            guard body != "none" else { return nil }
            let parts = body.split(separator: "_")
            guard parts.count == 3, let count = Int(parts[2]) else { return nil }
            return AlbumVerification(assetID: String(parts[0]), albumID: String(parts[1]), count: count)
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

    /// Reads "rowcountnil_<seen>_<liked>_<trash>", a `GateProbes` probe
    /// backed by a direct `modelContext.fetchCount` of rows with
    /// `cloudKey == nil`. This count is independent of
    /// `CloudKeyBackfiller`'s own bookkeeping. This makes it useful as a
    /// check on that bookkeeping, not a restatement of it. Debounced the
    /// same way as every other probe in this suite.
    private func rowCountNilReading(timeout: TimeInterval) -> (seen: Int, liked: Int, trash: Int)? {
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> (seen: Int, liked: Int, trash: Int)? {
            guard let identifier = elementSnapshots(withPrefix: "rowcountnil_").first?.identifier else { return nil }
            let body = identifier.dropFirst("rowcountnil_".count)
            let parts = body.split(separator: "_")
            guard parts.count == 3,
                  let seen = Int(parts[0]), let liked = Int(parts[1]), let trash = Int(parts[2]) else { return nil }
            return (seen, liked, trash)
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

    private struct BackfillReading: Equatable {
        let state: String
        let resolved: Int
        let pending: Int
        let total: Int
    }

    /// Parses "backfill_<state>_<resolved>_<pending>_<total>": four fields
    /// after the prefix, where the state token contains no underscore.
    /// Returns non-nil only once `state == "done"`, because a mid-run
    /// reading would race the assertions the caller makes right after.
    /// Debounced the same way as `poolTotal` and `shrinkVerification`.
    private func backfillReading(timeout: TimeInterval) -> BackfillReading? {
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> BackfillReading? {
            guard let identifier = elementSnapshots(withPrefix: "backfill_").first?.identifier else { return nil }
            let body = identifier.dropFirst("backfill_".count)
            let parts = body.split(separator: "_")
            guard parts.count == 4,
                  let resolved = Int(parts[1]),
                  let pending = Int(parts[2]),
                  let total = Int(parts[3]) else { return nil }
            let state = String(parts[0])
            guard state == "done" else { return nil }
            return BackfillReading(state: state, resolved: resolved, pending: pending, total: total)
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
}
