//
//  M12Tests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// UI tests for the media cache fix: a page's video should not have to
/// re-request its item from PhotoKit just because it scrolled off
/// screen and back, and an abandoned mid-load should be joined rather
/// than restarted. The third test covers a related fix, F8: liking a
/// video must refresh the preload window, not just the deck array.
///
/// The first two read the `itemreq_` probe (`PlayerPageView.swift`), which
/// counts real PhotoKit fetches per page id, not per asset — see
/// `ItemRequestCounters` in `DebugProbes.swift`. A cache hit never
/// bumps it, so the count is exactly "how many times this page actually
/// asked PhotoKit for its item".
///
/// Each test's final assertion names the plan step expected to fix it,
/// wrapped in `XCTExpectFailure` until that step lands. This file is
/// written against the plan's step 0 (DEBUG probes only, no behaviour
/// change yet), so both still measure the original bug. A later step's
/// commit should tighten (or remove) the wrapper for whichever test its
/// own fix actually reaches, rather than leaving every test soft
/// forever.
///
/// This class defines its own helpers, so it does not change
/// `FeedUITestCase`.
final class M12Tests: FeedUITestCase {

    // MARK: - 1. Plain swipe forward then back: does the starting page re-request?

    func testSwipeForwardThenBackRequestsItemOnlyOnce() throws {
        launch(resettingState: true)

        // This test travels at most one page from `start`, so it needs
        // none of `M10Tests`' 10-swipe headroom. `M5Tests`' shallower
        // tests use the same floor.
        guard let pool = poolTotal(timeout: 10), pool >= 5 else {
            XCTFail("Pool below floor (need >= 5): reseed via scripts/seed_m3.sh before gating")
            return
        }

        guard let start = centeredPage(timeout: 15) else {
            XCTFail("Feed never showed a page")
            return
        }
        let startPageID = Self.pageID(for: start)

        // Confirm the starting page's own first load actually counted as
        // one request, before touching anything else.
        guard let before = itemReq(timeout: 8), before.pageID == startPageID else {
            XCTFail("itemreq_ probe never reported for the starting page (slot \(start.slot))")
            return
        }
        XCTAssertEqual(
            before.count, 1,
            "Starting page reported \(before.count) requests before any swipe, expected exactly 1"
        )

        guard advance(from: start, afterPerforming: { self.app.swipeUp() }) != nil else {
            XCTFail("Pager did not advance past slot \(start.slot)")
            return
        }

        // `advance(from:afterPerforming:)` walks forward using the
        // `deck_next_` probe, which names the slot ahead of the page
        // currently on screen — there is no equivalent "previous slot"
        // probe. Swiping back is driven and checked directly instead.
        guard let backTo = swipeBack(to: start) else {
            XCTFail("Could not swipe back to slot \(start.slot)")
            return
        }
        XCTAssertEqual(backTo.assetID, start.assetID, "Slot \(start.slot) now holds a different asset after swiping back")

        guard let after = itemReq(timeout: 8), after.pageID == startPageID else {
            XCTFail("itemreq_ probe never reported for the starting page again after swiping back")
            return
        }

        ProbeLog.emit("m12_swipe_back_request_count", after.count)

        // This is the bug the plan exists to fix: the page's video item
        // lives only as long as it is on screen, so a swipe back
        // re-issues the PhotoKit request instead of reusing the item
        // that already finished loading. Fixed only once holders move
        // into the model (plan steps 4-7) — not landed yet.
        XCTExpectFailure("Swipe-back reuse needs holders in the model (plan steps 4-7); not landed yet") {
            XCTAssertEqual(
                after.count, 1,
                "Swipe back triggered \(after.count) total requests for slot \(start.slot), expected the already-loaded item to be reused (count 1)"
            )
        }
    }

    // MARK: - 2. Swipe away mid-load, then back: is the abandoned request joined or restarted?

