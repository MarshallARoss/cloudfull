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
import os
// The three ad SDKs are imported here and nowhere else in the app.
import FacebookCore
import FirebaseCore
import FirebaseAnalytics
import TikTokBusinessSDK

// This file answers one question: who paid for the app after an ad brought
// them. Each network gets one event per fact (counts, not people): paywall shown,
// purchase started, and each purchase once per transaction, with price and currency.
// TikTok also gets install, launch and retention, which the app sends itself.
//
// Rules this file keeps:
// - A sink starts only when the gate allows it AND its own keys are present.
// - Every vendor's automatic purchase logging is off. The app logs purchases.
// - No IDFA, no AdSupport import, no App Tracking Transparency call.
// - No transaction id goes to a network. One exception is forced by Google's
//   API: `Analytics.logTransaction` takes the StoreKit `Transaction`.

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
    /// `appId` next to `tiktokAppId` (the TikTok SDK takes both ids).
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
    /// four values `configureCore` reads must be present too (a malformed id is a crash).
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
    /// `AdRegion.decide(...) == .allowed`: the storefront and the device region are both outside the
    /// off-list. False when the storefront is unknown.
    var regionAllowsSDKs: Bool
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
    /// sdksMayStart = production && hasAnyKeys && regionAllowsSDKs
    /// appleAdsMayRun = production
    static func evaluate(_ input: AdGateInput) -> AdGateResult {
        let production = passesStaticChecks(input)
            && (input.debugOverride
                || (input.appTransaction?.isVerified == true && input.appTransaction?.environment == .production))
        return AdGateResult(
            sdksMayStart: production && input.hasAnyKeys && input.regionAllowsSDKs,
            appleAdsMayRun: production
        )
    }
}

// MARK: - Sink protocol and events

/// One ad network. Main actor: every SDK here wants the main thread for setup.
@MainActor
protocol AdSink: AnyObject {
    /// Called once per launch, and only when the gate allows it.
    func start(keys: AdKeys)
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
    static let shared = AdEvents(defaults: .standard, now: Date.init, makeSinks: AdEvents.liveSinks,
                                 conversionUpdater: LiveConversionUpdater(debugLog: AdEvents.debugOverrideRequested))

