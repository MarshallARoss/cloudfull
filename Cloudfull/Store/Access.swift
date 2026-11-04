//
//  Access.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Where a StoreKit fact came from. Mirrors `AppStore.Environment`, kept as
/// its own type so this file imports no StoreKit and `AccessResolver`
/// stays unit-testable with plain fixtures.
enum StoreEnvironment: String, Codable, Equatable {
    case production, sandbox, xcode, other
}

/// How a subscription entitlement is renewing, read from
/// `Product.SubscriptionInfo.Status.state`. Kept as its own type for the
/// same reason as `StoreEnvironment`.
enum RenewalState: String, Codable, Equatable {
    case subscribed, expired, inBillingRetryPeriod, inGracePeriod, revoked
}

/// The facts `Entitlements.LiveStoreFactsSource` reads from
/// `AppTransaction.shared`. A grandfathered 1.0 customer is proven from
/// this alone, with no entitlement to check.
struct AppTransactionFacts: Codable, Equatable {
    var environment: StoreEnvironment
    var originalAppVersion: String
    var originalPurchaseDate: Date?
    var isVerified: Bool
}

/// One unlock-product entitlement, as `Entitlements.LiveStoreFactsSource`
/// reads it from `Transaction.currentEntitlements`. Not `Codable`: it is
/// never cached, only read fresh on each `refresh()`.
struct EntitlementFact: Equatable {
    var productID: String
    var expirationDate: Date?
    var revocationDate: Date?
    var isIntroOffer: Bool
    var renewalState: RenewalState?
    var gracePeriodExpiresAt: Date?
    var willAutoRenew: Bool?
    /// When this subscription was first bought, for the
    /// `subscription.ageDays` analytics fact. Not used by the resolver.
    var originalPurchaseDate: Date? = nil
}

/// What `AccessResolver` decided the app is allowed to do, and why. A pure
/// value type, with no StoreKit import, so `AccessResolver.resolve` is
/// unit-testable with plain fixtures.
enum Access: Codable, Equatable {
    /// No facts yet, for example an offline first launch. Treated as
    /// unlocked until `Entitlements.refresh()` has something to say.
    case unknown
    /// A build with a different bundle id than the official one. An
    /// open-source fork never shows a paywall.
    case fork
    /// A paid-era customer (build 17, or any original purchase before the
    /// app went free), carried forward with no new purchase required.
    case grandfathered
    /// The non-consumable lifetime unlock.
    case lifetime
    /// The auto-renewable monthly unlock, trial or paid.
    case monthly(expiresAt: Date?, isTrial: Bool, willAutoRenew: Bool, inGracePeriod: Bool)
    /// A trial that ended, a subscription that lapsed, or a purchase never
    /// made. Shows the paywall.
    /// Named `locked`, not `none`: `.none` on an `Access?` parameter would
    /// silently mean `Optional.none` (nil), not this case.
    case locked
    #if DEBUG
    /// A Settings-picked or launch-argument override, or a build run from
    /// Xcode. Never compiled into a release build.
    case debugUnlocked
    #endif

    /// False only for `.locked`. Every other case lets the user in.
    var isUnlocked: Bool {
        if case .locked = self { return false }
        return true
    }

    /// The bucket `Usage.accessState(_:trialDaysLeft:)` records. Never the
    /// exact expiration date or renewal flag.
    var analyticsKind: Usage.AccessKind {
        switch self {
        case .unknown: return .unknown
        case .fork: return .fork
        case .grandfathered: return .grandfathered
        case .lifetime: return .lifetime
        case .monthly(_, let isTrial, _, _): return isTrial ? .trial : .monthly
        case .locked: return .none
        #if DEBUG
        case .debugUnlocked: return .debug
        #endif
        }
    }
}

/// Turns raw StoreKit facts into one `Access` value. Pure, synchronous, and
/// free of StoreKit: every fact it reads arrives as a plain value type, so
/// a unit test can hand it fixtures with no store, no network, and no
/// `async`.
enum AccessResolver {
    /// First match wins. See the file header comments on `Access` for what
    /// each case means. `cached` is the access value from before this
    /// resolution; it is the only way the fork and never-downgrade rules
    /// below can carry state forward when the newest facts are thin
    /// (offline, or an unverified app transaction).
    static func resolve(
        isOfficial: Bool,
        appTx: AppTransactionFacts?,
        entitlements: [EntitlementFact],
        cached: Access?,
        now: Date,
        freeSinceDate: Date = StoreProducts.freeSinceDate
    ) -> Access {
        guard isOfficial else { return .fork }

        if entitlements.contains(where: { $0.productID == StoreProducts.lifetime && $0.revocationDate == nil }) {
            return .lifetime
        }

        // Membership in `entitlements` is the signal for an active
        // subscription, not a fresh comparison of `expirationDate` against
        // `now`. Apple keeps a subscription in `currentEntitlements` while
        // its state is `.subscribed` or `.inGracePeriod`, and during grace
        // the transaction's own `expirationDate` already reads as past.
        // Three checks on top of membership. (1) Not revoked. (2) When the
        // renewal state is known, only `.subscribed` and `.inGracePeriod`
        // count: StoreKit can still list a subscription for a moment
        // after it expired or entered billing retry without grace. (3) A
        // past `expirationDate` ends access unless the state is
        // `.inGracePeriod`, the one state where Apple keeps the user
        // entitled past that date.
        if let monthlyFact = entitlements.first(where: { fact in
            guard fact.productID == StoreProducts.monthly, fact.revocationDate == nil else { return false }
            switch fact.renewalState {
            case .inGracePeriod: return true
            case nil, .subscribed: return fact.expirationDate.map { $0 > now } ?? true
            default: return false
            }
        }) {
            let inGrace = monthlyFact.renewalState == .inGracePeriod
            return .monthly(
                expiresAt: inGrace ? monthlyFact.gracePeriodExpiresAt : monthlyFact.expirationDate,
                isTrial: monthlyFact.isIntroOffer,
                willAutoRenew: monthlyFact.willAutoRenew ?? true,
                inGracePeriod: inGrace
            )
        }

        if let appTx, appTx.isVerified, appTx.environment == .production {
            let wasPaidBuild = StoreProducts.paidBuilds.contains(appTx.originalAppVersion)
            let boughtBeforeFree = (appTx.originalPurchaseDate ?? .distantFuture) < freeSinceDate
            if wasPaidBuild || boughtBeforeFree {
                return .grandfathered
            }
        }

        if appTx == nil, entitlements.isEmpty {
            return cached ?? .unknown
        }

        // A cached grandfathered customer never falls back to `.locked`
        // because one refresh came back with no app transaction, or an
        // unverified one. A real revocation would show up as a changed
        // fact, not as an absence of one.
        if case .grandfathered = cached, appTx == nil || appTx?.isVerified == false {
            return .grandfathered
        }

        return .locked
    }
}
