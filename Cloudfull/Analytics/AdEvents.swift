//
//  AdEvents.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import StoreKit
import UIKit
// The three ad SDKs are imported here and nowhere else in the app.
import FacebookCore
import FirebaseCore
import FirebaseAnalytics
import TikTokBusinessSDK

// This file answers one question: who paid for the app after an ad brought
// them. Each network learns the first purchase only (counts, not people).
//
// Rules this file keeps (design/ADS_PLAN.md, design/ADS_CONTRACT.md):
// - A sink starts only when the gate allows it AND its own keys are present.
// - Every vendor's automatic purchase logging is off. The app logs purchases.
// - No IDFA, no AdSupport import, no App Tracking Transparency call.
// - No transaction id goes to a network. One exception is forced by Google's
//   API: `Analytics.logTransaction` takes the StoreKit `Transaction`
//   (contract section 7, item 1).

// MARK: - Keys

/// What the build carries. A value that is empty or still starts with "$("
/// counts as absent (an unset xcconfig variable stays a literal `$(NAME)`).
struct AdKeys: Equatable, Sendable {
    var metaAppID: String?          // Info.plist "FacebookAppID"
    var metaClientToken: String?    // Info.plist "FacebookClientToken"
    var tiktokAppID: String?        // Info.plist "CloudfullTikTokAppID"
    var tiktokAccessToken: String?  // Info.plist "CloudfullTikTokAccessToken"
    /// `GoogleService-Info.plist` is in the bundle AND its BUNDLE_ID is "com.cloudfull.app".
    var hasFirebaseConfig: Bool
    /// Info.plist "CloudfullTikTokAppleAppID": the App Store id. `TikTokConfig` needs it as
    /// `appId` next to `tiktokAppId` (see ADS_NOTES_C.md, difference 1).
    var tiktokAppleAppID: String? = nil

    var hasMeta: Bool { metaAppID != nil && metaClientToken != nil }
    var hasTikTok: Bool { tiktokAppID != nil && tiktokAccessToken != nil && tiktokAppleAppID != nil }
    var hasAny: Bool { hasMeta || hasTikTok || hasFirebaseConfig }

    static func from(_ bundle: Bundle) -> AdKeys {
        func value(_ key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("$(") { return nil }
            return trimmed
        }
        return AdKeys(
            metaAppID: value("FacebookAppID"),
            metaClientToken: value("FacebookClientToken"),
            tiktokAppID: value("CloudfullTikTokAppID"),
            tiktokAccessToken: value("CloudfullTikTokAccessToken"),
            hasFirebaseConfig: firebaseConfigIsValid(in: bundle),
            tiktokAppleAppID: value("CloudfullTikTokAppleAppID")
        )
    }

    /// `FirebaseApp.configure()` raises an exception (a crash) with no plist, and Swift cannot
    /// catch it. So the file must exist, parse, and carry this app's bundle id.
    static func firebaseConfigIsValid(in bundle: Bundle) -> Bool {
        guard let path = bundle.path(forResource: "GoogleService-Info", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path)
        else { return false }
        return firebaseConfigIsValid(plist)
    }

