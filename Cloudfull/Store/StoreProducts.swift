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
    // Product IDs follow `com.cloudfull.app.unlock.<plan>.<US price in
    // cents>`. A product never changes its price. A new price is a new
    // product with a new ID, for example `com.cloudfull.app.unlock.monthly.399`.

    /// Every monthly product ID starts with this prefix.
    static let monthlyPrefix = "com.cloudfull.app.unlock.monthly."
    /// Every lifetime product ID starts with this prefix.
    static let lifetimePrefix = "com.cloudfull.app.unlock.lifetime."

    /// Auto-renewable, one month, in the subscription group "Cloudfull
    /// Unlock". It has no free introductory offer.
    static let monthly = "com.cloudfull.app.unlock.monthly.299"
    /// Non-consumable. Unlocks the app once, for good.
    static let lifetime = "com.cloudfull.app.unlock.lifetime.999"
    static let unlockIDs: Set<String> = [monthly, lifetime]

    /// The price tier of an unlock product: the last dot-separated part of
    /// its ID, for example `com.cloudfull.app.unlock.monthly.299` → `299`.
    /// `nil` for anything else, including the old tier-less
    /// `com.cloudfull.app.unlock.monthly`, a tip ID, or an empty or
    /// non-numeric tail.
    static func tier(of productID: String) -> String? {
        let tail: Substring
        if productID.hasPrefix(monthlyPrefix) {
            tail = productID.dropFirst(monthlyPrefix.count)
        } else if productID.hasPrefix(lifetimePrefix) {
            tail = productID.dropFirst(lifetimePrefix.count)
        } else {
            return nil
        }
        guard !tail.isEmpty, tail.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return String(tail)
    }

    // No hard-coded subscription group id here. The local
    // `Cloudfull.storekit` file used by Xcode's test configuration is not
    // synced with App Store Connect, so its group id does not match the
    // real one. Read `product.subscription?.subscriptionGroupID` from the
    // loaded monthly product at runtime instead. See
    // `Entitlements.subscriptionGroupID`.

    /// Every build that was ever live as a paid download. ASC verified
    /// 2026-11-03: build 17 (version 1.0) was the only paid build.
    static let paidBuilds: Set<String> = ["17"]

    /// The day the App Store price became Free. The second legacy
    /// signal: an original purchase dated before this day was a paid
    /// download, even if `paidBuilds` does not name its exact build.
    ///
    /// Set to the day of the 1.1 TestFlight upload (2026-11-04): every
    /// original purchase before it was a $6.99 download, since the price
    /// cannot become Free before this build exists. A later date would
    /// count free downloads made after the price change as legacy, so it gives
    /// away MORE free unlocks; an earlier one would miss paid buyers.
    /// (A far-future value would make every install legacy; `.distantPast`
    /// turns the signal off.)
    static let freeSinceDate: Date = ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z") ?? .distantPast

    /// False for an open-source fork built under a different bundle id. A
    /// fork never shows the paywall.
    static let isOfficialBuild = Bundle.main.bundleIdentifier == "com.cloudfull.app"
}
