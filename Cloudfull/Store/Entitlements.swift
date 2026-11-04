//
//  Entitlements.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import StoreKit
import os

/// Everything `Entitlements` needs from StoreKit, behind one protocol so a
/// test can hand it fixtures instead of talking to the real store.
/// `LiveStoreFactsSource` below is the only production implementation.
protocol StoreFactsSource {
    func appTransaction() async -> AppTransactionFacts?
    func currentEntitlements() async -> [EntitlementFact]
    func subscriptionStatuses(for product: Product) async -> [Product.SubscriptionInfo.Status]
    func products() async throws -> [Product]
    var canMakePayments: Bool { get }
    func isEligibleForIntroOffer(_ product: Product) async -> Bool
}

/// Owns the one `Transaction.updates` listener for the whole app (unlock
/// products and tip products both finish here), resolves `Access` from
/// StoreKit facts through `AccessResolver`, and drives the paywall.
///
/// Published state publishes a cached, instantly-correct value at launch,
/// before the first `refresh()` completes — a cold, offline launch should
/// not flash a paywall it cannot yet back up with real facts.
@MainActor
final class Entitlements: ObservableObject {
    static let shared = Entitlements(source: LiveStoreFactsSource())

    /// Where a paywall was raised from. `Usage.paywallShown(_:)` takes
    /// this type directly, so its own event vocabulary never drifts from
    /// this one.
    enum PaywallSource: String, Identifiable {
        case keep, unkeep, delete, share, album, shrink, emptyBin, settings
        var id: String { rawValue }
    }

    enum PurchaseOutcome {
        case success
        /// A lifetime purchase succeeded while the monthly subscription is
        /// still set to auto-renew. The caller should offer to cancel it.
        case successCancelTrialPrompt
        case unverified
        case userCancelled
        case pending
        case failed
    }

    enum RestoreOutcome {
        case restored
        case nothingFound
        case failed
    }

    @Published private(set) var access: Access = .unknown
    /// The monthly product's own status, chosen from the array
    /// `product.subscription?.status` returns: the entry whose state is
    /// `.subscribed` or `.inGracePeriod`, else the first entry.
    @Published private(set) var subscriptionStatus: Product.SubscriptionInfo.Status?
    @Published private(set) var products: [Product] = []
    @Published private(set) var isEligibleForTrial = false
    @Published private(set) var canMakePayments: Bool
    @Published private(set) var isRestoring = false
    @Published private(set) var productsLoadFailed = false
    /// Set by `require(_:_:)` or `presentPaywall(from:)`; cleared by
    /// `dismissPaywall()`, or automatically once `access` becomes
    /// unlocked.
    @Published private(set) var paywallRequest: PaywallSource? {
        didSet { muteFeedWhilePaywallIsUp(wasUp: oldValue != nil, isUp: paywallRequest != nil) }
    }
    /// The feed's mute value from before the paywall rose, restored when
    /// it drops. `nil` while no paywall is up.
    private var mutedBeforePaywall: Bool?
    /// The video keeps playing under the cover, so the paywall mutes it
    /// (owner, 2026-11-04) and puts the user's own setting back after.
    /// `feed.isMuted` is the `@AppStorage` key every player page reads.
    private func muteFeedWhilePaywallIsUp(wasUp: Bool, isUp: Bool) {
        let defaults = UserDefaults.standard
        if isUp, !wasUp {
            mutedBeforePaywall = defaults.bool(forKey: "feed.isMuted")
            defaults.set(true, forKey: "feed.isMuted")
        } else if !isUp, wasUp, let before = mutedBeforePaywall {
            defaults.set(before, forKey: "feed.isMuted")
            mutedBeforePaywall = nil
        }
    }
    /// True for a verified, currently live subscription — subscribed, in
    /// its grace period, or in billing retry, or one still set to
    /// auto-renew. Independent of `access`: a trial that has not yet
    /// started its first charge still counts here through `willAutoRenew`.
    @Published private(set) var hasLiveSubscription = false

