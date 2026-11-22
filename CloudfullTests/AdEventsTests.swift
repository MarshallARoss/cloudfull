//
//  AdEventsTests.swift
//  CloudfullTests
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
import StoreKit
@testable import Cloudfull

/// A sink that records. No ad SDK is imported or started by these tests; the app is the test
/// host, so the real singletons must stay inert (the launch gate stops at the static checks).
@MainActor
final class FakeAdSink: AdSink {
    var started: [AdKeys] = []
    var stops = 0
    var events: [AdEvent] = []
    func start(keys: AdKeys) { started.append(keys) }
    func stop() { stops += 1 }
    func send(_ event: AdEvent) { events.append(event) }
}

/// Plain recorder for the Firebase sink's hooks.
@MainActor
final class FirebaseHookLog {
    var calls: [String] = []
    var configured = false

    var hooks: FirebaseHooks {
        FirebaseHooks(
            isConfigured: { [self] in configured },
            configure: { [self] in calls.append("configure"); configured = true },
            setConsent: { [self] granted in calls.append("consent:\(granted)") },
            setCollectionEnabled: { [self] on in calls.append("collection:\(on)") }
        )
    }
}

@Suite("AdEventsTests", .serialized)
@MainActor
struct AdEventsTests {

    // MARK: - Fixtures

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let allKeys = AdKeys(metaAppID: "1", metaClientToken: "t", tiktokAppID: "2", tiktokAccessToken: "a",
                                 hasFirebaseConfig: true, tiktokAppleAppID: "3")

    /// A fresh defaults suite per test. Never `UserDefaults.standard`.
    private func makeSuite() -> (UserDefaults, String) {
        let name = "AdEventsTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func makeEvents(_ defaults: UserDefaults, sink: FakeAdSink) -> AdEvents {
        AdEvents(defaults: defaults, now: { fixedNow }, makeSinks: { _ in [sink] })
    }

    /// An events object that is already sending to `sink`.
    private func sendingEvents(_ defaults: UserDefaults, sink: FakeAdSink) -> AdEvents {
        let events = makeEvents(defaults, sink: sink)
        events.apply(AdGateResult(sdksMayStart: true, appleAdsMayRun: true), keys: allKeys)
        return events
    }

    private func fact(_ kind: Usage.PurchaseProduct = .lifetime, id: UInt64 = 1, age: TimeInterval = 60,
                      price: Decimal? = Decimal(string: "9.99"), currency: String? = "USD",
                      purchase: Bool = true, revoked: Bool = false, family: Bool = false,
                      upgraded: Bool = false) -> AdPurchaseFact {
        AdPurchaseFact(kind: kind, transactionID: id, purchaseDate: fixedNow.addingTimeInterval(-age),
                       price: price, currencyCode: currency, isPurchaseReason: purchase,
                       isRevoked: revoked, isFamilyShared: family, isUpgraded: upgraded)
    }

    /// A gate input that passes every production check. Each gate test breaks one thing.
    private func goodInput() -> AdGateInput {
        AdGateInput(
            isReleaseBuild: true, isOfficialBuild: true, isSimulator: false, isRunningTests: false,
            debugOverride: false, hasAnyKeys: true,
            appTransaction: AppTransactionFacts(environment: .production, originalAppVersion: "1.1",
                                                originalPurchaseDate: nil, isVerified: true),
            region: .notRequired, consent: .notAsked
        )
    }

    // MARK: - Gate table

    @Test("A production build with keys on a non-EEA storefront starts the SDKs")
    func gateOpens() {
        let result = AdGate.evaluate(goodInput())
        #expect(result == AdGateResult(sdksMayStart: true, appleAdsMayRun: true))
    }

    @Test("Debug build: closed")
    func gateDebug() {
        var input = goodInput()
        input.isReleaseBuild = false
        #expect(AdGate.evaluate(input) == AdGateResult(sdksMayStart: false, appleAdsMayRun: false))
    }

    @Test("Simulator: closed")
    func gateSimulator() {
        var input = goodInput()
        input.isSimulator = true
        #expect(AdGate.evaluate(input) == AdGateResult(sdksMayStart: false, appleAdsMayRun: false))
    }

    @Test("Fork bundle id: closed")
    func gateFork() {
        var input = goodInput()
        input.isOfficialBuild = false
        #expect(AdGate.evaluate(input) == AdGateResult(sdksMayStart: false, appleAdsMayRun: false))
    }