    /// `FIRApp.m` also raises "Configuration fails" when the Google app id is malformed, so the
    /// four values `configureCore` reads must be present too (design/ADS_REPAIR.md, H-H5).
    static func firebaseConfigIsValid(_ plist: NSDictionary) -> Bool {
        guard (plist["BUNDLE_ID"] as? String) == "com.cloudfull.app" else { return false }
        for key in ["GOOGLE_APP_ID", "API_KEY", "GCM_SENDER_ID", "PROJECT_ID"] {
            guard let value = plist[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        return true
    }
}

// MARK: - Gate

struct AdGateInput: Equatable, Sendable {
    var isReleaseBuild: Bool        // #if DEBUG false #else true
    var isOfficialBuild: Bool       // StoreProducts.isOfficialBuild
    var isSimulator: Bool           // #if targetEnvironment(simulator)
    var isRunningTests: Bool        // ProcessInfo env "XCTestConfigurationFilePath" != nil
    var debugOverride: Bool         // AdEvents.debugOverrideRequested (always false in Release)
    var hasAnyKeys: Bool            // AdKeys.hasAny
    var appTransaction: AppTransactionFacts?   // from LiveStoreFactsSource().appTransaction()
    var region: AdConsentRegion
    var consent: AdConsentAnswer
}

struct AdGateResult: Equatable, Sendable {
    /// The three ad SDKs may start (each sink still needs its own keys).
    var sdksMayStart: Bool
    /// Apple Ads attribution may run. Needs production conditions only.
    var appleAdsMayRun: Bool
}

enum AdGate {
    /// The part of `production` that needs no StoreKit and no storefront. The launch task stops
    /// here in the test host, the simulator, a fork, and Debug without the argument, so those
    /// never call `AppTransaction` or the storefront.
    static func passesStaticChecks(_ input: AdGateInput) -> Bool {
        (input.isReleaseBuild || input.debugOverride)
            && input.isOfficialBuild
            && !input.isSimulator
            && !input.isRunningTests
    }

    /// Pure.
    /// production = (isReleaseBuild || debugOverride) && isOfficialBuild && !isSimulator
    ///   && !isRunningTests && (debugOverride || (appTransaction verified && environment == .production))
    /// consentOK = region == .notRequired || (region == .required && consent == .yes)
    /// An unknown region fails closed: no SDKs.
    static func evaluate(_ input: AdGateInput) -> AdGateResult {
        let production = passesStaticChecks(input)
            && (input.debugOverride
                || (input.appTransaction?.isVerified == true && input.appTransaction?.environment == .production))
        let consentOK = input.region == .notRequired
            || (input.region == .required && input.consent == .yes)
        return AdGateResult(
            sdksMayStart: production && input.hasAnyKeys && consentOK,
            appleAdsMayRun: production
        )
    }

    /// Pure. The consent choice (the Settings row, and the card for a user who has not answered)
    /// exists wherever a yes would start an SDK. It stays whatever the stored answer is, so a
    /// user can withdraw a yes or change a no after a relaunch (GDPR Art. 7(3)).
    static func shouldOfferChoice(_ input: AdGateInput) -> Bool {
        let production = passesStaticChecks(input)
            && (input.debugOverride
                || (input.appTransaction?.isVerified == true && input.appTransaction?.environment == .production))
        return production && input.hasAnyKeys && input.region == .required
    }

    /// Pure. The one-time card is worth showing only when nothing is answered yet.
    static func shouldAsk(_ input: AdGateInput) -> Bool {
        shouldOfferChoice(input) && input.consent == .notAsked
    }
}

// MARK: - Sink protocol and events

/// One ad network. Main actor: every SDK here wants the main thread for setup.
@MainActor
protocol AdSink: AnyObject {
    /// Idempotent; may be called again after `stop()`. The Firebase sink calls
    /// `Analytics.setConsent` (all four types granted) here, before its first event.
    func start(keys: AdKeys)
    /// Stops new events. Firebase sink: `Analytics.setConsent` all denied. No SDK is unloaded.
    func stop()
    func send(_ event: AdEvent)
}

/// What a sink receives. Never a transaction id, except inside the StoreKit
/// `Transaction` that the Firebase sink hands to `Analytics.logTransaction`.
enum AdEvent: Equatable, Sendable {
    case paywallShown
    case checkoutStarted(AdPurchase)
    case subscribed(AdPurchase)          // monthly
    case lifetimePurchased(AdPurchase)   // lifetime
}

struct AdPurchase: Equatable, Sendable {
    var kind: Usage.PurchaseProduct
    var price: Decimal?
    var currencyCode: String?            // ISO 4217, e.g. "EUR"
    /// Only for `Analytics.logTransaction`. nil in tests and for `checkoutStarted`.
    var storeKitTransaction: Transaction?

    static func == (a: AdPurchase, b: AdPurchase) -> Bool {
        a.kind == b.kind && a.price == b.price && a.currencyCode == b.currencyCode
    }
}

/// Plain facts about one verified unlock transaction, so the send rule is testable.
struct AdPurchaseFact: Equatable, Sendable {
    var kind: Usage.PurchaseProduct
    var transactionID: UInt64
    var purchaseDate: Date
    var price: Decimal?
    var currencyCode: String?
    var isPurchaseReason: Bool           // transaction.reason == .purchase
    var isRevoked: Bool                  // transaction.revocationDate != nil
    var isFamilyShared: Bool             // transaction.ownershipType == .familyShared
    var isUpgraded: Bool                 // transaction.isUpgraded
    /// True when this install made the purchase: it came through `handlePurchase`, or its
    /// `appAccountToken` is this install's token. Another device of the same buyer has another
    /// token, so one sale never counts twice.
    var isFromThisInstall: Bool
    var storeKitTransaction: Transaction?

    /// `localPurchase`: the call comes from `handlePurchase`, where this process ran the purchase.
    init<T: AdTransactionFacts>(_ transaction: T, kind: Usage.PurchaseProduct, localPurchase: Bool = false,
                                installToken: UUID? = nil) {
        self.kind = kind
        self.transactionID = transaction.id
        self.purchaseDate = transaction.purchaseDate
        self.price = transaction.price
        self.currencyCode = transaction.currencyIdentifier
        self.isPurchaseReason = transaction.reason == .purchase
        self.isRevoked = transaction.revocationDate != nil
        self.isFamilyShared = transaction.ownershipType == .familyShared
        self.isUpgraded = transaction.isUpgraded
        self.isFromThisInstall = localPurchase
            || (installToken != nil && transaction.appAccountToken == installToken)
        self.storeKitTransaction = transaction.storeKitTransaction
    }

    init(kind: Usage.PurchaseProduct, transactionID: UInt64, purchaseDate: Date, price: Decimal?, currencyCode: String?,
         isPurchaseReason: Bool = true, isRevoked: Bool = false, isFamilyShared: Bool = false, isUpgraded: Bool = false,
         isFromThisInstall: Bool = true) {
        self.kind = kind
        self.transactionID = transactionID
        self.purchaseDate = purchaseDate
        self.price = price
        self.currencyCode = currencyCode
        self.isPurchaseReason = isPurchaseReason
        self.isRevoked = isRevoked
        self.isFamilyShared = isFamilyShared
        self.isUpgraded = isUpgraded
        self.isFromThisInstall = isFromThisInstall
        self.storeKitTransaction = nil
    }

    static func == (a: AdPurchaseFact, b: AdPurchaseFact) -> Bool {
        a.kind == b.kind && a.transactionID == b.transactionID && a.purchaseDate == b.purchaseDate
            && a.price == b.price && a.currencyCode == b.currencyCode
            && a.isPurchaseReason == b.isPurchaseReason && a.isRevoked == b.isRevoked
            && a.isFamilyShared == b.isFamilyShared && a.isUpgraded == b.isUpgraded
            && a.isFromThisInstall == b.isFromThisInstall
    }
}

/// The StoreKit `Transaction` fields the send rule reads. A test supplies a plain stand-in,
/// because a `Transaction` cannot be built outside StoreKit.
protocol AdTransactionFacts {
    var id: UInt64 { get }
    var purchaseDate: Date { get }
    var price: Decimal? { get }
    var currencyIdentifier: String? { get }
    var reason: Transaction.Reason { get }
    var revocationDate: Date? { get }
    var ownershipType: Transaction.OwnershipType { get }
    var isUpgraded: Bool { get }
    var appAccountToken: UUID? { get }
    var storeKitTransaction: Transaction? { get }
}

extension Transaction: AdTransactionFacts {
    var currencyIdentifier: String? { currency?.identifier }
    var storeKitTransaction: Transaction? { self }
}

// MARK: - Facade

@MainActor
final class AdEvents {
    static let shared = AdEvents(defaults: .standard, now: Date.init, makeSinks: AdEvents.liveSinks)

    /// UserDefaults [String] of decimal transaction ids already sent. Newest last.
    static let sentTransactionIDsKey = "ads.sentTransactionIDs"
    static let sentTransactionIDsCap = 64
    /// A purchase older than this is a restore or a replay, not a sale.
    static let freshness: TimeInterval = 24 * 60 * 60
    #if DEBUG
    /// Debug builds only. Waives "Release" and the AppTransaction check so a phone build can be
    /// tested with real keys. It never waives the official bundle id, the simulator, XCTest,
    /// keys or consent. Compiled out of Release.
    static let debugArgument = "-cloudfull-ads-debug"
    #endif
    static var debugOverrideRequested: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(debugArgument)
        #else
        return false
        #endif
    }

    /// UserDefaults String: this install's `appAccountToken` (a UUID). The paywall passes it to
    /// every purchase. It goes to Apple only, never to an ad network.
    static let installTokenKey = "ads.installAccountToken"
    /// Purchases that arrive before the launch decision are held in memory this long at most.
    static let pendingCap = 8

    /// The token for this install. Made on first use and kept.
    static func installAccountToken(defaults: UserDefaults = .standard) -> UUID {
        if let raw = defaults.string(forKey: installTokenKey), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: installTokenKey)
        return id
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private var pendingFacts: [AdPurchaseFact] = []
    private var launchDecided = false
    private let makeSinks: @MainActor (AdKeys) -> [any AdSink]
    private var sinks: [any AdSink] = []
    private var sinksMade = false
    private var launchTask: Task<Void, Never>?
    private var lastInput: AdGateInput?
    private var lastKeys: AdKeys?

    init(defaults: UserDefaults, now: @escaping () -> Date, makeSinks: @escaping @MainActor (AdKeys) -> [any AdSink]) {
        self.defaults = defaults
        self.now = now
        self.makeSinks = makeSinks
    }

    /// True between a start and a stop. Every send and every defaults write needs it.
    private(set) var isSending = false

    // MARK: Launch

    /// The ONE line in didFinishLaunching. Starts the launch task once. Returns at once.
    func scheduleLaunch() {
        guard launchTask == nil else { return }
        launchTask = Task { @MainActor [weak self] in
            await self?.runLaunch()
        }
    }

    private func runLaunch() async {
        // 1. After the first frame. Nothing here delays the launch.
        if UIApplication.shared.applicationState != .active {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                break
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }

        // 2. Static checks. The test host, the simulator, forks and plain Debug stop here.
        let keys = AdKeys.from(.main)
        var input = AdGateInput(
            isReleaseBuild: Self.isReleaseBuild,
            isOfficialBuild: StoreProducts.isOfficialBuild,
            isSimulator: Self.isSimulator,
            isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            debugOverride: Self.debugOverrideRequested,
            hasAnyKeys: keys.hasAny,
            appTransaction: nil,
            region: .unknown,
            consent: .notAsked
        )
        guard AdGate.passesStaticChecks(input) else { return }

        // 3. AppTransaction. Async. It never shows a sign-in sheet.
        input.appTransaction = await LiveStoreFactsSource().appTransaction()

        // 4. Apple Ads. Nothing leaves to another company, so it needs no consent.
        if AdGate.evaluate(input).appleAdsMayRun {
            Task { await AppleAdsAttribution.shared.runIfNeeded() }
        }

        // 5. Consent state.
        input.region = await AdConsentStore.shared.loadRegion()
        input.consent = AdConsentStore.shared.answer
        recordLaunch(input, keys: keys)

        // 6. Offer the choice only where a yes would start an SDK. The card itself still shows
        //    only for an unanswered user (AdConsentStore.cardMayShow).
        if AdGate.shouldOfferChoice(input) {
            AdConsentStore.shared.enableQuestion()
        }

        // 7. SDK start.
        apply(AdGate.evaluate(input), keys: keys)
    }

    static var isReleaseBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Applies a gate result: start (makeSinks(keys) once, then start(keys:) each) or stop.
    /// Internal so tests drive it without the launch task.
    func apply(_ result: AdGateResult, keys: AdKeys) {
        if result.sdksMayStart {
            if !sinksMade {
                sinks = makeSinks(keys)
                sinksMade = true
            }
            for sink in sinks { sink.start(keys: keys) }
            isSending = true
        } else if isSending {
            for sink in sinks { sink.stop() }
            isSending = false
        }
        launchDecided = true
        // A purchase that arrived before this decision (Ask to Buy approved while the app was
        // closed, a purchase a kill cut short) goes through the normal rule now. The 24 hour
        // rule and once-per-id still apply. A closed gate forgets it; nothing left the device.
        let held = pendingFacts
        pendingFacts = []
        if isSending { for fact in held { purchased(fact) } }
    }

    /// Remembers the launch input so a later answer can be re-evaluated against it.
    func recordLaunch(_ input: AdGateInput, keys: AdKeys) {
        lastInput = input
        lastKeys = keys
    }

    /// Where `consentDidChange` reads the answer. A test replaces it; the app never does.
    var consentAnswer: @MainActor () -> AdConsentAnswer = { AdConsentStore.shared.answer }

    /// Called by AdConsentStore. Re-evaluates the last launch input with the new answer.
    /// No launch input yet: does nothing (the launch reads the answer itself).
    func consentDidChange() {
        guard var input = lastInput, let keys = lastKeys else { return }
        input.consent = consentAnswer()
        lastInput = input
        apply(AdGate.evaluate(input), keys: keys)
    }

    // MARK: Events

    func paywallShown() {
        guard isSending else { return }
        send(.paywallShown)
    }

    func checkoutStarted(_ kind: Usage.PurchaseProduct, price: Decimal, currencyCode: String) {
        guard isSending else { return }
        send(.checkoutStarted(AdPurchase(kind: kind, price: price, currencyCode: currencyCode, storeKitTransaction: nil)))
    }

    func purchased(_ fact: AdPurchaseFact) {
        guard isSending else {
            // Before the launch decision: keep the fact in memory only. After it: drop it.
            if !launchDecided, pendingFacts.count < Self.pendingCap { pendingFacts.append(fact) }
            return
        }
        var sent = defaults.stringArray(forKey: Self.sentTransactionIDsKey) ?? []
        let sentIDs = sent.compactMap { UInt64($0) }
        guard Self.shouldSend(fact, now: now(), alreadySent: sentIDs) else { return }
        // Written before the send: a second call for the same id (a replay) must find it.
        sent.append(String(fact.transactionID))
        if sent.count > Self.sentTransactionIDsCap {
            sent.removeFirst(sent.count - Self.sentTransactionIDsCap)
        }
        defaults.set(sent, forKey: Self.sentTransactionIDsKey)
        let purchase = AdPurchase(kind: fact.kind, price: fact.price, currencyCode: fact.currencyCode,
                                  storeKitTransaction: fact.storeKitTransaction)
        switch fact.kind {
        case .monthly: send(.subscribed(purchase))
        case .lifetime: send(.lifetimePurchased(purchase))
        }
    }

    /// Pure send rule for `purchased`.
    static func shouldSend(_ fact: AdPurchaseFact, now: Date, alreadySent: [UInt64]) -> Bool {
        fact.isPurchaseReason
            && !fact.isRevoked
            && !fact.isFamilyShared
            && !fact.isUpgraded
            && fact.isFromThisInstall
            && fact.purchaseDate >= now.addingTimeInterval(-freshness)
            && !alreadySent.contains(fact.transactionID)
    }

    private func send(_ event: AdEvent) {
        for sink in sinks { sink.send(event) }
    }

    // MARK: Live sinks

    /// One sink per network whose keys are present.
    static func liveSinks(_ keys: AdKeys) -> [any AdSink] {
        var result: [any AdSink] = []
        if keys.hasMeta { result.append(MetaAdSink()) }
        if keys.hasFirebaseConfig { result.append(FirebaseAdSink()) }
        if keys.hasTikTok { result.append(TikTokAdSink()) }
        return result
    }
}

// MARK: - Event names

/// Which event each network receives for each app event. Pure, so a test pins it. The sinks only
/// translate these cases to the vendor's own constants.
enum AdEventMap {
    enum Meta: Equatable { case viewedContent, initiatedCheckout, subscribeInitiatedCheckout, subscribe, purchase }
    enum Firebase: Equatable { case viewItem, beginCheckout, transaction, purchase }