    private let source: StoreFactsSource
    private let now: () -> Date
    private let logger = Logger(subsystem: "com.cloudfull.app", category: "Entitlements")
    private var updatesTask: Task<Void, Never>?
    /// The app transaction facts from the most recent `refresh()`. Cached
    /// alongside `access`, and reused by `AccessResolver`'s
    /// never-downgrade rule when a later refresh comes back thin.
    private var lastAppTx: AppTransactionFacts?
    private var loggedInstallFacts = false
    /// True between a lifetime purchase that still has a monthly plan
    /// auto-renewing and the user's answer to the cancel-your-trial
    /// prompt. While true, the unlock does not drop the paywall cover.
    private var holdsPaywallForPrompt = false
    /// The paywall source at the moment the purchase sheet opened, for
    /// `purchase.<kind>.from.<source>` on success.
    private var purchaseSource: PaywallSource?
    /// For the `subscription.ageDays` fact.
    private var monthlyOriginalPurchaseDate: Date?
    /// For the `subscription.autoRenew` fact: Apple's own renewal flag,
    /// or `nil` when it could not be read (offline, products not loaded),
    /// so a canceller is never reported as "will renew" by assumption.
    private var monthlyWillAutoRenew: Bool?

    /// Also erased by `-cloudfull-reset-deck-state` (`CloudfullApp.init`).
    static let cacheKey = "store.access.v1"

    /// Designated initializer, for tests to inject a fake `source`. Use
    /// `Entitlements.shared` everywhere else.
    init(source: StoreFactsSource, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.now = now
        canMakePayments = source.canMakePayments
        if let cached = Self.loadCache() {
            access = cached.access
            lastAppTx = cached.appTx
        }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { [weak self] in
            await self?.finishUnfinished()
            await self?.refresh()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Cache

    private struct CachedState: Codable {
        var access: Access
        var appTx: AppTransactionFacts?
    }

    private static func loadCache() -> CachedState? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedState.self, from: data)
    }

