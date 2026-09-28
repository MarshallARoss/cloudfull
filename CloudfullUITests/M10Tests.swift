//
//  M10Tests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// UI tests for player load timing. On a slow load, the poster appears
/// within 100 ms. The spinner appears in the same frame the page becomes
/// active, since there is no grace period before it shows. The
/// view removes the spinner when the first frame is ready, with no fade.
/// On a fast local load, a preloaded neighbour page arrives with its first
/// frame already decoded, so the spinner has nothing to wait for.
///
/// Keep exactly two test methods. A script counts the executed tests.
///
/// This class defines its own helpers, so it does not change
/// `FeedUITestCase`.
final class M10Tests: FeedUITestCase {

    // MARK: - 1. Slow load: poster first, spinner immediately after, removed with no fade on first frame

    func testSlowLoadShowsPosterThenSpinnerThenRemovesItOnFirstFrame() throws {
        // Loads slowly enough to observe each stage of loading before the
        // first frame arrives.
        launchSlow(seconds: 6)

        guard let pool = poolTotal(timeout: 10), pool >= 12 else {
            XCTFail("Pool below floor (need >= 12): reseed via scripts/seed_m3.sh before gating")
            return
        }

        guard let start = centeredPage(timeout: 15) else {
            XCTFail("Feed never showed a page")
            return
        }

        // Uses a single swipe, not `recordPages`.
        // This test checks load timing on the page it lands on, not deck
        // correctness across swipes. `M1ExitTests` and `M5Tests` test deck
        // correctness.
        app.swipeUp()
        guard let landed = centeredPage(timeout: 10) else {
            XCTFail("No centered page found after swiping from slot \(start.slot)")
            return
        }
        XCTAssertNotEqual(landed.slot, start.slot, "Pager did not advance past slot \(start.slot) after swipe")

        // The poster and the spinner both appear within 100 ms of landing.
        guard let afterPoster = loadSeq(until: { $0.posterMs >= 0 }, timeout: 5) else {
            XCTFail("load_seq_ probe never appeared within 5s of landing on slot \(landed.slot)")
            return
        }
        XCTAssertTrue(
            (0...100).contains(afterPoster.posterMs),
            "posterMs (\(afterPoster.posterMs)) was not in 0...100 shortly after landing on slot \(landed.slot) — " +
            "the poster was not on screen essentially in the frame the page landed"
        )
        // `PlayerPageView.spinnerGrace` is 0, so the spinner appears as soon
        // as the page becomes active, if the page is still loading.
        XCTAssertTrue(
            (0...100).contains(afterPoster.spinnerMs),
            "spinnerMs (\(afterPoster.spinnerMs)) was not in 0...100 shortly after landing on slot \(landed.slot) — " +
            "with no grace, the loader must be up essentially in the frame the page lands"
        )
        XCTAssertFalse(retryVisible(), "player_retry appeared while waiting for the poster")

        // The spinner appears over the poster, and no video frame
        // exists yet.
        guard let afterSpinner = loadSeq(until: { $0.spinnerMs >= 0 }, timeout: 6) else {
            XCTFail("load_seq_ probe never appeared within 6s while waiting for the spinner on slot \(landed.slot)")
            return
        }
        // The bound is the same 0...100 range the poster check above
        // uses, since both values must land in the frame the page
        // appears.
        XCTAssertTrue(
            (0...100).contains(afterSpinner.spinnerMs),
            "spinnerMs (\(afterSpinner.spinnerMs)) was not in 0...100 — with no grace the loader must appear " +
            "as the page lands, not after a wait"
        )
        // The poster and the spinner can appear in either order, since both
        // show in the same frame. Asserting an order between them would
        // assert the outcome of a race. The spinner must be over the
        // poster, not over a black screen. The posterMs bound and the
        // firstFrameMs check prove this.
        // The accessibility tree can lag the SwiftUI render by a frame or
        // two, so this polls briefly instead of taking one snapshot.
        XCTAssertTrue(waitFor(timeout: 2) { self.spinnerVisible() }, "feed_spinner was not in the tree once spinnerMs was reported")
        XCTAssertEqual(
            afterSpinner.firstFrameMs, -1,
            "firstFrameMs was \(afterSpinner.firstFrameMs), not -1, the instant the spinner appeared — the " +
            "spinner should be over the poster, not a video frame"
        )
        XCTAssertFalse(retryVisible(), "player_retry appeared while the spinner was up")

        // The first frame arrives, and the view removes the spinner at
        // the same instant, with no fade.
        guard let done = loadSeq(
            until: { $0.firstFrameMs >= 0 && $0.spinnerGoneMs >= 0 },
            timeout: 12
        ) else {
            XCTFail("load_seq_ probe never appeared within 12s while waiting for the first frame on slot \(landed.slot)")
            return
        }
        XCTAssertGreaterThanOrEqual(
            done.firstFrameMs, 0,
            "firstFrameMs never became >= 0 within 12s (last reading: \(done))"
        )
        XCTAssertGreaterThanOrEqual(
            done.spinnerGoneMs, 0,
            "spinnerGoneMs never became >= 0 within 12s (last reading: \(done))"
        )
        XCTAssertLessThanOrEqual(
            abs(done.spinnerGoneMs - done.firstFrameMs), 50,
            "spinnerGoneMs (\(done.spinnerGoneMs)) is more than 50ms from firstFrameMs (\(done.firstFrameMs)) " +
            "— the removal is not bound to the first-frame event; a scheduled fade-out would show here as ~200ms"
        )
        XCTAssertTrue(
            waitFor(timeout: 2) { !self.spinnerVisible() },
            "feed_spinner was still in the tree after firstFrameMs and spinnerGoneMs were both reported"
        )
        XCTAssertFalse(retryVisible(), "player_retry appeared by the end of the slow-load sequence")

        ProbeLog.emit("m10_slow_poster_ms", done.posterMs)
        ProbeLog.emit("m10_slow_spinner_ms", done.spinnerMs)
        ProbeLog.emit("m10_slow_firstframe_ms", done.firstFrameMs)
        ProbeLog.emit("m10_slow_spinner_gone_delta", done.spinnerGoneMs - done.firstFrameMs)
    }