    static func meta(_ event: AdEvent) -> Meta {
        switch event {
        case .paywallShown: return .viewedContent
        case .checkoutStarted(let p): return p.kind == .monthly ? .subscribeInitiatedCheckout : .initiatedCheckout
        case .subscribed: return .subscribe
        case .lifetimePurchased: return .purchase
        }
    }

    /// A purchase with the StoreKit transaction goes to `Analytics.logTransaction`.
    static func firebase(_ event: AdEvent) -> Firebase {
        switch event {
        case .paywallShown: return .viewItem
        case .checkoutStarted: return .beginCheckout
        case .subscribed(let p), .lifetimePurchased(let p): return p.storeKitTransaction != nil ? .transaction : .purchase
        }
    }

    static func tiktok(_ event: AdEvent) -> String {
        switch event {
        case .paywallShown: return "ViewContent"
        case .checkoutStarted: return "Checkout"
        case .subscribed: return TTEventName.subscribe.rawValue
        case .lifetimePurchased: return "Purchase"
        }
    }
}

// MARK: - Meta

/// Meta: the only writer of the conversion value (its SKAdNetwork reporter reads the events
/// logged here). Automatic logging is off in Info.plist, so `activateApp()` is ours to call:
/// it sends the install ping and must run on each foreground (ADS_SDK_FACTS 1.1.3).
@MainActor
private final class MetaAdSink: AdSink {
    private var isStarted = false
    private var isActive = false
    private var activeObserver: NSObjectProtocol?