    private func saveCache() {
        let state = CachedState(access: access, appTx: lastAppTx)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    // MARK: - Refresh

    /// Re-derives `access` from the facts StoreKit has right now, then
    /// reloads `products` and the subscription-derived state if needed.
    /// Safe to call from anywhere, any number of times; it never shows a
    /// sign-in sheet. Only `restore()`, a user action, calls
    /// `AppTransaction.refresh()`, which can.
    func refresh() async {
        guard StoreProducts.isOfficialBuild else {
            // A fork never shows the paywall and never talks to the store.
            apply(.fork, cache: false)
            return
        }
        #if DEBUG
        // `real` runs the resolver below against the real StoreKit facts,
        // also in Xcode's StoreKit environment. `auto` (the default) and a
        // fixed value take the early returns here.
        var runRealResolverInXcode = false
        if StoreProducts.isOfficialBuild {
            let token = Self.launchArgumentToken() ?? AccessOverride.shared.value.rawValue
            if token == "real" {
                runRealResolverInXcode = true
            } else if let overridden = Self.debugAccess(for: token, now: now()) {
                apply(overridden, cache: false)
                await loadProductsIfNeeded()
                await refreshSubscriptionDerivedState()
                return
            }
        }
        #endif

        // Loaded before resolution, not after: a monthly entitlement's
        // grace-period details only come from the loaded product's own
        // subscription status (`enriched(_:)` below), and the resolver
        // needs them to tell a live grace period from a lapsed one.
        await loadProductsIfNeeded()

        // `AppTransaction.shared` never shows a sign-in sheet. An
        // unverified result resolves as the rules say (a cached
        // grandfathered customer is never downgraded); Restore Purchases
        // is the one place that asks Apple again, with a sign-in if needed.
        let appTx = await source.appTransaction()
        logInstallFactsIfNeeded(appTx)

        #if DEBUG
        // `auto` unlocks a Debug build in Xcode's StoreKit environment and
        // in the sandbox (a Debug build installed on a phone with
        // devicectl reports `.sandbox`). Pick "Real" in Settings › Debug
        // to run the real resolver against sandbox purchases.
        if StoreProducts.isOfficialBuild, !runRealResolverInXcode,
           appTx?.environment == .xcode || appTx?.environment == .sandbox {
            lastAppTx = appTx
            apply(.debugUnlocked, cache: false)
            await refreshSubscriptionDerivedState()
            return
        }
        #endif

        let entitlements = await enriched(source.currentEntitlements())
        let monthlyFact = entitlements.first { $0.productID == StoreProducts.monthly }
        monthlyOriginalPurchaseDate = monthlyFact?.originalPurchaseDate
        monthlyWillAutoRenew = monthlyFact?.willAutoRenew
        let resolved = AccessResolver.resolve(
            isOfficial: StoreProducts.isOfficialBuild,
            appTx: appTx,
            entitlements: entitlements,
            cached: access,
            now: now()
        )
        lastAppTx = appTx
        apply(resolved)

        await refreshSubscriptionDerivedState()
        // The facts below can change without the access kind changing
        // (a cancel in iOS Settings, a day passing), and a cold launch
        // records the session before this first refresh is done. So they
        // are re-recorded after every refresh; `set` is idempotent.
        Usage.shared.accessState(access.analyticsKind, trialDaysLeft: trialDaysLeft, subscriptionAgeDays: subscriptionAgeDays, autoRenew: autoRenew)
    }

    /// `cache: false` for a DEBUG override or `.debugUnlocked`: a fixed
    /// test value must not survive into the next launch as the "cached
    /// state from the store", where the never-downgrade rule could keep
    /// it.
    private func apply(_ newAccess: Access, cache: Bool = true) {
        let changedKind = access.analyticsKind != newAccess.analyticsKind
        if access != newAccess { access = newAccess }   // `@Published` fires on every assignment; skip the no-ops
        // The hold keeps the cover up for the cancel-your-trial prompt
        // after a lifetime purchase; `clearPaywall()` ends it.
        if newAccess.isUnlocked, !holdsPaywallForPrompt { paywallRequest = nil }
        if changedKind {
            Usage.shared.accessState(newAccess.analyticsKind, trialDaysLeft: trialDaysLeft, subscriptionAgeDays: subscriptionAgeDays, autoRenew: autoRenew)
        }
        if cache { saveCache() }
    }

    private func loadProductsIfNeeded() async {
        guard products.isEmpty else { return }
        do {
            let loaded = try await source.products()
            if loaded.isEmpty {
                logger.error("Product.products(for:) returned no unlock products")
                productsLoadFailed = true
            } else {
                products = loaded
                productsLoadFailed = false
            }
        } catch {
            logger.error("Failed to load unlock products: \(error.localizedDescription, privacy: .public)")
            productsLoadFailed = true
        }
    }

    private func refreshSubscriptionDerivedState() async {
        guard let monthlyProduct = products.first(where: { $0.id == StoreProducts.monthly }) else {
            subscriptionStatus = nil
            hasLiveSubscription = false
            isEligibleForTrial = false
            return
        }
        let statuses = await source.subscriptionStatuses(for: monthlyProduct)
        subscriptionStatus = statuses.first { $0.state == .subscribed || $0.state == .inGracePeriod } ?? statuses.first
        let liveNow = statuses.contains { status in
            if status.state == .subscribed || status.state == .inGracePeriod || status.state == .inBillingRetryPeriod {
                return true
            }
            guard case .verified(let renewalInfo) = status.renewalInfo else { return false }
            return renewalInfo.willAutoRenew
        }
        if hasLiveSubscription != liveNow { hasLiveSubscription = liveNow }
        let eligibleNow = await source.isEligibleForIntroOffer(monthlyProduct)
        if isEligibleForTrial != eligibleNow { isEligibleForTrial = eligibleNow }
    }

    /// Fills in a monthly `EntitlementFact`'s renewal state, grace-period
    /// expiry, and auto-renew flag from the loaded monthly product's own
    /// subscription status — the only place that status is available.
    /// `Transaction.currentEntitlements` alone cannot say whether a
    /// subscription is mid-grace-period; only `Product.SubscriptionInfo.Status`
    /// can.
    private func enriched(_ facts: [EntitlementFact]) async -> [EntitlementFact] {
        guard let monthlyProduct = products.first(where: { $0.id == StoreProducts.monthly }) else { return facts }
        guard facts.contains(where: { $0.productID == StoreProducts.monthly }) else { return facts }
        let statuses = await source.subscriptionStatuses(for: monthlyProduct)
        guard let status = statuses.first(where: { $0.state == .subscribed || $0.state == .inGracePeriod }) ?? statuses.first else { return facts }
        return facts.map { fact in
            guard fact.productID == StoreProducts.monthly else { return fact }
            var enrichedFact = fact
            enrichedFact.renewalState = Self.map(status.state)
            if case .verified(let renewalInfo) = status.renewalInfo {
                enrichedFact.willAutoRenew = renewalInfo.willAutoRenew
                enrichedFact.gracePeriodExpiresAt = renewalInfo.gracePeriodExpirationDate
            }
            return enrichedFact
        }
    }

    /// `Product.SubscriptionInfo.RenewalState` is a `RawRepresentable`
    /// struct of static members, not a Swift enum, so this switch takes a
    /// plain `default`, not `@unknown default`.
    private static func map(_ state: Product.SubscriptionInfo.RenewalState) -> RenewalState {
        switch state {
        case .subscribed: return .subscribed
        case .expired: return .expired
        case .inBillingRetryPeriod: return .inBillingRetryPeriod
        case .inGracePeriod: return .inGracePeriod
        case .revoked: return .revoked
        default: return .expired
        }
    }

    /// Logs the raw `originalAppVersion` and environment once per process,
    /// for the TestFlight grandfathering check.
    private func logInstallFactsIfNeeded(_ appTx: AppTransactionFacts?) {
        guard !loggedInstallFacts else { return }
        loggedInstallFacts = true
        logger.log("appTransaction originalAppVersion=\(appTx?.originalAppVersion ?? "nil", privacy: .public) environment=\(appTx?.environment.rawValue ?? "nil", privacy: .public) verified=\(appTx?.isVerified ?? false, privacy: .public)")
    }

    // MARK: - Paywall

    /// Runs `action` when unlocked; otherwise records the source and
    /// raises the paywall.
    func require(_ source: PaywallSource, _ action: () -> Void) {
        if access.isUnlocked {
            action()
            return
        }
        Usage.shared.paywallShown(source)
        paywallRequest = source
    }

    func dismissPaywall() {
        holdsPaywallForPrompt = false
        paywallRequest = nil
        Usage.shared.paywallDismissed()
    }

    /// Drops the cover without counting a user dismissal: after the
    /// cancel-your-trial prompt is answered, or when the screen under
    /// the cover goes away (photo access lost).
    func clearPaywall() {
        holdsPaywallForPrompt = false
        paywallRequest = nil
    }

    /// The Settings entry point: raises the paywall with no unlocked
    /// check, since Settings shows it on request even to an already
    /// unlocked user (to manage or upgrade).
    func presentPaywall(from source: PaywallSource) {
        Usage.shared.paywallShown(source)
        paywallRequest = source
    }

    // MARK: - Transaction.updates

    /// The single `Transaction.updates` listener for the whole app.
    /// Finishes every unlock and tip transaction StoreKit hands the app
    /// outside a direct purchase call, for example a revocation, a Family
    /// Sharing grant, or one an interrupted launch left unfinished.
    func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            logger.error("Ignored an unverified transaction update")
            return
        }
        if StoreProducts.unlockIDs.contains(transaction.productID) {
            if transaction.offer?.type == .code {
                Usage.shared.purchaseViaOfferCode()
            }
            // A purchase that never went through `handlePurchase` in this
            // process: an Ask to Buy approval, a purchase on another
            // device, an offer code, or one a force-quit cut short. A
            // renewal is not a purchase. (`product.purchase()` results are
            // not delivered here, so this never double counts.)
            if transaction.reason == .purchase, let kind = Usage.purchaseProduct(for: transaction.productID) {
                Usage.shared.purchase(kind, .success)
            }
            await transaction.finish()
            await refresh()
        } else if TipJar.productIDs.contains(transaction.productID) {
            await transaction.finish()
        }
    }

    /// Finishes any already-verified unlock or tip transaction left
    /// unfinished by an interrupted launch, before the first `refresh()`
    /// resolves access. StoreKit keeps handing an unfinished transaction
    /// back on every launch until it is finished.
    private func finishUnfinished() async {
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result else { continue }
            guard StoreProducts.unlockIDs.contains(transaction.productID) || TipJar.productIDs.contains(transaction.productID) else { continue }
            await transaction.finish()
        }
    }

    // MARK: - Purchase

    /// Called from `.onInAppPurchaseStart`, before Apple's purchase sheet
    /// appears. A lifetime purchase while a monthly plan is live sets the
    /// hold now, not after the purchase: the sheet makes the scene
    /// inactive, and the `.active` refresh that follows it could unlock
    /// access and drop the paywall cover before `handlePurchase` runs.
    func purchaseStarted(_ product: Product) {
        guard let kind = Usage.purchaseProduct(for: product.id) else { return }
        purchaseSource = paywallRequest
        Usage.shared.purchase(kind, .started)
        holdsPaywallForPrompt = kind == .lifetime && hasLiveSubscription
    }

    /// Processes the outcome of a `product.purchase()` call the caller
    /// already made. `product` must be one of `StoreProducts.unlockIDs`.
    /// Every path that does not end in the cancel-your-trial prompt
    /// releases the hold `purchaseStarted` may have set.
    func handlePurchase(_ product: Product, _ result: Result<Product.PurchaseResult, Error>) async -> PurchaseOutcome {
        guard let kind = Usage.purchaseProduct(for: product.id) else {
            logger.error("handlePurchase called for a non-unlock product: \(product.id, privacy: .public)")
            return .failed
        }
        // `.started` is counted by `PaywallView`'s own
        // `.onInAppPurchaseStart`, before this method is ever called, so
        // it is not bumped again here.
        switch result {
        case .failure(let error):
            logger.error("Purchase of \(product.id, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
            Usage.shared.purchase(kind, .failed)
            holdsPaywallForPrompt = false
            return .failed
        case .success(let purchaseResult):
            switch purchaseResult {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    Usage.shared.purchase(kind, .unverified)
                    holdsPaywallForPrompt = false
                    return .unverified
                }
                await transaction.finish()
                #if DEBUG
                // A fixed override (None, Trial, …) would hide the real
                // result of the purchase that just succeeded. Flip to
                // Real so the phone shows what Apple now says.
                // Not under `-cloudfull-access=`: the launch argument wins
                // over the stored override anyway, so a flip would change
                // nothing now and only surprise the next launch.
                if Self.launchArgumentToken() == nil,
                   AccessOverride.shared.value != .auto, AccessOverride.shared.value != .real {
                    AccessOverride.shared.value = .real
                }
                #endif
                // Checked before `refresh()`: the refresh unlocks access,
                // and the unlock drops the paywall cover unless the hold
                // is already set.
                var promptToCancelMonthly = false
                if kind == .lifetime {
                    promptToCancelMonthly = await hasAutoRenewingMonthlySubscription()
                }
                holdsPaywallForPrompt = promptToCancelMonthly
                await refresh()
                Usage.shared.purchase(kind, .success, from: purchaseSource)
                if promptToCancelMonthly {
                    return .successCancelTrialPrompt
                }
                if access.isUnlocked { paywallRequest = nil }   // the hold set at start may have kept it up
                return .success
            case .userCancelled:
                Usage.shared.purchase(kind, .cancelled)
                holdsPaywallForPrompt = false
                return .userCancelled
            case .pending:
                Usage.shared.purchase(kind, .pending)
                holdsPaywallForPrompt = false
                return .pending
            @unknown default:
                Usage.shared.purchase(kind, .failed)
                holdsPaywallForPrompt = false
                return .failed
            }
        }
    }

    /// After a lifetime purchase, checks whether the monthly subscription
    /// (bought earlier, independent of this purchase) is still set to
    /// renew, so the caller can prompt to cancel it.
    private func hasAutoRenewingMonthlySubscription() async -> Bool {
        guard let monthlyProduct = products.first(where: { $0.id == StoreProducts.monthly }) else { return false }
        let statuses = await source.subscriptionStatuses(for: monthlyProduct)
        return statuses.contains { status in
            guard case .verified(let renewalInfo) = status.renewalInfo else { return false }
            return renewalInfo.willAutoRenew
        }
    }

    // MARK: - Restore

    @discardableResult
    func restore() async -> RestoreOutcome {
        Usage.shared.restore(.tapped)
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            Usage.shared.restore(.nothingFound)
            return .nothingFound
        } catch {
            logger.error("AppStore.sync() failed: \(error.localizedDescription, privacy: .public)")
            Usage.shared.restore(.failed)
            return .failed
        }
        if lastAppTx == nil || lastAppTx?.isVerified == false {
            // The one call that may show an App Store sign-in sheet; it
            // runs only here, on the user's own Restore tap.
            _ = try? await AppTransaction.refresh()
        }
        await refresh()
        let outcome: RestoreOutcome
        switch access {
        case .lifetime, .monthly, .grandfathered:
            outcome = .restored
        default:
            outcome = .nothingFound
        }
        Usage.shared.restore(outcome == .restored ? .restored : .nothingFound)
        return outcome
    }

    // MARK: - Subscription management

    func manageSubscriptionsOpened() {
        Usage.shared.manageSubscriptionOpened()
    }

    /// Read from the loaded monthly product, not hard-coded. See the
    /// comment on `StoreProducts`.
    var subscriptionGroupID: String? {
        products.first { $0.id == StoreProducts.monthly }?.subscription?.subscriptionGroupID
    }

    /// Days since the monthly plan was first bought, or `nil` without one.
    var subscriptionAgeDays: Int? {
        guard case .monthly = access, let start = monthlyOriginalPurchaseDate else { return nil }
        return max(Calendar.current.dateComponents([.day], from: start, to: now()).day ?? 0, 0)
    }

    /// Whether the monthly plan will renew, or `nil` without one.
    var autoRenew: Bool? {
        guard case .monthly = access else { return nil }
        return monthlyWillAutoRenew
    }

    /// Days left in a free trial, or `nil` when `access` is not an active
    /// trial.
    var trialDaysLeft: Int? {
        guard case .monthly(let expiresAt, let isTrial, _, _) = access, isTrial, let expiresAt else { return nil }
        let days = Calendar.current.dateComponents([.day], from: now(), to: expiresAt).day ?? 0
        return max(days, 0)
    }

    // MARK: - DEBUG overrides

    #if DEBUG
    /// The token after `-cloudfull-access=`, when the launch argument is
    /// present. Applies to this launch only; never persisted.
    private static func launchArgumentToken() -> String? {
        guard let raw = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(CloudfullApp.accessArgument) }) else { return nil }
        return String(raw.dropFirst(CloudfullApp.accessArgument.count))
    }

    private static func debugAccess(for token: String, now: Date) -> Access? {
        switch token {
        case "auto", "real": return nil
        case "unknown": return .unknown
        case "none": return .locked
        case "trial": return .monthly(expiresAt: now.addingTimeInterval(7 * 86_400), isTrial: true, willAutoRenew: true, inGracePeriod: false)
        case "monthly": return .monthly(expiresAt: now.addingTimeInterval(30 * 86_400), isTrial: false, willAutoRenew: true, inGracePeriod: false)
        case "lifetime": return .lifetime
        case "grandfathered": return .grandfathered
        default: return nil
        }
    }
    #endif
}

