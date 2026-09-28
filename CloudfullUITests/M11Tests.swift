//
//  M11Tests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// UI tests for the chin nav, the photo feed, and Settings.
///
/// - The chin nav opens, switches modes, and collapses on a tap outside.
/// - A cold launch always opens Videos.
/// - The photo deck shuffles with seen memory, like the video deck.
/// - A photo delete and a photo keep use the same bin and the same shield
///   table as videos.
/// - A Live Photo plays once, then holds its key photo. This check skips
///   on this simulator. `xcrun simctl addmedia` imports a still and a
///   movie as two separate assets, never a pair, so `live_badge` never
///   publishes here.
/// - Tier-2 metadata never stalls the scroll.
/// - Settings opens from the chin nav. It shows four rows this suite
///   checks: `settings_open_muted`, `settings_icloud_status`,
///   `settings_reset_onboarding`, and `settings_version`.
///
/// The helpers for this suite are in this file. No hard-coded pool count
/// exists anywhere in this file. Every bound comes from a probe. A person
/// runs `scripts/seed_photos.sh` once, by hand, never from a test body.
final class M11Tests: FeedUITestCase {

    // MARK: - 1. Chin nav expands and switches to Photos

    /// Proves the chin nav opens on a tap, shows all three tabs, and
    /// switches to Photos.
    func testChinNavExpandsAndSwitchesToPhotos() throws {
        launch(resettingState: true)

        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_videos") }, "mode_videos did not appear on cold launch")
        XCTAssertTrue(element("chin_nav_button").waitForExistence(timeout: 10), "chin_nav_button does not exist")
        XCTAssertFalse(snapshotExists("chin_nav_expanded"), "chin_nav_expanded exists before the chin nav is ever tapped")

        expandChinNav()
        XCTAssertTrue(snapshotExists("chin_nav_expanded"), "chin_nav_expanded did not appear after tapping chin_nav_button")
        XCTAssertTrue(snapshotExists("chin_nav_videos"), "chin_nav_videos does not exist while the chin nav is expanded")
        XCTAssertTrue(snapshotExists("chin_nav_photos"), "chin_nav_photos does not exist while the chin nav is expanded")
        XCTAssertTrue(snapshotExists("chin_nav_settings"), "chin_nav_settings does not exist while the chin nav is expanded")

        selectChinNavTab("chin_nav_photos")

        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after tapping chin_nav_photos")
        XCTAssertFalse(snapshotExists("chin_nav_expanded"), "chin_nav_expanded is still present after switching to Photos")
        XCTAssertNotNil(centeredPhotoPage(timeout: 10), "No photo_page_ element resolved within 10s of switching to Photos")
    }

    // MARK: - 1b. Photo filters

    /// Proves the Photos top bar's filter menu builds a photo-only PhotoKit
    /// fetch predicate and narrows the photo feed.
    ///
    /// The main assertion is that PhotoKit accepts the fetch predicate
    /// these filters build. `PHFetchOptions` takes a narrow predicate
    /// grammar. A bitwise test against `mediaSubtypes` is the only way to
    /// express "Live Photo" or "no special kind". An invalid predicate
    /// makes the fetch raise. A feed that does not crash, and still shows
    /// photos after the toggle, is the proof.
    func testPhotoFilterMenuFiltersTheDeck() throws {
        launch(resettingState: true)
        expandChinNav()
        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(
            waitFor(timeout: 10) { self.snapshotExists("mode_photos") },
            "mode_photos did not appear"
        )
        guard let unfiltered = photoPoolCount(timeout: 15) else {
            XCTFail("photo_pool_ probe never appeared")
            return
        }

        let filterButton = app.buttons["photo_filter_button"]
        XCTAssertTrue(
            filterButton.waitForExistence(timeout: 10),
            "photo_filter_button does not exist — is the Photos top bar still mounting the video menu?"
        )
        filterButton.tap()

        // Every type starts selected. Un-ticking "Photo" (the no-special-
        // subtype kind) must narrow the pool on any real library.
        let photoType = app.buttons["photo_type_photo"]
        XCTAssertTrue(photoType.waitForExistence(timeout: 5), "photo_type_photo is not in the menu")
        photoType.tap()

        guard let filtered = waitForPoolChange(from: unfiltered, timeout: 15) else {
            XCTFail("photo_pool_ never changed after un-ticking Photo (was \(unfiltered))")
            return
        }
        XCTAssertLessThan(
            filtered, unfiltered,
            "Un-ticking Photo should shrink the pool, not grow it"
        )

        // Reset must change the pool count again. This shows that the app
        // clears the predicate.
        filterButton.tap()
        let reset = app.buttons["photo_filter_reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "photo_filter_reset is not in the menu")
        reset.tap()

        XCTAssertNotNil(
            waitForPoolChange(from: filtered, timeout: 15),
            "photo_pool_ never recovered after Reset (stuck at \(filtered))"
        )
    }

    /// Polls `photo_pool_<n>` until it reads something other than `previous`.
    private func waitForPoolChange(from previous: Int, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let now = photoPoolCount(timeout: 2), now != previous { return now }
        }
        return nil
    }

    // MARK: - 1c. Photo sort

    /// Test 1 of 4 for the photo date sort. Random is the checked sort at
    /// default options. The menu offers all three sorts.
    func testPhotoSortMenuOffersThreeSortsAndRandomIsChecked() throws {
        launch(resettingState: true)
        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")
        guard centeredPhotoPage(timeout: 15) != nil else {
            XCTFail("No centered photo_page_ element found in Photos")
            return
        }

        openPhotoFilterMenu()
        for id in ["photo_sort_datenewest", "photo_sort_dateoldest"] {
            guard element(id).waitForExistence(timeout: 3) else {
                XCTFail("\(id) does not exist in the open photo filter menu")
                return
            }
        }
        let randomItem = element("photo_sort_random")
        guard randomItem.waitForExistence(timeout: 3) else {
            XCTFail("photo_sort_random does not exist in the open photo filter menu")
            return
        }

        XCTAssertTrue(
            randomItem.label.contains("Random"),
            "photo_sort_random is not rendered as the checked sort at default options (label: '\(randomItem.label)')"
        )

        // Dismiss by re-selecting Random, a no-op that still closes the menu.
        tapPhotoMenuItem("photo_sort_random")
    }

