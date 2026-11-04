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
    private let session: SKTestSession

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
    private func tearDown() {
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
        await entitlements.refresh()

        guard case let .monthly(_, isTrial, _, _) = entitlements.access else {
            Issue.record("Expected .monthly, got \(entitlements.access)")
            return
        }
        #expect(!isTrial)   // no introductory offer in Cloudfull.storekit
        #expect(entitlements.access.isUnlocked)
        #expect(entitlements.hasLiveSubscription)
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

    // MARK: - 7: grandfathering through the live refresh path

    @Test("A production app transaction for build 17 grandfathers with no purchase at all")
    func grandfatheredFromProductionBuild17() async {
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
        #expect(entitlements.access == .grandfathered)
    }

    @Test("A grandfathered customer stays grandfathered after the app transaction later comes back unverified")
    func grandfatheredStaysWhenAppTransactionLaterUnverified() async {
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
        #expect(entitlements.access == .grandfathered)

        fake.appTransactionFacts?.isVerified = false
        await entitlements.refresh()
        #expect(entitlements.access == .grandfathered)
    }

    // No test here for the purchase-date grandfather signal
    // (`originalPurchaseDate` before `freeSinceDate`): `Entitlements.refresh()`
    // calls `AccessResolver.resolve(...)` with no `freeSinceDate:` argument,
    // so it always uses the real default, `StoreProducts.freeSinceDate`.
    // That constant is `.distantPast` until release day, so no purchase
    // date can ever trigger this path through the live `Entitlements`
    // flow — it is only reachable by passing `freeSinceDate:` directly to
    // `AccessResolver.resolve(...)`, which `AccessResolverTests` covers
    // (`purchaseDateBeforeFreeSinceDateIsGrandfathered`). Not testable here
    // without adding an injection point to `Entitlements.swift`, which is
    // out of scope for this change.

    // MARK: - 8: host build sanity

    @Test("The host app's own build is not in the paid-builds list")
    func paidBuildsExcludesHostVersion() {
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

    func appTransaction() async -> AppTransactionFacts? { appTransactionFacts }

    func currentEntitlements() async -> [EntitlementFact] {
        await live.currentEntitlements()
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
