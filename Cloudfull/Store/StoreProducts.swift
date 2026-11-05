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
    /// Set to the day of the 1.1 TestFlight upload (2026-11-04): every
    /// original purchase before it was a $6.99 download, since the price
    /// cannot become Free before this build exists. A later date would
    /// only risk missing a paid buyer; an earlier one changes nothing.
    /// (A far-future value would grandfather every install; `.distantPast`
    /// turns the signal off.)
    static let freeSinceDate: Date = ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z") ?? .distantPast

    /// False for an open-source fork built under a different bundle id. A
    /// fork never shows the paywall.
    static let isOfficialBuild = Bundle.main.bundleIdentifier == "com.cloudfull.app"
}