    @Test("XCTest host: closed")
    func gateXCTest() {
        var input = goodInput()
        input.isRunningTests = true
        #expect(AdGate.evaluate(input) == AdGateResult(sdksMayStart: false, appleAdsMayRun: false))
    }

    @Test("Sandbox, Xcode, other and unverified AppTransaction: closed; missing AppTransaction: closed")
    func gateNotProduction() {
        for environment in [StoreEnvironment.sandbox, .xcode, .other] {
            var input = goodInput()
            input.appTransaction = AppTransactionFacts(environment: environment, originalAppVersion: "1.1",
                                                       originalPurchaseDate: nil, isVerified: true)
            #expect(AdGate.evaluate(input) == AdGateResult(sdksMayStart: false, appleAdsMayRun: false))
        }
        var unverified = goodInput()
        unverified.appTransaction = AppTransactionFacts(environment: .production, originalAppVersion: "1.1",
                                                        originalPurchaseDate: nil, isVerified: false)
        #expect(AdGate.evaluate(unverified) == AdGateResult(sdksMayStart: false, appleAdsMayRun: false))
        var missing = goodInput()
        missing.appTransaction = nil
        #expect(AdGate.evaluate(missing) == AdGateResult(sdksMayStart: false, appleAdsMayRun: false))
    }

    @Test("No keys: SDKs closed, Apple Ads still allowed (nothing leaves to another company)")
    func gateNoKeys() {
        var input = goodInput()
        input.hasAnyKeys = false
        #expect(AdGate.evaluate(input) == AdGateResult(sdksMayStart: false, appleAdsMayRun: true))
    }

    @Test("Region by consent: only notRequired, or required with a yes, opens the SDKs")
    func gateRegionTable() {
        let cases: [(AdConsentRegion, AdConsentAnswer, Bool)] = [
            (.notRequired, .notAsked, true), (.notRequired, .yes, true), (.notRequired, .no, true),
            (.required, .notAsked, false), (.required, .yes, true), (.required, .no, false),
            (.unknown, .notAsked, false), (.unknown, .yes, false), (.unknown, .no, false),
        ]
        for (region, consent, mayStart) in cases {
            var input = goodInput()
            input.region = region
            input.consent = consent
            let result = AdGate.evaluate(input)
            #expect(result.sdksMayStart == mayStart, "region \(region) consent \(consent)")
            // Apple Ads never waits for the consent answer.
            #expect(result.appleAdsMayRun)
        }
    }

    @Test("An unknown storefront never opens the SDKs, even with a yes stored")
    func gateUnknownStorefront() {
        var input = goodInput()
        input.region = .unknown
        input.consent = .yes
        #expect(AdGate.evaluate(input).sdksMayStart == false)
        #expect(AdGate.shouldAsk(input) == false)
    }

    @Test("Debug override waives Release and AppTransaction, never the bundle id, simulator, tests or keys")
    func gateDebugOverride() {
        var input = goodInput()
        input.isReleaseBuild = false
        input.appTransaction = AppTransactionFacts(environment: .sandbox, originalAppVersion: "1.1",
                                                   originalPurchaseDate: nil, isVerified: true)
        input.debugOverride = true
        #expect(AdGate.evaluate(input).sdksMayStart)

        var fork = input; fork.isOfficialBuild = false
        var sim = input; sim.isSimulator = true
        var tests = input; tests.isRunningTests = true
        var noKeys = input; noKeys.hasAnyKeys = false
        var eeaNoYes = input; eeaNoYes.region = .required
        #expect(AdGate.evaluate(fork).sdksMayStart == false)
        #expect(AdGate.evaluate(sim).sdksMayStart == false)
        #expect(AdGate.evaluate(tests).sdksMayStart == false)
        #expect(AdGate.evaluate(noKeys).sdksMayStart == false)
        #expect(AdGate.evaluate(eeaNoYes).sdksMayStart == false)
    }