    func start(keys: AdKeys) {
        guard keys.hasMeta else { return }
        isActive = true
        if !isStarted {
            // The `application(_:didFinishLaunchingWithOptions:)` form with nil; a second call is a no-op.
            ApplicationDelegate.shared.application(UIApplication.shared, didFinishLaunchingWithOptions: nil)
            isStarted = true
        }
        AppEvents.shared.activateApp()
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    AppEvents.shared.activateApp()
                }
            }
        }
    }

    func stop() {
        isActive = false
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
            self.activeObserver = nil
        }
    }

    func send(_ event: AdEvent) {
        guard isActive else { return }
        switch (AdEventMap.meta(event), event) {
        case (.viewedContent, _):
            AppEvents.shared.logEvent(.viewedContent)
        case (.subscribeInitiatedCheckout, .checkoutStarted(let p)):
            // Meta's own name for the monthly checkout; not in the SDK's standard-event list, so
            // it counts for conversion value only if it is in the Events Manager schema.
            log(.subscribeInitiatedCheckout, p)
        case (.initiatedCheckout, .checkoutStarted(let p)):
            log(.initiatedCheckout, p)
        case (.subscribe, .subscribed(let p)):
            log(.subscribe, p)
        case (.purchase, .lifetimePurchased(let p)):
            if let price = p.price, let code = p.currencyCode {
                AppEvents.shared.logPurchase(amount: Self.double(price), currency: code)
            } else {
                AppEvents.shared.logEvent(.purchased)
            }
        default:
            break
        }
    }

    private func log(_ name: AppEvents.Name, _ p: AdPurchase) {
        guard let price = p.price else {
            AppEvents.shared.logEvent(name)
            return
        }
        // Meta reads the currency only from `fb_currency`.
        var parameters: [AppEvents.ParameterName: Any] = [:]
        if let code = p.currencyCode { parameters[.currency] = code }
        AppEvents.shared.logEvent(name, valueToSum: Self.double(price), parameters: parameters)
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}

