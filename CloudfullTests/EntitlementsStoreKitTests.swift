//
//  EntitlementsStoreKitTests.swift
//  CloudfullTests
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import StoreKit
import StoreKitTest
import Foundation
@testable import Cloudfull

/// Integration tests driving `Entitlements` through a real `SKTestSession`
/// loaded from the root `Cloudfull.storekit` file (bundled as a resource of
/// this test target). Complements the pure-fixture coverage in
/// `AccessResolverTests`.
///
/// Serialized: every test in this suite shares the same simulated StoreKit
/// state for the process, so they cannot run concurrently.
@Suite("Entitlements + StoreKit", .serialized)
@MainActor
struct EntitlementsStoreKitTests {
    let session: SKTestSession

    init() throws {
        session = try SKTestSession(configurationFileNamed: "Cloudfull")
        session.disableDialogs = true
        session.clearTransactions()
        session.resetToDefaultState()
        setUp()
    }

    /// Isolates these tests from the host app's own `Entitlements.shared`
    /// and `AccessOverride.shared`. Both are process-wide singletons the
    /// host app touches at launch — `PermissionGateView` holds
    /// `Entitlements.shared` as an `@ObservedObject`, and `CloudfullApp`
    /// force-initializes it too — all before any test code runs.
    ///
    /// - `Entitlements.cacheKey` ("store.access.v1") is the same
    ///   UserDefaults key every `Entitlements` instance reads/writes, so a
    ///   stale cached `Access` from the host app's own launch could leak
    ///   into a freshly constructed `Entitlements(source:)` here. Clear it
    ///   before constructing one.
    /// - `AccessOverride.shared` is already constructed by the time this
    ///   runs, so writing `AccessOverride.storageKey` to `UserDefaults`
    ///   alone would land too late: the singleton only reads that key in
    ///   its own `init()`, never again. Setting `AccessOverride.shared.value`
    ///   directly updates the live singleton (its own `didSet` still
    ///   persists the UserDefaults key). Forcing `.real` matters because
    ///   the DEBUG `auto` default now also returns `.debugUnlocked` for
    ///   `.sandbox`, not just `.xcode` — `.real` is what makes
    ///   `Entitlements.refresh()` run the real resolver against this
    ///   suite's fakes, the same as the simulator end-to-end check.
    private func setUp() {
        UserDefaults.standard.removeObject(forKey: Entitlements.cacheKey)
        AccessOverride.shared.value = .real
    }

    /// The counterpart to `setUp()`. Every test calls this via `defer` at
    /// its own start, since a `struct` has no `deinit` and these are
    /// process-wide or simulator-wide state that outlives any one test.
    /// `session.clearTransactions()` matters beyond this suite: the hosted
    /// app shares the simulator's StoreKit store, so a subscription left
    /// live here would make `hasLiveSubscription` true in UI tests that
    /// run afterward.
    func tearDown() {
        session.clearTransactions()
        UserDefaults.standard.removeObject(forKey: Entitlements.cacheKey)
        AccessOverride.shared.value = .auto
    }