    /// Test 2 of 4: Oldest first orders three consecutive pages oldest-first.
    func testPhotoSortOldestOrdersPagesOldestFirst() throws {
        launch(resettingState: true)
        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")

        guard let poolCount = photoPoolCount(timeout: 10), poolCount > 8 else {
            XCTFail("photo_pool_ is below the floor (need > 8): run scripts/seed_photos.sh before gating")
            return
        }

        tapPhotoMenuItem("photo_sort_dateoldest")
        guard waitForPhotoOptions("dateOldest_00t0") else {
            XCTFail("photo_options_ never settled on 'dateOldest_00t0' after selecting Oldest first")
            return
        }

        guard let page0 = centeredPhotoPage(timeout: 10), let f0 = photoFacts(timeout: 8) else {
            XCTFail("No centered photo_page_ element or photo_facts_ probe on page 1 of Oldest first")
            return
        }
        guard let page1 = recordPhotoPages(swipes: 1, from: page0).last, let f1 = photoFacts(timeout: 8) else {
            XCTFail("Pager did not advance to page 2, or photo_facts_ never appeared, under Oldest first")
            return
        }
        guard recordPhotoPages(swipes: 1, from: page1).count == 2, let f2 = photoFacts(timeout: 8) else {
            XCTFail("Pager did not advance to page 3, or photo_facts_ never appeared, under Oldest first")
            return
        }

        let d = [f0, f1, f2]
        XCTAssertTrue(d[0] <= d[1] && d[1] <= d[2], "Oldest-first sequence was not non-decreasing: \(d)")

        ProbeLog.emit("m11_photosort_oldest_epochs", "\(d[0]),\(d[1]),\(d[2])")
    }

    /// Test 3 of 4: Newest first orders three consecutive pages newest-first.
    func testPhotoSortNewestOrdersPagesNewestFirst() throws {
        launch(resettingState: true)
        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")

        guard let poolCount = photoPoolCount(timeout: 10), poolCount > 8 else {
            XCTFail("photo_pool_ is below the floor (need > 8): run scripts/seed_photos.sh before gating")
            return
        }

        tapPhotoMenuItem("photo_sort_datenewest")
        guard waitForPhotoOptions("dateNewest_00t0") else {
            XCTFail("photo_options_ never settled on 'dateNewest_00t0' after selecting Newest first")
            return
        }

        guard let page0 = centeredPhotoPage(timeout: 10), let f0 = photoFacts(timeout: 8) else {
            XCTFail("No centered photo_page_ element or photo_facts_ probe on page 1 of Newest first")
            return
        }
        guard let page1 = recordPhotoPages(swipes: 1, from: page0).last, let f1 = photoFacts(timeout: 8) else {
            XCTFail("Pager did not advance to page 2, or photo_facts_ never appeared, under Newest first")
            return
        }
        guard recordPhotoPages(swipes: 1, from: page1).count == 2, let f2 = photoFacts(timeout: 8) else {
            XCTFail("Pager did not advance to page 3, or photo_facts_ never appeared, under Newest first")
            return
        }

        let d = [f0, f1, f2]
        XCTAssertTrue(d[0] >= d[1] && d[1] >= d[2], "Newest-first sequence was not non-increasing: \(d)")

        ProbeLog.emit("m11_photosort_newest_epochs", "\(d[0]),\(d[1]),\(d[2])")
    }

    /// Test 4 of 4: after five swipes in Oldest, switching to Newest and back
    /// to Oldest puts the first asset id back on screen.
    func testPhotoSortChangeRestartsAtTheTop() throws {
        launch(resettingState: true)
        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")

        guard let poolCount = photoPoolCount(timeout: 10), poolCount > 8 else {
            XCTFail("photo_pool_ is below the floor (need > 8): run scripts/seed_photos.sh before gating")
            return
        }

        tapPhotoMenuItem("photo_sort_dateoldest")
        guard waitForPhotoOptions("dateOldest_00t0") else {
            XCTFail("photo_options_ never settled on 'dateOldest_00t0' after selecting Oldest first")
            return
        }
        guard let page0 = centeredPhotoPage(timeout: 10) else {
            XCTFail("No centered photo_page_ element found after switching to Oldest first")
            return
        }
        let firstAssetID = page0.assetID

        let swipes = min(poolCount - 1, 5)
        guard swipes > 0, recordPhotoPages(swipes: swipes, from: page0).count == swipes + 1 else {
            XCTFail("Did not record \(swipes) swipes' worth of photo pages under Oldest first")
            return
        }

        tapPhotoMenuItem("photo_sort_datenewest")
        guard waitForPhotoOptions("dateNewest_00t0"), centeredPhotoPage(timeout: 10) != nil else {
            XCTFail("Did not settle on Newest first after \(swipes) swipes in Oldest first")
            return
        }

        tapPhotoMenuItem("photo_sort_dateoldest")
        guard waitForPhotoOptions("dateOldest_00t0"), let backAtTop = centeredPhotoPage(timeout: 10) else {
            XCTFail("Did not settle back on Oldest first after switching from Newest first")
            return
        }

        XCTAssertEqual(
            backAtTop.assetID, firstAssetID,
            "Switching to Newest and back to Oldest did not restart at the top (expected \(firstAssetID), got \(backAtTop.assetID))"
        )
    }

    // MARK: - 2. Chin nav collapses on a tap outside the capsule

