//
//  AddToAlbumActivity.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// A custom share-sheet activity that performs no work of its own.
///
/// It only signals, through the share sheet's own
/// `completionWithItemsHandler` (`ShareCoordinator.shareSheetFinished`),
/// that the user wants the album picker next.
final class AddToAlbumActivity: UIActivity {
    static let activityType = UIActivity.ActivityType("com.cloudfull.app.share.addToAlbum")

    override var activityType: UIActivity.ActivityType? { Self.activityType }
    // Do not change this title. UI tests find the activity by this exact label.
    override var activityTitle: String? { "Add to Album" }
    override var activityImage: UIImage? {
        UIImage(systemName: "rectangle.stack.badge.plus")
    }
    override class var activityCategory: UIActivity.Category { .action }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }
    override func prepare(withActivityItems activityItems: [Any]) {}
    override func perform() { activityDidFinish(true) }
}
