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
            cached: .legacy,
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

    // Changed 2026-11 (review fix 3): this test used to expect `.locked`. The
    // decided rule is that membership in `currentEntitlements` is enough, with
    // no check of `expirationDate` against the device clock, so a subscriber
    // at a renewal boundary is not locked out.
    @Test("A subscribed monthly fact with a past expirationDate is still entitled (membership, not the clock)")
    func monthlySubscribedWithPastExpirationStaysMonthly() {
        let pastExpiry = Date().addingTimeInterval(-86_400)
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: nil,
            entitlements: [EntitlementFact(productID: StoreProducts.monthly, expirationDate: pastExpiry, revocationDate: nil, isIntroOffer: false, renewalState: .subscribed, gracePeriodExpiresAt: nil, willAutoRenew: true)],
            cached: nil,
            now: Date()
        )
        guard case .monthly = resolved else {
            Issue.record("Expected .monthly, got \(resolved)")
            return
        }
    }

    @Test("A listed monthly fact with no renewal state and a past expirationDate is still entitled")
    func monthlyWithNilRenewalStateAndPastExpirationStaysMonthly() {
        // The status fetch failed, or the renewal transaction has not been
        // delivered yet: membership alone decides.
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: nil,
            entitlements: [EntitlementFact(productID: StoreProducts.monthly, expirationDate: Date().addingTimeInterval(-3_600), revocationDate: nil, isIntroOffer: false, renewalState: nil, gracePeriodExpiresAt: nil, willAutoRenew: nil)],
            cached: nil,
            now: Date()
        )
        guard case .monthly = resolved else {
            Issue.record("Expected .monthly, got \(resolved)")
            return
        }
    }

    @Test("A revoked monthly fact is not entitled, whatever its renewal state", arguments: [RenewalState?.none, .subscribed, .inGracePeriod])
    func revokedMonthlyIsLocked(renewalState: RenewalState?) {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: nil,
            entitlements: [EntitlementFact(productID: StoreProducts.monthly, expirationDate: nil, revocationDate: Date(), isIntroOffer: false, renewalState: renewalState, gracePeriodExpiresAt: nil, willAutoRenew: nil)],
            cached: .locked,
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

    // MARK: - Legacy rule by build

    @Test("Build 17 verified in production is legacy")
    func paidBuildIsLegacy() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "17", originalPurchaseDate: nil, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .legacy)
    }

    @Test("Builds outside the paid list are not legacy", arguments: ["18", "1", "2"])
    func unlistedBuildsAreNotLegacy(version: String) {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: version, originalPurchaseDate: nil, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    @Test("A paid build id in sandbox does not count as legacy")
    func paidBuildInSandboxIsNotLegacy() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .sandbox, originalAppVersion: "1.0", originalPurchaseDate: nil, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    @Test("A paid build id under the Xcode environment does not count as legacy; that override lives outside the resolver")
    func paidBuildUnderXcodeEnvironmentIsNotLegacy() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .xcode, originalAppVersion: "17", originalPurchaseDate: nil, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    @Test("An unverified app transaction never counts as legacy on its own")
    func unverifiedPaidBuildIsNotLegacy() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "17", originalPurchaseDate: nil, isVerified: false),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .locked)
    }

    // MARK: - Legacy rule by purchase date
    //
    // `StoreProducts.freeSinceDate` is 2026-11-04 (the 1.1 TestFlight upload
    // day), so the signal is ON by default — see the two boundary tests
    // below. The first pair exercises the signal with an explicit
    // `freeSinceDate:`.

    @Test("A production purchase dated before an explicit freeSinceDate is legacy even off the paid-builds list")
    func purchaseDateBeforeFreeSinceDateIsLegacy() {
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
        #expect(resolved == .legacy)
    }

    @Test("A production purchase dated after an explicit freeSinceDate is not legacy")
    func purchaseDateAfterFreeSinceDateIsNotLegacy() {
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

    @Test("With the default freeSinceDate (2026-11-04), a production purchase dated 2026-11-03 is legacy even off the paid-builds list")
    func purchaseDateBeforeDefaultFreeSinceDateIsLegacy() {
        // No `freeSinceDate:` argument: this uses the real default,
        // `StoreProducts.freeSinceDate`. Build "16" is not in `paidBuilds`,
        // so only the purchase-date signal can make it legacy.
        let purchaseDate = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        #expect(!StoreProducts.paidBuilds.contains("16"))
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "16", originalPurchaseDate: purchaseDate, isVerified: true),
            entitlements: [],
            cached: nil,
            now: Date()
        )
        #expect(resolved == .legacy)
    }

    @Test("With the default freeSinceDate (2026-11-04), a production purchase on or after that day, off the paid-builds list, is not legacy", arguments: ["2026-11-04T00:00:00Z", "2026-11-04T12:00:00Z", "2026-12-01T00:00:00Z"])
    func purchaseDateOnOrAfterDefaultFreeSinceDateIsNotLegacy(iso: String) {
        let purchaseDate = ISO8601DateFormatter().date(from: iso)!
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "18", originalPurchaseDate: purchaseDate, isVerified: true),
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

    // MARK: - Never-downgrade legacy

    @Test("A cached legacy customer stays legacy when the app transaction comes back unverified")
    func cachedLegacySurvivesUnverifiedAppTransaction() {
        let resolved = AccessResolver.resolve(
            isOfficial: true,
            appTx: AppTransactionFacts(environment: .production, originalAppVersion: "2", originalPurchaseDate: nil, isVerified: false),
            entitlements: [],
            cached: .legacy,
            now: Date()
        )
        #expect(resolved == .legacy)
    }

    @Test("A cached legacy customer stays legacy with no app transaction at all")
    func cachedLegacySurvivesNilAppTransaction() {
        let resolved = AccessResolver.resolve(isOfficial: true, appTx: nil, entitlements: [], cached: .legacy, now: Date())
        #expect(resolved == .legacy)
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