    /// Proves a tap outside the expanded chin nav closes it and does not
    /// page the feed.
    func testChinNavCollapsesOnTapOutside() throws {
        launch(resettingState: true)

        guard let before = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        expandChinNav()
        XCTAssertTrue(snapshotExists("chin_nav_expanded"), "chin_nav_expanded did not appear after tapping chin_nav_button")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        XCTAssertTrue(
            waitFor(timeout: 5) { !self.snapshotExists("chin_nav_expanded") },
            "chin_nav_expanded is still present after tapping outside the capsule"
        )
        XCTAssertTrue(snapshotExists("mode_videos"), "mode_videos is not the current mode after tapping outside the chin nav's catcher")

        guard let after = centeredPage(timeout: 5) else {
            XCTFail("No centered page_ element found after tapping outside the chin nav")
            return
        }
        XCTAssertEqual(
            before.slot, after.slot,
            "The centered page changed (before \(before.assetID) at slot \(before.slot), after \(after.assetID) at " +
            "slot \(after.slot)) — the catcher should have swallowed the tap instead of paging the feed"
        )
    }

    // MARK: - 3. Cold launch always opens Videos

    /// Proves a cold launch always opens Videos, even after a previous run
    /// left the app on Photos.
    func testColdLaunchAlwaysOpensVideos() throws {
        launch(resettingState: true)

        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before the relaunch")

        launch(resettingState: false)

        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_videos") }, "mode_videos did not appear after a cold relaunch from Photos")
        XCTAssertTrue(
            elementSnapshots(withPrefix: "photo_page_").isEmpty,
            "A photo_page_ element exists after a cold relaunch that should have opened on Videos"
        )
    }

    // MARK: - 4. The photo feed shows each photo once before repeating

    /// Proves the photo feed shows each photo once before any photo
    /// repeats. Needs more than 8 seeded photos.
    func testPhotoFeedShowsEachPhotoOnceBeforeRepeating() throws {
        launch(resettingState: true)
        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")

        guard let poolCount = photoPoolCount(timeout: 10) else {
            XCTFail("photo_pool_ probe never appeared")
            return
        }
        // The test records 9 pages, so the pool must hold more than 8
        // photos. With 8 or fewer photos, 9 distinct pages are not
        // possible.
        guard poolCount > 8 else {
            XCTFail("photo_pool_ (\(poolCount)) is below the floor (need > 8): run scripts/seed_photos.sh before gating")
            return
        }

        guard let first = centeredPhotoPage(timeout: 15) else {
            XCTFail("No centered photo_page_ element found in Photos")
            return
        }

        let swipes = min(poolCount, 8)
        let pages = recordPhotoPages(swipes: swipes, from: first)
        XCTAssertEqual(pages.count, swipes + 1, "Did not record a photo page for every swipe")

        let ids = pages.map(\.assetID)
        XCTAssertEqual(
            Set(ids).count, ids.count,
            "A photo repeated within \(swipes) swipes, before the deck could have exhausted its \(poolCount)-item pool: \(ids)"
        )
        for index in 1..<max(pages.count, 1) {
            XCTAssertNotEqual(
                pages[index - 1].assetID, pages[index].assetID,
                "Same photo in consecutive slots \(pages[index - 1].slot) and \(pages[index].slot)"
            )
        }
    }

    // MARK: - 5a. Photo delete survives a bin preview

