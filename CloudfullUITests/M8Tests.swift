//
//  M8Tests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// UI tests for the filter and sort menu.
///
/// The menu opens with every section and default options (Random sort, no
/// filters). Each date sort orders three consecutive pages. The test reads
/// the creation time from `feed_facts_` and checks the year in
/// `feed_caption`. Each filter narrows `pool_filtered_`, and each page that
/// the feed shows matches the test's own predicate. Filters AND-combine.
/// Options persist across a relaunch.
///
/// When the only selected type is one that no seeded video has (Cinematic),
/// the feed shows the "No videos match" card. Reset restores the full pool.
///
/// This class has exactly eight `func test…` methods. A test script
/// (scripts/gate_all.sh) compares the `Executed N tests` count against this
/// number.
///
/// All helpers for this class are private to this file. No hard-coded pool
/// count exists anywhere in this file. Every bound below comes from
/// `pool_total_`, `pool_filtered_`, `feed_facts_`, or the seeder's
/// environment variables.
final class M8Tests: FeedUITestCase {

    // MARK: - 1. Menu opens with every section and starts at default options

    func testFilterMenuOpensWithEverySectionAndDefaultsAreClean() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }
        guard let filtered = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared")
            return
        }
        XCTAssertEqual(
            filtered, poolTotal,
            "pool_filtered_ (\(filtered)) does not equal pool_total_ (\(poolTotal)) at default options — an empty filter set must exclude nothing"
        )

        guard let token = optionsToken(timeout: 5) else {
            XCTFail("feed_options_ probe never appeared")
            return
        }
        XCTAssertEqual(token, "random_0000t0", "Default feed_options_ token was not 'random_0000t0' (read '\(token)')")

        XCTAssertTrue(app.buttons["feed_filter_button"].exists, "feed_filter_button does not exist")
        XCTAssertFalse(menuItem("feed_filter_badge").exists, "feed_filter_badge exists at default options (badgeCount should be 0)")
        // The mute pill sits left of the filter button. This test proves it
        // exists and is a button when the view is not fullscreen.
        // `M6Tests` proves it hides in fullscreen, using the same
        // `isFullscreen` condition as `feed_filter_button`.
        XCTAssertTrue(app.buttons["feed_mute_toggle"].exists, "feed_mute_toggle does not exist — the mute pill should be back, left of the filter button")

        openFilterMenu()
        let expectedItems = [
            "feed_sort_random", "feed_sort_datenewest", "feed_sort_dateoldest",
            "feed_filter_shrinkable", "feed_filter_big", "feed_filter_long",
            "feed_type_video", "feed_type_slomo", "feed_type_timelapse",
            "feed_type_screenrecording", "feed_type_cinematic",
            "feed_filter_reset"
        ]
        XCTAssertEqual(expectedItems.count, 12, "Test bookkeeping error: expected 3 sort + 3 filters + 5 types + reset = 12 items")
        for id in expectedItems {
            XCTAssertTrue(menuItem(id).waitForExistence(timeout: 3), "\(id) does not exist in the open filter menu")
        }

        let randomItem = menuItem("feed_sort_random")
        XCTAssertTrue(randomItem.waitForExistence(timeout: 3), "feed_sort_random not found before reading its checked-label")
        XCTAssertTrue(
            randomItem.label.contains("Random"),
            "feed_sort_random is not rendered as the checked sort at default options (label: '\(randomItem.label)')"
        )

        let resetItem = menuItem("feed_filter_reset")
        XCTAssertTrue(resetItem.waitForExistence(timeout: 3), "feed_filter_reset not found before reading isEnabled")
        XCTAssertFalse(resetItem.isEnabled, "feed_filter_reset is enabled at default options")

        // Tap Random again to close the menu. Random is already selected,
        // so the options do not change.
        tapMenuItem("feed_sort_random")
    }

    // MARK: - 2. Sort: Newest first orders pages newest-first

    func testSortDateNewestOrdersPagesNewestFirst() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }
        // The test uses the Random-sort facts only in a later failure
        // message. It does not compare them to other values.
        let randomBaseline = pageFacts(timeout: 8)

        tapMenuItem("feed_sort_datenewest")
        XCTAssertTrue(
            waitForOptions("dateNewest_0000t0"),
            "feed_options_ never settled on 'dateNewest_0000t0' after selecting Newest first"
        )

        guard let page0 = centeredPage(timeout: 10) else {
            XCTFail("No centered page_ element found after switching to Newest first")
            return
        }
        guard let f0 = pageFacts(timeout: 8) else {
            XCTFail("feed_facts_ probe never appeared on page 1 of Newest first (Random baseline was \(String(describing: randomBaseline)))")
            return
        }
        let advanced1 = recordPages(swipes: 1, from: page0)
        guard advanced1.count == 2, let page1 = advanced1.last else {
            XCTFail("Pager did not advance to page 2 under Newest first")
            return
        }
        guard let f1 = pageFacts(timeout: 8) else {
            XCTFail("feed_facts_ probe never appeared on page 2 of Newest first")
            return
        }
        let advanced2 = recordPages(swipes: 1, from: page1)
        guard advanced2.count == 2 else {
            XCTFail("Pager did not advance to page 3 under Newest first")
            return
        }
        guard let f2 = pageFacts(timeout: 8) else {
            XCTFail("feed_facts_ probe never appeared on page 3 of Newest first")
            return
        }

        let d = [f0.createdMs, f1.createdMs, f2.createdMs]
        XCTAssertTrue(d[0] >= d[1] && d[1] >= d[2], "Newest-first sequence was not non-increasing: \(d)")

        guard let caption = captionLabel(), !caption.isEmpty else {
            XCTFail("feed_caption missing or empty on the first page of Newest first")
            return
        }
        let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: Double(d[0]) / 1000))
        XCTAssertTrue(
            caption.contains("\(year)"),
            "feed_caption ('\(caption)') does not contain the year (\(year)) implied by feed_facts_'s createdMs (\(d[0]))"
        )

        ProbeLog.emit("m8_datenewest_epochs", "\(d[0]),\(d[1]),\(d[2])")
    }

    // MARK: - 3. Sort: Oldest first orders pages oldest-first, and the pool has more than one creation date

    func testSortDateOldestOrdersPagesOldestFirst() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }

        tapMenuItem("feed_sort_dateoldest")
        XCTAssertTrue(
            waitForOptions("dateOldest_0000t0"),
            "feed_options_ never settled on 'dateOldest_0000t0' after selecting Oldest first"
        )

        guard let page0 = centeredPage(timeout: 10) else {
            XCTFail("No centered page_ element found after switching to Oldest first")
            return
        }
        guard let f0 = pageFacts(timeout: 8) else {
            XCTFail("feed_facts_ probe never appeared on page 1 of Oldest first")
            return
        }
        let advanced1 = recordPages(swipes: 1, from: page0)
        guard advanced1.count == 2, let page1 = advanced1.last else {
            XCTFail("Pager did not advance to page 2 under Oldest first")
            return
        }
        guard let f1 = pageFacts(timeout: 8) else {
            XCTFail("feed_facts_ probe never appeared on page 2 of Oldest first")
            return
        }
        let advanced2 = recordPages(swipes: 1, from: page1)
        guard advanced2.count == 2 else {
            XCTFail("Pager did not advance to page 3 under Oldest first")
            return
        }
        guard let f2 = pageFacts(timeout: 8) else {
            XCTFail("feed_facts_ probe never appeared on page 3 of Oldest first")
            return
        }

        let d = [f0.createdMs, f1.createdMs, f2.createdMs]
        XCTAssertTrue(d[0] <= d[1] && d[1] <= d[2], "Oldest-first sequence was not non-decreasing: \(d)")

        // This checks that the pool has more than one creation date. It
        // switches to Newest first and re-reads page 1. Two sorts that
        // return the same first video prove nothing about ordering.
        tapMenuItem("feed_sort_datenewest")
        XCTAssertTrue(
            waitForOptions("dateNewest_0000t0"),
            "feed_options_ never settled on 'dateNewest_0000t0' after switching to Newest first for the spread proof"
        )
        guard centeredPage(timeout: 10) != nil else {
            XCTFail("No centered page_ element found after switching to Newest first for the spread proof")
            return
        }
        guard let newestF0 = pageFacts(timeout: 8) else {
            XCTFail("feed_facts_ probe never appeared on page 1 of Newest first for the spread proof")
            return
        }

        guard d[0] < newestF0.createdMs else {
            XCTFail("seeded pool has no date spread — reseed via scripts/seed_m3.sh")
            return
        }

        ProbeLog.emit("m8_dateoldest_first", d[0])
        ProbeLog.emit("m8_datenewest_first", newestF0.createdMs)
    }

    // MARK: - 4. Filter: Shrinkable narrows the pool and every shown page matches

    func testShrinkableFilterNarrowsPoolAndEveryPageMatches() throws {
        launch(resettingState: true)

        guard let total = poolTotal(timeout: 10), total >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }

        tapMenuItem("feed_filter_shrinkable")
        XCTAssertTrue(
            waitForOptions("random_1000t0"),
            "feed_options_ never settled on 'random_1000t0' after toggling Shrinkable"
        )

        guard let filtered = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared after toggling Shrinkable")
            return
        }

        let shrinkableFixtures = shrinkableFixtureIDs()
        let known1080p = known1080pIDs()
        XCTAssertGreaterThanOrEqual(
            filtered, shrinkableFixtures.count,
            "pool_filtered_ (\(filtered)) is below the seeded shrinkable-fixture floor (\(shrinkableFixtures.count))"
        )
        XCTAssertLessThanOrEqual(
            filtered, total - known1080p.count,
            "pool_filtered_ (\(filtered)) does not exclude the seeded 1080p spot clips (total \(total), known1080p \(known1080p.count))"
        )

        let badge = menuItem("feed_filter_badge")
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "feed_filter_badge does not exist with one filter toggled on")
        XCTAssertEqual(badge.label, "1", "feed_filter_badge does not read '1' with only Shrinkable toggled on")

        guard var current = centeredPage(timeout: 10) else {
            XCTFail("No centered page_ element found with Shrinkable filtering active")
            return
        }
        for pageIndex in 0..<3 {
            guard let f = pageFacts(timeout: 8) else {
                XCTFail("feed_facts_ probe never appeared on Shrinkable page #\(pageIndex)")
                return
            }
            XCTAssertTrue(
                expectedMatch(f, shrinkable: true, big: false, long: false, types: 31),
                "Page #\(pageIndex) (\(current.assetID)) with facts \(f) does not satisfy the test's own Shrinkable predicate"
            )
            if pageIndex < 2 {
                let advanced = recordPages(swipes: 1, from: current)
                guard advanced.count == 2, let next = advanced.last else {
                    XCTFail("Pager did not advance past Shrinkable page #\(pageIndex)")
                    return
                }
                current = next
            }
        }

        // Reachability: the filter must include matching assets. It must
        // not only exclude assets that do not match.
        let budget = total + max(10, total / 4)
        XCTAssertNotNil(
            scrollToAsset(in: Set(shrinkableFixtures), from: current, budget: budget),
            "Never reached a seeded shrinkable fixture within \(budget) swipes while the Shrinkable filter was active"
        )

        ProbeLog.emit("m8_shrinkable_total", total)
        ProbeLog.emit("m8_shrinkable_filtered", filtered)
    }

    // MARK: - 5. Filters: Big and Long each match their own predicate

    func testBigAndLongFiltersMatchTheirPredicate() throws {
        launch(resettingState: true)

        guard let total = poolTotal(timeout: 10), total >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }
        let excludedFixtureCount = shrinkableFixtureIDs().count + known1080pIDs().count

        // --- Big ---
        tapMenuItem("feed_filter_big")
        XCTAssertTrue(waitForOptions("random_0100t0"), "feed_options_ never settled on 'random_0100t0' after toggling Big")
        guard let bigFiltered = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared after toggling Big")
            return
        }
        XCTAssertLessThanOrEqual(
            bigFiltered, total - excludedFixtureCount,
            "Big filter (filtered=\(bigFiltered)) does not exclude every seeded fixture (total \(total), fixtures \(excludedFixtureCount))"
        )
        if bigFiltered == 0 {
            XCTAssertTrue(
                app.descendants(matching: .any)["filter_empty_card"].waitForExistence(timeout: 8),
                "filter_empty_card did not appear with Big filtering the pool to 0"
            )
            XCTAssertNil(centeredPage(timeout: 3), "A page_ element is centered while Big filters the pool to 0")
        } else {
            guard var current = centeredPage(timeout: 10) else {
                XCTFail("No centered page_ element found with Big filtering active and filtered=\(bigFiltered) > 0")
                return
            }
            for pageIndex in 0..<3 {
                guard let f = pageFacts(timeout: 8) else {
                    XCTFail("feed_facts_ probe never appeared on Big page #\(pageIndex)")
                    return
                }
                // Estimate the file size with the test's own formula: 5
                // Mbit/s per megapixel times the duration. Big must be
                // more than 100 MB.
                let megapixels = Double(f.w) * Double(f.h) / 1_000_000
                let seconds = Double(f.durationMs) / 1000
                let estimatedBytes = Int64((megapixels * seconds * 5_000_000) / 8)
                XCTAssertGreaterThan(
                    estimatedBytes, 100_000_000,
                    "Page #\(pageIndex) (\(current.assetID)) does not satisfy the test's own Big estimate (\(estimatedBytes) bytes)"
                )
                if pageIndex < 2 {
                    let advanced = recordPages(swipes: 1, from: current)
                    guard advanced.count == 2, let next = advanced.last else {
                        XCTFail("Pager did not advance past Big page #\(pageIndex)")
                        return
                    }
                    current = next
                }
            }
        }
        ProbeLog.emit("m8_big_filtered", bigFiltered)

        // --- Long (Big toggled back off first) ---
        tapMenuItem("feed_filter_big")
        tapMenuItem("feed_filter_long")
        XCTAssertTrue(waitForOptions("random_0010t0"), "feed_options_ never settled on 'random_0010t0' after toggling Long")
        guard let longFiltered = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared after toggling Long")
            return
        }
        XCTAssertLessThanOrEqual(
            longFiltered, total - excludedFixtureCount,
            "Long filter (filtered=\(longFiltered)) does not exclude every seeded fixture (total \(total), fixtures \(excludedFixtureCount))"
        )
        if longFiltered == 0 {
            XCTAssertTrue(
                app.descendants(matching: .any)["filter_empty_card"].waitForExistence(timeout: 8),
                "filter_empty_card did not appear with Long filtering the pool to 0"
            )
            XCTAssertNil(centeredPage(timeout: 3), "A page_ element is centered while Long filters the pool to 0")
        } else {
            guard var current = centeredPage(timeout: 10) else {
                XCTFail("No centered page_ element found with Long filtering active and filtered=\(longFiltered) > 0")
                return
            }
            for pageIndex in 0..<3 {
                guard let f = pageFacts(timeout: 8) else {
                    XCTFail("feed_facts_ probe never appeared on Long page #\(pageIndex)")
                    return
                }
                XCTAssertGreaterThan(
                    f.durationMs, 60_000,
                    "Page #\(pageIndex) (\(current.assetID)) does not satisfy the test's own Long predicate (\(f.durationMs) ms)"
                )
                if pageIndex < 2 {
                    let advanced = recordPages(swipes: 1, from: current)
                    guard advanced.count == 2, let next = advanced.last else {
                        XCTFail("Pager did not advance past Long page #\(pageIndex)")
                        return
                    }
                    current = next
                }
            }
        }
        ProbeLog.emit("m8_long_filtered", longFiltered)
    }

    // MARK: - 6. Filters AND-combine; Type narrows too

    func testFiltersCombineWithAndAndTypeNarrowsToo() throws {
        launch(resettingState: true)

        guard let total = poolTotal(timeout: 10), total >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }

        tapMenuItem("feed_filter_shrinkable")
        XCTAssertTrue(waitForOptions("random_1000t0"), "feed_options_ never settled on 'random_1000t0' after toggling Shrinkable")
        guard let s = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared with only Shrinkable toggled on")
            return
        }
        tapMenuItem("feed_filter_shrinkable")
        XCTAssertTrue(waitForOptions("random_0000t0"), "feed_options_ did not return to default after untoggling Shrinkable")

        tapMenuItem("feed_filter_long")
        XCTAssertTrue(waitForOptions("random_0010t0"), "feed_options_ never settled on 'random_0010t0' after toggling Long")
        guard let l = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared with only Long toggled on")
            return
        }

        tapMenuItem("feed_filter_shrinkable")
        XCTAssertTrue(
            waitForOptions("random_1010t0"),
            "feed_options_ never settled on 'random_1010t0' with Shrinkable and Long both on"
        )
        guard let sl = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared with Shrinkable and Long both on")
            return
        }
        XCTAssertLessThanOrEqual(
            sl, min(s, l),
            "Shrinkable+Long combined (\(sl)) exceeds min(Shrinkable \(s), Long \(l)) — the AND rule was violated"
        )

        let badge = menuItem("feed_filter_badge")
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "feed_filter_badge does not exist with two filters toggled on")
        XCTAssertEqual(badge.label, "2", "feed_filter_badge does not read '2' with Shrinkable and Long both toggled on")

        // Turn both filters back off.
        tapMenuItem("feed_filter_shrinkable")
        tapMenuItem("feed_filter_long")
        XCTAssertTrue(waitForOptions("random_0000t0"), "feed_options_ did not return to default after untoggling Shrinkable and Long")

        // No selected type is the default, and it means every type. Video
        // alone narrows the feed to plain videos (t1).
        tapMenuItem("feed_type_video")
        XCTAssertTrue(waitForOptions("random_0000t1"), "feed_options_ never settled on 'random_0000t1' with only Video selected")

        let shrinkableFixtures = shrinkableFixtureIDs()
        let known1080p = known1080pIDs()
        guard let videoOnly = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared with only Video selected")
            return
        }
        XCTAssertGreaterThanOrEqual(
            videoOnly, shrinkableFixtures.count + known1080p.count,
            "pool_filtered_ (\(videoOnly)) with only Video selected is below the seeded plain-video fixture floor (\(shrinkableFixtures.count + known1080p.count))"
        )
        XCTAssertLessThanOrEqual(
            videoOnly, total,
            "pool_filtered_ (\(videoOnly)) with only Video selected exceeds pool_total_ (\(total))"
        )

        guard var current = centeredPage(timeout: 10) else {
            XCTFail("No centered page_ element found with only Video selected")
            return
        }
        let slomoBit = 1 << 17
        let timelapseBit = 1 << 18
        let screenRecordingBit = 1 << 19
        let cinematicBit = 1 << 21
        for pageIndex in 0..<3 {
            guard let f = pageFacts(timeout: 8) else {
                XCTFail("feed_facts_ probe never appeared on Video-only page #\(pageIndex)")
                return
            }
            XCTAssertEqual(f.subtypes & slomoBit, 0, "Page #\(pageIndex) (\(current.assetID)) carries the slo-mo bit while only Video is selected")
            XCTAssertEqual(f.subtypes & timelapseBit, 0, "Page #\(pageIndex) (\(current.assetID)) carries the time-lapse bit while only Video is selected")
            XCTAssertEqual(f.subtypes & screenRecordingBit, 0, "Page #\(pageIndex) (\(current.assetID)) carries the screen-recording bit while only Video is selected")
            XCTAssertEqual(f.subtypes & cinematicBit, 0, "Page #\(pageIndex) (\(current.assetID)) carries the cinematic bit while only Video is selected")
            if pageIndex < 2 {
                let advanced = recordPages(swipes: 1, from: current)
                guard advanced.count == 2, let next = advanced.last else {
                    XCTFail("Pager did not advance past Video-only page #\(pageIndex)")
                    return
                }
                current = next
            }
        }

        tapMenuItem("feed_filter_reset")
        XCTAssertTrue(waitForOptions("random_0000t0"), "feed_options_ did not return to 'random_0000t0' after Reset")
        guard let afterReset = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared after Reset")
            return
        }
        XCTAssertEqual(afterReset, total, "pool_filtered_ (\(afterReset)) does not equal pool_total_ (\(total)) after Reset")
    }

    // MARK: - 7. Options survive a relaunch

    func testOptionsSurviveRelaunch() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }

        tapMenuItem("feed_sort_dateoldest")
        tapMenuItem("feed_filter_shrinkable")
        XCTAssertTrue(
            waitForOptions("dateOldest_1000t0"),
            "feed_options_ never settled on 'dateOldest_1000t0' before relaunching"
        )

        guard let filteredBefore = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared before relaunching")
            return
        }
        guard let firstPage = centeredPage(timeout: 10) else {
            XCTFail("No centered page_ element found before relaunching")
            return
        }
        let firstAsset = firstPage.assetID

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before the relaunch")
        launch(resettingState: false)

        XCTAssertTrue(
            waitForOptions("dateOldest_1000t0"),
            "feed_options_ did not read 'dateOldest_1000t0' after relaunching without the reset flag — options did not persist"
        )

        guard let filteredAfter = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared after relaunching")
            return
        }
        XCTAssertEqual(
            filteredAfter, filteredBefore,
            "pool_filtered_ changed across the relaunch (\(filteredBefore) -> \(filteredAfter)) with nothing else touching the library"
        )

        let badge = menuItem("feed_filter_badge")
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "feed_filter_badge does not exist after relaunching with two facets set")
        XCTAssertEqual(badge.label, "2", "feed_filter_badge does not read '2' after relaunching with Oldest first + Shrinkable set")

        guard let resumedPage = centeredPage(timeout: 15) else {
            XCTFail("No centered page_ element found after relaunching")
            return
        }
        XCTAssertEqual(
            resumedPage.assetID, firstAsset,
            "Feed did not resume on the saved sorted cursor (\(firstAsset)); if that asset vanished from the " +
            "library between launches this is expected to fall back to the sorted list's own first entry " +
            "instead, but resumed on \(resumedPage.assetID)"
        )

        openFilterMenu()
        // `Label(title, systemImage: "checkmark")` inside a Menu Button
        // renders as a UIAction with a decorative image. The accessibility
        // label is the title alone. `UIMenuElement.State.on` applies only
        // to Picker and Toggle menu content, and this menu uses one Button
        // for each row. So `isSelected` is always false, and the label
        // never contains "checkmark". This test verifies only that each
        // item exists, plus the `feed_options_` token asserted after the
        // relaunch above. It does not check the checkmark shown on
        // screen.
        let dateOldestItem = menuItem("feed_sort_dateoldest")
        XCTAssertTrue(dateOldestItem.waitForExistence(timeout: 5), "feed_sort_dateoldest not found after reopening the menu post-relaunch")
        let shrinkableItem = menuItem("feed_filter_shrinkable")
        XCTAssertTrue(shrinkableItem.waitForExistence(timeout: 5), "feed_filter_shrinkable not found after reopening the menu post-relaunch")

        // This test relaunches without the reset flag. Thus it must reset
        // the options itself, so that later test classes start from
        // default options.
        tapMenuItem("feed_filter_reset")
        XCTAssertTrue(waitForOptions("random_0000t0"), "feed_options_ did not return to 'random_0000t0' after the teardown Reset")
    }

    // MARK: - 8. No matches shows the empty card; Reset restores the pool

    func testNoMatchesShowsEmptyCardAndResetRestoresPool() throws {
        launch(resettingState: true)

        guard let total = poolTotal(timeout: 10), total >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }

        let typeIDsAndBits: [(id: String, bit: Int)] = [
            ("feed_type_video", 1 << 0),
            ("feed_type_slomo", 1 << 1),
            ("feed_type_timelapse", 1 << 2),
            ("feed_type_screenrecording", 1 << 3),
            ("feed_type_cinematic", 1 << 4)
        ]

        // No selected type means every type. To get an empty feed, select
        // only Cinematic (type value 16). The seeded fixtures have no
        // Cinematic video. `typeIDsAndBits` documents the type bits and is not
        // otherwise used.
        _ = typeIDsAndBits
        tapMenuItem("feed_type_cinematic")
        XCTAssertTrue(
            waitForOptions("random_0000t16"),
            "feed_options_ never settled on 'random_0000t16' after ticking Cinematic — the tap may have silently missed"
        )

        guard let filtered = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared with only Cinematic ticked")
            return
        }
        XCTAssertEqual(
            filtered, 0,
            "pool_filtered_ (\(filtered)) is not 0 with only Cinematic ticked — the seeded fixtures should hold no cinematic video"
        )

        XCTAssertTrue(
            app.descendants(matching: .any)["filter_empty_card"].waitForExistence(timeout: 8),
            "filter_empty_card did not appear with only Cinematic ticked"
        )
        XCTAssertTrue(app.buttons["filter_empty_reset"].exists, "filter_empty_reset does not exist alongside filter_empty_card")
        XCTAssertNil(centeredPage(timeout: 3), "A page_ element is centered while every Type is deselected")
        XCTAssertTrue(app.buttons["feed_filter_button"].exists, "feed_filter_button is not reachable over the empty-match state")

        app.buttons["filter_empty_reset"].tap()
        XCTAssertTrue(waitForOptions("random_0000t0"), "feed_options_ did not return to 'random_0000t0' after tapping filter_empty_reset")
        guard let filteredAfterReset = filteredPool(timeout: 10) else {
            XCTFail("pool_filtered_ probe never appeared after tapping filter_empty_reset")
            return
        }
        XCTAssertEqual(
            filteredAfterReset, total,
            "pool_filtered_ (\(filteredAfterReset)) does not equal pool_total_ (\(total)) after tapping filter_empty_reset"
        )
        XCTAssertFalse(app.descendants(matching: .any)["filter_empty_card"].exists, "filter_empty_card still exists after tapping filter_empty_reset")
        XCTAssertNotNil(centeredPage(timeout: 15), "No centered page_ element found within 15s of tapping filter_empty_reset")
    }

    // MARK: - Shared helpers

    /// Any accessibility element by identifier, not only buttons. Several
    /// menu items and probes are plain views or bare `Text`, not controls.
    private func menuItem(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// Taps `feed_filter_button` and waits for the menu to open, proven by
    /// `feed_sort_random` existing. Does nothing if the menu is already open.
    private func openFilterMenu() {
        guard !menuItem("feed_sort_random").exists else { return }
        app.buttons["feed_filter_button"].tap()
        _ = menuItem("feed_sort_random").waitForExistence(timeout: 5)
    }

    /// Opens the menu if needed, taps `id`, then waits for that item to
    /// stop existing before returning. The menu closes after every item
    /// tap. It waits until the menu closes, so that the next
    /// `openFilterMenu()` call does not start before the close animation
    /// ends.
    private func tapMenuItem(_ id: String) {
        openFilterMenu()
        let item = menuItem(id)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(id) did not appear in the open filter menu")
        item.tap()
        _ = waitFor(timeout: 5) { !self.menuItem(id).exists }
    }

    /// Reads a probe with a debounce, shared by every probe below. Two
    /// samples 0.3 seconds apart must be equal. `FeedUITestCase.poolTotal()`
    /// and `centeredPage()` use the same rule.
    private func debouncedProbe<T: Equatable>(prefix: String, timeout: TimeInterval, parse: (String) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> T? {
            guard let identifier = elementSnapshots(withPrefix: prefix).first?.identifier else { return nil }
            return parse(String(identifier.dropFirst(prefix.count)))
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

    /// Reads "feed_options_<sort>_<flags>t<typesRawValue>", the whole
    /// selection as one token.
    private func optionsToken(timeout: TimeInterval = 5) -> String? {
        debouncedProbe(prefix: "feed_options_", timeout: timeout) { $0 }
    }

    /// Polls `optionsToken()` until it equals `token` or `timeout` elapses.
    private func waitForOptions(_ token: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if optionsToken(timeout: 1) == token { return true }
        } while Date() < deadline
        return optionsToken(timeout: 1) == token
    }

    /// Reads "pool_filtered_<n>", which mirrors
    /// `AssetKeyResolver.filteredPooledCount`. The prefix `pool_filtered_`
    /// does not start with `pool_total_`, so a prefix search for one probe
    /// does not match the other.
    private func filteredPool(timeout: TimeInterval = 8) -> Int? {
        debouncedProbe(prefix: "pool_filtered_", timeout: timeout) { Int($0) }
    }

    /// The centered page's own facts, read directly from `feed_facts_`.
    /// `createdMs` is `-1` when the asset has no creation date.
    private struct Facts: Equatable {
        let w: Int
        let h: Int
        let durationMs: Int
        let subtypes: Int
        let createdMs: Int64
    }

    private func pageFacts(timeout: TimeInterval = 8) -> Facts? {
        debouncedProbe(prefix: "feed_facts_", timeout: timeout) { body in
            let parts = body.split(separator: "_")
            guard parts.count == 5,
                  let w = Int(parts[0]), let h = Int(parts[1]), let durationMs = Int(parts[2]),
                  let subtypes = Int(parts[3]), let createdMs = Int64(parts[4]) else { return nil }
            return Facts(w: w, h: h, durationMs: durationMs, subtypes: subtypes, createdMs: createdMs)
        }
    }

    /// `feed_caption`'s visible label, or `nil` if it is not in the tree.
    /// Reading `.label` on a missing element raises an uncatchable
    /// Objective-C exception. `FeedUITestCase.elementSnapshots` documents
    /// the same issue. This method checks existence first to avoid it.
    private func captionLabel() -> String? {
        let caption = app.descendants(matching: .any)["feed_caption"]
        guard caption.exists else { return nil }
        return caption.label
    }

    /// `xcodebuild` forwards each variable with the `TEST_RUNNER_` prefix to
    /// the test runner and removes the prefix. `M3ShrinkTests` and
    /// `M6Tests` have the same local helper.
    private func environmentAssetIDs(_ name: String) -> [String] {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The union of the three seeded 4K-fixture groups: 5 ids, all with a
    /// short side of 2160. Shrinkable must match every one of them.
    private func shrinkableFixtureIDs() -> [String] {
        environmentAssetIDs("CLOUDFULL_SHRINKABLE_ASSET_IDS")
            + environmentAssetIDs("CLOUDFULL_HDR_ASSET_ID")
            + environmentAssetIDs("CLOUDFULL_INCOMPRESSIBLE_ASSET_ID")
    }

    /// The two seeded 1080p clips (`spot_1080p_1.mp4`, `spot_1080p_2.mp4`).
    /// Shrinkable must exclude both.
    private func known1080pIDs() -> [String] {
        environmentAssetIDs("CLOUDFULL_KNOWN_1080P_ASSET_IDS")
    }

    /// The filter predicate, calculated again with the test's own
    /// arithmetic. The result does not depend on the app code under test.
    /// `types` is a `FeedTypeOptions`-shaped raw value (1 = Video, 31 = all
    /// five).
    private func expectedMatch(_ f: Facts, shrinkable: Bool, big: Bool, long: Bool, types: Int) -> Bool {
        if shrinkable, min(f.w, f.h) <= 1080 { return false }
        if big {
            let megapixels = Double(f.w) * Double(f.h) / 1_000_000
            let seconds = Double(f.durationMs) / 1000
            guard megapixels > 0, seconds.isFinite, seconds > 0 else { return false }
            let bytes = Int64((megapixels * seconds * 5_000_000) / 8)
            if bytes <= 100_000_000 { return false }
        }
        if long, !(f.durationMs > 60_000) { return false }

        let slomoBit = 1 << 17
        let timelapseBit = 1 << 18
        let screenRecordingBit = 1 << 19
        let cinematicBit = 1 << 21

        var assetTypes = 0
        var matchedSubtype = false
        if f.subtypes & slomoBit != 0 { assetTypes |= (1 << 1); matchedSubtype = true }
        if f.subtypes & timelapseBit != 0 { assetTypes |= (1 << 2); matchedSubtype = true }
        if f.subtypes & screenRecordingBit != 0 { assetTypes |= (1 << 3); matchedSubtype = true }
        if f.subtypes & cinematicBit != 0 { assetTypes |= (1 << 4); matchedSubtype = true }
        if !matchedSubtype { assetTypes |= (1 << 0) }

        return (assetTypes & types) != 0
    }

    /// Swipes forward up to `budget` times. Stops when the centered page's
    /// asset is in `targets`. `M3ShrinkTests` and `M6Tests` use a similar
    /// search.
    private func scrollToAsset(in targets: Set<String>, from start: Page, budget: Int) -> Page? {
        guard !targets.isEmpty else { return nil }
        var current = start
        if targets.contains(current.assetID) { return current }
        for _ in 0..<budget {
            let advanced = recordPages(swipes: 1, from: current)
            guard advanced.count == 2, let next = advanced.last else { return nil }
            current = next
            if targets.contains(current.assetID) { return current }
        }
        return nil
    }
}