    // MARK: - 2. Fast local load: the spinner does not linger, and preloaded neighbours are ready
    //
    // `PlayerPageView.spinnerGrace` is 0, so the spinner appears on every
    // page, including fast ones. This test proves the spinner does not
    // linger on a fast load. The poster appears immediately, and a
    // preloaded neighbour arrives with its first frame already decoded.

    func testFastLoadShowsLoaderBrieflyAndNeighboursAreReadyOnArrival() throws {
        launch(resettingState: true) // No slow-load flag.

        guard let pool = poolTotal(timeout: 10), pool >= 12 else {
            XCTFail("Pool below floor (need >= 12): reseed via scripts/seed_m3.sh before gating")
            return
        }

        guard let first = centeredPage(timeout: 15) else {
            XCTFail("Feed never showed a page")
            return
        }

        // `recordPages` swipes the whole batch in one call with no
        // per-landing hook, so a reading taken after it returns can only
        // describe the last page. This test instead reads `loadSeq()` after
        // each `centeredPage()` it lands on, using the same probe-backed
        // `advance(from:)` that `recordPages` uses internally.
        var pages: [Page] = [first]
        var readings: [LoadSeq] = []

        guard let firstReading = loadSeq(timeout: 5) else {
            XCTFail("load_seq_ probe never appeared on the first page (slot \(first.slot))")
            return
        }
        readings.append(firstReading)

        var current = first
        for swipeIndex in 0..<10 {
            guard let next = advance(from: current, afterPerforming: { self.app.swipeUp() }) else {
                XCTFail("Pager did not advance past slot \(current.slot) at swipe \(swipeIndex)")
                return
            }
            guard let reading = loadSeq(timeout: 5) else {
                XCTFail("load_seq_ probe never appeared on slot \(next.slot) (swipe \(swipeIndex))")
                return
            }
            pages.append(next)
            readings.append(reading)
            current = next
        }

        XCTAssertEqual(pages.count, 11, "Test bookkeeping error: expected 11 pages (first + 10 swipes)")
        XCTAssertEqual(readings.count, 11, "Did not collect a load_seq_ reading for every one of the 11 pages")

        // The spinner appearing on a fast load is expected. The regression
        // to catch is the spinner still being there seconds later. This
        // polls with a timeout, so one frame of accessibility-tree lag
        // cannot fail it. The slow-load test uses the same method.
        XCTAssertTrue(
            waitFor(timeout: 3) { !self.spinnerVisible() },
            "feed_spinner was still in the tree seconds after the last swipe — the loader lingered on a fast local load"
        )

        // On every page, the spinner appeared within 100 ms, and the
        // poster appeared within 100 ms (page 0: 600 ms).
        //
        // This does not assert whether the spinner is still in the tree at
        // the moment of a snapshot. That is a race between playback
        // starting and the test taking a snapshot, and asserting either
        // outcome would assert the winner of a race.
        for (index, reading) in readings.enumerated() {
            // A preloaded neighbour has no wait before playing, so
            // `spinnerRevealKey`'s task's `guard isActive, isLoading`
            // fails and the task returns without showing the spinner.
            // Page 0 is not preloaded, so it does show one.
            //
            // The invariant: either there was nothing to wait for
            // (spinnerMs is -1), or the spinner appeared at once
            // (0...100). A larger value means a grace period delays
            // the spinner.
            XCTAssertTrue(
                reading.spinnerMs == -1 || (0...100).contains(reading.spinnerMs),
                "Page #\(index) (\(pages[index].assetID)) reported spinnerMs \(reading.spinnerMs) — expected either " +
                "-1 (nothing to wait for) or 0...100 (shown as the page landed). A larger value means a grace came back."
            )
            // Page 0 has its own bound below.
            if index > 0 {
                XCTAssertTrue(
                    (0...100).contains(reading.posterMs),
                    "Page #\(index) (\(pages[index].assetID)) reported posterMs \(reading.posterMs), not in 0...100"
                )
            }
        }
        // Page 0's poster is a real PhotoKit round trip, not a cache
        // hit, measured at 23-273 ms on a test Mac.
        XCTAssertTrue(
            (0...600).contains(readings[0].posterMs),
            "First page reported posterMs \(readings[0].posterMs), not in 0...600"
        )

        // Each of the 10 pages after the first was a preloaded neighbour
        // before the swipe, so its first frame should already be decoded.
        // At least 7 of 10 should report exactly 0ms, and the
        // rest within 100ms of landing.
        let neighbourReadings = Array(readings.dropFirst())
        var zeroCount = 0
        for (offset, reading) in neighbourReadings.enumerated() {
            let index = offset + 1
            XCTAssertTrue(
                (0...100).contains(reading.firstFrameMs),
                "Page #\(index) (\(pages[index].assetID)) reported firstFrameMs \(reading.firstFrameMs), not in 0...100"
            )
            if reading.firstFrameMs == 0 { zeroCount += 1 }
        }
        XCTAssertGreaterThanOrEqual(
            zeroCount, 7,
            "Only \(zeroCount)/10 neighbour pages reported firstFrameMs == 0 — fewer than 7 landed with " +
            "their first frame already decoded before the swipe"
        )

        ProbeLog.emit("m10_fast_firstframe_ms_list", neighbourReadings.map { String($0.firstFrameMs) }.joined(separator: ","))
        ProbeLog.emit("m10_fast_zero_count", zeroCount)
    }