// MARK: - LiveStoreFactsSource

/// The production `StoreFactsSource`: every method is a thin wrapper
/// around the real StoreKit 2 API, with no caching and no fallback logic
/// of its own. `Entitlements` owns all of that.
struct LiveStoreFactsSource: StoreFactsSource {
    var canMakePayments: Bool { AppStore.canMakePayments }

    /// `AppTransaction.shared` never shows a sign-in sheet; only
    /// `AppTransaction.refresh()` can.
    func appTransaction() async -> AppTransactionFacts? {
        guard let result = try? await AppTransaction.shared else { return nil }
        switch result {
        case .verified(let transaction):
            return AppTransactionFacts(
                environment: Self.map(transaction.environment),
                originalAppVersion: transaction.originalAppVersion,
                originalPurchaseDate: transaction.originalPurchaseDate,
                isVerified: true
            )
        case .unverified(let transaction, _):
            return AppTransactionFacts(
                environment: Self.map(transaction.environment),
                originalAppVersion: transaction.originalAppVersion,
                originalPurchaseDate: transaction.originalPurchaseDate,
                isVerified: false
            )
        }
    }

    /// Only `.verified` results count. Filtered to the two unlock product
    /// ids, so a tip's own (consumable, no-entitlement) transaction never
    /// reaches here.
    ///
    /// This leaves `renewalState`, `gracePeriodExpiresAt`, and
    /// `willAutoRenew` at their default `nil`. A bare `Transaction` has no
    /// renewal-state API of its own; only `Product.SubscriptionInfo.Status`
    /// does, and that needs a loaded `Product`. `Entitlements.enriched(_:)`
    /// fills those three fields in once products are loaded.
    func currentEntitlements() async -> [EntitlementFact] {
        var facts: [EntitlementFact] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard StoreProducts.unlockIDs.contains(transaction.productID) else { continue }
            facts.append(EntitlementFact(
                productID: transaction.productID,
                expirationDate: transaction.expirationDate,
                revocationDate: transaction.revocationDate,
                isIntroOffer: transaction.offer?.type == .introductory,
                renewalState: nil,
                gracePeriodExpiresAt: nil,
                willAutoRenew: nil,
                originalPurchaseDate: transaction.originalPurchaseDate
            ))
        }
        return facts
    }

    func subscriptionStatuses(for product: Product) async -> [Product.SubscriptionInfo.Status] {
        guard let subscriptionInfo = product.subscription else { return [] }
        return (try? await subscriptionInfo.status) ?? []
    }

    func products() async throws -> [Product] {
        try await Product.products(for: StoreProducts.unlockIDs)
    }

    func isEligibleForIntroOffer(_ product: Product) async -> Bool {
        guard let subscriptionInfo = product.subscription else { return false }
        return await subscriptionInfo.isEligibleForIntroOffer
    }

    private static func map(_ environment: AppStore.Environment) -> StoreEnvironment {
        switch environment {
        case .production: return .production
        case .sandbox: return .sandbox
        case .xcode: return .xcode
        default: return .other
        }
    }
}