    @Test("shouldAsk: only in production, with keys, on a required region, with nothing answered")
    func shouldAskTable() {
        var input = goodInput()
        input.region = .required
        #expect(AdGate.shouldAsk(input))

        var answered = input; answered.consent = .yes
        var declined = input; declined.consent = .no
        var notRequired = input; notRequired.region = .notRequired
        var noKeys = input; noKeys.hasAnyKeys = false
        var simulator = input; simulator.isSimulator = true
        var sandbox = input
        sandbox.appTransaction = AppTransactionFacts(environment: .sandbox, originalAppVersion: "1.1",
                                                     originalPurchaseDate: nil, isVerified: true)
        #expect(AdGate.shouldAsk(answered) == false)
        #expect(AdGate.shouldAsk(declined) == false)
        #expect(AdGate.shouldAsk(notRequired) == false)
        #expect(AdGate.shouldAsk(noKeys) == false)
        #expect(AdGate.shouldAsk(simulator) == false)
        #expect(AdGate.shouldAsk(sandbox) == false)
    }

    @Test("shouldOfferChoice: the Settings row stays after a stored yes or no, and only there")
    func offerChoiceTable() {
        var input = goodInput()
        input.region = .required
        for consent in AdConsentAnswer.allCases {
            input.consent = consent
            #expect(AdGate.shouldOfferChoice(input), "consent \(consent)")
        }
        // The one-time card is for an unanswered user only.
        input.consent = .yes
        #expect(AdGate.shouldAsk(input) == false)
        input.consent = .no
        #expect(AdGate.shouldAsk(input) == false)

        var notRequired = input; notRequired.region = .notRequired
        var unknown = input; unknown.region = .unknown
        var noKeys = input; noKeys.hasAnyKeys = false
        var simulator = input; simulator.isSimulator = true
        #expect(AdGate.shouldOfferChoice(notRequired) == false)
        #expect(AdGate.shouldOfferChoice(unknown) == false)
        #expect(AdGate.shouldOfferChoice(noKeys) == false)
        #expect(AdGate.shouldOfferChoice(simulator) == false)
    }

    @Test("The test host itself passes no static check, so the real launch task stops early")
    func testHostIsClosed() {
        // The same four values `runLaunch` reads, from the real `#if` switches and the real process.
        let input = AdGateInput(
            isReleaseBuild: AdEvents.isReleaseBuild, isOfficialBuild: StoreProducts.isOfficialBuild,
            isSimulator: AdEvents.isSimulator,
            isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            debugOverride: AdEvents.debugOverrideRequested, hasAnyKeys: false,
            appTransaction: nil, region: .unknown, consent: .notAsked
        )
        #expect(input.isRunningTests, "the unit tests run inside the app host with XCTest configured")
        #expect(AdGate.passesStaticChecks(input) == false)
        // And the real, never-launched singleton has started nothing.
        #expect(AdEvents.shared.isSending == false)
    }

    // MARK: - Keys

    @Test("Empty and unset-variable values count as absent keys")
    func keysAbsent() {
        let keys = AdKeys(metaAppID: nil, metaClientToken: nil, tiktokAppID: nil, tiktokAccessToken: nil,
                          hasFirebaseConfig: false)
        #expect(keys.hasAny == false)
        // The test bundle is not the app bundle; this only proves `from` returns no keys for a
        // bundle that carries none (no Info.plist values, no GoogleService-Info.plist).
        let empty = AdKeys.from(Bundle(for: FakeAdSinkAnchor.self))
        #expect(empty.hasMeta == false)
        #expect(empty.hasTikTok == false)
        #expect(empty.hasFirebaseConfig == false)
    }

