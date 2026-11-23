//
//  AdConversionValue.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import StoreKit
import os

// Apple's ad measurement keeps ONE conversion value per install. Meta's SDK writes it when it
// starts. Where no Meta SDK runs (the off regions, an unknown storefront, a build with no Meta
// key), the app writes it. This file holds that writer. It makes no network request: iOS sends
// the grouped report to the ad network later.
// The app stores every purchase fact, also when Meta writes, so a launch where the app writes never
// writes a lower value than the stored set. Known limit: Meta's SDK writes fine 0 one time on its
// first run (FBSDKAppEvents.m:1104-1111); that write cannot be undone from here.

/// Apple's three coarse values.
enum AdCoarseValue: Int, Sendable {
    case low = 0, medium, high
}

/// A fine value (0...63, counted in the first window only) and a coarse value (all windows).
struct AdConversionValue: Equatable, Sendable {
    var fine: Int
    var coarse: AdCoarseValue
}

/// The facts the app records, one bit each. The fine value is the OR of the recorded bits.
/// Bits 2 to 5 are not used and stay 0. Paywall and checkout events set nothing.
struct AdFacts: OptionSet, Sendable {
    let rawValue: Int
    static let subscribed = AdFacts(rawValue: 1)           // bit 0: a monthly plan was bought (verified)
    static let lifetimePurchased = AdFacts(rawValue: 2)    // bit 1: the lifetime unlock was bought (verified)
}

/// The ONE table. Fine value: 0 = installed, nothing bought; 1 = monthly; 2 = lifetime; 3 = both.
/// Coarse value (it carries the plan in the later windows): low = nothing bought; medium = monthly
/// bought and no lifetime; high = lifetime bought. The same table must be entered in Meta Events
/// Manager, TikTok Events Manager and Google Ads: fine 1 = Subscribe, fine 2 = Purchase, fine 3 =
/// both, with the product's price as the money value of each row. Meta's own rule format is "a value
/// matches when all its listed events were recorded" (FBSDKSKAdNetworkRule.m,
/// isMatchedWithRecordedEvents); this table can be written in it.
enum AdConversionSchema {
    /// nil for the paywall and the checkout: they set nothing.
    static func fact(for event: AdEvent) -> AdFacts? {
        switch event {
        case .paywallShown, .checkoutStarted: return nil
        case .subscribed: return .subscribed
        case .lifetimePurchased: return .lifetimePurchased
        }
    }

    static func value(for facts: AdFacts) -> AdConversionValue {
        let coarse: AdCoarseValue
        if facts.contains(.lifetimePurchased) {
            coarse = .high
        } else if facts.contains(.subscribed) {
            coarse = .medium
        } else {
            coarse = .low
        }
        return AdConversionValue(fine: facts.rawValue, coarse: coarse)
    }

    /// The lifetime unlock is the highest fact, so nothing higher can follow; locking the window
    /// makes Apple send the report sooner. Every other call leaves the window open.
    static func locksWindow(for fact: AdFacts) -> Bool { fact == .lifetimePurchased }
}

/// The one call to Apple. The live type calls StoreKit; tests use a fake.
protocol AdConversionUpdating {
    func update(_ value: AdConversionValue, lockWindow: Bool)
}

/// A failed call has no retry and no user-visible effect. iOS ignores the call when no postback is
/// pending. In a Debug build started with `-cloudfull-ads-debug`, each call and its result go to
/// the log, so a real-key test can see what Apple answered (`debugLog` is false in Release).
struct LiveConversionUpdater: AdConversionUpdating {
    var debugLog = false

    func update(_ value: AdConversionValue, lockWindow: Bool) {
        let coarse: SKAdNetwork.CoarseConversionValue
        switch value.coarse {
        case .low: coarse = .low
        case .medium: coarse = .medium
        case .high: coarse = .high
        }
        #if DEBUG
        let log = debugLog
        #endif
        SKAdNetwork.updatePostbackConversionValue(value.fine, coarseValue: coarse, lockWindow: lockWindow) { error in
            #if DEBUG
            if log {
                Logger(subsystem: "com.cloudfull.app", category: "AdConversion").info(
                    "postback update fine=\(value.fine) coarse=\(String(describing: value.coarse), privacy: .public) lock=\(lockWindow) error=\(error?.localizedDescription ?? "none", privacy: .public)")
            }
            #endif
        }
    }
}

/// Holds the set of recorded facts and makes the update calls. The set only grows, so the value
/// never goes down.
@MainActor
struct AdConversionWriter {
    static let factsKey = "ads.conversionFacts"

    let defaults: UserDefaults
    let updater: any AdConversionUpdating

    /// Pure. The app writes when production conditions hold (`result.appleAdsMayRun`, the same
    /// conditions that let Apple Ads attribution run) and the Meta sink does not start in this
    /// launch. Meta starts when the gate opens the SDKs and the build carries Meta keys.
    nonisolated static func appIsWriter(_ result: AdGateResult, keys: AdKeys) -> Bool {
        result.appleAdsMayRun && !(result.sdksMayStart && keys.hasMeta)
    }

    /// The facts recorded so far. Only the two known bits are read.
    var stored: AdFacts {
        AdFacts(rawValue: defaults.integer(forKey: Self.factsKey) & 3)
    }

    /// At the launch decision. Registers the install (0, low on the first launch) and carries
    /// the stored value into the later windows.
    func register() {
        updater.update(AdConversionSchema.value(for: stored), lockWindow: false)
    }

    /// After the facade accepted the event (purchases passed the send rules). A fact that is
    /// already recorded makes no call. `writeToApple` false (Meta's SDK is the writer in this
    /// launch) only stores the fact, so a later launch where the app writes never lowers the value.
    func record(_ event: AdEvent, writeToApple: Bool = true) {
        guard let fact = AdConversionSchema.fact(for: event) else { return }
        let facts = stored
        guard !facts.contains(fact) else { return }
        let all = facts.union(fact)
        defaults.set(all.rawValue, forKey: Self.factsKey)
        guard writeToApple else { return }
        updater.update(AdConversionSchema.value(for: all), lockWindow: AdConversionSchema.locksWindow(for: fact))
    }
}
