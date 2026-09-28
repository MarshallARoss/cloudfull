//
//  PurgeAlbumsHelper.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// Test-infrastructure helper, not a product test. It drives the DEBUG
/// album purge (`-cloudfull-purge-test-albums`) and answers the system
/// consent alert, the same way `M2TrashTests` answers the batch-delete
/// confirm.
///
/// This class answers the alert through XCUITest rather than through the
/// simulator's own accessibility service. That service can switch off
/// during a test run and not come back reliably. An external UI tool
/// such as `idb ui` then sees an empty accessibility tree and cannot tap
/// the alert. XCUITest manages its own accessibility session, so it does
/// not depend on that service.
///
/// This class makes no pass-or-fail claim about the purge result.
/// `scripts/purge_albums.sh` counts the albums in the Photos database
/// before and after. That count is the only measure of success. The one
/// assertion here confirms only that the app launched.
final class PurgeAlbumsHelper: XCTestCase {

    func testDriveAlbumPurgeConsentDialog() {
        let app = XCUIApplication()
        app.launchArguments = ["-cloudfull-purge-test-albums"]
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "App never reached foreground with the purge launch argument"
        )

        // If there is nothing to purge, the app logs album_purge_done_0 and
        // no alert appears. That is a valid outcome, so the test waits for
        // the alert instead of asserting it must appear.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        // Waits 130 seconds, not 20. iOS throttles repeated consent alerts
        // for the same app: this dialog can take 95 to 105 seconds to
        // render after several triggers. A 20-second wait can exit before
        // the alert renders, and `terminate()` then cancels the pending
        // `performChanges` call.
        if alert.waitForExistence(timeout: 130) {
            // Only answer the album consent alert ("...to delete N
            // albums?"). Do not tap PhotoKit's asset-deletion confirm
            // ("...to delete N videos?") here. Tapping it would destroy
            // seeded fixtures instead of cleaning up albums.
            let label = alert.staticTexts.allElementsBoundByIndex
                .map(\.label).joined(separator: " ").lowercased()
            guard label.contains("delete"), label.contains("album") else {
                app.terminate()
                return
            }
            let deleteButton = alert.buttons
                .matching(NSPredicate(format: "label CONTAINS 'Delete'")).firstMatch
            if deleteButton.waitForExistence(timeout: 5) {
                deleteButton.tap()
                // Wait up to 15 seconds for the alert to close, then 2
                // seconds, so PhotoKit commits the change before
                // purge_albums.sh reads the database.
                _ = springboard.alerts.firstMatch.waitForNonExistence(timeout: 15)
                sleep(2)
            }
        }
        app.terminate()
    }
}