    func testSwipeAwayMidLoadThenBackRequestsItemOnlyOnce() throws {
        // Slow enough that a swipe-away-and-back cycle, which takes well
        // under a second of real time, lands comfortably inside the
        // window where the neighbour's load has not resolved yet.
        launchSlow(seconds: 6)

        // Same shallow-travel floor as test 1 above.
        guard let pool = poolTotal(timeout: 10), pool >= 5 else {
            XCTFail("Pool below floor (need >= 5): reseed via scripts/seed_m3.sh before gating")
            return
        }

        guard let start = centeredPage(timeout: 15) else {
            XCTFail("Feed never showed a page")
            return
        }

        guard let next = advance(from: start, afterPerforming: { self.app.swipeUp() }) else {
            XCTFail("Pager did not advance past slot \(start.slot)")
            return
        }
        let neighborPageID = Self.pageID(for: next)

        // The neighbour's own slow load has just started. Confirm the
        // first request landed before abandoning it.
        guard let firstReading = itemReq(timeout: 8), firstReading.pageID == neighborPageID else {
            XCTFail("itemreq_ probe never reported for slot \(next.slot) after swiping to it")
            return
        }
        XCTAssertEqual(
            firstReading.count, 1,
            "Neighbour reported \(firstReading.count) requests on first arrival, expected exactly 1"
        )

        // Swipe away well inside the slow load's window, abandoning the
        // in-flight request.
        guard swipeBack(to: start) != nil else {
            XCTFail("Could not swipe back to slot \(start.slot) from slot \(next.slot)")
            return
        }

        // Swipe forward to the same neighbour again.
        guard let again = advance(from: start, afterPerforming: { self.app.swipeUp() }) else {
            XCTFail("Pager did not advance past slot \(start.slot) on the second attempt")
            return
        }
        XCTAssertEqual(
            again.slot, next.slot,
            "Second forward swipe landed on slot \(again.slot), not the same neighbour slot \(next.slot) — deck changed mid-test"
        )

        guard let secondReading = itemReq(timeout: 8), secondReading.pageID == neighborPageID else {
            XCTFail("itemreq_ probe never reported for slot \(next.slot) again after returning to it")
            return
        }

        ProbeLog.emit("m12_abandon_midload_request_count", secondReading.count)

        // Today, swiping away cancels the view's own load task, which
        // cancels the in-flight PhotoKit request outright
        // (`PhotoLibraryService.cancelImageRequest`). Coming back issues
        // a brand new request instead of joining the one abandoned
        // seconds ago. Expected to start passing once `PlayerItemCache`
        // starts the ±1 slots on its own task, independent of any one
        // view (plan step 2) — not landed yet in this reading.
        XCTExpectFailure("Abandoned mid-load join needs PlayerItemCache's own ±1 task (plan step 2); not landed yet") {
            XCTAssertEqual(
                secondReading.count, 1,
                "Returning to slot \(next.slot) after abandoning its load triggered \(secondReading.count) total requests, expected the abandoned request to be joined (count 1)"
            )
        }
    }

    // MARK: - 3. Like, then swipe: the preload window still works (F8)

    /// The plan's own illustration for this fix — "like a video whose
    /// asset repeats at +1, then swipe; the new +1 is ready" — cannot
    /// be built from a real swipe sequence. `ShuffleEngine
    /// .openingWithoutRecentRepeat` (see `M1ExitTests
    /// .assertRepeatsAreSpacedOut`) guarantees at least `poolTotal / 2 +
    /// 1` pages between two showings of the same asset, specifically to
    /// smooth the seam between one shuffled cycle and the next. A
    /// repeat at +1 is not a rare event this harness could wait out —
    /// it is an outcome the app deliberately prevents, so no swipe
    /// sequence run against the real shuffle can ever produce it.
    ///
    /// `removeFromFuture` can still remove an entry inside the render
    /// window through a different path:
    /// `removeResolvedExclusionsFromFuture`, fired when a cloud-key
    /// resolution lands for an asset shielded or queued in an earlier
    /// session. That asset is unrelated to whatever is on screen now,
    /// so no gap guarantee protects its position — it can land at +1
    /// by ordinary chance. Driving that deterministically would need
    /// `KeyRotationHarness` to land its result on a chosen slot, which
    /// it does not expose; that is a missing knob in the harness, not
    /// something this test file can work around.
    ///
    /// What this test can state: liking the page on screen — the
    /// common, always-reachable path into `removeFromFuture` — still
    /// leaves the preload window healthy. It confirms the like actually
    /// ran (`pool_total_` drops by one, so this is not vacuous), then
    /// swipes forward and checks that the neighbour still arrives
    /// preloaded, the same way `M10Tests
    /// .testFastLoadShowsLoaderBrieflyAndNeighboursAreReadyOnArrival`
    /// checks it with no like involved. This is a regression guard on
    /// the changed call path, not proof of the F8 scenario itself,
    /// which this harness has no way to construct.
    func testLikeThenSwipeNeighbourStillPreloads() throws {
        launch(resettingState: true)

        // Same shallow-travel floor as tests 1 and 2 above.
        guard let poolBefore = poolTotal(timeout: 10), poolBefore >= 5 else {
            XCTFail("Pool below floor (need >= 5): reseed via scripts/seed_m3.sh before gating")
            return
        }

        guard let start = centeredPage(timeout: 15) else {
            XCTFail("Feed never showed a page")
            return
        }

        app.buttons["rail_like"].tap()
        XCTAssertTrue(
            waitFor(timeout: 10) { (self.poolTotal(timeout: 2) ?? poolBefore) == poolBefore - 1 },
            "pool_total_ did not drop by 1 after liking — removeFromFuture never ran, so this test cannot say anything about it"
        )

        guard let next = advance(from: start, afterPerforming: { self.app.swipeUp() }) else {
            XCTFail("Pager did not advance past slot \(start.slot) after liking")
            return
        }

        guard let reading = firstFrameMs(timeout: 5) else {
            XCTFail("load_seq_ probe never appeared on slot \(next.slot) after liking and swiping")
            return
        }
        // The same bound `M10Tests` uses for an already-preloaded
        // neighbour: its first frame should already be decoded, not
        // freshly requested.
        XCTAssertTrue(
            (0...100).contains(reading),
            "Neighbour (slot \(next.slot)) reported firstFrameMs \(reading) after a like on the previous " +
            "page — expected it still preloaded, in 0...100"
        )

        ProbeLog.emit("m12_like_then_swipe_firstframe_ms", reading)

        // Leave no `LikedEntry` behind on a shared simulator — `M9Tests`
        // follows the same convention after exercising `rail_like`.
        // `rail_like` only exists on the active page, so this swipes
        // back to the page that was actually liked before tapping it
        // again.
        guard swipeBack(to: start) != nil else {
            XCTFail("Could not swipe back to slot \(start.slot) to undo the like")
            return
        }
        app.buttons["rail_like"].tap()
        XCTAssertTrue(
            waitFor(timeout: 10) { (self.poolTotal(timeout: 2) ?? poolBefore - 1) == poolBefore },
            "pool_total_ did not return to its starting value after unliking"
        )
    }