// MARK: - Firebase (Google)

/// The calls the Firebase sink makes, so a test can see the order without the SDK.
struct FirebaseHooks {
    var isConfigured: () -> Bool
    var configure: () -> Void
    /// All four consent types granted (true) or denied (false). Google's EEA / UK / CH rule.
    var setConsent: (_ granted: Bool) -> Void
    var setCollectionEnabled: (Bool) -> Void

    @MainActor static let live = FirebaseHooks(
        isConfigured: { FirebaseApp.app() != nil },
        configure: { FirebaseApp.configure() },
        setConsent: { granted in
            let status: ConsentStatus = granted ? .granted : .denied
            Analytics.setConsent([.analyticsStorage: status, .adStorage: status,
                                  .adUserData: status, .adPersonalization: status])
        },
        setCollectionEnabled: { Analytics.setAnalyticsCollectionEnabled($0) }
    )
}

/// Google. `FirebaseApp.configure()` raises (a crash) with no plist or a second call, so it is
/// guarded twice. Consent goes through here (ADS_SDK_FACTS 1.2.4).
@MainActor
final class FirebaseAdSink: AdSink {
    private let hooks: FirebaseHooks
    private var isActive = false

    init(hooks: FirebaseHooks = .live) {
        self.hooks = hooks
    }

