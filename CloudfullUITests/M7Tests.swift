//
//  M7Tests.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

/// M7 (iCloud sync) proofs that run on one simulator, with no iCloud
/// account required. Each test backs one DEBUG launch argument handled
/// by `SyncTestHarness` or a model-field default, and reads a
/// `GateProbes` probe `RowCountProbe` or the model layer backs directly.
/// Two-device and real-CloudKit proofs are a manual simulator plan
/// (`design/M7_SPEC.md` Step G2/G3), not UI tests.
final class M7Tests: FeedUITestCase {

    // MARK: - Step C: bin ownership + cloudKey stamping

    /// Seeds one `TrashEntry` stamped with another device's id and one
    /// with this device's own (`-cloudfull-seed-foreign-trash`), both
    /// already dormant for 120s. `TrashService.reconcileWithLibrary`
    /// deletes the own row on its first pass (the two-strike window has
    /// already elapsed), but must never mark or delete the foreign row.
    func testReconcileKeepsAnotherDevicesBinRow() throws {
        app.launchArguments = ["-cloudfull-reset-deck-state", "-cloudfull-local-only", "-cloudfull-seed-foreign-trash"]
        app.launch()
        grantPhotoAccessIfAsked()

        XCTAssertTrue(
            waitFor(timeout: 20) { self.trashRowCount() == 1 && self.foreignTrashCount() == 1 },
            "Expected trash_rows_1_* (the own dead row gone after reconcile) and trash_foreign_1 " +
            "(the foreign row kept) within 20s; last read trash_rows=\(String(describing: trashRowCount())), " +
            "trash_foreign=\(String(describing: foreignTrashCount()))"
        )
    }

    /// Queues the current video, the same tap path as
    /// `M2TrashTests.testTrashQueueRestoreEmpty`, and proves
    /// `CloudKeyBackfillLauncher.noteNewRow` resolves its `cloudKey`
    /// within seconds, instead of waiting for the next launch's
    /// full-table backfill pass.
    func testQueueStampsCloudKeyWithinSeconds() throws {
        launch(resettingState: true)

        guard let current = centeredPage(timeout: 20) else {
            XCTFail("No centered page_ element found at start")
            return
        }

        guard advance(from: current, afterPerforming: { self.app.buttons["rail_trash"].tap() }) != nil else {
            XCTFail("Pager did not advance after tapping rail_trash")
            return
        }

        XCTAssertTrue(
            waitFor(timeout: 10) { self.rowCountNilReading()?.trash == 0 },
            "Expected rowcountnil_*_*_0 (the just-queued row's cloudKey resolved) within 10s; " +
            "last read \(String(describing: rowCountNilReading()))"
        )
    }

    // MARK: - Probes

    /// Reads "trash_rows_<trash>_<dormant>", a `GateProbes` probe backed
    /// directly by `RowCountProbe`. Returns only the row count; the
    /// dormant count is irrelevant to this suite's assertions.
    private func trashRowCount() -> Int? {
        guard let identifier = elementSnapshots(withPrefix: "trash_rows_").first?.identifier else { return nil }
        let body = identifier.dropFirst("trash_rows_".count)
        let parts = body.split(separator: "_")
        guard parts.count == 2, let trash = Int(parts[0]) else { return nil }
        return trash
    }

    /// Reads "trash_foreign_<n>", a `GateProbes` probe backed directly
    /// by `RowCountProbe`.
    private func foreignTrashCount() -> Int? {
        guard let identifier = elementSnapshots(withPrefix: "trash_foreign_").first?.identifier else { return nil }
        return Int(identifier.dropFirst("trash_foreign_".count))
    }

    /// Reads "rowcountnil_<seen>_<liked>_<trash>", a `GateProbes` probe
    /// backed by a direct `modelContext.fetchCount` of rows with
    /// `cloudKey == nil`. Matches `M4Tests`' own reader of the same
    /// probe.
    private func rowCountNilReading() -> (seen: Int, liked: Int, trash: Int)? {
        guard let identifier = elementSnapshots(withPrefix: "rowcountnil_").first?.identifier else { return nil }
        let body = identifier.dropFirst("rowcountnil_".count)
        let parts = body.split(separator: "_")
        guard parts.count == 3,
              let seen = Int(parts[0]), let liked = Int(parts[1]), let trash = Int(parts[2]) else { return nil }
        return (seen, liked, trash)
    }
}