    @Test("Meta needs both ids; TikTok needs all three; any one network is enough for the gate")
    func keysPerNetwork() {
        var keys = AdKeys(metaAppID: "1", metaClientToken: nil, tiktokAppID: "2", tiktokAccessToken: "a",
                          hasFirebaseConfig: false)
        #expect(keys.hasMeta == false)
        #expect(keys.hasTikTok == false)
        #expect(keys.hasAny == false)
        keys.metaClientToken = "t"
        #expect(keys.hasMeta)
        #expect(keys.hasAny)
        keys.tiktokAppleAppID = "3"
        #expect(keys.hasTikTok)
        #expect(AdKeys(metaAppID: nil, metaClientToken: nil, tiktokAppID: nil, tiktokAccessToken: nil,
                       hasFirebaseConfig: true).hasAny)
    }

    // MARK: - Send rule

    @Test("Monthly gives Subscribe; lifetime gives Purchase; price and currency pass through unchanged")
    func eventKinds() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = sendingEvents(defaults, sink: sink)

        events.purchased(fact(.monthly, id: 10, price: Decimal(string: "3.49"), currency: "EUR"))
        events.purchased(fact(.lifetime, id: 11, price: Decimal(string: "12.99"), currency: "GBP"))

        #expect(sink.events == [
            .subscribed(AdPurchase(kind: .monthly, price: Decimal(string: "3.49"), currencyCode: "EUR", storeKitTransaction: nil)),
            .lifetimePurchased(AdPurchase(kind: .lifetime, price: Decimal(string: "12.99"), currencyCode: "GBP", storeKitTransaction: nil)),
        ])
    }

    @Test("Paywall shown and checkout started reach the sink; checkout keeps price and currency")
    func paywallAndCheckout() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = sendingEvents(defaults, sink: sink)

        events.paywallShown()
        events.checkoutStarted(.monthly, price: Decimal(string: "2.99")!, currencyCode: "USD")
        #expect(sink.events == [
            .paywallShown,
            .checkoutStarted(AdPurchase(kind: .monthly, price: Decimal(string: "2.99"), currencyCode: "USD", storeKitTransaction: nil)),
        ])
        // A started checkout is not a purchase: no transaction id is kept.
        #expect(defaults.stringArray(forKey: AdEvents.sentTransactionIDsKey) == nil)
    }

    @Test("One event per transaction id, also across a new AdEvents on the same defaults (relaunch)")
    func oneEventPerID() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = FakeAdSink()
        let events = sendingEvents(defaults, sink: first)
        events.purchased(fact(id: 42))
        events.purchased(fact(id: 42))
        #expect(first.events.count == 1)
        #expect(defaults.stringArray(forKey: AdEvents.sentTransactionIDsKey) == ["42"])

        let second = FakeAdSink()
        let relaunched = sendingEvents(defaults, sink: second)
        relaunched.purchased(fact(id: 42))
        #expect(second.events.isEmpty)
        relaunched.purchased(fact(id: 43))
        #expect(second.events.count == 1)
    }

    @Test("The sent-id list keeps the newest 64")
    func idCap() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = sendingEvents(defaults, sink: sink)
        for id in 1...70 { events.purchased(fact(id: UInt64(id))) }
        let stored = defaults.stringArray(forKey: AdEvents.sentTransactionIDsKey) ?? []
        #expect(stored.count == AdEvents.sentTransactionIDsCap)
        #expect(stored.first == "7")
        #expect(stored.last == "70")
        #expect(sink.events.count == 70)
    }

    @Test("Stale, renewal or restore, revoked, family shared and upgraded transactions send nothing")
    func nothingForNonSales() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = sendingEvents(defaults, sink: sink)

        events.purchased(fact(id: 1, age: AdEvents.freshness + 1))          // a restore or a replay
        events.purchased(fact(id: 2, purchase: false))                      // a renewal
        events.purchased(fact(id: 3, revoked: true))                        // a refund
        events.purchased(fact(id: 4, family: true))                         // a Family Sharing grant
        events.purchased(fact(id: 5, upgraded: true))                       // an upgrade
        #expect(sink.events.isEmpty)
        #expect(defaults.stringArray(forKey: AdEvents.sentTransactionIDsKey) == nil)

        // The edge of the freshness window still counts.
        events.purchased(fact(id: 6, age: AdEvents.freshness))
        #expect(sink.events.count == 1)
    }

    @Test("Tips have no kind, so no ad call exists for them; a restore is a non-purchase reason")
    func tipsAndRestores() {
        #expect(Usage.purchaseProduct(for: "com.cloudfull.app.tip.10") == nil)
        #expect(AdEvents.shouldSend(fact(purchase: false), now: fixedNow, alreadySent: []) == false)
        #expect(AdEvents.shouldSend(fact(age: 30 * 24 * 60 * 60), now: fixedNow, alreadySent: []) == false)
        #expect(AdEvents.shouldSend(fact(), now: fixedNow, alreadySent: []))
        #expect(AdEvents.shouldSend(fact(id: 9), now: fixedNow, alreadySent: [9]) == false)
    }

    /// The tip and restore paths live in code the unit target cannot drive (the gate is closed in
    /// the test host), so this reads the sources: ad calls sit only at the five planned places.
    @Test("Source check: no ad call in the tip jar, in restore, or anywhere outside the planned call sites")
    func adCallsOnlyAtPlannedSites() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("Cloudfull")
        let entitlements = try String(contentsOf: app.appendingPathComponent("Store/Entitlements.swift"), encoding: .utf8)
        let tips = try String(contentsOf: app.appendingPathComponent("Settings/TipJar.swift"), encoding: .utf8)
        #expect(!tips.contains("AdEvents"))
        #expect(entitlements.components(separatedBy: "AdEvents.shared.").count - 1 == 5)
        let start = try #require(entitlements.range(of: "func restore() async -> RestoreOutcome"))
        let tail = entitlements[start.upperBound...]
        let end = tail.range(of: "\n    }\n")?.upperBound ?? tail.endIndex
        #expect(!tail[..<end].contains("AdEvents"))
    }

    // MARK: - Transaction mapping

    private struct FakeTransaction: AdTransactionFacts {
        var id: UInt64 = 7
        var purchaseDate = Date(timeIntervalSince1970: 1_800_000_000)
        var price: Decimal? = Decimal(string: "9.99")
        var currencyIdentifier: String? = "USD"
        var reason: Transaction.Reason = .purchase
        var revocationDate: Date? = nil
        var ownershipType: Transaction.OwnershipType = .purchased
        var isUpgraded = false
        var appAccountToken: UUID? = nil
        var storeKitTransaction: Transaction? { nil }
    }

    @Test("AdPurchaseFact reads each StoreKit field into the right flag")
    func factMapping() {
        let plain = AdPurchaseFact(FakeTransaction(), kind: .lifetime, localPurchase: true)
        #expect(plain.transactionID == 7)
        #expect(plain.price == Decimal(string: "9.99"))
        #expect(plain.currencyCode == "USD")
        #expect(plain.isPurchaseReason && !plain.isRevoked && !plain.isFamilyShared && !plain.isUpgraded)

        #expect(AdPurchaseFact(FakeTransaction(reason: .renewal), kind: .monthly, localPurchase: true).isPurchaseReason == false)
        #expect(AdPurchaseFact(FakeTransaction(revocationDate: fixedNow), kind: .monthly, localPurchase: true).isRevoked)
        #expect(AdPurchaseFact(FakeTransaction(ownershipType: .familyShared), kind: .monthly, localPurchase: true).isFamilyShared)
        #expect(AdPurchaseFact(FakeTransaction(isUpgraded: true), kind: .monthly, localPurchase: true).isUpgraded)
    }

    @Test("A purchase from another device (another appAccountToken) is not sent; this install's token is")
    func otherDeviceIsNotSent() {
        let mine = UUID()
        let other = UUID()
        func send(_ t: FakeTransaction, local: Bool = false) -> Bool {
            let f = AdPurchaseFact(t, kind: .lifetime, localPurchase: local, installToken: mine)
            return AdEvents.shouldSend(f, now: fixedNow, alreadySent: [])
        }
        #expect(send(FakeTransaction(appAccountToken: mine)))
        #expect(send(FakeTransaction(appAccountToken: other)) == false)   // the buyer's second device
        #expect(send(FakeTransaction(appAccountToken: nil)) == false)     // offer code, or a build without the token
        #expect(send(FakeTransaction(appAccountToken: other), local: true))   // made in this process
    }

    @Test("The install token is made once and kept")
    func installTokenIsStable() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AdEvents.installAccountToken(defaults: defaults)
        #expect(AdEvents.installAccountToken(defaults: defaults) == first)
        #expect(defaults.string(forKey: AdEvents.installTokenKey) == first.uuidString)
    }

    // MARK: - Purchases that arrive before the launch decision

    @Test("A purchase that arrives before the launch decision is sent after a start, once")
    func earlyPurchaseIsHeld() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = makeEvents(defaults, sink: sink)
        events.purchased(fact(.monthly, id: 21))
        events.purchased(fact(.monthly, id: 21))         // a replay while held
        #expect(sink.events.isEmpty)
        #expect(defaults.stringArray(forKey: AdEvents.sentTransactionIDsKey) == nil)   // memory only

        events.apply(AdGateResult(sdksMayStart: true, appleAdsMayRun: true), keys: allKeys)
        #expect(sink.events.count == 1)
        #expect(defaults.stringArray(forKey: AdEvents.sentTransactionIDsKey) == ["21"])
    }

    @Test("A held purchase is forgotten when the gate is closed; a later yes does not send it")
    func earlyPurchaseDroppedOnClosedGate() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = makeEvents(defaults, sink: sink)
        events.purchased(fact(id: 31))
        events.apply(AdGateResult(sdksMayStart: false, appleAdsMayRun: true), keys: allKeys)
        events.apply(AdGateResult(sdksMayStart: true, appleAdsMayRun: true), keys: allKeys)
        #expect(sink.events.isEmpty)
    }

    @Test("A held purchase that is older than 24 hours at the start is not sent")
    func earlyPurchaseKeepsFreshnessRule() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        var clock = fixedNow
        let events = AdEvents(defaults: defaults, now: { clock }, makeSinks: { _ in [sink] })
        events.purchased(fact(id: 41, age: 60))
        clock = fixedNow.addingTimeInterval(AdEvents.freshness + 120)
        events.apply(AdGateResult(sdksMayStart: true, appleAdsMayRun: true), keys: allKeys)
        #expect(sink.events.isEmpty)
    }

    @Test("At most pendingCap purchases are held")
    func pendingIsCapped() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = makeEvents(defaults, sink: sink)
        for id in 1...(AdEvents.pendingCap + 5) { events.purchased(fact(id: UInt64(id))) }
        events.apply(AdGateResult(sdksMayStart: true, appleAdsMayRun: true), keys: allKeys)
        #expect(sink.events.count == AdEvents.pendingCap)
    }

    // MARK: - What each network receives

    @Test("Event names per network")
    func eventMap() {
        let monthly = AdPurchase(kind: .monthly, price: 2.99, currencyCode: "USD", storeKitTransaction: nil)
        let lifetime = AdPurchase(kind: .lifetime, price: 9.99, currencyCode: "USD", storeKitTransaction: nil)
        #expect(AdEventMap.meta(.paywallShown) == .viewedContent)
        #expect(AdEventMap.meta(.checkoutStarted(monthly)) == .subscribeInitiatedCheckout)
        #expect(AdEventMap.meta(.checkoutStarted(lifetime)) == .initiatedCheckout)
        #expect(AdEventMap.meta(.subscribed(monthly)) == .subscribe)
        #expect(AdEventMap.meta(.lifetimePurchased(lifetime)) == .purchase)

        #expect(AdEventMap.firebase(.paywallShown) == .viewItem)
        #expect(AdEventMap.firebase(.checkoutStarted(monthly)) == .beginCheckout)
        #expect(AdEventMap.firebase(.subscribed(monthly)) == .purchase)       // no StoreKit transaction in a test
        #expect(AdEventMap.firebase(.lifetimePurchased(lifetime)) == .purchase)

        #expect(AdEventMap.tiktok(.paywallShown) == "ViewContent")
        #expect(AdEventMap.tiktok(.checkoutStarted(monthly)) == "Checkout")
        #expect(AdEventMap.tiktok(.subscribed(monthly)) == "Subscribe")
        #expect(AdEventMap.tiktok(.lifetimePurchased(lifetime)) == "Purchase")
    }

    // MARK: - TikTok sink

    @MainActor
    final class TikTokHookLog {
        var calls: [String] = []
        var tracked: [(String, [String: Any])] = []
        var hooks: TikTokHooks {
            TikTokHooks(
                initialize: { [self] _, _ in calls.append("initialize"); return true },
                setTrackingEnabled: { [self] on in calls.append("tracking:\(on)") },
                track: { [self] name, props in tracked.append((name, props)) }
            )
        }
    }

    @Test("TikTok: value goes as a string with the currency; a start initializes once")
    func tiktokSinkSends() {
        let log = TikTokHookLog()
        let sink = TikTokAdSink(hooks: log.hooks)
        sink.start(keys: allKeys)
        sink.start(keys: allKeys)
        #expect(log.calls == ["initialize"])
        sink.send(.lifetimePurchased(AdPurchase(kind: .lifetime, price: Decimal(string: "9.99"), currencyCode: "USD", storeKitTransaction: nil)))
        sink.send(.paywallShown)
        #expect(log.tracked.map(\.0) == ["Purchase", "ViewContent"])
        #expect(log.tracked[0].1["value"] as? String == "9.99")
        #expect(log.tracked[0].1["currency"] as? String == "USD")
        #expect(log.tracked[1].1.isEmpty)
    }

    @Test("TikTok: after a no, tracking is not turned on again in the same run, and nothing is sent")
    func tiktokNoIsFinalForTheRun() {
        let log = TikTokHookLog()
        let sink = TikTokAdSink(hooks: log.hooks)
        sink.start(keys: allKeys)
        sink.stop()
        #expect(log.calls == ["initialize", "tracking:false"])
        sink.start(keys: allKeys)                       // a yes in Settings in the same run
        sink.send(.paywallShown)
        #expect(log.calls == ["initialize", "tracking:false"])   // never "tracking:true"
        #expect(log.tracked.isEmpty)
    }

    @Test("TikTok: no keys, nothing happens")
    func tiktokNeedsKeys() {
        let log = TikTokHookLog()
        let sink = TikTokAdSink(hooks: log.hooks)
        var keys = allKeys
        keys.tiktokAppleAppID = nil
        sink.start(keys: keys)
        sink.send(.paywallShown)
        sink.stop()
        #expect(log.calls.isEmpty)
        #expect(log.tracked.isEmpty)
    }

    // MARK: - Firebase plist

    @Test("A GoogleService-Info.plist needs the bundle id and the four ids FirebaseApp.configure() reads")
    func firebasePlistChecks() {
        let good: [String: Any] = ["BUNDLE_ID": "com.cloudfull.app", "GOOGLE_APP_ID": "1:1:ios:a", "API_KEY": "k",
                                   "GCM_SENDER_ID": "1", "PROJECT_ID": "p"]
        #expect(AdKeys.firebaseConfigIsValid(good as NSDictionary))
        for missing in ["BUNDLE_ID", "GOOGLE_APP_ID", "API_KEY", "GCM_SENDER_ID", "PROJECT_ID"] {
            var broken = good
            broken[missing] = nil
            #expect(AdKeys.firebaseConfigIsValid(broken as NSDictionary) == false, "missing \(missing)")
            broken[missing] = "  "
            #expect(AdKeys.firebaseConfigIsValid(broken as NSDictionary) == false, "blank \(missing)")
        }
        var otherApp = good
        otherApp["BUNDLE_ID"] = "com.example.other"
        #expect(AdKeys.firebaseConfigIsValid(otherApp as NSDictionary) == false)
    }

    // MARK: - Lifecycle

    @Test("Nothing is sent and nothing is written before apply")
    func nothingBeforeApply() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = makeEvents(defaults, sink: sink)
        #expect(events.isSending == false)
        events.paywallShown()
        events.checkoutStarted(.lifetime, price: 9, currencyCode: "USD")
        events.purchased(fact())
        #expect(sink.events.isEmpty)
        #expect(sink.started.isEmpty)
        #expect(defaults.stringArray(forKey: AdEvents.sentTransactionIDsKey) == nil)
    }

    @Test("A closed gate starts nothing and stops nothing")
    func closedGate() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = makeEvents(defaults, sink: sink)
        events.apply(AdGateResult(sdksMayStart: false, appleAdsMayRun: true), keys: allKeys)
        #expect(sink.started.isEmpty)
        #expect(sink.stops == 0)
        #expect(events.isSending == false)
    }

    @Test("A later no stops new events and writes nothing; a purchase made while stopped is never sent later")
    func laterNoStops() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = sendingEvents(defaults, sink: sink)
        #expect(sink.started == [allKeys])
        events.purchased(fact(id: 1))
        #expect(sink.events.count == 1)

        events.apply(AdGateResult(sdksMayStart: false, appleAdsMayRun: true), keys: allKeys)
        #expect(sink.stops == 1)
        #expect(events.isSending == false)

        events.paywallShown()
        events.purchased(fact(id: 2))
        #expect(sink.events.count == 1)
        #expect(defaults.stringArray(forKey: AdEvents.sentTransactionIDsKey) == ["1"])

        // A second stop does not stop twice.
        events.apply(AdGateResult(sdksMayStart: false, appleAdsMayRun: true), keys: allKeys)
        #expect(sink.stops == 1)

        // Id 2 was never recorded, and a later yes does not queue it: only new events go out.
        events.apply(AdGateResult(sdksMayStart: true, appleAdsMayRun: true), keys: allKeys)
        #expect(sink.started.count == 2)
        #expect(sink.events.count == 1)
        events.paywallShown()
        #expect(sink.events.count == 2)
    }

    @Test("makeSinks runs once, however many starts follow")
    func sinksMadeOnce() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        var made = 0
        let events = AdEvents(defaults: defaults, now: { fixedNow }, makeSinks: { _ in made += 1; return [sink] })
        let open = AdGateResult(sdksMayStart: true, appleAdsMayRun: true)
        events.apply(open, keys: allKeys)
        events.apply(open, keys: allKeys)
        #expect(made == 1)
    }

    @Test("consentDidChange does nothing before the launch has produced an input")
    func consentBeforeLaunch() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = makeEvents(defaults, sink: sink)
        events.consentDidChange()
        #expect(sink.started.isEmpty)
        #expect(events.isSending == false)
    }

    @Test("A later answer in Settings reaches the facade: no stops new events, yes starts them again")
    func consentDidChangeAppliesAnswer() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sink = FakeAdSink()
        let events = makeEvents(defaults, sink: sink)
        var answer = AdConsentAnswer.yes
        events.consentAnswer = { answer }
        var input = goodInput()
        input.region = .required
        input.consent = .yes
        events.recordLaunch(input, keys: allKeys)
        events.consentDidChange()
        #expect(events.isSending)
        events.paywallShown()
        #expect(sink.events.count == 1)

        answer = .no
        events.consentDidChange()
        #expect(events.isSending == false)
        #expect(sink.stops == 1)
        events.paywallShown()
        #expect(sink.events.count == 1)

        answer = .yes
        events.consentDidChange()
        #expect(events.isSending)
    }

    // MARK: - EEA consent and Google

    @Test("EEA with a yes: the gate opens, the sinks start, and Google receives the consent before any event")
    func eeaYesStartsAndGrantsGoogle() {
        var input = goodInput()
        input.region = .required
        input.consent = .yes
        let result = AdGate.evaluate(input)
        #expect(result.sdksMayStart)

        let log = FirebaseHookLog()
        let firebase = FirebaseAdSink(hooks: log.hooks)
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let events = AdEvents(defaults: defaults, now: { fixedNow }, makeSinks: { _ in [firebase] })
        events.apply(result, keys: allKeys)

        #expect(events.isSending)
        #expect(log.calls == ["configure", "consent:true", "collection:true"])
    }

    @Test("EEA without a yes: the gate stays shut and Google is never configured")
    func eeaNoYesStaysOff() {
        for consent in [AdConsentAnswer.notAsked, .no] {
            var input = goodInput()
            input.region = .required
            input.consent = consent
            let result = AdGate.evaluate(input)
            #expect(result.sdksMayStart == false)

            let log = FirebaseHookLog()
            let firebase = FirebaseAdSink(hooks: log.hooks)
            let (defaults, name) = makeSuite()
            defer { defaults.removePersistentDomain(forName: name) }
            let events = AdEvents(defaults: defaults, now: { fixedNow }, makeSinks: { _ in [firebase] })
            events.apply(result, keys: allKeys)
            #expect(log.calls.isEmpty)
        }
    }

    @Test("A later no denies Google's consent and stops collection")
    func laterNoDeniesGoogle() {
        let log = FirebaseHookLog()
        let firebase = FirebaseAdSink(hooks: log.hooks)
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let events = AdEvents(defaults: defaults, now: { fixedNow }, makeSinks: { _ in [firebase] })
        events.apply(AdGateResult(sdksMayStart: true, appleAdsMayRun: true), keys: allKeys)
        events.apply(AdGateResult(sdksMayStart: false, appleAdsMayRun: true), keys: allKeys)
        #expect(log.calls == ["configure", "consent:true", "collection:true", "consent:false", "collection:false"])

        // A new yes grants again and does not configure twice (a second configure() would crash).
        events.apply(AdGateResult(sdksMayStart: true, appleAdsMayRun: true), keys: allKeys)
        #expect(log.calls.filter { $0 == "configure" }.count == 1)
        #expect(log.calls.suffix(2) == ["consent:true", "collection:true"])
    }

    @Test("The Firebase sink does nothing without a valid GoogleService-Info.plist")
    func firebaseNeedsConfig() {
        let log = FirebaseHookLog()
        let firebase = FirebaseAdSink(hooks: log.hooks)
        var keys = allKeys
        keys.hasFirebaseConfig = false
        firebase.start(keys: keys)
        firebase.stop()
        #expect(log.calls.isEmpty)
    }
}

/// Gives the test target a class to anchor `Bundle(for:)` on.
private final class FakeAdSinkAnchor {}
