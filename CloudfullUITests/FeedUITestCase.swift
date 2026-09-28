//
//  FeedUITestCase.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// Shared driving infrastructure for every UI test that exercises the
/// feed. Every feed UI test class subclasses this, so the low-level
/// helpers and their debounce logic exist in one place. See the MARK
/// sections below for the helper groups.
class FeedUITestCase: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// One page of the feed, as the accessibility tree reports it.
    struct Page: Equatable {
        /// Absolute slot in the deck. Unique per deck entry within one launch.
        let slot: Int
        let assetID: String
    }

    // MARK: - Launch

    func launch(resettingState: Bool) {
        app.launchArguments = resettingState ? ["-cloudfull-reset-deck-state"] : []
        app.launch()
        grantPhotoAccessIfAsked()
    }

    /// A fresh install lands on the app's own permission gate. Only an
    /// explicit tap there triggers the system prompt. Both steps are
    /// optional. After the first launch of a session, the app has
    /// already granted access.
    func grantPhotoAccessIfAsked() {
        let allowInApp = app.buttons["Allow photo access"]
        if allowInApp.waitForExistence(timeout: 3) {
            allowInApp.tap()

            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allowButton = springboard.buttons["Allow Full Access"]
            if allowButton.waitForExistence(timeout: 5) {
                allowButton.tap()
            }
        }
    }

    // MARK: - Reading the accessibility tree

    /// Every identifier in the current accessibility tree that starts
    /// with `prefix`, paired with the frame it had at that instant.
    ///
    /// This method takes one atomic `snapshot()` of the app. It does not
    /// resolve a query and read each element. Each element read resolves
    /// the query again. If the tree changes between the two steps,
    /// XCTest raises "Failed to get matching snapshot: No matches found
    /// for Element at index N". Swift cannot catch that Objective-C
    /// exception, so the whole test fails. `snapshot()` throws a Swift
    /// error instead, and the caller's poll loop retries.
    ///
    /// This method does not read `isHittable`, because a snapshot does
    /// not carry it. Callers filter on geometry instead. For full-screen
    /// pages, the centering check below is a stricter test.
    func elementSnapshots(withPrefix prefix: String) -> [(identifier: String, frame: CGRect)] {
        guard let root = try? app.snapshot() else { return [] }
        var found: [(identifier: String, frame: CGRect)] = []
        var stack: [XCUIElementSnapshot] = [root]
        while let node = stack.popLast() {
            if node.identifier.hasPrefix(prefix) {
                found.append((node.identifier, node.frame))
            }
            stack.append(contentsOf: node.children)
        }
        return found
    }

    // MARK: - Pool-total probe

    /// Reads the hidden "pool_total_<n>" element `FeedView` always
    /// renders: the library count, minus liked, minus trash-queued, as
    /// of the view model's last recompute. A single sample can catch the
    /// tree mid-update. The method returns a value only when two reads
    /// 0.3 seconds apart agree.
    func poolTotal(timeout: TimeInterval = 10) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> Int? {
            guard let identifier = elementSnapshots(withPrefix: "pool_total_").first?.identifier else { return nil }
            return Int(identifier.dropFirst("pool_total_".count))
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

    /// Polls `poolTotal()` until it equals `expected` or `timeout`
    /// elapses. A trash-queue action recomputes the pool synchronously.
    /// A real PhotoKit delete (`emptyBin()`) changes the count only
    /// after an async change notification. The app debounces that
    /// notification by 300 ms, after PhotoKit's own delay. Reaching a
    /// post-delete count needs real retries, not one read.
    @discardableResult
    func waitForPoolTotal(toEqual expected: Int, timeout: TimeInterval = 25) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSeen: Int?
        repeat {
            if let value = poolTotal(timeout: 2) {
                lastSeen = value
                if value == expected { return value }
            }
        } while Date() < deadline
        return lastSeen
    }

    /// Polls `condition` until it is true or `timeout` elapses. A
    /// general-purpose check for UI state with no dedicated probe, for
    /// example "this element eventually disappears".
    @discardableResult
    func waitFor(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return condition()
    }

    // MARK: - Deck-next-slot probe

    /// What the "deck_next_" probe reports about the entry immediately
    /// after the currently centered page: a real absolute slot, or the
    /// deck's tail.
    enum NextSlot: Equatable {
        case slot(Int)
        case end
    }

    /// Reads the hidden "deck_next_<n>" / "deck_next_end" probe
    /// `FeedView` always renders. The value is the absolute slot of the
    /// deck entry immediately after the currently centered page, from
    /// `DeckViewModel`'s own state. Debounced like
    /// `centeredPage`/`poolTotal`. Two reads 0.3 seconds apart must
    /// agree before the caller trusts either one.
    ///
    /// The deck removes the slot of a liked, trash-queued, or deleted
    /// video (`DeckViewModel.removeFromFuture`, `performLibraryChange`).
    /// After such an edit, the next slot can be `current.slot + 2` or
    /// more. So `recordPages` and `advance` read the next slot from the
    /// deck and do not assume `current.slot + 1`.
    func expectedNextSlot(timeout: TimeInterval = 5) -> NextSlot? {
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> NextSlot? {
            guard let identifier = elementSnapshots(withPrefix: "deck_next_").first?.identifier else { return nil }
            let body = identifier.dropFirst("deck_next_".count)
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

    // MARK: - Driving the feed

    /// Swipes `swipes` times, returning `from` followed by every page
    /// landed on.
    ///
    /// The method reads the expected slot from the `deck_next_` probe
    /// before each swipe. It records a page only when its slot matches
    /// that value. It does not reject a repeated video, because the
    /// assertions check for repeats. If the slot does not change, the
    /// method swipes again. If the swipe skips past the expected slot,
    /// the method swipes down until it reaches that slot. Otherwise, the
    /// skipped page would look like an early repeat.
    func recordPages(swipes: Int, from first: Page) -> [Page] {
        var pages = [first]
        var current = first

        for swipe in 0..<swipes {
            XCTAssertEqual(app.state, .runningForeground, "App left the foreground at swipe \(swipe)")

            guard let expected = expectedNextSlot(timeout: 5) else {
                XCTFail("Could not read deck_next_ probe before swipe \(swipe), on slot \(current.slot)")
                break
            }

            guard case .slot(let expectedSlot) = expected else {
                // The probe reports the deck's tail. Retry before
                // failing, because one stale read does not prove that
                // the pager cannot move.
                let next = pollForAdvance(from: current, expectedSlot: nil, byPerforming: { self.app.swipeUp() })
                guard let next else {
                    failAtDeckTail(current: current, swipe: swipe)
                    return pages
                }
                pages.append(next)
                current = next
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }

            guard let next = pollForAdvance(from: current, expectedSlot: expectedSlot, byPerforming: { self.app.swipeUp() }) else {
                XCTFail("Pager did not advance past slot \(current.slot) to expected slot \(expectedSlot) after swipe \(swipe)")
                break
            }

            pages.append(next)
            current = next
            Thread.sleep(forTimeInterval: 0.5)
        }

        return pages
    }

    /// Performs `action`, which is expected to advance the pager the way
    /// a swipe would, for example a rail-button tap that auto-advances.
    /// Waits for the centered page to land on a new slot, and retries
    /// the action if the first attempt does not visibly register.
    /// Mirrors `recordPages`' own probe-driven retry loop, but driven by
    /// an arbitrary action instead of `app.swipeUp()`.
    @discardableResult
    func advance(
        from current: Page,
        retries: Int = 3,
        timeout: TimeInterval = 5,
        afterPerforming action: () -> Void
    ) -> Page? {
        guard let expected = expectedNextSlot(timeout: timeout) else {
            XCTFail("Could not read deck_next_ probe before advancing past slot \(current.slot)")
            return nil
        }
        guard case .slot(let expectedSlot) = expected else {
            return pollForAdvance(from: current, expectedSlot: nil, timeout: timeout, retries: retries, byPerforming: action)
        }
        return pollForAdvance(from: current, expectedSlot: expectedSlot, timeout: timeout, retries: retries, byPerforming: action)
    }

    /// Shared retry loop behind `recordPages` and `advance`. Performs
    /// `action` up to `retries` times, walking back with
    /// `app.swipeDown()` (up to 3 steps) whenever a fling overshoots
    /// `expectedSlot`. A `nil` `expectedSlot` means the probe reported the
    /// deck's tail. No walk-back target exists then, so the method
    /// accepts any change away from `current.slot`. For example, the
    /// deck can grow when an extension lands between the probe read and
    /// the swipe. If the slot does not change after all retries, the
    /// method returns nil.
    private func pollForAdvance(
        from current: Page,
        expectedSlot: Int?,
        timeout: TimeInterval = 5,
        retries: Int = 3,
        byPerforming action: () -> Void
    ) -> Page? {
        for _ in 0..<retries {
            action()
            var candidate = centeredPage(timeout: timeout)
            var backSteps = 0
            if let expectedSlot {
                while let c = candidate, c.slot > expectedSlot, backSteps < 3 {
                    app.swipeDown()
                    candidate = centeredPage(timeout: timeout)
                    backSteps += 1
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

    /// Reports a stall at the deck's tail. An empty pool is correct
    /// behavior. A non-empty pool means `extendDeckAfterExhaustion` did
    /// not extend the deck, which is an app regression.
    private func failAtDeckTail(current: Page, swipe: Int) {
        let pool = poolTotal(timeout: 5)
        if let pool, pool > 0 {
            XCTFail(
                "Deck reported its tail (deck_next_end) at slot \(current.slot) after swipe \(swipe), " +
                "but pool_total is \(pool) (> 0). extendDeckAfterExhaustion should have appended a " +
                "fresh cycle when the pager reached the true last slot — this looks like an app " +
                "regression, not a harness gap."
            )
        } else {
            XCTFail(
                "Deck reported its tail (deck_next_end) at slot \(current.slot) after swipe \(swipe) " +
                "and pool_total is \(pool.map(String.init) ?? "unreadable") — pool genuinely exhausted, " +
                "but the caller still expected another page."
            )
        }
    }

    /// Polls for the page centered in the viewport. During a paging
    /// animation, a preloaded neighbor can also be on screen. The
    /// method picks the page whose midY is nearest the screen center.
    /// It accepts that page only if the distance is less than a quarter
    /// of the page height. A mid-transition frame fails this check, so
    /// the poll waits.
    func centeredPage(timeout: TimeInterval = 5) -> Page? {
        let deadline = Date().addingTimeInterval(timeout)
        let screenMidY = app.frame.midY

        func sample() -> Page? {
            let candidates = elementSnapshots(withPrefix: "page_").filter { $0.frame.height > 0 }
            guard let closest = candidates.min(by: {
                abs($0.frame.midY - screenMidY) < abs($1.frame.midY - screenMidY)
            }), abs(closest.frame.midY - screenMidY) < closest.frame.height / 4 else {
                return nil
            }
            return Self.parse(closest.identifier)
        }

        // Require the same answer on two reads 0.3 seconds apart before
        // trusting it. A single sample can catch the accessibility tree
        // mid-update. For example, a stale frame for a page that already
        // scrolled away can pass the "centered" filter.
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

    /// Splits "page_<slot>_<assetID>". Asset local identifiers contain no
    /// underscore, so the first one separates the two halves.
    static func parse(_ identifier: String) -> Page? {
        guard identifier.hasPrefix("page_") else { return nil }
        let body = identifier.dropFirst("page_".count)
        guard let separator = body.firstIndex(of: "_") else { return nil }
        guard let slot = Int(body[body.startIndex..<separator]) else { return nil }
        let assetID = String(body[body.index(after: separator)...])
        guard !assetID.isEmpty else { return nil }
        return Page(slot: slot, assetID: assetID)
    }
}