    /// Polls `condition` on the main actor until it is true or `timeout`
    /// elapses. Used to prove the `Transaction.updates` listener inside
    /// `Entitlements` delivers on its own, without an explicit `refresh()`.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Repeatedly calls `entitlements.refresh()` until `condition` is true
    /// or `timeout` elapses. StoreKit Test updates a subscription's status
    /// asynchronously, so the very next `refresh()` right after
    /// `expireSubscription`/`forceRenewalOfSubscription` can still observe
    /// the old entitlement; a single refresh-then-assert flakes.
    private func refreshUntil(_ entitlements: Entitlements, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await entitlements.refresh()
        }
    }

    private func label(_ outcome: Entitlements.PurchaseOutcome) -> String {
        // `PurchaseOutcome` is not `Equatable`, so tests compare this label
        // instead of the case directly.
        switch outcome {
        case .success: return "success"
        case .successCancelTrialPrompt: return "successCancelTrialPrompt"
        case .unverified: return "unverified"
        case .userCancelled: return "userCancelled"
        case .pending: return "pending"
        case .failed: return "failed"
        }
    }

    private func transaction(for productID: String) throws -> SKTestTransaction {
        guard let transaction = session.allTransactions().first(where: { $0.productIdentifier == productID }) else {
            struct MissingTransaction: Error {}
            throw MissingTransaction()
        }
        return transaction
    }

    /// Finds the latest `VerificationResult<Transaction>` for `productID`
    /// via `Transaction.latest(for:)`, polling up to `timeout`, to feed
    /// into `Entitlements.handlePurchase(_:_:)` directly. `product.purchase()`
    /// has been observed to resolve as `.userCancelled` with no user
    /// involved when run hosted under Swift Testing, so these tests drive
    /// the purchase itself through `SKTestSession.buyProduct(identifier:)`
    /// (an external-transaction API, no confirmation UI) and hand
    /// `handlePurchase` the resulting transaction's own verification.
    /// `Transaction.currentEntitlements` (scanned directly) was tried
    /// first and did not reliably see a `buyProduct` purchase right away;
    /// `Transaction.latest(for:)` is the more direct lookup for "the most
    /// recent transaction for this product," polled since StoreKit Test
    /// can still be catching up right after `buyProduct` returns.
    private func verificationResult(for productID: String, timeout: TimeInterval = 5) async -> VerificationResult<Transaction>? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let result = await Transaction.latest(for: productID) { return result }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - 1 & 2: monthly purchase, then expiry

    @Test("Buying the monthly product unlocks with a live subscription (no trial: the owner dropped the intro offer 2026-11-04)")
    func monthlyPurchaseUnlocks() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()

        _ = try await session.buyProduct(identifier: StoreProducts.monthly)
        // StoreKit Test lists the new entitlement a moment after
        // `buyProduct` returns (seen once in the 2026-11-04 preflight: a
        // refresh 0.1 s later still read `.locked`), so poll.
        for _ in 0..<25 {
            await entitlements.refresh()
            if case .monthly = entitlements.access { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        guard case let .monthly(_, isTrial, _, _) = entitlements.access else {
            Issue.record("Expected .monthly, got \(entitlements.access)")
            return
        }
        #expect(!isTrial)   // no introductory offer in Cloudfull.storekit
        #expect(entitlements.access.isUnlocked)
        #expect(entitlements.hasLiveSubscription)
        #expect(entitlements.entitlementTier == "299")
        #expect(Usage.shared.current.facts["entitlementTier"] == "299")
    }

    // No StoreKit-level "expire the monthly plan" test. `SKTestSession.expireSubscription`
    // left the trial's status at `.subscribed`, auto-renew on, expiry a week
    // out, for the whole 10 s poll (run 2026-11-03, diagnostics in the log),
    // so that lever does not work in this StoreKit Test environment. The
    // same path to `.locked` is covered by the billing-retry-without-grace
    // test below (a status StoreKit Test does change) and by the pure
    // resolver tests for a past `expirationDate` and a lapsed renewal state.

    // MARK: - 3: lifetime purchase, delivered via Transaction.updates, then refund

    @Test("Buying lifetime unlocks via the Transaction.updates listener alone, and a refund drops it")
    func lifetimePurchaseThenRefundLosesAccess() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        #expect(entitlements.access == .locked)

        _ = try await session.buyProduct(identifier: StoreProducts.lifetime)
        // No manual refresh() here: `Entitlements.handle(_:)` listens on
        // `Transaction.updates`, finishes the transaction, and refreshes on
        // its own. Poll instead of calling refresh() to prove that path.
        await waitUntil { entitlements.access == .lifetime }
        #expect(entitlements.access == .lifetime)

        let lifetimeTransaction = try transaction(for: StoreProducts.lifetime)
        try session.refundTransaction(identifier: lifetimeTransaction.identifier)
        await refreshUntil(entitlements) { entitlements.access == .locked }
        #expect(entitlements.access == .locked)
    }

    // MARK: - 4: grace period
    //
    // Two independent sessions, not one test that flips
    // `billingGracePeriodIsEnabled` mid-flight: once a subscription has
    // entered its grace period, re-forcing a renewal in the same session
    // after disabling grace does not reliably push it into billing retry
    // before the next real renewal event, so an in-process toggle flaked.
    // Each `@Test` here gets its own `init()` (a fresh `SKTestSession`,
    // `clearTransactions()`, `resetToDefaultState()`), which is the clean
    // "fresh buy" each half needs.

    @Test("A billing-retry renewal with grace enabled stays unlocked and reports inGracePeriod")
    func gracePeriodRenewalStaysUnlocked() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()

        session.billingGracePeriodIsEnabled = true
        session.shouldEnterBillingRetryOnRenewal = true
        _ = try await session.buyProduct(identifier: StoreProducts.monthly)
        try session.forceRenewalOfSubscription(productIdentifier: StoreProducts.monthly)
        await refreshUntil(entitlements) {
            if case .monthly(_, _, _, true) = entitlements.access { return true }
            return false
        }

        guard case let .monthly(_, _, _, inGracePeriod) = entitlements.access else {
            Issue.record("Expected .monthly, got \(entitlements.access)")
            return
        }
        #expect(inGracePeriod)
        #expect(entitlements.access.isUnlocked)
    }

    @Test("A billing-retry renewal with grace disabled from the start drops access to locked")
    func billingRetryRenewalWithoutGraceDropsAccess() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()

        session.billingGracePeriodIsEnabled = false
        session.shouldEnterBillingRetryOnRenewal = true
        _ = try await session.buyProduct(identifier: StoreProducts.monthly)
        try session.forceRenewalOfSubscription(productIdentifier: StoreProducts.monthly)
        await refreshUntil(entitlements) { entitlements.access == .locked }
        #expect(entitlements.access == .locked)
    }

    // MARK: - 5: handlePurchase outcomes
    //
    // None of these call `product.purchase()`: it has been observed to
    // resolve as `.userCancelled` with no user involved when run hosted
    // under Swift Testing. Instead each builds the exact
    // `Result<Product.PurchaseResult, Error>` `handlePurchase` would have
    // received from a real purchase, and feeds it directly.

    @Test("handlePurchase reports .pending for an ask-to-buy purchase")
    func handlePurchaseAskToBuyIsPending() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        guard let monthlyProduct = entitlements.products.first(where: { $0.id == StoreProducts.monthly }) else {
            Issue.record("Monthly product did not load")
            return
        }

        let outcome = await entitlements.handlePurchase(monthlyProduct, .success(.pending))
        #expect(label(outcome) == "pending")
    }

    @Test("handlePurchase reports .failed when the purchase call itself fails")
    func handlePurchaseFailureIsFailed() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        guard let monthlyProduct = entitlements.products.first(where: { $0.id == StoreProducts.monthly }) else {
            Issue.record("Monthly product did not load")
            return
        }

        let outcome = await entitlements.handlePurchase(monthlyProduct, .failure(StoreKitError.unknown))
        #expect(label(outcome) == "failed")
    }

    @Test("Buying lifetime while the monthly plan is still auto-renewing prompts to cancel it")
    func handlePurchaseLifetimeAfterAutoRenewingTrialPromptsCancel() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()

        _ = try await session.buyProduct(identifier: StoreProducts.monthly)
        await entitlements.refresh()

        guard let lifetimeProduct = entitlements.products.first(where: { $0.id == StoreProducts.lifetime }) else {
            Issue.record("Lifetime product did not load")
            return
        }
        _ = try await session.buyProduct(identifier: StoreProducts.lifetime)
        guard let verification = await verificationResult(for: StoreProducts.lifetime) else {
            Issue.record("No VerificationResult<Transaction> found for the lifetime purchase")
            return
        }
        let outcome = await entitlements.handlePurchase(lifetimeProduct, .success(.success(verification)))
        #expect(label(outcome) == "successCancelTrialPrompt")
    }

    @Test("Buying lifetime after the monthly plan's auto-renew is disabled is a plain success")
    func handlePurchaseLifetimeAfterCancelledTrialIsPlainSuccess() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()

        _ = try await session.buyProduct(identifier: StoreProducts.monthly)
        await entitlements.refresh()

        let monthlyTransaction = try transaction(for: StoreProducts.monthly)
        try session.disableAutoRenewForTransaction(identifier: monthlyTransaction.identifier)

        guard let lifetimeProduct = entitlements.products.first(where: { $0.id == StoreProducts.lifetime }) else {
            Issue.record("Lifetime product did not load")
            return
        }
        _ = try await session.buyProduct(identifier: StoreProducts.lifetime)
        guard let verification = await verificationResult(for: StoreProducts.lifetime) else {
            Issue.record("No VerificationResult<Transaction> found for the lifetime purchase")
            return
        }
        let outcome = await entitlements.handlePurchase(lifetimeProduct, .success(.success(verification)))
        #expect(label(outcome) == "success")
    }

    // MARK: - 6: dead ends

    @Test("An empty product catalog flags productsLoadFailed")
    func productsLoadFailureIsFlagged() async {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.productsOverride = { [] }
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        #expect(entitlements.productsLoadFailed)
    }

    @Test("canMakePayments mirrors the source")
    func canMakePaymentsReflectsSource() {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.canMakePaymentsOverride = false
        let entitlements = Entitlements(source: fake)
        #expect(entitlements.canMakePayments == false)
    }

    // MARK: - 7: legacy through the live refresh path

    @Test("A production app transaction for build 17 is legacy with no purchase at all")
    func legacyFromProductionBuild17() async {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = AppTransactionFacts(
            environment: .production,
            originalAppVersion: "17",
            originalPurchaseDate: nil,
            isVerified: true
        )
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        #expect(entitlements.access == .legacy)
    }

    @Test("A legacy customer stays legacy after the app transaction later comes back unverified")
    func legacyStaysWhenAppTransactionLaterUnverified() async {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = AppTransactionFacts(
            environment: .production,
            originalAppVersion: "17",
            originalPurchaseDate: nil,
            isVerified: true
        )
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        #expect(entitlements.access == .legacy)

        fake.appTransactionFacts?.isVerified = false
        await entitlements.refresh()
        #expect(entitlements.access == .legacy)
    }

    // No test here for the purchase-date legacy signal through the live
    // `Entitlements` flow: the fake's `AppTransactionFacts` could carry a
    // purchase date before `StoreProducts.freeSinceDate` (2026-11-04), but
    // `AccessResolverTests` already covers that signal against the real
    // default (`purchaseDateBeforeDefaultFreeSinceDateIsLegacy`) and
    // against an explicit `freeSinceDate:`.

    // MARK: - Review fixes: paywall hold, purchase floor, serialized refresh, restore

    private var build17: AppTransactionFacts {
        AppTransactionFacts(environment: .production, originalAppVersion: "17", originalPurchaseDate: nil, isVerified: true)
    }

    /// A verified production app transaction that is NOT legacy
    /// (build "18", bought after `freeSinceDate`): with no entitlement it
    /// resolves `.locked`, and unlike `appTx == nil` it never falls back to
    /// the cached value.
    private var notLegacy: AppTransactionFacts {
        AppTransactionFacts(
            environment: .production,
            originalAppVersion: "18",
            originalPurchaseDate: ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"),
            isVerified: true
        )
    }

    @Test("A refresh while already unlocked does not close a paywall opened from Settings")
    func refreshKeepsSettingsPaywallForUnlockedUser() async {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = build17
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        #expect(entitlements.access == .legacy)

        entitlements.presentPaywall(from: .settings)
        await entitlements.refresh()   // what every scene `.active` does
        #expect(entitlements.paywallRequest == .settings)
        entitlements.clearPaywall()
    }

    @Test("The move from locked to unlocked still closes the paywall")
    func unlockClosesPaywall() async {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        #expect(entitlements.access == .locked)
        entitlements.require(.keep) {}
        #expect(entitlements.paywallRequest == .keep)

        fake.appTransactionFacts = build17
        await entitlements.refresh()
        #expect(entitlements.access == .legacy)
        #expect(entitlements.paywallRequest == nil)
    }

    // The floor tests hide the entitlement list BEFORE the purchase, so
    // StoreKit "lags" for the whole test, and use a non-legacy app
    // transaction, so a refresh that finds no entitlement resolves
    // `.locked` instead of keeping the cached unlock.

    private func boughtWithLag(_ productID: String, _ entitlements: Entitlements, _ fake: FakeStoreFactsSource) async throws -> Entitlements.PurchaseOutcome? {
        guard let product = entitlements.products.first(where: { $0.id == productID }) else {
            Issue.record("\(productID) did not load")
            return nil
        }
        _ = try await session.buyProduct(identifier: productID)
        guard let verification = await verificationResult(for: productID) else {
            Issue.record("No VerificationResult<Transaction> found for \(productID)")
            return nil
        }
        return await entitlements.handlePurchase(product, .success(.success(verification)))
    }

    @Test("A verified lifetime purchase stays unlocked through later refreshes while the entitlement list lags")
    func lifetimePurchaseFloorSurvivesLag() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        fake.hideEntitlements = true
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        #expect(entitlements.access == .locked)

        let outcome = try await boughtWithLag(StoreProducts.lifetime, entitlements, fake)
        #expect(outcome.map(label) == "success")
        #expect(entitlements.access == .lifetime)
        await entitlements.refresh()   // the `.active` refresh after the purchase sheet closes
        #expect(entitlements.access == .lifetime)
    }

    @Test("A verified monthly purchase stays unlocked through later refreshes while the entitlement list lags")
    func monthlyPurchaseFloorSurvivesLag() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        fake.hideEntitlements = true
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()

        let outcome = try await boughtWithLag(StoreProducts.monthly, entitlements, fake)
        #expect(outcome.map(label) == "success")
        guard case .monthly = entitlements.access else {
            Issue.record("Expected .monthly, got \(entitlements.access)")
            return
        }
        await entitlements.refresh()
        guard case .monthly = entitlements.access else {
            Issue.record("Expected .monthly after a second refresh, got \(entitlements.access)")
            return
        }
    }

    @Test("A monthly subscriber who buys lifetime ends at lifetime, also while the list lags")
    func monthlyThenLifetimeEndsLifetime() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        fake.hideEntitlements = true
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        _ = try await boughtWithLag(StoreProducts.monthly, entitlements, fake)
        guard case .monthly = entitlements.access else {
            Issue.record("Expected .monthly, got \(entitlements.access)")
            return
        }

        let outcome = try await boughtWithLag(StoreProducts.lifetime, entitlements, fake)
        // The monthly plan is still set to renew, so the prompt may come.
        #expect(outcome.map(label) == "success" || outcome.map(label) == "successCancelTrialPrompt")
        #expect(entitlements.access == .lifetime)
        await entitlements.refresh()
        #expect(entitlements.access == .lifetime)
        entitlements.clearPaywall()
    }

    @Test("The floor ends once StoreKit's own facts cover the purchase")
    func floorIsDroppedWhenFactsCatchUp() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        fake.hideEntitlements = true
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        _ = try await boughtWithLag(StoreProducts.lifetime, entitlements, fake)
        #expect(entitlements.access == .lifetime)

        fake.hideEntitlements = false   // StoreKit catches up
        await entitlements.refresh()
        #expect(entitlements.access == .lifetime)

        fake.hideEntitlements = true    // the list loses it again; the floor must be gone
        await entitlements.refresh()
        #expect(entitlements.access == .locked)
    }

    @Test("A refresh with no facts at all does not end the floor by echoing the cache")
    func noFactsRefreshDoesNotDropFloor() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        fake.hideEntitlements = true
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        _ = try await boughtWithLag(StoreProducts.lifetime, entitlements, fake)
        #expect(entitlements.access == .lifetime)

        fake.appTransactionFacts = nil   // offline: no app transaction, empty list; the resolver returns the cache
        await entitlements.refresh()
        #expect(entitlements.access == .lifetime)

        fake.appTransactionFacts = notLegacy   // back online, the list still lags
        await entitlements.refresh()
        #expect(entitlements.access == .lifetime)
    }

    @Test("A listed monthly plan does not cover a lifetime purchase the list has not shown yet")
    func listedMonthlyDoesNotCoverLifetimeFloor() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()

        _ = try await session.buyProduct(identifier: StoreProducts.monthly)
        for _ in 0..<50 {   // wait until the monthly entitlement is really listed
            if await fake.currentEntitlements().contains(where: { $0.productID == StoreProducts.monthly }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await entitlements.refresh()
        guard case .monthly = entitlements.access else {
            Issue.record("Expected .monthly before the lifetime purchase, got \(entitlements.access)")
            return
        }

        fake.hiddenProductIDs = [StoreProducts.lifetime]   // monthly listed, lifetime lagging
        _ = try await boughtWithLag(StoreProducts.lifetime, entitlements, fake)
        #expect(entitlements.access == .lifetime)
        await entitlements.refresh()   // the resolver alone says `.monthly`; the floor keeps `.lifetime`
        #expect(entitlements.access == .lifetime)
        entitlements.clearPaywall()
    }

    @Test("A refund of the proven purchase ends the floor, so access locks again")
    func revocationEndsFloor() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        fake.hideEntitlements = true
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        _ = try await boughtWithLag(StoreProducts.lifetime, entitlements, fake)
        #expect(entitlements.access == .lifetime)

        let lifetimeTransaction = try transaction(for: StoreProducts.lifetime)
        try session.refundTransaction(identifier: lifetimeTransaction.identifier)
        await refreshUntil(entitlements) { entitlements.access == .locked }
        #expect(entitlements.access == .locked)
    }

    @Test("An older in-flight refresh cannot apply stale facts after a newer one")
    func refreshesAreSerialized() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        #expect(entitlements.access == .locked)

        fake.holdFirstAppTransaction = true
        let older = Task { await entitlements.refresh() }   // reads the not-legacy facts, then waits
        for _ in 0..<100 where !fake.isHolding { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(fake.isHolding)

        fake.appTransactionFacts = build17
        let newer = Task { await entitlements.refresh() }
        try await Task.sleep(nanoseconds: 100_000_000)
        fake.releaseHeld()
        await older.value
        await newer.value
        #expect(entitlements.access == .legacy)
    }

    @Test("A refund of a lifetime purchase is not counted as a purchase success")
    func revokedTransactionIsNotCountedAsPurchase() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        let key = "purchase.lifetime.success"

        _ = try await session.buyProduct(identifier: StoreProducts.lifetime)
        await waitUntil { entitlements.access == .lifetime && (Usage.shared.current.counts[key] ?? 0) >= 1 }
        let afterBuy = Usage.shared.current.counts[key] ?? 0
        #expect(afterBuy >= 1)   // control: the listener does count the live purchase
        #expect((Usage.shared.current.counts["purchase.lifetime.999.success"] ?? 0) >= 1)   // and its tier twin

        let lifetimeTransaction = try transaction(for: StoreProducts.lifetime)
        try session.refundTransaction(identifier: lifetimeTransaction.identifier)
        // Hand the revoked transaction to `handle(_:)` ourselves, once it
        // reads as revoked: the count is then decided by the time the
        // call returns, with no timing to guess. (The listener may also
        // deliver it; it must not count either.)
        var revoked: VerificationResult<Transaction>?
        for _ in 0..<50 {
            if let latest = await Transaction.latest(for: StoreProducts.lifetime),
               case .verified(let t) = latest, t.revocationDate != nil {
                revoked = latest
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let revoked else {
            Issue.record("The refunded transaction never read as revoked")
            return
        }
        await entitlements.handle(revoked)
        #expect((Usage.shared.current.counts[key] ?? 0) == afterBuy)
    }

    @Test("canMakePayments is re-read on refresh")
    func canMakePaymentsIsReReadOnRefresh() async {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.canMakePaymentsOverride = false
        let entitlements = Entitlements(source: fake)
        #expect(entitlements.canMakePayments == false)
        fake.canMakePaymentsOverride = true
        await entitlements.refresh()
        #expect(entitlements.canMakePayments)
    }

    @Test("A restore that finds a purchase keeps the paywall up for its alert")
    func restoreKeepsPaywallUpUntilCleared() async {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy   // verified, so `restore()` never calls the real `AppTransaction.refresh()`
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        entitlements.require(.keep) {}
        #expect(entitlements.paywallRequest == .keep)

        fake.appTransactionFacts = build17
        let outcome = await entitlements.restore()
        #expect(outcome == .restored)
        #expect(entitlements.paywallRequest == .keep)   // the "Welcome back" alert needs the cover
        entitlements.clearPaywall()
        #expect(entitlements.paywallRequest == nil)
    }

    @Test("An unlock that lands while the restore sheet is up does not drop the cover")
    func unlockDuringSyncKeepsPaywallUp() async throws {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        entitlements.require(.keep) {}

        fake.holdSync = true
        let restoring = Task { await entitlements.restore() }
        for _ in 0..<100 where !fake.isHoldingSync { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(fake.isHoldingSync)

        // What the scene going `.active` after Apple's sheet does.
        fake.appTransactionFacts = build17
        await entitlements.refresh()
        #expect(entitlements.access == .legacy)
        #expect(entitlements.paywallRequest == .keep)

        fake.releaseSync()
        let outcome = await restoring.value
        #expect(outcome == .restored)
        #expect(entitlements.paywallRequest == .keep)
        entitlements.clearPaywall()
    }

    @Test("A restore the user cancels shows nothing, is not counted as nothing found, and releases the hold")
    func cancelledRestoreIsNotNothingFound() async {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        fake.syncError = StoreKitError.userCancelled
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        entitlements.require(.keep) {}
        let key = "restore.nothingFound"
        let before = Usage.shared.current.counts[key] ?? 0

        let outcome = await entitlements.restore()
        #expect(outcome == .cancelled)
        #expect((Usage.shared.current.counts[key] ?? 0) == before)

        // The hold is released: a later unlock drops the cover.
        fake.appTransactionFacts = build17
        await entitlements.refresh()
        #expect(entitlements.paywallRequest == nil)
    }

    @Test("A restore that finds nothing leaves the locked paywall up and releases the hold")
    func restoreNothingFoundLeavesPaywall() async {
        defer { tearDown() }
        let fake = FakeStoreFactsSource()
        fake.appTransactionFacts = notLegacy
        let entitlements = Entitlements(source: fake)
        await entitlements.refresh()
        entitlements.require(.keep) {}

        let outcome = await entitlements.restore()
        #expect(outcome == .nothingFound)
        #expect(entitlements.paywallRequest == .keep)

        fake.appTransactionFacts = build17   // a later unlock must still drop the cover
        await entitlements.refresh()
        #expect(entitlements.paywallRequest == nil)
    }

    // MARK: - 8: host build sanity

    @Test("The host app's own build is not in the paid-builds list")
    func paidBuildsExcludesHostVersion() {
        defer { tearDown() }   // the suite init set `AccessOverride.shared.value = .real`; put it back
        let hostVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        #expect(hostVersion != nil)
        if let hostVersion {
            #expect(!StoreProducts.paidBuilds.contains(hostVersion))
        }
    }
}

// MARK: - FakeStoreFactsSource

/// A `StoreFactsSource` that delegates every real StoreKit call to a wrapped
/// `LiveStoreFactsSource` (so it talks to the active `SKTestSession`), but
/// returns an injectable `AppTransactionFacts?` and `canMakePayments`.
///
/// `Entitlements.refresh()` has a DEBUG-only shortcut that applies
/// `.debugUnlocked` whenever the app transaction's environment reads
/// `.xcode` or `.sandbox`, unless `AccessOverride.shared.value == .real`
/// — see `EntitlementsStoreKitTests.setUp()`, which forces that for every
/// test in this suite, so `appTransactionFacts` here is free to read
/// `.sandbox` and still exercise the real `AccessResolver` path.
private final class FakeStoreFactsSource: StoreFactsSource {
    private let live = LiveStoreFactsSource()

    var appTransactionFacts: AppTransactionFacts? = AppTransactionFacts(
        environment: .sandbox,
        originalAppVersion: "1",
        originalPurchaseDate: nil,
        isVerified: true
    )
    var canMakePaymentsOverride = true
    var productsOverride: (() async throws -> [Product])?

    var canMakePayments: Bool { canMakePaymentsOverride }

    /// What `sync()` throws, if set. The real `AppStore.sync()` waits for
    /// a sign-in that never comes under a hosted test, so it is never
    /// called here.
    var syncError: Error?
    /// Makes the next `sync()` wait for `releaseSync()`, like Apple's sheet.
    var holdSync = false
    private var heldSync: CheckedContinuation<Void, Never>?
    var isHoldingSync: Bool { heldSync != nil }
    func releaseSync() {
        heldSync?.resume()
        heldSync = nil
    }
    func sync() async throws {
        if holdSync {
            holdSync = false
            await withCheckedContinuation { heldSync = $0 }
        }
        if let syncError { throw syncError }
    }

    /// Simulates StoreKit's entitlement list lagging behind a purchase.
    var hideEntitlements = false
    /// Hides only these products from the entitlement list.
    var hiddenProductIDs: Set<String> = []
    /// Makes the next `appTransaction()` read its facts, then wait for
    /// `releaseHeld()`, so a test can run a newer refresh in between.
    var holdFirstAppTransaction = false
    private var heldContinuation: CheckedContinuation<Void, Never>?
    var isHolding: Bool { heldContinuation != nil }
    func releaseHeld() {
        heldContinuation?.resume()
        heldContinuation = nil
    }

    func appTransaction() async -> AppTransactionFacts? {
        let snapshot = appTransactionFacts
        if holdFirstAppTransaction {
            holdFirstAppTransaction = false
            await withCheckedContinuation { heldContinuation = $0 }
        }
        return snapshot
    }

    func currentEntitlements() async -> [EntitlementFact] {
        if hideEntitlements { return [] }
        return await live.currentEntitlements().filter { !hiddenProductIDs.contains($0.productID) }
    }

    func subscriptionStatuses(for product: Product) async -> [Product.SubscriptionInfo.Status] {
        await live.subscriptionStatuses(for: product)
    }

    func products() async throws -> [Product] {
        if let productsOverride { return try await productsOverride() }
        return try await live.products()
    }

    func isEligibleForIntroOffer(_ product: Product) async -> Bool {
        await live.isEligibleForIntroOffer(product)
    }
}