    func start(keys: AdKeys) {
        guard keys.hasFirebaseConfig else { return }
        if !hooks.isConfigured() { hooks.configure() }
        // Before the first event of this run.
        hooks.setConsent(true)
        hooks.setCollectionEnabled(true)
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        hooks.setConsent(false)
        hooks.setCollectionEnabled(false)
    }

    func send(_ event: AdEvent) {
        guard isActive else { return }
        switch (AdEventMap.firebase(event), event) {
        case (.viewItem, _):
            Analytics.logEvent(AnalyticsEventViewItem, parameters: nil)
        case (.beginCheckout, .checkoutStarted(let p)):
            Analytics.logEvent(AnalyticsEventBeginCheckout, parameters: Self.valueParameters(p))
        case (.transaction, .subscribed(let p)), (.transaction, .lifetimePurchased(let p)):
            // Google reads price and currency from the verified transaction.
            if let transaction = p.storeKitTransaction { Analytics.logTransaction(transaction) }
        case (.purchase, .subscribed(let p)), (.purchase, .lifetimePurchased(let p)):
            Analytics.logEvent(AnalyticsEventPurchase, parameters: Self.valueParameters(p))
        default:
            break
        }
    }

    /// "If you supply value you must also supply currency" (FIRParameterNames.h).
    private static func valueParameters(_ p: AdPurchase) -> [String: Any]? {
        guard let price = p.price, let code = p.currencyCode else { return nil }
        return [AnalyticsParameterValue: NSDecimalNumber(decimal: price).doubleValue,
                AnalyticsParameterCurrency: code]
    }
}

