//
//  M5Tests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// UI tests for key rotation safety, render-path fetches, deck write cost,
/// launch time, Limited access, the scrubber, and the space counter.
///
/// The tests prove: a liked video stays protected from the trash through
/// identifier rotation. PhotoKit and SwiftData fetches during an export
/// stay within a small fixed budget (8 and 2 over 6 seconds). A like or
/// trash tap writes O(1) into SwiftData, independent of deck length. A pool
/// of 300 or more items launches to the first playing frame in under 3
/// seconds. Limited Photos access does not destroy queued or liked state.
/// The bottom-edge scrubber seeks without breaking tap-to-mute or paging.
/// The space counter counts every byte exactly once across queue, shrink,
/// restore, and empty.
///
/// This class has exactly eight `func test…` methods. The gate parses
/// `Executed N tests` from the output, so this count is a contract. The
/// standard rounds expect 7 executed methods.
/// `testLargePoolLaunchesUnderThreeSeconds` is skipped by default. The scale
/// round expects 1 executed method, only that one. Adding or removing a
/// method without updating `scripts/gate_all.sh`'s expected counts fails the
/// gate.
///
/// This class defines its own helpers so that `FeedUITestCase` keeps a
/// small shared surface. `M4Tests` uses the same pattern.
final class M5Tests: FeedUITestCase {

    // MARK: - Kept video survives identifier rotation

    func testKeptVideoSurvivesIdentifierRotation() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 5 else {
            XCTFail("Pool floor of 5 not met for the rotation scenario")
            return
        }
        guard let kept = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        app.buttons["rail_like"].tap()
        XCTAssertTrue(
            waitFor(timeout: 10) { (self.poolTotal(timeout: 2) ?? poolTotal) == poolTotal - 1 },
            "pool_total_ did not drop by 1 after liking — the shield never took effect"
        )

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before the backfill relaunch")
        launch(resettingState: false)

        guard let backfill = backfillReading(timeout: 45) else {
            XCTFail("backfill_ probe never reached 'done' within 45s")
            return
        }
        guard backfill.resolved >= 1 else {
            XCTFail(
                "Backfill resolved 0 rows — the simulator produced no portable id, so the rotation " +
                "scenario cannot be driven. Failing loudly rather than proving nothing."
            )
            return
        }

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before the rotation relaunch")
        launchRotating()

        guard let rotation = rotationProbe(timeout: 15) else {
            XCTFail("rotation_probe_ never appeared")
            return
        }
        guard let likedLive = rotation.liked else {
            XCTFail("rotation_probe_ reported no rotated liked row (read 'none') — the harness found " +
                     "no eligible LikedEntry or its cloud key would not resolve")
            return
        }
        XCTAssertEqual(likedLive, kept.assetID, "rotation_probe_ rotated a different row than the one this test liked")

        // The deck removes a rotated shielded video as soon as key
        // resolution completes (`removeResolvedExclusionsFromFuture`). A
        // pager scan for the video therefore gives an unreliable result.
        // `rotation_safety_` reads the resolver shield state for the live
        // id directly.
        guard let safety = rotationSafetyProbe(timeout: 10) else {
            XCTFail("rotation_safety_ probe never appeared")
            return
        }
        XCTAssertEqual(
            safety.likedShielded, true,
            "AssetKeyResolver does not report the rotated liked video (\(likedLive)) as shielded"
        )
        // `TrashService.queue(assetID:)` guards on
        // `!resolver.isShielded(assetID)`, which reads this exact flag. A
        // `false` value here lets a shielded, rotated video enter the
        // trash queue. No row must exist for it anywhere in this flow.
        guard let rowsAfterRotation = trashRowsProbe(timeout: 10) else {
            XCTFail("trash_rows_ probe never appeared after rotation")
            return
        }
        XCTAssertEqual(rowsAfterRotation.count, 0, "A TrashEntry row exists for a shielded, rotated video")
        XCTAssertEqual(rowsAfterRotation.dormant, 0)

