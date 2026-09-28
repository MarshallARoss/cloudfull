//
//  M1ExitTests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// Proves that the feed shuffles the whole library, shows no repeat until
/// every video has been seen once, and keeps its place across a restart.
///
/// The library size is not fixed. Videos get added by seeding and removed
/// by emptying the bin over the life of the simulator. Every count here
/// is read at runtime from the app's own "pool_total_<n>" probe, not
/// hardcoded. See `FeedUITestCase.poolTotal()`.
final class M1ExitTests: FeedUITestCase {

    // MARK: - Clean store

    /// Proves that the feed shows no repeat until every video has been
    /// seen once, judged from the start of a pass. The test starts from a
    /// wiped store, since this property belongs to a whole pass and a
    /// resumed half-pass cannot decide it.
    func testScrollFiftyPagesNoEarlyRepeat() throws {
        launch(resettingState: true)

        guard let first = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        guard let poolTotal = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }
        let minimumRepeatGap = poolTotal / 2 + 1

        // The budget must clear `poolTotal` — a full cycle takes exactly
        // that many pages — plus headroom past it. The extra headroom lets
        // the run also catch a repeat and check its spacing. Deriving the
        // budget from the live pool keeps the suite correct at any library
        // size of 25 or more.
        let recordingBudget = poolTotal + max(10, poolTotal / 4)
        let pages = recordPages(swipes: recordingBudget - 1, from: first)
        XCTAssertEqual(pages.count, recordingBudget, "Did not record a page for every swipe")

        let ids = pages.map(\.assetID)
        let distinctIDs = Set(ids)

        // The library holds exactly `poolTotal` eligible videos right now,
        // and the recording budget must reach all of them. Anything less
        // means the deck is not shuffling the whole library.
        XCTAssertEqual(
            distinctIDs.count, poolTotal,
            "Expected all \(poolTotal) pooled videos, saw \(distinctIDs.count): \(ids)"
        )

        // First index where an id repeats something already seen earlier.
        var seenSoFar = Set<String>()
        var firstRepeatIndex: Int?
        for (idx, id) in ids.enumerated() {
            if seenSoFar.contains(id) {
                firstRepeatIndex = idx
                break
            }
            seenSoFar.insert(id)
        }

        if let firstRepeatIndex {
            // No-early-repeat property: every distinct id seen in the whole
            // run must appear once before the first repeat. The deck
            // finishes a full pass before it reshuffles.
            let idsBeforeFirstRepeat = Set(ids[0..<firstRepeatIndex])
            XCTAssertEqual(
                idsBeforeFirstRepeat, distinctIDs,
                "Deck repeated a video before the full library had been shown once. " +
                "First repeat at index \(firstRepeatIndex). Full sequence: \(ids)"
            )
        }

        assertNoAdjacentRepeat(pages)
        assertRepeatsAreSpacedOut(pages, minimumGap: minimumRepeatGap)
    }

    // MARK: - Resume

    /// Proves that the feed's position survives an app restart. The test
    /// runs against whatever state is already on disk, with no reset flag.
    /// It then restarts the app mid-run. This proves the feed returns to
    /// where it was and keeps going.
    func testResumesSavedPositionAfterRelaunch() throws {
        launch(resettingState: false)

        guard let first = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found on the resumed feed")
            return
        }

        guard let poolTotal = poolTotal(timeout: 10) else {
            XCTFail("Could not read pool_total_<n> probe")
            return
        }
        let minimumRepeatGap = poolTotal / 2 + 1

        let before = recordPages(swipes: 14, from: first)
        XCTAssertEqual(before.count, 15, "Did not record a page for every swipe before the restart")
        assertNoAdjacentRepeat(before)
        assertRepeatsAreSpacedOut(before, minimumGap: minimumRepeatGap)

        guard let leftOn = before.last else {
            XCTFail("No page recorded before the restart")
            return
        }

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate")

        launch(resettingState: false)

        guard let resumed = centeredPage(timeout: 20) else {
            XCTFail("Feed did not come back after the restart")
            return
        }

        // The deck re-deals slot numbers from zero on every launch, so
        // slots are not comparable across a restart. The test compares the
        // asset id instead. The cursor is the furthest page the user
        // reached, so the feed must return to the same page.
        XCTAssertEqual(
            resumed.assetID, leftOn.assetID,
            "Feed did not resume on the video it was left on. " +
            "Left on \(leftOn.assetID), came back on \(resumed.assetID)"
        )

        // The feed must also keep scrolling from there, not stop.
        let after = recordPages(swipes: 9, from: resumed)
        XCTAssertEqual(after.count, 10, "Did not record a page for every swipe after the restart")
        assertNoAdjacentRepeat(after)
        assertRepeatsAreSpacedOut(after, minimumGap: minimumRepeatGap)
    }

    // MARK: - Assertions

    /// A video must never appear in two consecutive slots. `recordPages`
    /// records every page by slot, so this check sees a real repeat.
    private func assertNoAdjacentRepeat(
        _ pages: [Page],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in 1..<max(pages.count, 1) {
            let previous = pages[index - 1]
            let current = pages[index]
            XCTAssertNotEqual(
                previous.assetID, current.assetID,
                "Same video in consecutive slots \(previous.slot) and \(current.slot) " +
                "(index \(index - 1) to \(index)): \(current.assetID)",
                file: file, line: line
            )
        }
    }

    /// Two showings of one video must be at least half a library apart.
    /// `ShuffleEngine.openingWithoutRecentRepeat` (called by `DeckViewModel`
    /// when it deals a fresh cycle) guarantees this gap onto the tail of
    /// the old cycle. The caller derives `minimumGap` from the live pool
    /// total, since the library size is not fixed.
    private func assertRepeatsAreSpacedOut(
        _ pages: [Page],
        minimumGap: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lastIndex: [String: Int] = [:]
        for (index, page) in pages.enumerated() {
            if let previous = lastIndex[page.assetID] {
                XCTAssertGreaterThanOrEqual(
                    index - previous, minimumGap,
                    "\(page.assetID) repeated after only \(index - previous) pages " +
                    "(indices \(previous) and \(index)); minimum is \(minimumGap)",
                    file: file, line: line
                )
            }
            lastIndex[page.assetID] = index
        }
    }
}
