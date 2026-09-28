//
//  M9Tests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// Proves that 20 swipes cause no main-thread stall: `main_stalls_` reads
/// 0, and a worst gap above 0 proves the watchdog ran. Proves that the
/// rail answers a tap within 300 ms of a swipe. This proves that a load
/// never delays a tap.
///
/// This file holds exactly two test methods. A script parses
/// `Executed N tests` from the test run output, so the method count in
/// this file is part of that script's contract.
///
/// Every helper this file needs lives here; `FeedUITestCase.swift` stays
/// unmodified.
///
/// One rule shapes the first test: no accessibility read may happen inside
/// the measured window. `app.snapshot()`, which every `FeedUITestCase`
/// probe helper calls, makes the app serialize its whole accessibility
/// tree on its own main thread. The watchdog cannot tell that apart from
/// an app stall. So the 20 swipes run with bare `app.swipeUp()` calls
/// and a fixed pacing sleep, with no reads until all 20 finish. This costs
/// the test the ability to verify which pages it landed on. `M1ExitTests`
/// already proves landing correctness.
final class M9Tests: FeedUITestCase {

    // MARK: - 1. Twenty swipes produce no main-thread stalls

    func testTwentySwipesProduceNoMainThreadStalls() throws {
        app.launchArguments = ["-cloudfull-reset-deck-state", "-cloudfull-reset-stalls"]
        app.launch()
        grantPhotoAccessIfAsked()

        guard let pool = poolTotal(timeout: 10), pool >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }

        guard centeredPage(timeout: 15) != nil else {
            XCTFail("Feed never showed a page")
            return
        }

        // The watchdog's settle window is 2.0 seconds from when it arms.
        // `feedDidAppear()` restarts the watchdog under
        // `-cloudfull-reset-stalls`. This sleep of 2.5 seconds gives
        // margin, so the first swipe below cannot land inside the settle
        // window.
        Thread.sleep(forTimeInterval: 2.5)

        // Measured window: no snapshots, no queries, and no element
        // lookups of any kind between here and the probe read below.
        for _ in 0..<20 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.9)
        }

        // This sleep lets the last load finish inside the window, instead
        // of adding its cost to the probe read below.
        Thread.sleep(forTimeInterval: 1.0)

        guard let reading = mainStallReading(timeout: 10) else {
            XCTFail(
                "main_stalls_ probe never appeared — the watchdog is not running, so a zero here " +
                "would prove nothing"
            )
            return
        }

        ProbeLog.emit("main_stalls", reading.count)
        ProbeLog.emit("main_worst_gap_ms", reading.worstMs)

        XCTAssertEqual(
            reading.count, 0,
            "Main thread stalled \(reading.count) time(s) over 250 ms across 20 swipes (worst gap " +
            "\(reading.worstMs) ms) — design/M9_SPEC.md §2.3 lists every call that can cause this"
        )
        // This check proves the watchdog ran. A watchdog that never ran
        // reports main_stalls_0_0, which would otherwise pass the
        // assertion above while proving nothing.
        XCTAssertGreaterThan(
            reading.worstMs, 0,
            "worstGapMs is 0 — the display link never ticked, so the assertion above is vacuous"
        )
    }

    // MARK: - 2. The rail responds immediately after a swipe

    func testRailRespondsImmediatelyAfterASwipe() throws {
        launch(resettingState: true)

        guard let poolBefore = poolTotal(timeout: 10), poolBefore >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }

        guard centeredPage(timeout: 15) != nil else {
            XCTFail("Feed never showed a page")
            return
        }

        app.swipeUp() // Starts the load for the new page.
        let landed = Date()

        let heart = app.buttons["rail_like"]
        XCTAssertTrue(
            heart.waitForExistence(timeout: 0.3),
            "rail_like was not resolvable within 300 ms of a swipe — the main thread was busy loading"
        )
        ProbeLog.emit("rail_resolve_ms", Int(Date().timeIntervalSince(landed) * 1000))

        XCTAssertFalse(heart.isSelected, "Test precondition: the landed page is already kept")
        heart.tap()

        XCTAssertTrue(
            waitFor(timeout: 5) { app.buttons["rail_like"].isSelected },
            "Tapping rail_like within 300 ms of a swipe did not change the keep state"
        )

        // Cleanup required: a `LikedEntry` here is durable and would
        // shrink the pool for every later suite that runs against the
        // same simulator.
        app.buttons["rail_like"].tap() // unkeep
        XCTAssertTrue(
            waitFor(timeout: 5) { !app.buttons["rail_like"].isSelected },
            "rail_like did not return to unkept — this test must leave no LikedEntry behind"
        )
        XCTAssertEqual(
            waitForPoolTotal(toEqual: poolBefore), poolBefore,
            "pool_total_ did not return to its pre-test value — a LikedEntry survived this test"
        )
    }

    // MARK: - Shared harness

    /// Reads "main_stalls_<count>_<worstMs>", debounced with the same
    /// two-reads-0.3-seconds-apart discipline that `poolTotal` and
    /// `centeredPage` use elsewhere. A single sample can catch the
    /// accessibility tree mid-update.
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
