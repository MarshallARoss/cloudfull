//
//  DuoR4RotationCheck.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// Throwaway verification for Duo build R4 (real fullscreen rotation) on
/// the 17 Pro simulator. Not part of the gate; run alone with
/// `-only-testing:CloudfullUITests/DuoR4RotationCheck`.
///
/// `scripts/seed_m3.sh` could not run (host is out of disk space right
/// now), so this reads two assets already resident in the 17 Pro sim's
/// library from earlier seeding, by raw `ZUUID` (confirmed live via a
/// direct `sqlite3` read of `Photos.sqlite`, not re-derived here) rather
/// than the usual `TEST_RUNNER_CLOUDFULL_*` fixture env vars M6Tests
/// reads. `/L0/001` is the same `PHAsset.localIdentifier` suffix
/// `seed_m3.sh` itself appends (see that script's `add_one`).
///
/// Delete this file once the owner has seen the screenshots and signed
/// off on R4's feel — it is scaffolding for this one check, not a
/// permanent regression test.
final class DuoR4RotationCheck: FeedUITestCase {
    /// 3840×2160, confirmed live and untrashed.
    private static let landscapeAssetID = "6F15F716-E255-4345-9BDA-04ADBB1C3071/L0/001"
    /// 1080×1920, confirmed live and untrashed.
    private static let portraitAssetID = "E7E4DE3A-C426-413A-84A1-56B0C14EC643/L0/001"

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
    }

    func testRotationLooksRightOnWideAndTallVideo() throws {
        // `-cloudfull-log-rotation` so the real `windowSize`/`isFullscreen`
        // numbers are readable afterward via `log show`.
        app.launchArguments = ["-cloudfull-log-rotation"]
        app.launch()
        grantPhotoAccessIfAsked()

        guard let start = centeredPage(timeout: 20) else {
            XCTFail("No centered page at launch")
            return
        }

        guard let widePage = scrollToAsset(Self.landscapeAssetID, from: start, budget: 60) else {
            XCTFail("Never reached the known landscape fixture \(Self.landscapeAssetID)")
            return
        }
        save(app.screenshot().image, "r4_17pro_wide_portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        guard let wideActive = waitForFullscreenState(assetID: widePage.assetID, timeout: 8) else {
            XCTFail("fullscreen_state_ never appeared for the wide video after rotating")
            return
        }
        // Lets any transition settle before the screenshot.
        Thread.sleep(forTimeInterval: 1.5)
        save(app.screenshot().image, "r4_17pro_wide_landscape")
        ProbeLog.emit("r4_wide_fullscreen_active", wideActive.active ? 1 : 0)
        XCTAssertTrue(wideActive.active, "wide video did not go fullscreen on rotation")
        XCTAssertTrue(element("fullscreen_overlay").exists, "fullscreen_overlay missing while fullscreen_state_ reads active")

        XCUIDevice.shared.orientation = .portrait
        _ = waitForFullscreenState(assetID: widePage.assetID, timeout: 8, expectActive: false)

        guard let afterWide = centeredPage(timeout: 10) else {
            XCTFail("No centered page after rotating the wide video back")
            return
        }
        guard let tallPage = scrollToAsset(Self.portraitAssetID, from: afterWide, budget: 60) else {
            XCTFail("Never reached the known portrait fixture \(Self.portraitAssetID)")
            return
        }
        save(app.screenshot().image, "r4_17pro_tall_portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        guard let tallDeclined = waitForFullscreenState(assetID: tallPage.assetID, timeout: 8, expectActive: false) else {
            XCTFail("fullscreen_state_ never appeared for the tall video after rotating")
            return
        }
        Thread.sleep(forTimeInterval: 1.5)
        save(app.screenshot().image, "r4_17pro_tall_landscape")
        XCTAssertFalse(tallDeclined.active, "tall video incorrectly went fullscreen on rotation")
        XCTAssertEqual(tallDeclined.stance, "landscapeLeft", "rotation never reached the app")

        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Helpers (duplicated from M6Tests, same pattern that file's own comment describes)

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func scrollToAsset(_ assetID: String, from start: Page, budget: Int) -> Page? {
        var current = start
        if current.assetID == assetID { return current }
        for _ in 0..<budget {
            let advanced = recordPages(swipes: 1, from: current)
            guard advanced.count == 2, let next = advanced.last else { return nil }
            current = next
            if current.assetID == assetID { return current }
        }
        return nil
    }

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

    /// Polls until the probe's `assetID` matches `assetID` and, if
    /// `expectActive` is non-nil, its `active` field also matches.
    private func waitForFullscreenState(
        assetID: String, timeout: TimeInterval = 8, expectActive: Bool? = nil
    ) -> (active: Bool, stance: String, assetID: String)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let reading = sampleFullscreenStateRaw(), reading.assetID == assetID,
               expectActive == nil || reading.active == expectActive {
                Thread.sleep(forTimeInterval: 0.3)
                if let again = sampleFullscreenStateRaw(), again == reading {
                    return again
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return sampleFullscreenStateRaw()
    }

    private func save(_ image: UIImage, _ name: String) {
        guard let data = image.pngData() else { return }
        let dir = "/private/tmp/claude-501/-Users-barrychanleerwilliams-Downloads-cloudfull/cc902d69-3e6c-435e-a364-3e3da7a81e44/scratchpad/screens"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(dir)/\(name).png", contents: data)
    }
}
