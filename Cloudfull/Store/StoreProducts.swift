//
//  StoreProducts.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The two in-app unlock products, and the fixed facts `AccessResolver`
/// needs about them. Holds no StoreKit type, so `Access.swift` can resolve
/// access with no StoreKit import.
enum StoreProducts {
    /// Auto-renewable, one month, in the subscription group "Cloudfull
    /// Unlock", with a 7-day free introductory offer.
    static let monthly = "com.cloudfull.app.unlock.monthly"
    /// Non-consumable. Unlocks the app once, for good.
    static let lifetime = "com.cloudfull.app.unlock.lifetime"
    static let unlockIDs: Set<String> = [monthly, lifetime]

    // No hard-coded subscription group id here. The local
    // `Cloudfull.storekit` file used by Xcode's test configuration is not
    // synced with App Store Connect, so its group id does not match the
    // real one. Read `product.subscription?.subscriptionGroupID` from the
    // loaded monthly product at runtime instead. See
    // `Entitlements.subscriptionGroupID`.

    /// Every build that was ever live as a paid download. ASC verified
    /// 2026-11-03: build 17 (version 1.0) was the only paid build.
    static let paidBuilds: Set<String> = ["17"]

    /// The day the App Store price became Free. The second grandfather
    /// signal: an original purchase dated before this day was a paid
    /// download, even if `paidBuilds` does not name its exact build.
    ///
    /// Until release day this is `.distantPast`, so the signal is OFF: no
    /// purchase date can be earlier than it. (A far-future placeholder
    /// would do the opposite and grandfather every install.) Release day
    /// (PR 7) sets it to the real date the price changed, for example
    /// `ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z")!`.
    static let freeSinceDate: Date = .distantPast

    /// False for an open-source fork built under a different bundle id. A
    /// fork never shows the paywall.
    static let isOfficialBuild = Bundle.main.bundleIdentifier == "com.cloudfull.app"
}