    // MARK: - Shared harness

    /// `-cloudfull-slow-load` takes its value as the next argument, so it
    /// cannot go through `FeedUITestCase.launch(resettingState:)`. Mirrors
    /// `M10Tests`' private helper of the same name and shape.
    private func launchSlow(seconds: Int) {
        app.launchArguments = ["-cloudfull-reset-deck-state", "-cloudfull-slow-load", "\(seconds)", "-cloudfull-local-only"]
        app.launch()
        grantPhotoAccessIfAsked()
    }

    /// `DeckEntry.id`'s own shape: `"<slot>_<assetID>"`. Reconstructed
    /// from a harness `Page` rather than read from the view, since the
    /// pager only exposes `page_<slot>_<assetID>` and `pageID` is
    /// private to `PlayerPageView`.
    private static func pageID(for page: Page) -> String { "\(page.slot)_\(page.assetID)" }

    /// Swipes down (backward) up to `retries` times until the centered
    /// page reports `target.slot`, or returns nil.
    /// `advance(from:afterPerforming:)` cannot do this: its retry
    /// walk-back assumes a forward `deck_next_` target, which does not
    /// exist for a page already behind the one on screen.
    private func swipeBack(to target: Page, retries: Int = 3, timeout: TimeInterval = 5) -> Page? {
        for _ in 0..<retries {
            app.swipeDown()
            if let candidate = centeredPage(timeout: timeout), candidate.slot == target.slot {
                return candidate
            }
        }
        return nil
    }

    /// Reads just `firstFrameMs` from
    /// `load_seq_<pageID>_<posterMs>_<spinnerMs>_<firstFrameMs>_<spinnerGoneMs>`
    /// (`PlayerPageView.swift`). Debounced the same way `itemReq` and
    /// `M10Tests.loadSeq` are. A full `LoadSeq` struct is not needed
    /// here, since this test only ever reads the one field.
    private func firstFrameMs(timeout: TimeInterval = 5) -> Int? {
        let prefix = "load_seq_"
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> Int? {
            guard let identifier = elementSnapshots(withPrefix: prefix).first?.identifier else { return nil }
            let parts = identifier.dropFirst(prefix.count).split(separator: "_", omittingEmptySubsequences: false)
            guard parts.count == 6 else { return nil }
            return Int(parts[4])
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

    private struct ItemReq: Equatable {
        let pageID: String
        let count: Int
    }

    /// Splits "itemreq_<pageID>_<n>". `pageID` itself is
    /// "<position>_<assetID>". Asset local identifiers contain no
    /// underscore, so the body always splits into exactly three parts.
    /// `M10Tests.parseLoadSeq` relies on the same fact.
    private static func parseItemReq(_ identifier: String) -> ItemReq? {
        let prefix = "itemreq_"
        guard identifier.hasPrefix(prefix) else { return nil }
        let body = identifier.dropFirst(prefix.count)
        let parts = body.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3, let count = Int(parts[2]) else { return nil }
        return ItemReq(pageID: "\(parts[0])_\(parts[1])", count: count)
    }

    /// Reads `itemreq_`, debounced with the same two-reads-0.3s-apart
    /// method `centeredPage`, `poolTotal`, and `M10Tests.loadSeq` all
    /// use. A single sample can catch the accessibility tree mid-update.
    private func itemReq(timeout: TimeInterval = 8) -> ItemReq? {
        let prefix = "itemreq_"
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> ItemReq? {
            guard let identifier = elementSnapshots(withPrefix: prefix).first?.identifier else { return nil }
            return Self.parseItemReq(identifier)
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
}
