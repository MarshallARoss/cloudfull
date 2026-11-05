//
//  AccessResolverTests.swift
//  CloudfullTests
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
@testable import Cloudfull

/// Pure, synchronous tests of `AccessResolver.resolve(...)`. No StoreKit, no
/// `SKTestSession`, no `async` — every fact is a plain fixture. See
/// `EntitlementsStoreKitTests` for the StoreKit-integration half of this
/// coverage.
@Suite("AccessResolver")
struct AccessResolverTests {

    // MARK: - Fork

    @Test("A non-official build is always a fork, regardless of other facts")
    func forkBuildIsAlwaysFork() {
        let resolved = AccessResolver.resolve(
            isOfficial: false,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "17", originalPurchaseDate: nil, isVerified: true),
            entitlements: [EntitlementFact(productID: StoreProducts.lifetime, expirationDate: nil, revocationDate: nil, isIntroOffer: false, renewalState: nil, gracePeriodExpiresAt: nil, willAutoRenew: nil)],
            cached: .grandfathered,
            now: Date()
        )
        #expect(resolved == .fork)
    }

    // MARK: - Lifetime

    @Test("A live lifetime entitlement wins over a cached locked")
    func lifetimeBeatsLocked() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "2", originalPurchaseDate: nil, isVerified: true),
            entitlements: [EntitlementFact(productID: StoreProducts.lifetime, expirationDate: nil, revocationDate: nil, isIntroOffer: false, renewalState: nil, gracePeriodExpiresAt: nil, willAutoRenew: nil)],
            cached: .locked,
            now: Date()
        )
        #expect(resolved == .lifetime)
    }

    @Test("A revoked lifetime entitlement does not count")
    func revokedLifetimeIsLocked() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: nil,
            entitlements: [EntitlementFact(productID: StoreProducts.lifetime, expirationDate: nil, revocationDate: Date(), isIntroOffer: false, renewalState: nil, gracePeriodExpiresAt: nil, willAutoRenew: nil)],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    // MARK: - Monthly

    @Test("An intro-offer monthly entitlement with a future expiry is a trial")
    func monthlyTrialWithFutureExpiry() {
        let expiry = Date().addingTimeInterval(5 * 86_400)
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: nil,
            entitlements: [EntitlementFact(productID: StoreProducts.monthly, expirationDate: expiry, revocationDate: nil, isIntroOffer: true, renewalState: nil, gracePeriodExpiresAt: nil, willAutoRenew: nil)],
            cached: nil,
            now: Date()
        )
        guard case let .monthly(expiresAt, isTrial, willAutoRenew, inGracePeriod) = resolved else {
            Issue.record("Expected .monthly, got \(resolved)")
            return
        }
        #expect(isTrial)
        #expect(expiresAt == expiry)
        #expect(willAutoRenew)
        #expect(!inGracePeriod)
    }

    @Test("A monthly entitlement whose renewalState has lapsed is ignored, even while still listed", arguments: [RenewalState.inBillingRetryPeriod, .expired])
    func monthlyWithLapsedRenewalStateIsIgnored(renewalState: RenewalState) {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: nil,
            entitlements: [EntitlementFact(productID: StoreProducts.monthly, expirationDate: Date(), revocationDate: nil, isIntroOffer: false, renewalState: renewalState, gracePeriodExpiresAt: nil, willAutoRenew: true)],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    @Test("A subscribed monthly fact with a past expirationDate is not live")
    func monthlySubscribedWithPastExpirationIsLocked() {
        let pastExpiry = Date().addingTimeInterval(-86_400)
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: nil,
            entitlements: [EntitlementFact(productID: StoreProducts.monthly, expirationDate: pastExpiry, revocationDate: nil, isIntroOffer: false, renewalState: .subscribed, gracePeriodExpiresAt: nil, willAutoRenew: true)],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    @Test("A grace-period monthly fact with a past expirationDate still counts")
    func monthlyInGracePeriodWithPastExpirationStaysMonthly() {
        let pastExpiry = Date().addingTimeInterval(-86_400)
        let graceExpiry = Date().addingTimeInterval(3 * 86_400)
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: nil,
            entitlements: [EntitlementFact(productID: StoreProducts.monthly, expirationDate: pastExpiry, revocationDate: nil, isIntroOffer: false, renewalState: .inGracePeriod, gracePeriodExpiresAt: graceExpiry, willAutoRenew: true)],
            cached: nil,
            now: Date()
        )
        guard case let .monthly(_, _, _, inGracePeriod) = resolved else {
            Issue.record("Expected .monthly, got \(resolved)")
            return
        }
        #expect(inGracePeriod)
    }

    @Test("An expired monthly entitlement that Transaction.currentEntitlements already dropped resolves to locked")
    func expiredMonthlyNotInListIsLocked() {
        // Apple never hands back an expired, non-grace transaction in
        // `Transaction.currentEntitlements`; this models that absence
        // directly rather than an `expirationDate` in the past.
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "2", originalPurchaseDate: nil, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    @Test("A monthly entitlement in its grace period reads its grace expiry, not its past expiration date, and stays unlocked")
    func monthlyInGracePeriodStaysUnlocked() {
        let pastExpiry = Date().addingTimeInterval(-86_400)
        let graceExpiry = Date().addingTimeInterval(3 * 86_400)
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: nil,
            entitlements: [EntitlementFact(productID: StoreProducts.monthly, expirationDate: pastExpiry, revocationDate: nil, isIntroOffer: false, renewalState: .inGracePeriod, gracePeriodExpiresAt: graceExpiry, willAutoRenew: true)],
            cached: nil,
            now: Date()
        )
        guard case let .monthly(expiresAt, _, _, inGracePeriod) = resolved else {
            Issue.record("Expected .monthly, got \(resolved)")
            return
        }
        #expect(inGracePeriod)
        #expect(expiresAt == graceExpiry)
        #expect(resolved.isUnlocked)
    }

    // MARK: - Grandfathering by build

    @Test("Build 17 verified in production is grandfathered")
    func paidBuildIsGrandfathered() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "17", originalPurchaseDate: nil, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .grandfathered)
    }

    @Test("Builds outside the paid list are not grandfathered", arguments: ["18", "1", "2"])
    func unlistedBuildsAreNotGrandfathered(version: String) {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: version, originalPurchaseDate: nil, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    @Test("A paid build id in sandbox does not grandfather")
    func paidBuildInSandboxIsNotGrandfathered() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .sandbox, originalAppVersion: "1.0", originalPurchaseDate: nil, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    @Test("A paid build id under the Xcode environment does not grandfather; that override lives outside the resolver")
    func paidBuildUnderXcodeEnvironmentIsNotGrandfathered() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .xcode, originalAppVersion: "17", originalPurchaseDate: nil, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    @Test("An unverified app transaction never grandfathers on its own")
    func unverifiedPaidBuildIsNotGrandfathered() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "17", originalPurchaseDate: nil, isVerified: false),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    // MARK: - Grandfathering by purchase date
    //
    // `StoreProducts.freeSinceDate` itself is `.distantPast` until release
    // day (PR 7 sets the real date), so this signal is OFF by default — see
    // `purchaseDateSignalIsOffByDefaultBeforeReleaseDay` below. These tests
    // exercise the signal itself by passing an explicit `freeSinceDate:`,
    // the way `resolve(...)` will be called once that constant is set.

    @Test("A production purchase dated before an explicit freeSinceDate is grandfathered even off the paid-builds list")
    func purchaseDateBeforeFreeSinceDateIsGrandfathered() {
        let freeSinceDate = ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z")!
        let purchaseDate = ISO8601DateFormatter().date(from: "2020-01-01T00:00:00Z")!
        #expect(purchaseDate < freeSinceDate)
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "2", originalPurchaseDate: purchaseDate, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date(),
            freeSinceDate: freeSinceDate
        )
        #expect(resolved == .grandfathered)
    }

    @Test("A production purchase dated after an explicit freeSinceDate is not grandfathered")
    func purchaseDateAfterFreeSinceDateIsNotGrandfathered() {
        let freeSinceDate = ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z")!
        let purchaseDate = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!
        #expect(purchaseDate > freeSinceDate)
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "2", originalPurchaseDate: purchaseDate, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date(),
            freeSinceDate: freeSinceDate
        )
        #expect(resolved == .locked)
    }

    @Test("With the default freeSinceDate (distantPast, pre-release), the purchase-date signal is off")
    func purchaseDateSignalIsOffByDefaultBeforeReleaseDay() {
        // No `freeSinceDate:` argument: this uses the real default,
        // `StoreProducts.freeSinceDate`, which is `.distantPast` until
        // release day. A purchase dated "now" must not grandfather.
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "1", originalPurchaseDate: Date(), isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    // MARK: - Unknown / thin facts

    @Test("With no app transaction, no entitlements, and no cache, access is unknown but unlocked")
    func noFactsAndNoCacheIsUnknownAndUnlocked() {
        let resolved = AccessResolver.resolve(isOfficial: true, appTx: nil, entitlements: [], cached: nil, now: Date())
        #expect(resolved == .unknown)
        #expect(resolved.isUnlocked)
    }

    @Test("With no facts, a cached locked stays locked")
    func noFactsWithCachedLockedStaysLocked() {
        let resolved = AccessResolver.resolve(isOfficial: true, appTx: nil, entitlements: [], cached: .locked, now: Date())
        #expect(resolved == .locked)
    }

    // MARK: - Never-downgrade grandfathered

    @Test("A cached grandfathered customer stays grandfathered when the app transaction comes back unverified")
    func cachedGrandfatheredSurvivesUnverifiedAppTransaction() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "2", originalPurchaseDate: nil, isVerified: false),
            entitlements: [],
            cached: .grandfathered,
            now: Date()
        )
        #expect(resolved == .grandfathered)
    }

    @Test("A cached grandfathered customer stays grandfathered with no app transaction at all")
    func cachedGrandfatheredSurvivesNilAppTransaction() {
        let resolved = AccessResolver.resolve(isOfficial: true, appTx: nil, entitlements: [], cached: .grandfathered, now: Date())
        #expect(resolved == .grandfathered)
    }

    // MARK: - Host build sanity

    @Test("The host app's own build is not in the paid-builds list")
    func hostBuildIsNotAPaidBuild() {
        let hostVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        #expect(hostVersion != nil)
        if let hostVersion {
            #expect(!StoreProducts.paidBuilds.contains(hostVersion))
        }
    }
}