    /// UserDefaults [String] of decimal transaction ids already sent. Newest last.
    static let sentTransactionIDsKey = "ads.sentTransactionIDs"
    static let sentTransactionIDsCap = 64
    /// A purchase older than this is a restore or a replay, not a sale.
    static let freshness: TimeInterval = 24 * 60 * 60
    #if DEBUG
    /// Debug builds only. Waives "Release" and the AppTransaction check so a phone build can be
    /// tested with real keys. It never waives the official bundle id, the simulator, XCTest,
    /// keys or the region rule. Compiled out of Release.
    static let debugArgument = "-cloudfull-ads-debug"
    #endif
    static var debugOverrideRequested: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(debugArgument)
        #else
        return false
        #endif
    }

    /// Keys TikTok's `+load` code writes in every launch (NSObject+TikTokAdditions.m).
    static let tiktokReferrerKeys = ["source_url", "refer"]

    /// UserDefaults String: this install's `appAccountToken` (a UUID). The paywall passes it to
    /// every purchase. It goes to Apple only, never to an ad network.
    static let installTokenKey = "ads.installAccountToken"
    /// At most this many purchases (and, separately, funnel events) are held in memory before the launch decision.
    static let pendingCap = 8

    /// The token for this install. Made on first use and kept.
    static func installAccountToken(defaults: UserDefaults = .standard) -> UUID {
        if let raw = defaults.string(forKey: installTokenKey), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: installTokenKey)
        return id
    }

    /// The options every unlock purchase carries. Both paywall paths (the card style's
    /// `configuration.purchase()` has no options argument, so it takes these from the view
    /// environment) use it. A test buys with the same set.
    static func purchaseOptions(defaults: UserDefaults = .standard) -> Set<Product.PurchaseOption> {
        [.appAccountToken(installAccountToken(defaults: defaults))]
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private var pendingFacts: [AdPurchaseFact] = []
    /// Paywall shown and purchase started while the storefront is unknown. Sent after a late start.
    private var pendingEvents: [AdEvent] = []
    private var launchDecided = false
    /// True from the launch decision until the storefront is known. Purchases are held meanwhile.
    private(set) var waitingForRegion = false
    private let makeSinks: @MainActor (AdKeys) -> [any AdSink]
    private var sinks: [any AdSink] = []
    private var launchTask: Task<Void, Never>?
    private let conversion: AdConversionWriter?

    /// `conversionUpdater` nil means the app never writes Apple's conversion value (tests that do
    /// not cover it, so the test host never reaches StoreKit).
    init(defaults: UserDefaults, now: @escaping () -> Date, makeSinks: @escaping @MainActor (AdKeys) -> [any AdSink],
         conversionUpdater: (any AdConversionUpdating)? = nil) {
        self.defaults = defaults
        self.now = now
        self.makeSinks = makeSinks
        self.conversion = conversionUpdater.map {
            AdConversionWriter(defaults: defaults, updater: $0)
        }
    }

    /// True once the SDKs have started.
    private(set) var isSending = false
    /// True when the app, not Meta's SDK, writes Apple's conversion value in this launch.
    private(set) var appIsWriter = false
    /// Every send and every defaults write needs one of the two.
    private var isActive: Bool { isSending || appIsWriter }

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

        await launch(
            input: AdGateInput(
                isReleaseBuild: Self.isReleaseBuild,
                isOfficialBuild: StoreProducts.isOfficialBuild,
                isSimulator: Self.isSimulator,
                isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
                debugOverride: Self.debugOverrideRequested,
                hasAnyKeys: false,
                appTransaction: nil,
                regionAllowsSDKs: false
            ),
            keys: AdKeys.from(.main),
            appTransaction: { await LiveStoreFactsSource().appTransaction() },
            region: { await AdRegion.decideNow() },
            regionChanges: { AdRegion.changes() },
            startAppleAds: { Task { await AppleAdsAttribution.shared.runIfNeeded() } }
        )
    }

    /// Steps 2 to 7 of the launch. Internal so a test drives it with fake providers; `runLaunch`
    /// only waits for the first frame and passes the live ones.
    func launch(input staticInput: AdGateInput,
                keys: AdKeys,
                appTransaction: () async -> AppTransactionFacts?,
                region: () async -> AdRegion.Decision,
                regionChanges: () -> AsyncStream<Void>,
                startAppleAds: () -> Void) async {
        // 2. Static checks. The test host, the simulator, forks and plain Debug stop here.
        var input = staticInput
        input.hasAnyKeys = keys.hasAny
        guard AdGate.passesStaticChecks(input) else { return }

        // 3. AppTransaction. Async. It never shows a sign-in sheet.
        input.appTransaction = await appTransaction()

        // 4. Apple Ads. Nothing goes to another company, so the region does not matter.
        if AdGate.evaluate(input).appleAdsMayRun { startAppleAds() }

        // 5. Region. The three ad SDKs stay off in Europe, the UK and Switzerland.
        let decision = await region()
        input.regionAllowsSDKs = decision == .allowed

        // 6. SDK start. A storefront that is not known yet is not a "no": the SDKs would start
        // if it were known and allowed, so they wait for it (step 7) and purchases are held.
        var ifAllowed = input
        ifAllowed.regionAllowsSDKs = true
        let waits = decision == .unknown && AdGate.evaluate(ifAllowed).sdksMayStart
        apply(AdGate.evaluate(input), keys: keys, waitingForRegion: waits)
        guard waits else { return }

        // 7. Wait for the storefront. Each tick reads the region again. It ends after the first
        // known answer, so the SDKs start at most once in a launch.
        for await _ in regionChanges() {
            let later = await region()
            if later == .unknown { continue }
            input.regionAllowsSDKs = later == .allowed
            startAfterRegionKnown(AdGate.evaluate(input), keys: keys)
            return
        }
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

    /// Applies a gate result: start every sink, or do nothing. Internal so tests drive it without
    /// the launch task. The app calls it once per launch. `waitingForRegion`: the storefront is not
    /// known yet, so purchases stay held until `startAfterRegionKnown`.
    func apply(_ result: AdGateResult, keys: AdKeys, waitingForRegion: Bool = false) {
        if result.sdksMayStart {
            startSinks(keys)
        } else if !waitingForRegion {
            clearTikTokReferrer()
        }
        // One writer of Apple's conversion value per launch: Meta's SDK when it started, else the app.
        // While the storefront is unknown and a Meta key exists, Meta may start late, so the app does
        // not write yet: a write now could lower a value Meta wrote and will not write again.
        // `startAfterRegionKnown` chooses the writer.
        let metaMayStart = waitingForRegion && keys.hasMeta
        appIsWriter = conversion != nil && !metaMayStart && AdConversionWriter.appIsWriter(result, keys: keys)
        if appIsWriter { conversion?.register() }
        launchDecided = true
        self.waitingForRegion = waitingForRegion
        let held = pendingFacts
        if waitingForRegion {
            // The app's own conversion value needs no region: it counts these now. The sinks get
            // them when the storefront is known.
            for fact in held { recordConversionFact(fact) }
            return
        }
        // A purchase that arrived before this decision (Ask to Buy approved while the app was
        // closed, a purchase a kill cut short) goes through the normal rule now. The 24 hour
        // rule and once-per-id still apply. A closed gate forgets it; nothing left the device.
        pendingFacts = []
        if isActive { for fact in held { purchased(fact) } }
    }

    /// The storefront became known after the launch decision. Starts the sinks now if the region
    /// is allowed, and sends the held purchases; an off region drops them. Runs once: a second call
    /// finds nothing to wait for, so no sink starts twice.
    func startAfterRegionKnown(_ result: AdGateResult, keys: AdKeys) {
        guard waitingForRegion else { return }
        waitingForRegion = false
        if result.sdksMayStart {
            startSinks(keys)
        } else {
            clearTikTokReferrer()
        }
        // Choose the writer now that the region is known. Meta's SDK writes when it started and the app
        // stops. If the app writes and did not register at the launch decision (a Meta key was
        // present), it registers now with the stored set, then the held purchases count below.
        let wasWriter = appIsWriter
        appIsWriter = conversion != nil && AdConversionWriter.appIsWriter(result, keys: keys)
        if appIsWriter && !wasWriter { conversion?.register() }
        let held = pendingFacts
        pendingFacts = []
        let heldEvents = pendingEvents
        pendingEvents = []
        if isActive {
            for event in heldEvents { send(event) }
            for fact in held { purchased(fact) }
        }
    }

    private func startSinks(_ keys: AdKeys) {
        guard !isSending else { return }
        sinks = makeSinks(keys)
        for sink in sinks { sink.start(keys: keys) }
        isSending = true
    }

    /// TikTok's +load code writes the launch referrer to standard UserDefaults in every region,
    /// and a later allowed launch could send it. Cleared when the SDKs stay off.
    private func clearTikTokReferrer() {
        for key in Self.tiktokReferrerKeys { defaults.removeObject(forKey: key) }
    }

    // MARK: Events

    func paywallShown() {
        sendOrHold(.paywallShown)
    }

    func checkoutStarted(_ kind: Usage.PurchaseProduct, price: Decimal, currencyCode: String) {
        sendOrHold(.checkoutStarted(AdPurchase(kind: kind, price: price, currencyCode: currencyCode, storeKitTransaction: nil)))
    }

    /// While the storefront is unknown no sink exists yet, so these two events wait in memory for
    /// the late start (an off region drops them).
    private func sendOrHold(_ event: AdEvent) {
        if waitingForRegion {
            if pendingEvents.count < Self.pendingCap { pendingEvents.append(event) }
            return
        }
        guard isActive else { return }
        send(event)
    }

    func purchased(_ fact: AdPurchaseFact) {
        if waitingForRegion {
            if pendingFacts.count < Self.pendingCap { pendingFacts.append(fact) }
            recordConversionFact(fact)
            return
        }
        guard isActive else {
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
        send(Self.event(for: fact))
    }

    private static func event(for fact: AdPurchaseFact) -> AdEvent {
        let purchase = AdPurchase(kind: fact.kind, price: fact.price, currencyCode: fact.currencyCode,
                                  storeKitTransaction: fact.storeKitTransaction)
        switch fact.kind {
        case .monthly: return .subscribed(purchase)
        case .lifetime: return .lifetimePurchased(purchase)
        }
    }

    /// A held purchase that passes the send rules counts for the app's own conversion value at
    /// once. Nothing is marked as sent: the sinks still get it later.
    private func recordConversionFact(_ fact: AdPurchaseFact) {
        guard appIsWriter else { return }
        let sentIDs = (defaults.stringArray(forKey: Self.sentTransactionIDsKey) ?? []).compactMap { UInt64($0) }
        guard Self.shouldSend(fact, now: now(), alreadySent: sentIDs) else { return }
        conversion?.record(Self.event(for: fact))
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
        // The app writes Apple's value, or (Meta writes) only stores the fact. Never lowers a value.
        if isActive { conversion?.record(event, writeToApple: appIsWriter) }
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
    enum Firebase: Equatable { case viewItem, beginCheckout, transaction }

    static func meta(_ event: AdEvent) -> Meta {
        switch event {
        case .paywallShown: return .viewedContent
        case .checkoutStarted(let p): return p.kind == .monthly ? .subscribeInitiatedCheckout : .initiatedCheckout
        case .subscribed: return .subscribe
        case .lifetimePurchased: return .purchase
        }
    }

    /// Every purchase goes to `Analytics.logTransaction`: production facts always carry the StoreKit
    /// transaction. A fact without one (a test) logs nothing at Firebase.
    static func firebase(_ event: AdEvent) -> Firebase {
        switch event {
        case .paywallShown: return .viewItem
        case .checkoutStarted: return .beginCheckout
        case .subscribed, .lifetimePurchased: return .transaction
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

/// Meta writes the conversion value when its SDK starts; otherwise the app does
/// (`AdConversionWriter`). Meta's SKAdNetwork reporter reads the events logged here. Automatic logging is off in Info.plist, so `activateApp()` is ours to call:
/// it sends the install ping and must run on each foreground.
@MainActor
private final class MetaAdSink: AdSink {
    private var isActive = false

    func start(keys: AdKeys) {
        guard keys.hasMeta else { return }
        // The `application(_:didFinishLaunchingWithOptions:)` form with nil.
        ApplicationDelegate.shared.application(UIApplication.shared, didFinishLaunchingWithOptions: nil)
        #if DEBUG
        // A real-key test (`-cloudfull-ads-debug`) reads each event and flush in the Xcode console.
        if AdEvents.debugOverrideRequested { Settings.shared.enableLoggingBehavior(.appEvents) }
        #endif
        AppEvents.shared.activateApp()
        isActive = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppEvents.shared.activateApp() }
        }
    }

    func send(_ event: AdEvent) {
        guard isActive else { return }
        send(sdkEvent: event)
        #if DEBUG
        // Meta batches events; the debug test wants each one at once.
        if AdEvents.debugOverrideRequested { AppEvents.shared.flush() }
        #endif
    }

    private func send(sdkEvent event: AdEvent) {
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

    @MainActor static let live = FirebaseHooks(
        isConfigured: { FirebaseApp.app() != nil },
        configure: { FirebaseApp.configure() }
    )
}

/// Google. `FirebaseApp.configure()` raises (a crash) with no plist or a second call, so it is
/// guarded twice. In the regions where Google applies its EU User Consent Policy, Google denies
/// ad user data and ad personalization by itself (Info.plist `eu_consent_policy`).
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
        isActive = true
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
    var track: (_ name: String, _ properties: [String: Any]) -> Void
    /// Makes TikTok's screenshot switch impossible to turn on. True when it is installed. The sink
    /// does not start when this is false.
    var blockScreenshots: () -> Bool = { true }

    @MainActor static let live = TikTokHooks(
        initialize: { keys, debug in
            guard let appleID = keys.tiktokAppleAppID, let tiktokAppID = keys.tiktokAppID,
                  let token = keys.tiktokAccessToken,
                  let config = TikTokConfig(accessToken: token, appId: appleID, tiktokAppId: tiktokAppID)
            else { return false }
            config.disableSKAdNetworkSupport()
            // TikTok's server can switch its payment tracking back on (TikTokBusiness.m:989-990),
            // but its StoreKit observer starts only when automatic tracking is on too (:1049), and
            // no server value sets that. So the master switch is what keeps a purchase, a renewal
            // and a tip from being logged a second time. `disablePaymentTracking()` stays as well.
            // The app sends install, launch and retention itself (`TikTokAutomaticEvents`).
            config.disableAutomaticTracking()
            config.disablePaymentTracking()
            if debug { config.enableDebugMode() }
            TikTokBusiness.initializeSdk(config) { _, _ in }
            #if DEBUG
            if debug { Self.logScreenshotBlockCheck() }
            #endif
            for name in TikTokAutomaticEvents.due(defaults: .standard, now: Date()) {
                TikTokBusiness.trackTTEvent(TikTokBaseEvent(eventName: name, properties: ["type": "auto"],
                                                            eventId: UUID().uuidString))
            }
            // The user may come back on day 1 to an app that stayed in memory: check retention on
            // each foreground too.
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { _ in
                if TikTokAutomaticEvents.retentionDue(defaults: .standard, now: Date()) {
                    TikTokBusiness.trackTTEvent(TikTokBaseEvent(eventName: "2Dretention", properties: ["type": "auto"],
                                                                eventId: UUID().uuidString))
                }
            }
            return true
        },
        track: { name, properties in
            TikTokBusiness.trackTTEvent(TikTokBaseEvent(eventName: name, properties: properties, eventId: UUID().uuidString))
        },
        // TikTok's server can ask the SDK to attach a screenshot of the key window to each event:
        // the config fetch sets the private `screenshotEnabled` from `enable_screenshot`
        // (TikTokBusiness.m:70, :1069-1074), and when it is true each event carries the image
        // (:617-622, :1181-1193, TikTokRequestHandler.m:395-396). Cloudfull's window shows the
        // user's photos, and a screenshot is not ad measurement. The SDK has no public switch, so
        // the setter is replaced: the stored value is always NO.
        blockScreenshots: {
            BoolSetterGuard.installForcingFalse(on: TikTokBusiness.self,
                                                setter: NSSelectorFromString("setScreenshotEnabled:"),
                                                getter: NSSelectorFromString("screenshotEnabled"))
        }
    )

    #if DEBUG
    /// For the phone test: tries to turn the switch on, reads it back, logs the answer.
    @MainActor private static func logScreenshotBlockCheck() {
        let instance: TikTokBusiness? = TikTokBusiness.getInstance()
        instance?.setValue(true, forKey: "screenshotEnabled")
        let stored = instance?.value(forKey: "screenshotEnabled") as? Bool
        Logger(subsystem: "com.cloudfull.app", category: "AdTikTok").info(
            "tiktok screenshot block ok=\(stored == false)")
    }
    #endif
}

/// Replaces a Bool setter on a class so the stored value is always false, for a flag the
/// vendor's SDK exposes no switch for. Generic on purpose: a test runs it on its own class.
enum BoolSetterGuard {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: Set<String> = []

    /// True when the guard is in place (now, or from an earlier call: it is installed one time).
    /// False, with nothing changed, when the setter or the getter is missing or is not the
    /// `void set(BOOL)` / `BOOL get()` shape.
    static func installForcingFalse(on cls: AnyClass, setter: Selector, getter: Selector) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(NSStringFromClass(cls))|\(NSStringFromSelector(setter))"
        if installed.contains(key) { return true }
        guard let setterMethod = class_getInstanceMethod(cls, setter),
              let getterMethod = class_getInstanceMethod(cls, getter),
              let setterTypes = method_getTypeEncoding(setterMethod),
              let getterTypes = method_getTypeEncoding(getterMethod),
              ["v@:B", "v@:c"].contains(stripped(setterTypes)),
              ["B@:", "c@:"].contains(stripped(getterTypes))
        else {
            Logger(subsystem: "com.cloudfull.app", category: "AdTikTok").error(
                "bool setter guard not installed: \(NSStringFromSelector(setter), privacy: .public) missing or unexpected type")
            return false
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(setterMethod), to: Setter.self)
        let replacement: @convention(block) (AnyObject, Bool) -> Void = { object, _ in
            original(object, setter, false)
        }
        class_replaceMethod(cls, setter, imp_implementationWithBlock(replacement), setterTypes)
        installed.insert(key)
        return true
    }

    /// A type encoding with the byte offsets removed: "v20@0:8B16" becomes "v@:B".
    private static func stripped(_ encoding: UnsafePointer<CChar>) -> String {
        String(String(cString: encoding).filter { !$0.isNumber })
    }
}

/// The events TikTok's SDK would log by itself with automatic tracking on. That switch is off
/// (it is the only one a TikTok server value cannot undo), so the app logs them, once each.
/// Same names and properties as TikTok's own (TikTokBusiness.m:1013, :1027, :572-590).
enum TikTokAutomaticEvents {
    static let installDateKey = "ads.tiktokInstallDate"
    static let retentionLoggedKey = "ads.tiktokRetentionLogged"

    /// The event names to log now. Marks each one in `defaults` before it returns, so a second call
    /// does not return it again: install once per install, launch once per call (one per launch),
    /// retention once, on the calendar day after the install day.
    static func due(defaults: UserDefaults, now: Date, calendar: Calendar = .current) -> [String] {
        var names: [String] = []
        if defaults.object(forKey: installDateKey) is Date {
            if retentionDue(defaults: defaults, now: now, calendar: calendar) { names.append("2Dretention") }
        } else {
            defaults.set(now, forKey: installDateKey)
            names.append("InstallApp")
        }
        names.append("LaunchAPP")
        return names
    }

    /// True once, on the calendar day after the install day, and marks it. TikTok's own code also
    /// checked on each foreground (TikTokBusiness.m:702-704), so the sink calls this again then.
    static func retentionDue(defaults: UserDefaults, now: Date, calendar: Calendar = .current) -> Bool {
        guard let installed = defaults.object(forKey: installDateKey) as? Date,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: installed),
              calendar.isDate(now, inSameDayAs: nextDay), !defaults.bool(forKey: retentionLoggedKey)
        else { return false }
        defaults.set(true, forKey: retentionLoggedKey)
        return true
    }
}

/// TikTok. Automatic tracking is off; the app logs install, launch and retention
/// (`TikTokAutomaticEvents`) and the purchases, so each fact is logged once.
/// `disableSKAdNetworkSupport()` keeps TikTok out of the conversion value (Meta or the app writes it).
@MainActor
final class TikTokAdSink: AdSink {
    private let hooks: TikTokHooks
    private var isActive = false

    init(hooks: TikTokHooks = .live) {
        self.hooks = hooks
    }

    func start(keys: AdKeys) {
        guard keys.hasTikTok else { return }
        // Fail closed: without the screenshot block TikTok does not start.
        guard hooks.blockScreenshots() else { return }
        guard hooks.initialize(keys, AdEvents.debugOverrideRequested) else { return }
        isActive = true
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