        // After key resolution, the deck must not deal the rotated kept
        // video again. A bounded scan of the whole pool that never shows
        // it proves the exclusion works.
        let budget = poolTotal + max(10, poolTotal / 4)
        guard var current = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found after the rotation relaunch")
            return
        }
        var sawKept = current.assetID == kept.assetID
        var swiped = 0
        while !sawKept && swiped < budget {
            guard let next = stepForward(from: current) else { break }
            current = next
            swiped += 1
            sawKept = current.assetID == kept.assetID
        }
        XCTAssertFalse(
            sawKept,
            "The rotated kept video \(kept.assetID) was dealt into the pager after \(swiped) swipes — " +
            "resolution landing should have removed it from every future slot"
        )

        // The rotation does not change pool_total_. The PhotoKit asset
        // keeps its identity. The harness changes only the stored
        // `assetKey`, and the `cloudKey` still resolves to the same live
        // id. The exclusion count must equal the count after the like.
        XCTAssertEqual(
            waitForPoolTotal(toEqual: poolTotal - 1, timeout: 15), poolTotal - 1,
            "pool_total_ changed across the rotation — the shielded video's exclusion did not survive"
        )

        app.buttons["bin_open"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["trash_empty_state"].waitForExistence(timeout: 10),
            "trash_empty_state did not appear — a row was written for a shielded video"
        )
    }

    // MARK: - Queued video survives identifier rotation

    func testQueuedVideoSurvivesIdentifierRotation() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 5 else {
            XCTFail("Pool floor of 5 not met for the rotation scenario")
            return
        }
        guard let queued = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        guard advance(from: queued, afterPerforming: { self.app.buttons["rail_trash"].tap() }) != nil else {
            XCTFail("Pager did not advance after tapping rail_trash while seeding a TrashEntry row")
            return
        }
        XCTAssertTrue(app.buttons["bin_open"].label.contains("1"), "bin_open does not read 1 after queuing")

        guard let spaceBefore = spaceProbe(timeout: 10) else {
            XCTFail("space_probe_ never appeared after queuing")
            return
        }
        XCTAssertEqual(spaceBefore.reclaimed, 0)
        let pendingBefore = spaceBefore.pending

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before the backfill relaunch")
        launch(resettingState: false)

        guard let backfill = backfillReading(timeout: 45) else {
            XCTFail("backfill_ probe never reached 'done' within 45s")
            return
        }
        guard backfill.resolved >= 1 else {
            XCTFail("Backfill resolved 0 rows — the rotation scenario cannot be driven. Failing loudly rather than proving nothing.")
            return
        }

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before the rotation relaunch")
        launchRotating()

        guard let rotation = rotationProbe(timeout: 15) else {
            XCTFail("rotation_probe_ never appeared")
            return
        }
        guard let trashLive = rotation.trash else {
            XCTFail("rotation_probe_ reported no rotated trash row (read 'none')")
            return
        }
        XCTAssertEqual(trashLive, queued.assetID, "rotation_probe_ rotated a different row than the one this test queued")

        XCTAssertTrue(
            waitFor(timeout: 10) { self.app.buttons["bin_open"].label.contains("1") },
            "bin_open no longer reads 1 after rotation — the queue did not survive"
        )
        guard let rowsAfterRotation = trashRowsProbe(timeout: 10) else {
            XCTFail("trash_rows_ probe never appeared after rotation")
            return
        }
        XCTAssertEqual(rowsAfterRotation.count, 1, "trash_rows_ count changed after rotation")
        XCTAssertEqual(
            rowsAfterRotation.dormant, 0,
            "trash_rows_ reported a dormant row — the row must resolve through its cloud key, not go dormant"
        )
        guard let spaceAfterRotation = spaceProbe(timeout: 10) else {
            XCTFail("space_probe_ never appeared after rotation")
            return
        }
        XCTAssertEqual(spaceAfterRotation.pending, pendingBefore, "space_probe_ pending changed after rotation")
        XCTAssertEqual(spaceAfterRotation.reclaimed, 0)

        // This check reads the queue state from the resolver for the live
        // id that `rotationProbe()` names. `bin_open` and `trash_rows_`
        // prove only that a row exists.
        guard let safetyAfterRotation = rotationSafetyProbe(timeout: 10) else {
            XCTFail("rotation_safety_ probe never appeared after rotation")
            return
        }
        XCTAssertEqual(
            safetyAfterRotation.trashQueued, true,
            "AssetKeyResolver does not report the rotated queued video (\(trashLive)) as queued"
        )

        // The queued video must stay restorable. The restore cell
        // identifier uses the stored `assetKey`, which is now the old id.
        // Find the cell by prefix, not from `queued.assetID`.
        app.buttons["bin_open"].tap()
        guard let restoreID = elementSnapshots(withPrefix: "trash_restore_")
            .map(\.identifier)
            .first(where: { $0 != "trash_restore_failed" }) else {
            XCTFail("No trash_restore_ cell found in the bin after rotation")
            return
        }
        let restoreCell = app.descendants(matching: .any)[restoreID]
        XCTAssertTrue(restoreCell.waitForExistence(timeout: 5), "Restore cell did not resolve to a live element")
        restoreCell.tap()
        XCTAssertTrue(waitFor(timeout: 10) { !restoreCell.exists }, "Restored cell did not disappear")

        // `GateProbes` (space_probe_/trash_rows_/etc.) lives in
        // `PermissionGateView`, below anything `FeedView` presents as a
        // sheet. A presented modal makes that background content
        // unreachable to XCUITest. Dismiss the bin before reading them.
        // These are persisted store values, and they do not depend on
        // whether the sheet is open.
        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        } else {
            app.swipeDown()
        }

        guard let rowsAfterRestore = trashRowsProbe(timeout: 10) else {
            XCTFail("trash_rows_ probe never appeared after restoring")
            return
        }
        XCTAssertEqual(rowsAfterRestore.count, 0, "trash_rows_ count did not return to 0 after restoring")
        guard let spaceAfterRestore = spaceProbe(timeout: 10) else {
            XCTFail("space_probe_ never appeared after restoring")
            return
        }
        XCTAssertEqual(spaceAfterRestore.pending, 0, "space_probe_ pending did not return to 0 after restoring")
        XCTAssertEqual(spaceAfterRestore.reclaimed, 0)

        // A restore removes the id from the resolver exclusion set. It
        // does not remove the permanent exception in the current cycle.
        // Exceptions are append-only for a cycle. The video returns only
        // in a new cycle. This test checks pool_total_ and the identity
        // probe for the exact id instead.
        XCTAssertEqual(
            waitForPoolTotal(toEqual: poolTotal, timeout: 15), poolTotal,
            "Pool total did not return to its pre-queue value after restoring"
        )
        guard let safetyAfterRestore = rotationSafetyProbe(timeout: 10) else {
            XCTFail("rotation_safety_ probe never appeared after restoring")
            return
        }
        XCTAssertEqual(
            safetyAfterRestore.trashQueued, false,
            "AssetKeyResolver still reports the restored video (\(trashLive)) as queued — the restore " +
            "may have mis-targeted a different row"
        )
    }

    // MARK: - No body-time fetches during an export

    func testNoBodyTimeFetchesDuringExport() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 25 else {
            XCTFail("Pool below floor (need >= 25): reseed via scripts/seed_m3.sh before gating")
            return
        }
        guard let shrinkPage = findSeededShrinkablePage(poolTotal: poolTotal) else {
            XCTFail("Never reached a seeded shrinkable 4K clip (CLOUDFULL_SHRINKABLE_ASSET_IDS)")
            return
        }
        _ = shrinkPage

        let shrinkButton = app.buttons["rail_shrink"]
        XCTAssertTrue(shrinkButton.waitForExistence(timeout: 5), "rail_shrink missing on the seeded 4K clip")
        XCTAssertTrue(shrinkButton.isEnabled, "rail_shrink is not enabled on the seeded 4K clip")
        shrinkButton.tap()
        XCTAssertTrue(app.buttons["shrink_confirm"].waitForExistence(timeout: 5), "Shrink confirm sheet did not appear")
        app.buttons["shrink_confirm"].tap()

        XCTAssertTrue(
            element("shrink_progress").waitForExistence(timeout: 10),
            "shrink_progress badge did not appear after confirming the shrink"
        )

        guard let before = fetchCounters(timeout: 10) else {
            XCTFail("libfetch_ probe never appeared")
            return
        }

        // No touch events happen for the whole window. The export
        // republishes `jobs` about 5 times per second, so up to three
        // `FeedPageContent` bodies and `FeedView`'s body re-evaluate about
        // 30 times. The test allows at most 8 PhotoKit fetches and 2
        // SwiftData fetches in this window.
        Thread.sleep(forTimeInterval: 6)

        guard let after = fetchCounters(timeout: 10) else {
            XCTFail("libfetch_ probe never re-appeared")
            return
        }

        XCTAssertTrue(
            element("shrink_progress").exists,
            "shrink_progress disappeared during the measurement window — it must cover an in-flight export"
        )

        let deltaPhotoKit = after.photoKit - before.photoKit
        let deltaSwiftData = after.swiftData - before.swiftData
        XCTAssertLessThanOrEqual(
            deltaPhotoKit, 8,
            "Δ(photoKit)=\(deltaPhotoKit) exceeds the body-fetch budget of 8 over the 6s window"
        )
        // Record the measured value for the gate log.
        ProbeLog.emit("libfetch_photokit_delta", deltaPhotoKit)
        XCTAssertLessThanOrEqual(
            deltaSwiftData, 2,
            "Δ(swiftData)=\(deltaSwiftData) exceeds the body-fetch budget of 2 over the 6s window"
        )
        ProbeLog.emit("libfetch_swiftdata_delta", deltaSwiftData)
    }

    // MARK: - Deck tap writes are constant

    func testDeckTapWritesAreConstant() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 12 else {
            XCTFail("Pool below floor (need >= 12: 5 like/trash pairs plus headroom)")
            return
        }
        guard var current = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }
        guard var writes = deckWrites(timeout: 10) else {
            XCTFail("deckwrites_ probe never appeared after the deck settled")
            return
        }

        var likeDeltas: [DeckDelta] = []
        var trashDeltas: [DeckDelta] = []
        var expectedPool = poolTotal
        var expectedBin = 0

        for round in 0..<5 {
            app.buttons["rail_like"].tap()
            expectedPool -= 1
            XCTAssertTrue(
                waitFor(timeout: 10) { (self.poolTotal(timeout: 2) ?? -1) == expectedPool },
                "pool_total_ did not drop by 1 after rail_like tap #\(round)"
            )
            guard let afterLike = deckWrites(timeout: 10) else {
                XCTFail("deckwrites_ probe missing after like #\(round)")
                return
            }
            let likeDelta = DeckDelta(writes: writes, after: afterLike)
            XCTAssertLessThanOrEqual(likeDelta.ids, 1, "Δids too high on like #\(round): \(likeDelta)")
            XCTAssertLessThanOrEqual(likeDelta.ints, 4, "Δints too high on like #\(round): \(likeDelta)")
            XCTAssertEqual(likeDelta.saves, 1, "Δsaves != 1 on like #\(round): \(likeDelta)")
            likeDeltas.append(likeDelta)
            writes = afterLike

            // The trash button does nothing on a liked video, because
            // liked videos are protected from the trash. Swipe to a new
            // page before the trash tap.
            let advanced = recordPages(swipes: 1, from: current)
            guard advanced.count == 2, let nextPage = advanced.last else {
                XCTFail("Pager did not advance before the trash tap #\(round)")
                return
            }
            current = nextPage

            expectedBin += 1
            // `TrashService.queue` excludes the queued id from the pool
            // exactly like `like` does — `AssetKeyResolver.noteQueued` feeds
            // the same `excludedLive` set `noteLiked` does. A trash tap
            // therefore also drops `pool_total_` by 1, so `expectedPool`
            // must account for it here too.
            expectedPool -= 1
            guard advance(from: current, afterPerforming: { self.app.buttons["rail_trash"].tap() }) != nil else {
                XCTFail("Pager did not advance after rail_trash tap #\(round)")
                return
            }
            guard let afterAdvance = centeredPage(timeout: 10) else {
                XCTFail("No centered page after trash tap #\(round)")
                return
            }
            current = afterAdvance
            XCTAssertTrue(
                waitFor(timeout: 10) { self.binQueuedCount() == expectedBin },
                "bin badge did not reach \(expectedBin) after trash tap #\(round)"
            )
            XCTAssertTrue(
                waitFor(timeout: 10) { (self.poolTotal(timeout: 2) ?? -1) == expectedPool },
                "pool_total_ did not drop by 1 after rail_trash tap #\(round)"
            )
            guard let afterTrash = deckWrites(timeout: 10) else {
                XCTFail("deckwrites_ probe missing after trash #\(round)")
                return
            }
            let trashDelta = DeckDelta(writes: writes, after: afterTrash)
            XCTAssertLessThanOrEqual(trashDelta.ids, 1, "Δids too high on trash #\(round): \(trashDelta)")
            XCTAssertLessThanOrEqual(trashDelta.ints, 4, "Δints too high on trash #\(round): \(trashDelta)")
            XCTAssertEqual(trashDelta.saves, 1, "Δsaves != 1 on trash #\(round): \(trashDelta)")
            trashDeltas.append(trashDelta)
            writes = afterTrash
        }

        // The deck gets shorter on each tap. Identical deltas across all 5
        // rounds prove that the write cost is O(1).
        XCTAssertTrue(
            likeDeltas.allSatisfy { $0 == likeDeltas[0] },
            "Like-tap deltas were not identical across taps: \(likeDeltas)"
        )
        XCTAssertTrue(
            trashDeltas.allSatisfy { $0 == trashDeltas[0] },
            "Trash-tap deltas were not identical across taps: \(trashDeltas)"
        )
        ProbeLog.emit("deckwrites_ids_delta", likeDeltas[0].ids)
        ProbeLog.emit("deckwrites_ints_delta", likeDeltas[0].ints)
    }

    // MARK: - Large pool launches under three seconds (scale round only)

    /// Skipped unless `CLOUDFULL_RUN_SCALE_TEST=1`. The test needs a pool
    /// of 300 or more items. The normal seed gives about 52.
    /// `scripts/gate_all.sh` runs it in a separate scale round with
    /// `POOL_TARGET=320`. A larger pool for every round makes the gate
    /// much slower.
    func testLargePoolLaunchesUnderThreeSeconds() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CLOUDFULL_RUN_SCALE_TEST"] == "1",
            "Scale-only test. Set CLOUDFULL_RUN_SCALE_TEST=1 to run it; it needs a 300+ pool " +
            "(gate_all.sh's scale round seeds POOL_TARGET=320)."
        )

        launch(resettingState: true)

        let poolReading = poolTotal(timeout: 30)
        guard let pool = poolReading, pool >= 300 else {
            XCTFail("Scale round requires a pool of 300+, saw \(poolReading.map(String.init) ?? "nil")")
            return
        }

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before the timed relaunch")
        // A resume launch, the kind a user takes, not a reset launch.
        launch(resettingState: false)

        guard let ms = launchMilliseconds(timeout: 20) else {
            XCTFail("launch_ms_ probe never reported a reading")
            return
        }
        XCTAssertLessThan(ms, 3000, "Launch took \(ms) ms to first playing frame, want < 3000")
        ProbeLog.emit("launch_ms", ms)

        let poolAfterReading = poolTotal(timeout: 20)
        guard let poolAfter = poolAfterReading, poolAfter >= 300 else {
            XCTFail(
                "poolTotal read \(poolAfterReading.map(String.init) ?? "nil") after the timed relaunch — " +
                "a launch that dealt nothing cannot be fast by being empty"
            )
            return
        }
        ProbeLog.emit("pool_total", poolAfter)
    }

    // MARK: - Limited access keeps the queue intact

    func testLimitedAccessKeepsQueueIntact() throws {
        // Register this teardown before the downgrade. If the test fails
        // on Limited access, the teardown restores Full access for later
        // tests. The teardown also checks the result and fails with a
        // clear message.
        addTeardownBlock {
            self.restoreFullAccessAndRelaunch()
            XCTAssertNotNil(
                self.poolTotal(timeout: 15),
                "Photo access was not restored to Full after this test's teardown — later tests " +
                "will run against a broken permission state"
            )
        }

        // --- Phase 1: build the state at full access. The test does not
        // call `terminate()` here before the downgrade below.
        //
        // `reconcileWithLibrary()`'s `authStatus == .authorized` guard, and
        // the two-strike rule, need a session that is already alive and
        // registered as a PhotoKit observer when the downgrade happens.
        // `tccd` can still terminate the app when the access level changes.
        // `app.activate()` in Phase 3 then relaunches it with the
        // recorded launch options.
        //
        // The test launches twice. The first launch resets the deck state.
        // The second relaunches without `-cloudfull-reset-deck-state`, so
        // the automation session's recorded launch options no longer carry
        // it.
        //
        // `setPhotoAccess(.limited)` below makes `tccd` terminate this app,
        // and the `app.activate()` that follows relaunches it from those
        // recorded options. XCUITest re-reads `app.launchArguments` only on
        // `launch()`, never on `activate()`. A replayed reset flag runs
        // `CloudfullApp.eraseLocalStore()`, which deletes `default.store`
        // and destroys the queue this test exists to prove survives.
        launch(resettingState: true)
        launch(resettingState: false)
        guard let pool = poolTotal(timeout: 10), pool >= 5 else {
            XCTFail("Pool floor of 5 not met for the limited-access scenario")
            return
        }
        guard var current = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }
        for tapIndex in 0..<3 {
            guard let next = advance(from: current, afterPerforming: { self.app.buttons["rail_trash"].tap() }) else {
                XCTFail("Pager did not advance after rail_trash tap #\(tapIndex)")
                return
            }
            current = next
        }
        guard let spaceBefore = spaceProbe(timeout: 10) else {
            XCTFail("space_probe_ never appeared after queuing 3 videos")
            return
        }
        guard let rowsBefore = trashRowsProbe(timeout: 10) else {
            XCTFail("trash_rows_ never appeared after queuing 3 videos")
            return
        }
        XCTAssertEqual(rowsBefore.count, 3, "trash_rows_ did not read 3 after queuing 3 videos")
        XCTAssertEqual(rowsBefore.dormant, 0)
        XCTAssertTrue(app.buttons["bin_open"].label.contains("3"), "bin_open does not read 3 after queuing 3 videos")
        let pendingBefore = spaceBefore.pending

        // `app.activate()` in Phase 3 relaunches the app after `tccd`
        // terminates it. The relaunch uses the launch options from the
        // last `launch()`. Phase 1 removes the reset flag from those
        // options. Setting `app.launchArguments` here has no effect,
        // because `activate()` does not read it.

        // --- Phase 2: downgrade to Limited access through the real
        // Settings app. The test does not terminate Cloudfull. It stays
        // in the background while Settings changes the access level.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        setPhotoAccess(.limited)

        // --- Phase 3: bring the app to the foreground and prove that no
        // state is lost. `app.activate()` calls `refreshAuthStatus()`
        // through `.onChange(of: scenePhase)`. This sets
        // `library.authStatus` and sets `AssetKeyResolver` to `.partial`.
        // The access change can also post a PhotoKit library-change
        // notification that runs `reconcileWithLibrary()` under `.limited`.
        app.activate()
        XCTAssertTrue(
            app.buttons["permission_limited_settings"].waitForExistence(timeout: 15),
            "permission_limited_settings did not appear after downgrading to Limited access"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["permission_limited_steps"].exists,
            "permission_limited_steps missing under Limited access"
        )

        // Poll for up to 90 seconds. This covers the 300 ms change
        // coalesce and the 60-second two-strike window. `app.activate()`
        // can relaunch the app. iOS can end the app during the Settings
        // steps, and `tccd` ends it on the access change. After a relaunch
        // under `.limited`, `RowCountProbe` opens the store first. Its
        // 1 Hz timer can be late.
        func pollSpaceAndRows(timeout: TimeInterval) -> (space: (pending: Int64, reclaimed: Int64), rows: (count: Int, dormant: Int))? {
            let deadline = Date().addingTimeInterval(timeout)
            var last: (space: (pending: Int64, reclaimed: Int64), rows: (count: Int, dormant: Int))?
            repeat {
                if let space = spaceProbe(timeout: 3), let rows = trashRowsProbe(timeout: 3) {
                    last = (space, rows)
                    if space.pending == pendingBefore && rows.count == 3 { return last }
                }
                Thread.sleep(forTimeInterval: 1)
            } while Date() < deadline
            return last
        }

        guard let afterActivate = pollSpaceAndRows(timeout: 90) else {
            XCTFail("space_probe_/trash_rows_ never appeared under Limited access")
            return
        }
        XCTAssertEqual(afterActivate.space.pending, pendingBefore, "space_probe_ pending changed after downgrading to Limited access")
        XCTAssertEqual(afterActivate.space.reclaimed, 0, "space_probe_ reclaimed nonzero under Limited access")
        XCTAssertEqual(afterActivate.rows.count, 3, "trash_rows_ count changed after downgrading to Limited access")
        XCTAssertEqual(afterActivate.rows.dormant, 0, "trash_rows_ marked a row dormant->deleted under Limited access")

        // Background and foreground the app again to start a second
        // reconcile attempt.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()

        guard let afterSecondReconcile = pollSpaceAndRows(timeout: 90) else {
            XCTFail("space_probe_/trash_rows_ never appeared after the forced reconcile attempt")
            return
        }
        XCTAssertEqual(afterSecondReconcile.space.pending, pendingBefore, "space_probe_ pending changed after a forced reconcile under Limited access")
        XCTAssertEqual(afterSecondReconcile.rows.count, 3, "trash_rows_ count changed after a forced reconcile under Limited access")

        // --- Phase 4: restore full access and reconcile. This is the
        // first termination in this test, so it also proves the state
        // survives a cold relaunch, not only a foreground/background
        // cycle. ---
        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "App did not terminate before restoring full access")
        restoreFullAccessAndRelaunch()

        // Wait for the feed before reading any element in it.
        // `XCUIElement.label` on a missing element raises an Objective-C
        // exception. Swift cannot catch it, so the test fails at once.
        // `poolTotal` reads an atomic snapshot and is safe to poll.
        XCTAssertNotNil(
            poolTotal(timeout: 30),
            "Feed did not return after restoring full access — no pool_total_ element"
        )
        XCTAssertTrue(
            waitFor(timeout: 15) {
                let bin = self.app.buttons["bin_open"]
                return bin.exists && bin.label.contains("3")
            },
            "bin_open does not read 3 after restoring full access"
        )
        guard let spaceRestored = spaceProbe(timeout: 10) else {
            XCTFail("space_probe_ never appeared after restoring full access")
            return
        }
        XCTAssertEqual(spaceRestored.pending, pendingBefore, "space_probe_ pending changed after restoring full access")

        app.buttons["bin_open"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trash_empty"].waitForExistence(timeout: 10), "trash_empty did not appear")
        let restoreCells = elementSnapshots(withPrefix: "trash_restore_")
            .map(\.identifier)
            .filter { $0 != "trash_restore_failed" }
        XCTAssertEqual(restoreCells.count, 3, "Expected exactly 3 trash_restore_ cells, found \(restoreCells.count)")

        for identifier in restoreCells {
            let cell = app.descendants(matching: .any)[identifier]
            if cell.waitForExistence(timeout: 5) {
                cell.tap()
                Thread.sleep(forTimeInterval: 1)
            }
        }
        // Dismiss before reading `space_probe_`. It lives in
        // `PermissionGateView`, below the still-open bin sheet, which makes
        // it unreachable to XCUITest until dismissed. See the same pattern
        // in the rotation and space-counter tests.
        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        } else {
            app.swipeDown()
        }
        XCTAssertTrue(
            waitFor(timeout: 15) { (self.spaceProbe(timeout: 2)?.pending ?? -1) == 0 },
            "space_probe_ pending did not return to 0 after restoring all 3 queued videos"
        )
    }

    // MARK: - Scrub seeks without breaking tap-to-mute

    func testScrubSeeksWithoutBreakingTapToMute() throws {
        launch(resettingState: true)

        guard let page = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }
        guard let initial = scrubberProbe(timeout: 15), initial.durationMs > 0 else {
            XCTFail("scrubber_probe_ never reported a loaded item with a positive duration")
            return
        }
        XCTAssertFalse(initial.scrubbing, "scrubber_probe_ reports scrubbing before any gesture happened")

        // --- Tap-to-mute survives. ---
        // The video tap is the only mute control. Read `feed.isMuted`
        // through the `mute_state_` probe in `FeedView.swift`. Tapping the
        // stage must toggle mute, and a second tap must toggle it back.
        guard let mutedBefore = debouncedProbe(prefix: "mute_state_", timeout: 5) else {
            XCTFail("mute_state_ probe not found")
            return
        }
        let stage = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        stage.tap()
        XCTAssertTrue(
            waitFor(timeout: 5) { self.debouncedProbe(prefix: "mute_state_", timeout: 2) != mutedBefore },
            "mute_state_ did not flip after tapping the stage"
        )
        stage.tap()
        XCTAssertTrue(
            waitFor(timeout: 5) { self.debouncedProbe(prefix: "mute_state_", timeout: 2) == mutedBefore },
            "mute_state_ did not flip back after a second tap"
        )

        // --- The scrubber seeks. ---
        let track = app.descendants(matching: .any)["scrubber_track"]
        XCTAssertTrue(track.waitForExistence(timeout: 5), "scrubber_track not found on the centered page")
        let dragStart = track.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let dragEnd = track.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))

        guard let preDrag = scrubberProbe(timeout: 5) else {
            XCTFail("scrubber_probe_ never produced a reading immediately before the drag")
            return
        }
        let durationMs = preDrag.durationMs
        guard durationMs > 0 else {
            XCTFail("scrubber_probe_ reported a non-positive duration immediately before the drag")
            return
        }
        let preDragAt = Date()

        // Do not call XCUITest APIs from another thread during a gesture.
        // A gesture on a background queue crashes with "must be called on
        // the main thread". A poll on a background queue during the
        // gesture crashes with "Activity cannot be used after its scope
        // has completed". This is an XCTest internal limit.
        //
        // The gesture therefore runs as a single, ordinary sequential
        // call. The seek verification below is a wall-clock projection,
        // and it is the only proof scrubbing engaged.
        // `seekToScrubFraction()` is reachable only through
        // `handleScrubChanged`, which runs only while `isScrubbing` is
        // true. A seek cannot happen any other way.
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)

        // `waitForScrubEnded` polls a single sample until `isScrubbing`
        // reads false, rather than requiring two samples 0.3s apart to be
        // identical. A continuously playing item's `currentMs` republishes
        // about 4 times per second, so it can never satisfy that kind of
        // identical-sample check. `isScrubbing` is the field that stays
        // stable.
        guard let afterScrub = waitForScrubEnded(timeout: 5) else {
            XCTFail("scrubber_probe_ never settled back to false after the drag")
            return
        }
        let afterAt = Date()
        XCTAssertFalse(afterScrub.scrubbing, "scrubber_probe_ still reports scrubbing after the drag ended")

        // Plain looping playback gives `currentMs >= 0.6 * duration` about
        // 40% of the time. The check therefore requires the playhead
        // within 12.5% of duration of the 75% drag target. The drag takes
        // about 1 second, which is 20 to 33% of a 3 to 5 second clip. A
        // drift check can reject a correct seek. `preDrag` and `afterAt`
        // appear only in the failure message.
        let elapsedMs = Int(afterAt.timeIntervalSince(preDragAt) * 1000)
        let noSeekProjection = (preDrag.currentMs + elapsedMs) % durationMs
        let targetMs = Int(0.75 * Double(durationMs))
        let deviationFromTarget = abs(afterScrub.currentMs - targetMs)

        XCTAssertLessThanOrEqual(
            deviationFromTarget, durationMs / 8,
            "Playhead (\(afterScrub.currentMs)ms of \(durationMs)ms) did not land near the drag's 75% " +
            "target, \(targetMs)ms (no-seek projection would have been \(noSeekProjection)ms)"
        )

        // --- The scrub did not page. ---
        XCTAssertEqual(centeredPage(timeout: 5)?.slot, page.slot, "Scrubbing paged the feed")

        // --- Paging still works. ---
        let paged = recordPages(swipes: 1, from: page)
        XCTAssertEqual(paged.count, 2, "recordPages did not record a page for the post-scrub swipe")
        XCTAssertEqual(paged.last?.slot, page.slot + 1, "Post-scrub swipe did not advance exactly one slot")

        // --- Long-press entry works, and a swipe afterward still pages. ---
        // The gesture again runs as one sequential call, and a seek to
        // the touch's own position is the proof scrubbing engaged. A long
        // press held with no drag movement still seeks once it releases.
        // `handleScrubChanged` runs on the recognizer's `.began` and
        // `.changed` states with the finger's unmoving x position, and
        // `endScrub()` performs the final seek on `.ended`.
        let longPressStage = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        guard let preLongPress = scrubberProbe(timeout: 5) else {
            XCTFail("scrubber_probe_ never produced a reading immediately before the long press")
            return
        }
        let longPressDurationMs = preLongPress.durationMs
        guard longPressDurationMs > 0 else {
            XCTFail("scrubber_probe_ reported a non-positive duration immediately before the long press")
            return
        }
        let preLongPressAt = Date()

        longPressStage.press(forDuration: 0.5)

        guard let afterLongPress = waitForScrubEnded(timeout: 5) else {
            XCTFail("scrubber_probe_ never settled back to false after the long press")
            return
        }
        let afterLongPressAt = Date()
        XCTAssertFalse(afterLongPress.scrubbing, "scrubber_probe_ still reports scrubbing after the long press ended")

        // Check only the distance to the target, within 12.5% of
        // duration. A no-seek drift check can reject a correct seek on
        // these short clips. See the drag comment above.
        let longPressElapsedMs = Int(afterLongPressAt.timeIntervalSince(preLongPressAt) * 1000)
        let longPressNoSeekProjection = (preLongPress.currentMs + longPressElapsedMs) % longPressDurationMs
        // The stage center sits at dx: 0.5, so the touch is at about
        // 50% of duration.
        let longPressTargetMs = Int(0.5 * Double(longPressDurationMs))
        let longPressDeviationFromTarget = abs(afterLongPress.currentMs - longPressTargetMs)
        XCTAssertLessThanOrEqual(
            longPressDeviationFromTarget, longPressDurationMs / 8,
            "Playhead (\(afterLongPress.currentMs)ms of \(longPressDurationMs)ms) did not land near the " +
            "long press's own ~50% position, \(longPressTargetMs)ms (no-seek projection would have " +
            "been \(longPressNoSeekProjection)ms)"
        )

        guard let pageBeforeSwipe = centeredPage(timeout: 5) else {
            XCTFail("No centered page after the long-press-scrub")
            return
        }
        app.swipeUp()
        XCTAssertTrue(
            waitFor(timeout: 5) { (self.centeredPage(timeout: 2)?.slot ?? pageBeforeSwipe.slot) > pageBeforeSwipe.slot },
            "A swipe after a long-press-scrub did not page — gesture arbitration stole the pan"
        )
    }

    // MARK: - Space counter counts every byte exactly once

    func testSpaceCounterCountsEveryByteOnce() throws {
        launch(resettingState: true)

        guard let poolTotal = poolTotal(timeout: 10), poolTotal >= 25 else {
            XCTFail("Pool below floor (need >= 25, to reach a seeded 4K clip): reseed via scripts/seed_m3.sh")
            return
        }
        guard let space0 = spaceProbe(timeout: 10) else {
            XCTFail("space_probe_ never appeared")
            return
        }
        XCTAssertEqual(space0.pending, 0, "space_probe_ pending was nonzero at launch")
        XCTAssertEqual(space0.reclaimed, 0, "space_probe_ reclaimed was nonzero at launch")
        var expected: Int64 = 0
        // Cross-check the visible `space_counter` chip's accessibility
        // label against the same test-accumulated `expected` value at
        // every step where the chip exists. This proves the number a real
        // user reads, not only the debug probe.
        assertSpaceCounterMatches(pending: 0)

        guard var current = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        func queueCurrentPage(label: String) -> (id: String, bytes: Int64)? {
            let assetID = current.assetID
            guard let next = advance(from: current, afterPerforming: { self.app.buttons["rail_trash"].tap() }) else {
                XCTFail("Pager did not advance after queuing video \(label)")
                return nil
            }
            current = next
            guard let entry = trashEntryProbe(timeout: 10), entry.key == assetID else {
                XCTFail("trash_entry_ did not reflect queued video \(label) (\(assetID))")
                return nil
            }
            XCTAssertEqual(entry.replacementBytes, 0, "trash_entry_ for a plain trash-queue reported nonzero replacementBytes")
            return (assetID, entry.bytes)
        }

        guard let a = queueCurrentPage(label: "A") else { return }
        expected += a.bytes
        guard let spaceA = spaceProbe(timeout: 10) else { XCTFail("space_probe_ never appeared after queuing A"); return }
        XCTAssertEqual(spaceA.pending, expected, "space_probe_ pending mismatch after queuing A")
        assertSpaceCounterMatches(pending: expected)

        guard let b = queueCurrentPage(label: "B") else { return }
        expected += b.bytes
        guard let spaceB = spaceProbe(timeout: 10) else { XCTFail("space_probe_ never appeared after queuing B"); return }
        XCTAssertEqual(spaceB.pending, expected, "space_probe_ pending mismatch after queuing B")
        assertSpaceCounterMatches(pending: expected)

        guard let c = queueCurrentPage(label: "C") else { return }
        expected += c.bytes
        guard let spaceC = spaceProbe(timeout: 10) else { XCTFail("space_probe_ never appeared after queuing C"); return }
        XCTAssertEqual(spaceC.pending, expected, "space_probe_ pending mismatch after queuing C")
        assertSpaceCounterMatches(pending: expected)

        guard let shrinkPage = findSeededShrinkablePage(poolTotal: poolTotal) else {
            XCTFail("Never reached a seeded shrinkable 4K clip (CLOUDFULL_SHRINKABLE_ASSET_IDS)")
            return
        }
        current = shrinkPage
        let dAssetID = shrinkPage.assetID
        let shrinkButton = app.buttons["rail_shrink"]
        XCTAssertTrue(shrinkButton.waitForExistence(timeout: 5), "rail_shrink missing on the seeded 4K clip")
        XCTAssertTrue(shrinkButton.isEnabled, "rail_shrink not enabled on the seeded 4K clip")
        shrinkButton.tap()
        XCTAssertTrue(app.buttons["shrink_confirm"].waitForExistence(timeout: 5), "Shrink confirm sheet did not appear")
        app.buttons["shrink_confirm"].tap()
        XCTAssertTrue(
            waitFor(timeout: 120) { self.binQueuedCount() == 4 },
            "Bin badge did not reach 4 within 120s of confirming the shrink"
        )
        guard let dEntry = trashEntryProbe(timeout: 15), dEntry.key == dAssetID else {
            XCTFail("trash_entry_ did not reflect the shrunk original \(dAssetID)")
            return
        }
        XCTAssertGreaterThan(
            dEntry.replacementBytes, 0,
            "trash_entry_ reported 0 replacementBytes — a shrink that queued nothing cannot satisfy this step"
        )
        expected += max(dEntry.bytes - dEntry.replacementBytes, 0)
        guard let spaceD = spaceProbe(timeout: 15) else { XCTFail("space_probe_ never appeared after the shrink"); return }
        XCTAssertEqual(spaceD.pending, expected, "space_probe_ pending mismatch after the shrink")
        assertSpaceCounterMatches(pending: expected)

        // Restore B.
        app.buttons["bin_open"].tap()
        let restoreButtonB = app.buttons["trash_restore_\(b.id)"]
        XCTAssertTrue(restoreButtonB.waitForExistence(timeout: 5), "trash_restore_ cell for B did not appear")
        restoreButtonB.tap()
        XCTAssertTrue(waitFor(timeout: 10) { !restoreButtonB.exists }, "B's restore cell did not disappear")
        expected -= b.bytes
        // `space_probe_` (`GateProbes`, in `PermissionGateView`) and
        // `space_counter` (`FeedView`'s own chip) both live below the
        // still-open bin sheet. A presented modal makes that background
        // content unreachable to XCUITest. Dismiss before reading either
        // one, then re-open for the Empty step below.
        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        } else {
            app.swipeDown()
        }
        guard let spaceAfterRestore = spaceProbe(timeout: 10) else {
            XCTFail("space_probe_ never appeared after restoring B")
            return
        }
        XCTAssertEqual(spaceAfterRestore.pending, expected, "space_probe_ pending mismatch after restoring B")
        XCTAssertEqual(spaceAfterRestore.reclaimed, 0)
        assertSpaceCounterMatches(pending: expected)

        // Empty the bin: one real PhotoKit delete of 4 videos, with one
        // system confirm, driven through SpringBoard exactly as
        // `M2TrashTests` does. This test permanently deletes 4 simulator
        // videos per run. The seeder's `POOL_TARGET` (52) accounts for
        // this deletion in addition to the 17 `M2TrashTests` makes.
        app.buttons["bin_open"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trash_empty"].waitForExistence(timeout: 10), "trash_empty did not reappear after re-opening the bin")
        app.buttons["trash_empty"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "No system delete confirmation appeared for Empty Bin")
        let deleteButton = alert.buttons.matching(NSPredicate(format: "label CONTAINS 'Delete'")).firstMatch
        XCTAssertTrue(deleteButton.exists, "No destructive 'Delete' button found in the confirm dialog")
        deleteButton.tap()

        // The bin does not auto-dismiss after Empty. It stays open with the
        // freed message and the reclaimed pill until Done or a swipe closes
        // it (`TrashView.performEmpty`). The reclaimed pill
        // (`shrink_saved_counter`) lives in this sheet's own header
        // (`TrashView.headerCount`), not in `FeedView`'s top bar.
        // `space_probe_` and `space_counter` are behind the sheet.
        // XCUITest cannot reach them while the sheet is open. Read
        // `shrink_saved_counter` first, while the sheet is open. Then
        // dismiss the sheet and read `space_probe_` and `space_counter`.
        let reclaimedBaseline = space0.reclaimed // == 0, asserted at the top of this test
        let expectedReclaimed = reclaimedBaseline + expected
        XCTAssertTrue(
            app.descendants(matching: .any)["trash_empty_state"].waitForExistence(timeout: 60),
            "trash_empty_state did not appear in the bin sheet after emptying"
        )
        // Use `waitForExistence`, not `.exists`. `TrashService` sets
        // `entries` and `reclaimedBytes` before the same `load()` call in
        // `emptyBin()`. The two values can still appear in different
        // accessibility snapshots. The snapshot can be one or two frames
        // behind the SwiftUI render.
        XCTAssertTrue(
            app.staticTexts["shrink_saved_counter"].waitForExistence(timeout: 5),
            "shrink_saved_counter does not exist after a nonzero reclaim"
        )
        assertShrinkSavedCounterMatches(reclaimed: expectedReclaimed)

        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        } else {
            app.swipeDown()
        }
        XCTAssertTrue(
            waitFor(timeout: 10) { !self.app.buttons["trash_empty"].exists },
            "Bin sheet did not dismiss after Done"
        )

        XCTAssertTrue(
            waitFor(timeout: 30) { (self.spaceProbe(timeout: 2)?.reclaimed ?? -1) == expectedReclaimed },
            "space_probe_ reclaimed never reached \(expectedReclaimed) after emptying the bin"
        )
        guard let spaceAfterEmpty = spaceProbe(timeout: 10) else {
            XCTFail("space_probe_ never appeared after emptying the bin")
            return
        }
        XCTAssertEqual(spaceAfterEmpty.pending, 0, "space_probe_ pending was not 0 after emptying the bin — every pending byte must move to reclaimed")
        ProbeLog.emit("space_pending_final", spaceAfterEmpty.pending)
        XCTAssertEqual(spaceAfterEmpty.reclaimed, expectedReclaimed, "space_probe_ reclaimed did not equal the expected total after emptying the bin")
        ProbeLog.emit("space_reclaimed_final", spaceAfterEmpty.reclaimed)

        XCTAssertFalse(app.staticTexts["space_counter"].exists, "space_counter still exists after pending reached 0")
        assertSpaceCounterMatches(pending: 0)
    }

    // MARK: - Shared helpers

    private enum PhotoAccess {
        case limited, full
    }

    /// Launches with `["-cloudfull-rotate-keys"]` and deliberately no reset
    /// flag. The rotation harness must act on rows a previous launch
    /// persisted.
    private func launchRotating() {
        app.launchArguments = ["-cloudfull-rotate-keys"]
        app.launch()
        grantPhotoAccessIfAsked()
    }

    /// Swipes one page forward, using `recordPages`'s own retry and settle
    /// discipline.
    private func stepForward(from current: Page) -> Page? {
        let pages = recordPages(swipes: 1, from: current)
        guard pages.count == 2 else { return nil }
        return pages[1]
    }

    /// Finds any accessibility element by identifier, not only buttons.
    /// Several probes and badges are plain views, not controls.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Converts a `Fmt.bytes` label (`ByteCountFormatter` `.file`, base
    /// 1000) back to an approximate byte count. The UI test process
    /// cannot call `Fmt.bytes`, so this is a separate implementation.
    private func parseFormattedBytes(_ text: String) -> Int64? {
        let cleaned = text.replacingOccurrences(of: "About ", with: "")
        guard let regex = try? NSRegularExpression(pattern: #"([\d.,]+)\s*([a-zA-Z]+)"#),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let numberRange = Range(match.range(at: 1), in: cleaned),
              let unitRange = Range(match.range(at: 2), in: cleaned) else { return nil }
        guard let value = Double(cleaned[numberRange].replacingOccurrences(of: ",", with: "")) else { return nil }
        let multiplier: Double
        switch cleaned[unitRange].lowercased() {
        case "byte", "bytes": multiplier = 1
        case "kb": multiplier = 1_000
        case "mb": multiplier = 1_000_000
        case "gb": multiplier = 1_000_000_000
        case "tb": multiplier = 1_000_000_000_000
        default: return nil
        }
        return Int64((value * multiplier).rounded())
    }

    /// Cross-checks the visible `space_counter` chip against
    /// `expectedPending`, the number a real user reads, not only the debug
    /// `space_probe_` reading. Asserts absence when `expectedPending == 0`,
    /// matching `counterCapsule`'s own `showPending` gate. Otherwise it
    /// parses the chip's accessibility label. The label must fall within a
    /// formatter-rounding tolerance of `expectedPending`. This test
    /// accumulates that figure from per-entry `trash_entry_` readings, not
    /// from `space_probe_`.
    private func assertSpaceCounterMatches(pending expectedPending: Int64, file: StaticString = #filePath, line: UInt = #line) {
        let text = app.staticTexts["space_counter"]
        guard expectedPending > 0 else {
            XCTAssertFalse(text.exists, "space_counter exists with a zero expected pending total", file: file, line: line)
            return
        }
        guard text.waitForExistence(timeout: 5) else {
            XCTFail("space_counter does not exist with a nonzero expected pending total (\(expectedPending))", file: file, line: line)
            return
        }
        guard let parsed = parseFormattedBytes(text.label) else {
            XCTFail("Could not parse a byte figure out of space_counter's label: '\(text.label)'", file: file, line: line)
            return
        }
        let tolerance = max(Int64(Double(expectedPending) * 0.06), 1024)
        XCTAssertLessThanOrEqual(
            abs(parsed - expectedPending), tolerance,
            "space_counter shows \(parsed) bytes (from '\(text.label)'), test-accumulated expected is " +
            "\(expectedPending) (tolerance \(tolerance))",
            file: file, line: line
        )
    }

    /// Sibling of `assertSpaceCounterMatches` for `shrink_saved_counter`,
    /// which reports `TrashService.reclaimedBytes`, not
    /// `ShrinkService.sessionSavedBytes`.
    private func assertShrinkSavedCounterMatches(reclaimed expectedReclaimed: Int64, file: StaticString = #filePath, line: UInt = #line) {
        let text = app.staticTexts["shrink_saved_counter"]
        guard expectedReclaimed > 0 else {
            XCTAssertFalse(text.exists, "shrink_saved_counter exists with a zero expected reclaimed total", file: file, line: line)
            return
        }
        guard text.waitForExistence(timeout: 5) else {
            XCTFail("shrink_saved_counter does not exist with a nonzero expected reclaimed total (\(expectedReclaimed))", file: file, line: line)
            return
        }
        guard let parsed = parseFormattedBytes(text.label) else {
            XCTFail("Could not parse a byte figure out of shrink_saved_counter's label: '\(text.label)'", file: file, line: line)
            return
        }
        let tolerance = max(Int64(Double(expectedReclaimed) * 0.06), 1024)
        XCTAssertLessThanOrEqual(
            abs(parsed - expectedReclaimed), tolerance,
            "shrink_saved_counter shows \(parsed) bytes (from '\(text.label)'), test-accumulated " +
            "expected is \(expectedReclaimed) (tolerance \(tolerance))",
            file: file, line: line
        )
    }

    /// Parses the digits out of `bin_open`'s label ("Trash" -> 0, "Trash, 3
    /// queued" -> 3), the same convention `M2TrashTests` and
    /// `M3ShrinkTests` use.
    private func binQueuedCount() -> Int {
        let digits = app.buttons["bin_open"].label.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    private func shrinkableAssetIDs() -> [String] {
        guard let raw = ProcessInfo.processInfo.environment["CLOUDFULL_SHRINKABLE_ASSET_IDS"] else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Scrolls a full-deck-cycle budget looking for one of the seeded 4K
    /// shrinkable clips, the same search `M3ShrinkTests` performs.
    private func findSeededShrinkablePage(poolTotal: Int) -> Page? {
        guard var current = centeredPage(timeout: 20) else { return nil }
        let targets = Set(shrinkableAssetIDs())
        guard !targets.isEmpty else { return nil }
        if targets.contains(current.assetID) { return current }
        let budget = poolTotal + max(10, poolTotal / 4)
        for _ in 0..<budget {
            guard let next = stepForward(from: current) else { return nil }
            current = next
            if targets.contains(current.assetID) { return current }
        }
        return nil
    }

    /// Drives the real Settings app to change Cloudfull's Photos access,
    /// since `simctl privacy grant` is broken on this runtime. Every lookup
    /// is an ordered candidate list with an `XCTFail` naming what was on
    /// screen, the same discipline `M4Tests`'s `waitForSystemShareSheet`
    /// uses.
    private func setPhotoAccess(_ target: PhotoAccess) {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        var reachedAppPane = false

        // (a) iOS nests third-party apps under "Apps", well down Settings'
        // root list, after every core system section. It does not appear
        // without scrolling first. This scrolls in bounded steps instead
        // of one `waitForExistence` call over the unscrolled viewport.
        let appsCell = settings.cells.staticTexts["Apps"]
        if !appsCell.exists {
            for _ in 0..<8 {
                if appsCell.exists { break }
                settings.swipeUp()
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        if appsCell.waitForExistence(timeout: 5) {
            appsCell.tap()
            let cloudfullCell = settings.cells.staticTexts["Cloudfull"]
            if cloudfullCell.waitForExistence(timeout: 5) {
                cloudfullCell.tap()
                reachedAppPane = true
            }
        }

        // (b) Older layout: Cloudfull sits at Settings' root. Scroll for it
        // too, for the same reason.
        if !reachedAppPane {
            let cloudfullRoot = settings.cells.staticTexts["Cloudfull"]
            if !cloudfullRoot.exists {
                for _ in 0..<8 {
                    if cloudfullRoot.exists { break }
                    settings.swipeUp()
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
            if cloudfullRoot.waitForExistence(timeout: 5) {
                cloudfullRoot.tap()
                reachedAppPane = true
            }
        }

        // (c) search fallback.
        if !reachedAppPane {
            let search = settings.searchFields.firstMatch
            if search.waitForExistence(timeout: 5) {
                search.tap()
                search.typeText("Cloudfull")
                let cloudfullResult = settings.cells.staticTexts["Cloudfull"].firstMatch
                if cloudfullResult.waitForExistence(timeout: 5) {
                    cloudfullResult.tap()
                    reachedAppPane = true
                }
            }
        }

        guard reachedAppPane else {
            let seen = settings.cells.staticTexts.allElementsBoundByIndex.prefix(30).map(\.label)
            XCTFail("Could not reach the Cloudfull settings pane. Visible cells: \(seen)")
            return
        }

        let photosCell = settings.cells.staticTexts["Photos"]
        guard photosCell.waitForExistence(timeout: 10) else {
            let seen = settings.cells.staticTexts.allElementsBoundByIndex.prefix(30).map(\.label)
            XCTFail("'Photos' row not found in the Cloudfull settings pane. Visible cells: \(seen)")
            return
        }
        photosCell.tap()

        let candidates = target == .limited ? ["Limited Access", "Selected Photos"] : ["Full Access", "All Photos"]
        var tapped = false
        for label in candidates {
            let cell = settings.cells.staticTexts[label]
            if cell.waitForExistence(timeout: 5) {
                cell.tap()
                tapped = true
                break
            }
        }
        guard tapped else {
            let seen = settings.cells.staticTexts.allElementsBoundByIndex.prefix(30).map(\.label)
            XCTFail("None of \(candidates) found on the Photos access screen. Visible cells: \(seen)")
            return
        }

        // Some flows push the photo picker straight after choosing Limited.
        // Wait up to 3 seconds for Done or an "Add Photos" sheet. Dismiss it
        // if it appears; otherwise return. Never fail on its absence.
        //
        // Tap Done without selecting photos. On this runtime, Done accepts
        // zero new selections, and the callers of this helper check only
        // the access level. Photo cell taps are unreliable. XCUITest
        // hit-testing can disagree with the cell frame, and a grid query
        // can match a system element instead of a photo cell.
        let done = settings.buttons["Done"]
        let addPhotosDeadline = Date().addingTimeInterval(3)
        var pickerAppeared = false
        while Date() < addPhotosDeadline {
            if done.exists || settings.staticTexts["Add Photos"].exists {
                pickerAppeared = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if pickerAppeared, done.waitForExistence(timeout: 2) {
            done.tap()
        }

        settings.terminate()
        XCTAssertEqual(settings.state, .notRunning, "Settings did not terminate after changing photo access")
    }

    /// Widening `.limited` to `.full` through Settings does not take effect
    /// immediately. `setPhotoAccess(.full)` alone leaves
    /// `kTCCServicePhotos` at `.limited`. PhotoKit shows the "Allow Full
    /// Access" alert (`springboard.buttons["Allow Full Access"]`) when the
    /// relaunched app next reads the library. `launch` and
    /// `grantPhotoAccessIfAsked` do not handle this alert on a resume
    /// launch. Call this after each launch that follows
    /// `setPhotoAccess(.full)`. The alert can be absent. Returns `true` if
    /// it tapped the alert, a fact the caller has to act on — see
    /// `restoreFullAccessAndRelaunch`.
    @discardableResult
    private func grantFullAccessConfirmationIfShown() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowButton = springboard.buttons["Allow Full Access"]
        guard allowButton.waitForExistence(timeout: 5) else { return false }
        allowButton.tap()
        return true
    }

    /// Restores Full photo access and leaves the app running and
    /// authorized.
    ///
    /// Changing the setting is not sufficient. iOS shows a full-access
    /// alert on the relaunched app, and only a tap on it changes TCC.
    /// `tccd` then terminates the app a few seconds later. A launch before
    /// that termination also ends. The loop grants, waits for termination,
    /// relaunches, and returns when `pool_total_` appears.
    private func restoreFullAccessAndRelaunch() {
        setPhotoAccess(.full)
        for _ in 0..<3 {
            launch(resettingState: false)
            if grantFullAccessConfirmationIfShown() {
                _ = waitFor(timeout: 15) { self.app.state != .runningForeground }
                continue
            }
            if poolTotal(timeout: 15) != nil { return }
        }
    }

    // MARK: - Probe helpers

    /// Debounced read of the full identifier for the first element whose
    /// identifier begins with `prefix`. Two reads 0.3 seconds apart must
    /// agree, the same discipline `poolTotal`/`centeredPage` use.
    private func debouncedProbe(prefix: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        // Each probe updates on an event, on the 1 Hz `RowCountProbe`
        // timer, or on the 2 Hz `CounterProbe` timer. With a 0.3-second
        // gap, two reads can agree before the next timer update. That
        // makes a read after an action unreliable. A 1.2-second gap is
        // longer than both timer periods.
        let settleGap: TimeInterval = 1.2

        func sample() -> String? {
            elementSnapshots(withPrefix: prefix).first?.identifier
        }

        repeat {
            if let firstRead = sample() {
                Thread.sleep(forTimeInterval: settleGap)
                if let secondRead = sample(), secondRead == firstRead {
                    return firstRead
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline

        return nil
    }

    /// Parses `count` underscore-separated integer fields after `prefix`.
    private func intFields(prefix: String, count: Int, timeout: TimeInterval) -> [Int]? {
        guard let identifier = debouncedProbe(prefix: prefix, timeout: timeout) else { return nil }
        let body = identifier.dropFirst(prefix.count)
        let parts = body.split(separator: "_")
        guard parts.count == count else { return nil }
        let ints = parts.compactMap { Int($0) }
        guard ints.count == count else { return nil }
        return ints
    }

    /// "rotation_probe_<likedLiveID|none>_<trashLiveID|none>".
    private func rotationProbe(timeout: TimeInterval) -> (liked: String?, trash: String?)? {
        guard let identifier = debouncedProbe(prefix: "rotation_probe_", timeout: timeout) else { return nil }
        let body = identifier.dropFirst("rotation_probe_".count)
        let parts = body.split(separator: "_")
        guard parts.count == 2 else { return nil }
        let liked = parts[0] == "none" ? nil : String(parts[0])
        let trash = parts[1] == "none" ? nil : String(parts[1])
        return (liked, trash)
    }

    /// "launch_ms_<n>". Returns nil for "launch_ms_pending" until a value
    /// is available.
    private func launchMilliseconds(timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)

        func sample() -> Int? {
            guard let identifier = elementSnapshots(withPrefix: "launch_ms_").first?.identifier else { return nil }
            guard identifier != "launch_ms_pending" else { return nil }
            return Int(identifier.dropFirst("launch_ms_".count))
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

    /// "space_probe_<pendingBytes>_<reclaimedBytes>".
    private func spaceProbe(timeout: TimeInterval) -> (pending: Int64, reclaimed: Int64)? {
        guard let f = intFields(prefix: "space_probe_", count: 2, timeout: timeout) else { return nil }
        return (Int64(f[0]), Int64(f[1]))
    }

    /// "trash_rows_<count>_<dormantCount>".
    private func trashRowsProbe(timeout: TimeInterval) -> (count: Int, dormant: Int)? {
        guard let f = intFields(prefix: "trash_rows_", count: 2, timeout: timeout) else { return nil }
        return (f[0], f[1])
    }

    /// "trash_entry_<assetKey>_<bytes>_<replacementBytes>" (or
    /// "trash_entry_none", the newest-queued-entry probe reading no queue).
    private func trashEntryProbe(timeout: TimeInterval) -> (key: String, bytes: Int64, replacementBytes: Int64)? {
        guard let identifier = debouncedProbe(prefix: "trash_entry_", timeout: timeout) else { return nil }
        let body = identifier.dropFirst("trash_entry_".count)
        guard body != "none" else { return nil }
        let parts = body.split(separator: "_")
        guard parts.count == 3, let bytes = Int64(parts[1]), let replacementBytes = Int64(parts[2]) else { return nil }
        return (String(parts[0]), bytes, replacementBytes)
    }

    /// "libfetch_<photoKitCount>_<swiftDataCount>".
    private func fetchCounters(timeout: TimeInterval) -> (photoKit: Int, swiftData: Int)? {
        guard let f = intFields(prefix: "libfetch_", count: 2, timeout: timeout) else { return nil }
        return (f[0], f[1])
    }

    /// "deckwrites_<idStringsWritten>_<intsWritten>_<saves>".
    private func deckWrites(timeout: TimeInterval) -> (ids: Int, ints: Int, saves: Int)? {
        guard let f = intFields(prefix: "deckwrites_", count: 3, timeout: timeout) else { return nil }
        return (f[0], f[1], f[2])
    }

    /// "scrubber_probe_<isScrubbing>_<currentMs>_<durationMs>". Returns
    /// one sample, not a debounced pair. `currentMs` updates about 4 times
    /// per second during playback, so two equal samples are unlikely.
    /// `isScrubbing` and `durationMs` are stable. Polls until a
    /// well-formed reading exists or `timeout` ends.
    private func scrubberProbe(timeout: TimeInterval) -> (scrubbing: Bool, currentMs: Int, durationMs: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let identifier = elementSnapshots(withPrefix: "scrubber_probe_").first?.identifier {
                let body = identifier.dropFirst("scrubber_probe_".count)
                let parts = body.split(separator: "_")
                if parts.count == 3,
                   let scrubbing = Bool(String(parts[0])),
                   let currentMs = Int(parts[1]),
                   let durationMs = Int(parts[2]) {
                    return (scrubbing, currentMs, durationMs)
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }

    /// Polls until `scrubber_probe_` reports `isScrubbing == false`, then
    /// returns that single reading. Used right after a drag or long press
    /// ends. The accessibility tree can show the end of the gesture one or
    /// two frames after the drag call returns.
    private func waitForScrubEnded(timeout: TimeInterval) -> (scrubbing: Bool, currentMs: Int, durationMs: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: (scrubbing: Bool, currentMs: Int, durationMs: Int)?
        repeat {
            if let reading = scrubberProbe(timeout: 0.3) {
                last = reading
                if !reading.scrubbing { return reading }
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return last
    }

    /// "rotation_safety_<likedShielded|none>_<trashQueued|none>". Reads
    /// `AssetKeyResolver` directly for the exact live ids `rotationProbe()`
    /// already named. Proves the shield and queue state survive identifier
    /// rotation, independent of whatever slot the deck currently deals that
    /// asset into. The deck stops dealing a rotated shielded or queued
    /// video once key resolution completes. Scrolling the pager to find
    /// it is therefore not a reliable proof.
    private func rotationSafetyProbe(timeout: TimeInterval) -> (likedShielded: Bool?, trashQueued: Bool?)? {
        guard let identifier = debouncedProbe(prefix: "rotation_safety_", timeout: timeout) else { return nil }
        let body = identifier.dropFirst("rotation_safety_".count)
        let parts = body.split(separator: "_")
        guard parts.count == 2 else { return nil }
        func parse(_ token: Substring) -> Bool?? {
            switch token {
            case "none": return .some(nil)
            case "true": return .some(true)
            case "false": return .some(false)
            default: return nil
            }
        }
        guard let liked = parse(parts[0]), let trash = parse(parts[1]) else { return nil }
        return (liked, trash)
    }

    /// A parsed `backfill_` probe reading.
    private struct BackfillReading: Equatable {
        let resolved: Int
        let pending: Int
        let total: Int
    }

    /// Debounced read of "backfill_<state>_<resolved>_<pending>_<total>",
    /// only non-nil once `state == "done"`. Duplicated from `M4Tests`
    /// rather than widening `FeedUITestCase`, the same choice `M4Tests`
    /// itself already made for its own per-suite helpers.
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
            guard String(parts[0]) == "done" else { return nil }
            return BackfillReading(resolved: resolved, pending: pending, total: total)
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

    /// The change in `DeckWriteCounters` for one tap. `Equatable` lets
    /// `testDeckTapWritesAreConstant` check that every round gives the
    /// same delta. The deck gets one entry shorter on each tap.
    private struct DeckDelta: Equatable, CustomStringConvertible {
        let ids: Int
        let ints: Int
        let saves: Int

        init(writes: (ids: Int, ints: Int, saves: Int), after: (ids: Int, ints: Int, saves: Int)) {
            ids = after.ids - writes.ids
            ints = after.ints - writes.ints
            saves = after.saves - writes.saves
        }

        var description: String { "(Δids: \(ids), Δints: \(ints), Δsaves: \(saves))" }
    }
}