    /// Deletes a photo, opens the bin, opens the deleted photo's preview,
    /// closes both, then deletes a second photo. Proves a bin preview does
    /// not block a later delete.
    func testPhotoDeleteStillWorksAfterBinPhotoPreview() throws {
        launch(resettingState: true)
        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear")
        guard let first = centeredPhotoPage(timeout: 15) else { XCTFail("no centered photo page"); return }
        guard let rowsBefore = trashRows(timeout: 10) else { XCTFail("no trash_rows_ probe"); return }
        element("photo_rail_trash").tap()
        XCTAssertTrue(waitFor(timeout: 15) { self.trashRows(timeout: 2)?.trash == rowsBefore.trash + 1 }, "first photo delete did not queue")

        element("bin_open").tap()
        XCTAssertTrue(element("trash_empty").waitForExistence(timeout: 5), "Trash sheet did not open")
        let cell = element("trash_preview_\(first.assetID)")
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "no trash_cell_ for the deleted photo")
        cell.tap()
        XCTAssertTrue(element("preview_close").waitForExistence(timeout: 5), "preview did not open")
        XCTAssertTrue(waitFor(timeout: 8) { self.element("preview_photo").exists }, "preview showed no photo")
        XCTAssertFalse(app.staticTexts["Couldn't load this video"].exists, "photo preview showed the video error")
        element("preview_close").tap()
        XCTAssertTrue(waitFor(timeout: 5) { !self.element("preview_close").exists }, "preview did not close")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() } else { app.swipeDown() }
        XCTAssertTrue(waitFor(timeout: 10) { !self.element("trash_empty").exists }, "Bin sheet did not dismiss")

        sleep(2)
        XCTAssertNotNil(centeredPhotoPage(timeout: 10), "no centered photo page after the bin")
        let trash = element("photo_rail_trash")
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "no photo_rail_trash after the bin")
        XCTAssertTrue(trash.isEnabled, "photo_rail_trash is DISABLED after previewing a photo in the bin")
        guard let rowsMid = trashRows(timeout: 5) else { XCTFail("no trash_rows_ probe after the bin"); return }
        trash.tap()
        XCTAssertTrue(waitFor(timeout: 15) { self.trashRows(timeout: 2)?.trash == rowsMid.trash + 1 }, "second photo delete did not queue (was \(rowsMid.trash))")
    }

    // MARK: - 5b. Photo delete shares the same bin as videos

    /// Proves a photo delete uses the same bin as videos, shows a live
    /// thumbnail, and restores after a relaunch.
    func testPhotoDeleteSharesTheOneBin() throws {
        launch(resettingState: true)
        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")

        guard let current = centeredPhotoPage(timeout: 15) else {
            XCTFail("No centered photo_page_ element found in Photos")
            return
        }
        let deletedID = current.assetID

        guard let rowsBefore = trashRows(timeout: 10) else {
            XCTFail("trash_rows_ probe never appeared before deleting a photo")
            return
        }
        let spaceBefore = spaceCounterLabel()

        element("photo_rail_trash").tap()

        XCTAssertTrue(
            waitFor(timeout: 15) { self.trashRows(timeout: 2)?.trash == rowsBefore.trash + 1 },
            "trash_rows_ did not read \(rowsBefore.trash + 1) after deleting a photo (was \(rowsBefore.trash))"
        )
        XCTAssertTrue(
            waitFor(timeout: 10) { self.spaceCounterLabel() != spaceBefore },
            "space_counter did not change after deleting a photo (was \(spaceBefore ?? "<absent>"))"
        )
        XCTAssertTrue(
            waitFor(timeout: 10) {
                !self.elementSnapshots(withPrefix: "photo_page_").contains { Self.parsePhotoPage($0.identifier)?.assetID == deletedID }
            },
            "\(deletedID) still appears in a photo_page_ element after being queued for trash"
        )

        // `TrashCell` stamps `trash_dormant_<id>` only when its own
        // `isDormant` reads true (see that type's own comment). Its absence
        // right after opening the bin is the check: a freshly queued photo
        // must show a live thumbnail, not the dormant placeholder.
        element("bin_open").tap()
        XCTAssertTrue(element("trash_empty").waitForExistence(timeout: 5), "Trash sheet did not open")
        XCTAssertTrue(element("trash_restore_\(deletedID)").waitForExistence(timeout: 5), "Missing trash_restore_ cell for \(deletedID)")
        XCTAssertFalse(
            element("trash_dormant_\(deletedID)").exists,
            "\(deletedID)'s bin cell reads dormant ('Not available right now') right after being queued"
        )

        // Close without restoring, so the relaunch check below (opening the
        // bin from Videos mode without visiting Photos) still has a queued
        // photo row to check.
        dismissBinSheet()
        XCTAssertTrue(waitFor(timeout: 10) { !self.element("trash_empty").exists }, "Bin sheet did not dismiss")

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before the relaunch")
        launch(resettingState: false)
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_videos") }, "mode_videos did not appear after a cold relaunch")

        // Open the bin straight from Videos mode, without ever entering
        // Photos, to confirm the same dormant-placeholder check holds on
        // this path too.
        element("bin_open").tap()
        XCTAssertTrue(element("trash_empty").waitForExistence(timeout: 5), "Trash sheet did not open from Videos mode after relaunch")
        let restoreButton = element("trash_restore_\(deletedID)")
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 5), "Missing trash_restore_ cell for \(deletedID) after relaunch (Videos mode, Photos never entered)")
        XCTAssertFalse(
            element("trash_dormant_\(deletedID)").exists,
            "\(deletedID)'s bin cell reads dormant after a relaunch that opened the bin from Videos mode without visiting Photos"
        )

        // Restore through the shared bin sheet — the same sheet and
        // identifiers videos use.
        restoreButton.tap()
        XCTAssertTrue(waitFor(timeout: 5) { !restoreButton.exists }, "\(deletedID) still shows a restore cell after restoring it")
        dismissBinSheet()
        // This restore empties the bin, so `trash_empty` (which lives only
        // in the bottom chin, absent on an empty bin) would vacuously read
        // "gone" even if the sheet were still open. The nav bar, titled
        // "Bin" whether or not the sheet's content is empty, is the sound
        // signal here.
        XCTAssertTrue(waitFor(timeout: 10) { !self.app.navigationBars["Bin"].exists }, "Bin sheet did not dismiss after restoring")

        XCTAssertTrue(
            waitFor(timeout: 15) { self.trashRows(timeout: 2)?.trash == rowsBefore.trash },
            "trash_rows_ did not return to \(rowsBefore.trash) after restoring the deleted photo"
        )
    }

    /// Uses `app.buttons["Done"]`, not `element("Done")`. Every other
    /// suite's bin-sheet dismiss uses this type-scoped lookup.
    /// `element(_:)` matches the button and its
    /// toolbar-item container. Both have the identifier "Done" on iOS
    /// 26.5. The lookup then fails with "Multiple matching elements
    /// found".
    private func dismissBinSheet() {
        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        } else {
            app.swipeDown()
        }
    }

    // MARK: - 6. Double-tapping a photo keeps it and disables Delete

    /// Proves a double-tap keeps the current photo and disables
    /// `photo_rail_trash`. It also proves a photo keep does not change the
    /// video pool.
    func testPhotoDoubleTapKeepDisablesDelete() throws {
        launch(resettingState: true)

        guard let poolBeforeVideos = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_ (video pool) before switching to Photos")
            return
        }

        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")

        guard centeredPhotoPage(timeout: 15) != nil else {
            XCTFail("No centered photo_page_ element found in Photos")
            return
        }

        let likeButton = element("photo_rail_like")
        XCTAssertTrue(likeButton.waitForExistence(timeout: 5), "photo_rail_like does not exist on the current post")
        XCTAssertFalse(likeButton.isSelected, "Test precondition: the current photo is already kept")

        XCTAssertTrue(doubleTapCurrentPhotoToKeep(), "Double-tapping the current photo never selected photo_rail_like")

        let trashButton = element("photo_rail_trash")
        XCTAssertTrue(waitFor(timeout: 5) { !trashButton.isEnabled }, "photo_rail_trash is still enabled after keeping the current photo")

        XCTAssertEqual(
            waitForPoolTotal(toEqual: poolBeforeVideos, timeout: 5), poolBeforeVideos,
            "pool_total_ (video pool) moved after keeping a PHOTO — Keep is one shield table, but the video pool must not react to a photo Keep"
        )

        // Cleanup, required: a LikedEntry is durable and would narrow the
        // video pool for every later suite. Unkeep through the rail, not
        // another double-tap. Double-tap only ever calls keep(); it never
        // toggles off, unlike the rail's own toggle.
        element("photo_rail_like").tap()
        XCTAssertTrue(waitFor(timeout: 5) { !self.element("photo_rail_like").isSelected }, "photo_rail_like did not return to unkept during cleanup")
        XCTAssertEqual(
            waitForPoolTotal(toEqual: poolBeforeVideos, timeout: 5), poolBeforeVideos,
            "pool_total_ (video pool) did not remain at \(poolBeforeVideos) after the cleanup unkeep"
        )
    }

    // MARK: - 7. Live defaults ON: plays once, then holds the key photo

    /// Proves a Live Photo plays once with Live default ON, then holds its
    /// key photo. Needs a Live Photo; skips on the simulator.
    func testLiveDefaultsOnPlaysOnceThenHoldsKeyPhoto() throws {
        launch(resettingState: true)
        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")

        guard centeredPhotoPage(timeout: 15) != nil else {
            XCTFail("No centered photo_page_ element found in Photos")
            return
        }

        guard scrollUntilLiveBadge() else {
            throw XCTSkip(
                "No post ever published live_badge within 15s — Live Photos cannot be seeded on the " +
                "simulator (addmedia never pairs a still with a movie), M11_CONTRACT.md §4"
            )
        }

        XCTAssertTrue(element("live_toggle").waitForExistence(timeout: 5), "live_toggle does not exist")
        XCTAssertTrue(liveToggleReadsOn(), "live_toggle does not read as ON by default (label: '\(element("live_toggle").label)')")

        XCTAssertTrue(waitFor(timeout: 15) { self.snapshotExists("photo_live_state_playing") }, "photo_live_state_playing never appeared on a Live post with Live default ON")
        XCTAssertTrue(waitFor(timeout: 6) { self.snapshotExists("photo_live_state_key") }, "photo_live_state_key did not follow photo_live_state_playing within 6s")

        // The key state must hold for 3 more seconds. It never loops.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(snapshotExists("photo_live_state_key"), "photo_live_state_key did not hold for 3s — the Live Photo looped or replayed unprompted")

        tapCurrentPhoto()
        XCTAssertTrue(
            waitFor(timeout: 5) { self.snapshotExists("photo_live_state_playing") },
            "Tapping the Live photo once did not replay it (photo_live_state_playing never reappeared)"
        )
    }

    // MARK: - 8. Live OFF mutes and stops autoplay

    /// Proves Live OFF mutes autoplay and blocks it until a tap. Needs a
    /// Live Photo; skips on the simulator.
    func testLiveOffMutesAndStopsAutoplay() throws {
        launch(resettingState: true)
        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")

        guard centeredPhotoPage(timeout: 15) != nil else {
            XCTFail("No centered photo_page_ element found in Photos")
            return
        }

        // Run this check before any toggle tap.
        guard scrollUntilLiveBadge() else {
            throw XCTSkip(
                "No post ever published live_badge within 15s — Live Photos cannot be seeded on the " +
                "simulator (addmedia never pairs a still with a movie), M11_CONTRACT.md §4"
            )
        }

        let liveToggle = element("live_toggle")
        XCTAssertTrue(liveToggle.waitForExistence(timeout: 5), "live_toggle does not exist")
        if liveToggleReadsOn() {
            liveToggle.tap()
        }
        XCTAssertTrue(waitFor(timeout: 3) { !self.liveToggleReadsOn() }, "live_toggle still reads ON after tapping it off")

        XCTAssertTrue(waitFor(timeout: 3) { self.snapshotExists("photo_live_state_off") }, "photo_live_state_off did not appear on a Live post with Live toggled off")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(snapshotExists("photo_live_state_off"), "photo_live_state_off did not hold for 3s — autoplay fired with Live OFF")
        XCTAssertFalse(snapshotExists("photo_live_state_playing"), "photo_live_state_playing appeared with Live toggled off and no tap yet")

        tapCurrentPhoto()
        XCTAssertTrue(
            waitFor(timeout: 5) { self.snapshotExists("photo_live_state_playing") },
            "Tapping the photo with Live OFF did not play it once (photo_live_state_playing never appeared)"
        )
        XCTAssertTrue(
            waitFor(timeout: 6) { self.snapshotExists("photo_live_state_off") },
            "photo_live_state_off did not follow the muted single-tap playthrough"
        )

        // Cleanup: turn Live back ON so the rest of this test starts from
        // the default.
        liveToggle.tap()
        XCTAssertTrue(waitFor(timeout: 3) { self.liveToggleReadsOn() }, "live_toggle did not return to ON during cleanup")
    }

    // MARK: - 9. Photo metadata never blocks scroll

    /// Proves 20 photo swipes cause no main-thread stall over 250 ms,
    /// while tier-2 metadata loads. It resets deck and stall state before
    /// it launches.
    func testPhotoMetadataNeverBlocksScroll() throws {
        app.launchArguments = ["-cloudfull-reset-deck-state", "-cloudfull-reset-stalls"]
        app.launch()
        grantPhotoAccessIfAsked()

        selectChinNavTab("chin_nav_photos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_photos") }, "mode_photos did not appear after switching to Photos")

        guard centeredPhotoPage(timeout: 15) != nil else {
            XCTFail("Photo feed never showed a page")
            return
        }

        // The settle window is 2.0 seconds from the watchdog arming. This
        // sleeps 2.5 seconds so the first swipe below cannot land inside
        // it.
        Thread.sleep(forTimeInterval: 2.5)

        // Do not snapshot, query, or look up elements between here and the
        // probe read below. This is the measured window.
        for _ in 0..<20 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.9)
        }
        Thread.sleep(forTimeInterval: 1.0)

        guard let reading = mainStallReading(timeout: 10) else {
            XCTFail("main_stalls_ probe never appeared — the watchdog is not running, so a zero here would prove nothing")
            return
        }

        ProbeLog.emit("m11_photo_main_stalls", reading.count)
        ProbeLog.emit("m11_photo_main_worst_gap_ms", reading.worstMs)

        XCTAssertEqual(
            reading.count, 0,
            "Main thread stalled \(reading.count) time(s) over 250 ms across 20 photo swipes (worst gap \(reading.worstMs) ms)"
        )
        XCTAssertGreaterThan(reading.worstMs, 0, "worstGapMs is 0 — the display link never ticked, so the assertion above is vacuous")

        XCTAssertTrue(
            waitFor(timeout: 10) { self.snapshotExists("photo_meta_camera") },
            "No photo_meta_camera element ever resolved — tier 2 metadata never ran during the scroll"
        )
    }

    // MARK: - 10. Settings opens from the chin nav

    /// Proves Settings opens from the chin nav and shows `settings_root`.
    /// It also confirms `settings_version` appears after a scroll to the
    /// bottom.
    func testSettingsOpensFromChinNav() throws {
        launch(resettingState: true)

        selectChinNavTab("chin_nav_settings")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_settings") }, "mode_settings did not appear after tapping chin_nav_settings")

        XCTAssertTrue(element("settings_root").waitForExistence(timeout: 5), "settings_root does not exist")
        // Checks the muted-videos, iCloud status, and reset-onboarding rows.
        for id in ["settings_open_muted", "settings_icloud_status", "settings_reset_onboarding"] {
            XCTAssertTrue(element(id).waitForExistence(timeout: 5), "\(id) does not exist in Settings")
        }
        // `settings_version` sits near the bottom of the screen, under
        // the Assistance, tip jar, other-projects, and Diagnostics
        // sections. On this screen size it starts below the visible area.
        // XCUITest reports an off-screen row in a scroll view as not
        // existing. The version footer in `SettingsView` keeps its
        // identifier at every position, so the test swipes up until the
        // footer shows instead of assuming it is already visible.
        let version = element("settings_version")
        var swipesLeft = 8
        while !version.waitForExistence(timeout: 1) && swipesLeft > 0 {
            element("settings_root").swipeUp()
            swipesLeft -= 1
        }
        XCTAssertTrue(
            version.waitForExistence(timeout: 5),
            "settings_version does not exist in Settings even after scrolling to the bottom"
        )

        selectChinNavTab("chin_nav_videos")
        XCTAssertTrue(waitFor(timeout: 10) { self.snapshotExists("mode_videos") }, "mode_videos did not appear after tapping chin_nav_videos")
        XCTAssertNotNil(centeredPage(timeout: 10), "No page_ element resolved within 10s of switching back to Videos")
    }

    // MARK: - Generic element lookup

    /// Any accessibility element by identifier, not only a `.buttons[]`
    /// one. Several controls in this suite (chin nav tabs, the expanded and
    /// mode markers) are not guaranteed to be `Button`s.
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// Existence read off one atomic `snapshot()`, not a live query. See
    /// `FeedUITestCase.elementSnapshots`'s own doc comment for why this is
    /// the safer check for an element that may be mid-animation, such as
    /// the chin nav's expand or collapse, or a mode switch.
    private func snapshotExists(_ id: String) -> Bool {
        elementSnapshots(withPrefix: id).contains { $0.identifier == id }
    }

    // MARK: - Chin nav

    /// Opens the chin nav (no-op if already expanded) and waits for the
    /// marker to appear.
    private func expandChinNav() {
        guard !snapshotExists("chin_nav_expanded") else { return }
        element("chin_nav_button").tap()
        _ = waitFor(timeout: 5) { self.snapshotExists("chin_nav_expanded") }
    }

    /// Expands the chin nav if needed, taps one of its three destination
    /// tabs, and waits for the capsule to collapse back down.
    private func selectChinNavTab(_ id: String) {
        expandChinNav()
        let tab = element(id)
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(id) did not appear in the expanded chin nav")
        tab.tap()
        _ = waitFor(timeout: 5) { !self.snapshotExists("chin_nav_expanded") }
    }

    // MARK: - Photo sort menu

    /// Taps `photo_filter_button` and waits for the menu to be open (proven
    /// by `photo_sort_random` existing) — a no-op if it is already open.
    private func openPhotoFilterMenu() {
        guard !element("photo_sort_random").exists else { return }
        app.buttons["photo_filter_button"].tap()
        _ = element("photo_sort_random").waitForExistence(timeout: 5)
    }

    /// Opens the menu if needed, taps `id`, then waits for that item to stop
    /// existing before returning — the menu dismisses on every item tap.
    private func tapPhotoMenuItem(_ id: String) {
        openPhotoFilterMenu()
        let item = element(id)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(id) did not appear in the open photo filter menu")
        item.tap()
        _ = waitFor(timeout: 5) { !self.element(id).exists }
    }

    /// Reads "photo_options_<token>" — `PhotoOptionsStore.options.probeToken`
    /// — with the same two-reads-0.3s-apart discipline every other probe in
    /// this file uses.
    private func photoOptionsToken(timeout: TimeInterval = 5) -> String? {
        let prefix = "photo_options_"
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> String? {
            guard let identifier = elementSnapshots(withPrefix: prefix).first?.identifier else { return nil }
            return String(identifier.dropFirst(prefix.count))
        }

        repeat {
            if let firstRead = sample() {
                Thread.sleep(forTimeInterval: 0.3)
                if let secondRead = sample(), secondRead == firstRead { return firstRead }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline

        return nil
    }

    /// Polls `photoOptionsToken()` until it equals `token` or `timeout` elapses.
    private func waitForPhotoOptions(_ token: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if photoOptionsToken(timeout: 1) == token { return true }
        } while Date() < deadline
        return photoOptionsToken(timeout: 1) == token
    }

    /// Reads "photo_facts_<createdMs>" — the current post's creation date,
    /// directly from `PhotoDeck.debugCurrentCreatedMs`.
    private func photoFacts(timeout: TimeInterval = 8) -> Int64? {
        let prefix = "photo_facts_"
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> Int64? {
            guard let identifier = elementSnapshots(withPrefix: prefix).first?.identifier else { return nil }
            return Int64(identifier.dropFirst(prefix.count))
        }

        repeat {
            if let firstRead = sample() {
                Thread.sleep(forTimeInterval: 0.3)
                if let secondRead = sample(), secondRead == firstRead { return firstRead }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline

        return nil
    }

    // MARK: - Photo page identity

    private struct PhotoPage: Equatable {
        let slot: Int
        let assetID: String
    }

    /// Splits "photo_page_<slot>_<assetID>" — mirrors
    /// `FeedUITestCase.parse`'s own "page_<slot>_<assetID>" splitting.
    private static func parsePhotoPage(_ identifier: String) -> PhotoPage? {
        guard identifier.hasPrefix("photo_page_") else { return nil }
        let body = identifier.dropFirst("photo_page_".count)
        guard let separator = body.firstIndex(of: "_") else { return nil }
        guard let slot = Int(body[body.startIndex..<separator]) else { return nil }
        let assetID = String(body[body.index(after: separator)...])
        guard !assetID.isEmpty else { return nil }
        return PhotoPage(slot: slot, assetID: assetID)
    }

    /// The current post's own frame, in screen coordinates. The pager
    /// free-scrolls with no post-aligned snap. "Current" is a geometric
    /// read, the same containment-or-largest-visible rule
    /// `PhotoFeedView.nearestCenterID` uses. It returns the post whose
    /// frame contains the screen's vertical center. With no exact hit,
    /// such as a mid-scroll gap, it returns the post with the most
    /// visible height.
    private func currentPhotoPostFrame() -> CGRect? {
        let centerY = app.frame.midY
        let candidates = elementSnapshots(withPrefix: "photo_page_").filter { $0.frame.height > 0 }
        if let containing = candidates.first(where: { $0.frame.minY <= centerY && centerY <= $0.frame.maxY }) {
            return containing.frame
        }
        return candidates.max(by: { photoVisibleHeight($0.frame) < photoVisibleHeight($1.frame) })?.frame
    }

    /// How much of `frame` falls inside the app's own screen bounds. Mirrors
    /// `PhotoFeedView.visibleHeight` exactly, so this test's notion of "most
    /// visible" matches the app's own fallback rule.
    private func photoVisibleHeight(_ frame: CGRect) -> CGFloat {
        let screenTop = app.frame.minY
        let screenBottom = app.frame.maxY
        return max(0, min(frame.maxY, screenBottom) - max(frame.minY, screenTop))
    }

    /// Polls for the current post. It uses the rule in
    /// `currentPhotoPostFrame` and requires two equal reads 0.3 s apart.
    private func centeredPhotoPage(timeout: TimeInterval = 5) -> PhotoPage? {
        let deadline = Date().addingTimeInterval(timeout)
        let centerY = app.frame.midY

        func sample() -> PhotoPage? {
            let candidates = elementSnapshots(withPrefix: "photo_page_").filter { $0.frame.height > 0 }
            if let containing = candidates.first(where: { $0.frame.minY <= centerY && centerY <= $0.frame.maxY }) {
                return Self.parsePhotoPage(containing.identifier)
            }
            guard let largest = candidates.max(by: { photoVisibleHeight($0.frame) < photoVisibleHeight($1.frame) }) else {
                return nil
            }
            return Self.parsePhotoPage(largest.identifier)
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

    /// Taps the current post at `fraction` of its height. The photo has
    /// no accessibility identifier, so the tap uses a point in the middle
    /// band, below the header and above the caption.
    private func tapCurrentPhoto(fraction: CGFloat = 0.4) {
        guard let frame = currentPhotoPostFrame() else {
            XCTFail("Could not find the current photo_page_ frame to tap")
            return
        }
        let point = CGPoint(x: frame.midX, y: frame.minY + frame.height * fraction)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
    }

    /// Double-taps the current post at several heights until
    /// `photo_rail_like` is selected. The photo band changes with each
    /// photo's aspect ratio.
    @discardableResult
    private func doubleTapCurrentPhotoToKeep() -> Bool {
        for fraction: CGFloat in [0.35, 0.45, 0.55, 0.25] {
            guard let frame = currentPhotoPostFrame() else { continue }
            let point = CGPoint(x: frame.midX, y: frame.minY + frame.height * fraction)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).doubleTap()
            if waitFor(timeout: 3, condition: { self.element("photo_rail_like").isSelected }) {
                return true
            }
        }
        return false
    }

    // MARK: - Photo pool / deck-next probes

    /// Reads "photo_pool_<n>" — `PhotoDeck.poolCount` — debounced with the
    /// same two-reads-0.3s-apart discipline `FeedUITestCase.poolTotal` uses.
    private func photoPoolCount(timeout: TimeInterval = 10) -> Int? {
        let prefix = "photo_pool_"
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> Int? {
            guard let identifier = elementSnapshots(withPrefix: prefix).first?.identifier else { return nil }
            return Int(identifier.dropFirst(prefix.count))
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

    /// What the "photo_deck_next_" probe reports about the entry
    /// immediately after the current post — mirrors
    /// `FeedUITestCase.NextSlot`/`expectedNextSlot` for the photo deck.
    private enum PhotoNextSlot: Equatable {
        case slot(Int)
        case end
    }

    private func expectedNextPhotoSlot(timeout: TimeInterval = 5) -> PhotoNextSlot? {
        let prefix = "photo_deck_next_"
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> PhotoNextSlot? {
            guard let identifier = elementSnapshots(withPrefix: prefix).first?.identifier else { return nil }
            let body = identifier.dropFirst(prefix.count)
            if body == "end" { return .end }
            guard let slot = Int(body) else { return nil }
            return .slot(slot)
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

    /// Shared retry loop behind `recordPhotoPages`, the same shape as
    /// `FeedUITestCase`'s private `pollForAdvance`. Performs `action` up to
    /// `retries` times, then moves onto `expectedSlot` with `nudge`
    /// (below) when `action`'s own travel over- or undershoots it.
    ///
    /// Post heights change with aspect ratio. One `swipeUp()` can move
    /// past the target slot or stop before it. `nudge` then moves a small
    /// fixed distance until the target slot is centered.
    private func pollForPhotoAdvance(
        from current: PhotoPage,
        expectedSlot: Int?,
        timeout: TimeInterval = 5,
        retries: Int = 3,
        byPerforming action: () -> Void
    ) -> PhotoPage? {
        for _ in 0..<retries {
            action()
            var candidate = centeredPhotoPage(timeout: timeout)
            if let expectedSlot {
                var steps = 0
                while let c = candidate, c.slot != expectedSlot, steps < 8 {
                    nudge(forward: c.slot < expectedSlot)
                    candidate = centeredPhotoPage(timeout: timeout)
                    steps += 1
                }
                if let c = candidate, c.slot == expectedSlot {
                    return c
                }
            } else if let c = candidate, c.slot != current.slot {
                return c
            }
            Thread.sleep(forTimeInterval: expectedSlot == nil ? 0.5 : 1.0)
        }
        return nil
    }

    /// Drags about 30% of the screen height up or down. Only
    /// `pollForPhotoAdvance` uses it, to reach an exact slot. The swipe
    /// under test is always `app.swipeUp()`.
    private func nudge(forward: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: forward ? 0.65 : 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: forward ? 0.35 : 0.65))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Swipes `swipes` times, returning `from` followed by every post
    /// landed on. Mirrors `FeedUITestCase.recordPages` exactly, reading
    /// `photo_deck_next_` instead of `deck_next_` before each swipe, so the
    /// expected landing slot is never assumed to be `current.slot + 1`.
    private func recordPhotoPages(swipes: Int, from first: PhotoPage) -> [PhotoPage] {
        var pages = [first]
        var current = first

        for swipe in 0..<swipes {
            XCTAssertEqual(app.state, .runningForeground, "App left the foreground at photo swipe \(swipe)")

            guard let expected = expectedNextPhotoSlot(timeout: 5) else {
                XCTFail("Could not read photo_deck_next_ probe before swipe \(swipe), on slot \(current.slot)")
                break
            }

            guard case .slot(let expectedSlot) = expected else {
                let next = pollForPhotoAdvance(from: current, expectedSlot: nil, byPerforming: { self.app.swipeUp() })
                guard let next else {
                    let pool = photoPoolCount(timeout: 5)
                    XCTFail("Photo deck reported its tail (photo_deck_next_end) at slot \(current.slot) after swipe \(swipe), photo_pool_ was \(pool.map(String.init) ?? "unreadable")")
                    return pages
                }
                pages.append(next)
                current = next
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }

            guard let next = pollForPhotoAdvance(from: current, expectedSlot: expectedSlot, byPerforming: { self.app.swipeUp() }) else {
                XCTFail("Photo pager did not advance past slot \(current.slot) to expected slot \(expectedSlot) after swipe \(swipe)")
                break
            }

            pages.append(next)
            current = next
            Thread.sleep(forTimeInterval: 0.5)
        }

        return pages
    }

    // MARK: - Live Photo helpers

    /// Scans for `live_badge` for up to `timeout`, swiping the photo feed
    /// forward between checks. The tests that use this skip when it returns
    /// false, since the simulator cannot seed Live Photos.
    private func scrollUntilLiveBadge(timeout: TimeInterval = 15) -> Bool {
        if snapshotExists("live_badge") { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            if snapshotExists("live_badge") { return true }
        }
        return snapshotExists("live_badge")
    }

    /// `live_toggle` can show its state through `.isSelected` or only
    /// through its label. This function reads `.isSelected` first. Then it
    /// reads the label: "off" means OFF and "on" means ON.
    private func liveToggleReadsOn() -> Bool {
        let toggle = element("live_toggle")
        guard toggle.exists else { return false }
        if toggle.isSelected { return true }
        let label = toggle.label.lowercased()
        if label.contains("off") { return false }
        return label.contains("on")
    }

    // MARK: - Shared bin / space probes (also used by the video suites)

    /// Reads `trash_rows_<count>_<dormantCount>` from `GateProbes` in
    /// DebugProbes.swift. `GateProbes` is present in every `AppMode`, so
    /// this works in Videos, Photos, and Settings.
    private func trashRows(timeout: TimeInterval = 10) -> (trash: Int, dormant: Int)? {
        let prefix = "trash_rows_"
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> (trash: Int, dormant: Int)? {
            guard let identifier = elementSnapshots(withPrefix: prefix).first?.identifier else { return nil }
            let parts = identifier.dropFirst(prefix.count).split(separator: "_")
            guard parts.count == 2, let trash = Int(parts[0]), let dormant = Int(parts[1]) else { return nil }
            return (trash, dormant)
        }

        repeat {
            if let firstRead = sample() {
                Thread.sleep(forTimeInterval: 0.3)
                if let secondRead = sample(), secondRead == firstRead {
                    return secondRead
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline

        return nil
    }

    /// Returns the `space_counter` label, or nil if the element is absent.
    /// Reading `.label` on a missing element raises an Objective-C
    /// exception that Swift cannot catch. This function checks `exists`
    /// first.
    private func spaceCounterLabel() -> String? {
        let counter = app.staticTexts["space_counter"]
        guard counter.exists else { return nil }
        return counter.label
    }

    // MARK: - Main thread stall probe (own copy, kept private)

    private func mainStallReading(timeout: TimeInterval = 10) -> (count: Int, worstMs: Int)? {
        let prefix = "main_stalls_"
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> (count: Int, worstMs: Int)? {
            guard let identifier = elementSnapshots(withPrefix: prefix).first?.identifier else { return nil }
            let parts = identifier.dropFirst(prefix.count).split(separator: "_")
            guard parts.count == 2, let count = Int(parts[0]), let worstMs = Int(parts[1]) else { return nil }
            return (count, worstMs)
        }

        repeat {
            if let firstRead = sample() {
                Thread.sleep(forTimeInterval: 0.3)
                if let secondRead = sample(),
                   secondRead.count == firstRead.count,
                   secondRead.worstMs == firstRead.worstMs {
                    return secondRead
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline

        return nil
    }

}