    // MARK: - Shared harness

    /// `-cloudfull-slow-load` takes its value as the next argument, so it
    /// cannot go through `FeedUITestCase.launch(resettingState:)`.
    private func launchSlow(seconds: Int) {
        app.launchArguments = ["-cloudfull-reset-deck-state", "-cloudfull-slow-load", "\(seconds)"]
        app.launch()
        grantPhotoAccessIfAsked()
    }

    private struct LoadSeq: Equatable {
        let pageID: String
        let posterMs: Int
        let spinnerMs: Int
        let firstFrameMs: Int
        let spinnerGoneMs: Int
    }

    /// Splits "load_seq_<pageID>_<posterMs>_<spinnerMs>_<firstFrameMs>_<spinnerGoneMs>".
    /// `pageID` itself is "<position>_<assetID>". Asset local identifiers
    /// contain no underscore. `FeedUITestCase.parse` also relies on this.
    /// After the prefix, the body has six "_"-separated components. The
    /// last four parse as integers. They may be negative, such as "-1",
    /// since `split(separator:)` splits only on "_" and never touches a
    /// leading "-".
    private static func parseLoadSeq(_ identifier: String) -> LoadSeq? {
        let prefix = "load_seq_"
        guard identifier.hasPrefix(prefix) else { return nil }
        let body = identifier.dropFirst(prefix.count)
        let parts = body.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 6,
              let posterMs = Int(parts[2]), let spinnerMs = Int(parts[3]),
              let firstFrameMs = Int(parts[4]), let spinnerGoneMs = Int(parts[5]) else { return nil }
        let pageID = "\(parts[0])_\(parts[1])"
        return LoadSeq(pageID: pageID, posterMs: posterMs, spinnerMs: spinnerMs, firstFrameMs: firstFrameMs, spinnerGoneMs: spinnerGoneMs)
    }

    /// Reads `load_seq_`, debounced with the same two-reads-0.3s-apart
    /// method `centeredPage`, `poolTotal`, and `expectedNextSlot` all use.
    /// A single sample can catch the accessibility tree mid-update.
    private func loadSeq(timeout: TimeInterval = 8) -> LoadSeq? {
        let prefix = "load_seq_"
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> LoadSeq? {
            guard let identifier = elementSnapshots(withPrefix: prefix).first?.identifier else { return nil }
            return Self.parseLoadSeq(identifier)
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

    /// Polls `loadSeq()` until `predicate` holds or `timeout` elapses, and
    /// returns the last reading either way. Returns nil only when no
    /// reading was ever obtained, so a failure downstream can print the
    /// real milliseconds instead of "nil".
    private func loadSeq(until predicate: (LoadSeq) -> Bool, timeout: TimeInterval) -> LoadSeq? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: LoadSeq?
        repeat {
            if let reading = loadSeq(timeout: 1) {
                last = reading
                if predicate(reading) { return reading }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return last
    }

    /// True while `feed_spinner` is in the tree. Reads through
    /// `elementSnapshots(withPrefix:)`, not through `app.otherElements[…]`
    /// or `app.activityIndicators[…]`. The `XCUIElement` type of a
    /// SwiftUI `ProgressView` on iOS 26.5 is not known. A wrong type
    /// reads as absent, so the absence checks would pass falsely.
    private func spinnerVisible() -> Bool {
        !elementSnapshots(withPrefix: "feed_spinner").isEmpty
    }

    /// True while `player_retry` is in the tree. Reads the same
    /// snapshot-prefix way as `spinnerVisible()`, rather than guessing
    /// whether SwiftUI's `Button` reports as `.buttons` or `.staticTexts`.
    private func retryVisible() -> Bool {
        !elementSnapshots(withPrefix: "player_retry").isEmpty
    }
}