// MARK: - TikTok

/// The calls the TikTok sink makes, so a test can see them without the SDK.
struct TikTokHooks {
    /// Starts the SDK. False when `TikTokConfig` could not be made.
    var initialize: (_ keys: AdKeys, _ debug: Bool) -> Bool
    var setTrackingEnabled: (Bool) -> Void
    var track: (_ name: String, _ properties: [String: Any]) -> Void

    @MainActor static let live = TikTokHooks(
        initialize: { keys, debug in
            guard let appleID = keys.tiktokAppleAppID, let tiktokAppID = keys.tiktokAppID,
                  let token = keys.tiktokAccessToken,
                  let config = TikTokConfig(accessToken: token, appId: appleID, tiktokAppId: tiktokAppID)
            else { return false }
            config.disableSKAdNetworkSupport()
            // The client choice only. TikTok's server setting can override it, so its own
            // StoreKit observer may still log purchases (design/ADS_REPAIR.md, H-H2).
            config.disablePaymentTracking()
            if debug { config.enableDebugMode() }
            TikTokBusiness.initializeSdk(config) { _, _ in }
            return true
        },
        setTrackingEnabled: { TikTokBusiness.setTrackingEnabled($0) },
        track: { name, properties in
            TikTokBusiness.trackTTEvent(TikTokBaseEvent(eventName: name, properties: properties, eventId: UUID().uuidString))
        }
    )
}

/// TikTok. Install and launch stay automatic. `disableSKAdNetworkSupport()` leaves the
/// conversion value to Meta. The app logs purchases; the client switch for TikTok's own purchase
/// logging is set, but TikTok's server value can turn it back on (an owner decision, see
/// design/ADS_REPAIR.md H-H2).
@MainActor
final class TikTokAdSink: AdSink {
    private let hooks: TikTokHooks
    private var isInitialized = false
    private var isActive = false
    /// After a stop, TikTok's SDK keeps its own events cached "until tracking is enabled again"
    /// (TikTokBusiness.h), and a later enable would send them. So a no in this run is final for
    /// this run: the sink does not turn tracking back on until the next launch.
    private var isWithdrawn = false

    init(hooks: TikTokHooks = .live) {
        self.hooks = hooks
    }

    func start(keys: AdKeys) {
        guard keys.hasTikTok else { return }
        guard !isWithdrawn else { return }
        if !isInitialized {
            guard hooks.initialize(keys, AdEvents.debugOverrideRequested) else { return }
            isInitialized = true
        }
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        isWithdrawn = true
        hooks.setTrackingEnabled(false)
    }

    func send(_ event: AdEvent) {
        guard isActive else { return }
        let purchase: AdPurchase?
        switch event {
        case .paywallShown: purchase = nil
        case .checkoutStarted(let p), .subscribed(let p), .lifetimePurchased(let p): purchase = p
        }
        hooks.track(AdEventMap.tiktok(event), Self.properties(purchase))
    }

    /// TikTok takes the value as a string. The event id the hook adds is random, never a transaction id.
    static func properties(_ p: AdPurchase?) -> [String: Any] {
        var properties: [String: Any] = [:]
        if let price = p?.price, let code = p?.currencyCode {
            properties["value"] = NSDecimalNumber(decimal: price).stringValue
            properties["currency"] = code
        }
        return properties
    }
}
