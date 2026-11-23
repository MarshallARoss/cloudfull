//
//  AdConversionValueTests.swift
//  CloudfullTests
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
@testable import Cloudfull

/// Records the calls the app would make to Apple. The live type is never used in the test host.
final class FakeConversionUpdater: AdConversionUpdating, @unchecked Sendable {
    var calls: [AdConversionValue] = []
    /// The `lockWindow` flag of each call, in the same order as `calls`.
    var locks: [Bool] = []
    func update(_ value: AdConversionValue, lockWindow: Bool) {
        calls.append(value)
        locks.append(lockWindow)
    }
}

@Suite("AdConversionValueTests", .serialized)
@MainActor
struct AdConversionValueTests {

    // MARK: - Fixtures

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let allKeys = AdKeys(metaAppID: "1", metaClientToken: "t", tiktokAppID: "2", tiktokAccessToken: "a",
                                 hasFirebaseConfig: true, tiktokAppleAppID: "3")
    private var noMetaKeys: AdKeys {
        var keys = allKeys
        keys.metaAppID = nil
        keys.metaClientToken = nil
        return keys
    }

    private func makeSuite() -> (UserDefaults, String) {
        let name = "AdConversionValueTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func makeEvents(_ defaults: UserDefaults, updater: FakeConversionUpdater) -> AdEvents {
        AdEvents(defaults: defaults, now: { fixedNow }, makeSinks: { _ in [FakeAdSink()] },
                 conversionUpdater: updater)
    }

    private func goodInput() -> AdGateInput {
        AdGateInput(
            isReleaseBuild: true, isOfficialBuild: true, isSimulator: false, isRunningTests: false,
            debugOverride: false, hasAnyKeys: true,
            appTransaction: AppTransactionFacts(environment: .production, originalAppVersion: "1.1",
                                                originalPurchaseDate: nil, isVerified: true),
            regionAllowsSDKs: true
        )
    }

    private func launch(_ events: AdEvents, keys: AdKeys, region: Bool, input: AdGateInput? = nil) async {
        var base = input ?? goodInput()
        let transaction = base.appTransaction
        base.appTransaction = nil
        base.regionAllowsSDKs = false
        await events.launch(input: base, keys: keys,
                            appTransaction: { transaction },
                            region: { region ? .allowed : .off },
                            regionChanges: { AsyncStream { $0.finish() } },
                            startAppleAds: {})
    }

    private func fact(_ kind: Usage.PurchaseProduct = .lifetime, id: UInt64 = 1, age: TimeInterval = 60,
                      purchase: Bool = true, revoked: Bool = false, family: Bool = false,
                      upgraded: Bool = false, thisInstall: Bool = true) -> AdPurchaseFact {
        AdPurchaseFact(kind: kind, transactionID: id, purchaseDate: fixedNow.addingTimeInterval(-age),
                       price: Decimal(string: "9.99"), currencyCode: "USD", isPurchaseReason: purchase,
                       isRevoked: revoked, isFamilyShared: family, isUpgraded: upgraded,
                       isFromThisInstall: thisInstall)
    }

    private let registered = AdConversionValue(fine: 0, coarse: .low)

    // MARK: - Writer choice

    @Test("Writer choice table: Meta started, no production, no Meta key, off region")
    func writerChoice() {
        let open = AdGateResult(sdksMayStart: true, appleAdsMayRun: true)
        let offRegion = AdGateResult(sdksMayStart: false, appleAdsMayRun: true)
        let closed = AdGateResult(sdksMayStart: false, appleAdsMayRun: false)
        #expect(AdConversionWriter.appIsWriter(open, keys: allKeys) == false)
        #expect(AdConversionWriter.appIsWriter(open, keys: noMetaKeys) == true)
        #expect(AdConversionWriter.appIsWriter(offRegion, keys: allKeys) == true)
        #expect(AdConversionWriter.appIsWriter(offRegion, keys: noMetaKeys) == true)
        #expect(AdConversionWriter.appIsWriter(closed, keys: allKeys) == false)
        #expect(AdConversionWriter.appIsWriter(closed, keys: noMetaKeys) == false)
    }

    @Test("Launch: Meta starts, so the app does not write")
    func metaIsTheWriter() async {
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        await launch(events, keys: allKeys, region: true)
        #expect(events.isSending)
        #expect(events.appIsWriter == false)
        #expect(updater.calls.isEmpty)
        events.purchased(fact(.monthly))
        #expect(updater.calls.isEmpty)
    }

    @Test("Launch: an off region in production registers once with fine 0 and coarse low")
    func offRegionRegisters() async {
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        await launch(events, keys: allKeys, region: false)
        #expect(events.isSending == false)
        #expect(events.appIsWriter)
        #expect(updater.calls == [registered])
        #expect(updater.locks == [false])
    }

    @Test("Launch: an allowed region with no Meta key registers too")
    func noMetaKeyRegisters() async {
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        await launch(events, keys: noMetaKeys, region: true)
        #expect(events.appIsWriter)
        #expect(updater.calls == [registered])
    }

    @Test("Launch: without the production conditions nobody writes")
    func noProductionNoWrite() async {
        var simulator = goodInput()
        simulator.isSimulator = true
        var tests = goodInput()
        tests.isRunningTests = true
        var fork = goodInput()
        fork.isOfficialBuild = false
        var debug = goodInput()
        debug.isReleaseBuild = false
        var unverified = goodInput()
        unverified.appTransaction = AppTransactionFacts(environment: .sandbox, originalAppVersion: "1.1",
                                                        originalPurchaseDate: nil, isVerified: true)
        for input in [simulator, tests, fork, debug, unverified] {
            let (defaults, _) = makeSuite()
            let updater = FakeConversionUpdater()
            let events = makeEvents(defaults, updater: updater)
            await launch(events, keys: allKeys, region: false, input: input)
            #expect(events.appIsWriter == false)
            #expect(updater.calls.isEmpty)
            events.purchased(fact())
            #expect(updater.calls.isEmpty)
        }
    }

    @Test("The debug argument waives Release and AppTransaction, so the app writes in Debug")
    func debugOverrideWrites() async {
        var input = goodInput()
        input.isReleaseBuild = false
        input.debugOverride = true
        input.appTransaction = nil
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        await launch(events, keys: allKeys, region: false, input: input)
        #expect(updater.calls == [registered])
    }

    @Test("The test host: an AdEvents with no updater never writes, even in an open gate")
    func noUpdaterNoWrite() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let events = AdEvents(defaults: defaults, now: { fixedNow }, makeSinks: { _ in [] })
        events.apply(AdGateResult(sdksMayStart: false, appleAdsMayRun: true), keys: allKeys)
        #expect(events.appIsWriter == false)
        #expect(defaults.object(forKey: AdConversionWriter.factsKey) == nil)
    }

    // MARK: - The table

    private func v(_ fine: Int, _ coarse: AdCoarseValue) -> AdConversionValue {
        AdConversionValue(fine: fine, coarse: coarse)
    }

    @Test("Two bits: monthly is 1, lifetime is 2; paywall and checkout set nothing")
    func bits() {
        #expect(AdFacts.subscribed.rawValue == 1)
        #expect(AdFacts.lifetimePurchased.rawValue == 2)
        let purchase = AdPurchase(kind: .monthly, price: nil, currencyCode: nil, storeKitTransaction: nil)
        #expect(AdConversionSchema.fact(for: .paywallShown) == nil)
        #expect(AdConversionSchema.fact(for: .checkoutStarted(purchase)) == nil)
        #expect(AdConversionSchema.fact(for: .subscribed(purchase)) == .subscribed)
        #expect(AdConversionSchema.fact(for: .lifetimePurchased(purchase)) == .lifetimePurchased)
    }

    @Test("The final table: fine 0 to 3 with coarse low, medium, high")
    func finalTable() {
        #expect(AdConversionSchema.value(for: []) == v(0, .low))
        #expect(AdConversionSchema.value(for: [.subscribed]) == v(1, .medium))
        #expect(AdConversionSchema.value(for: [.lifetimePurchased]) == v(2, .high))
        #expect(AdConversionSchema.value(for: [.subscribed, .lifetimePurchased]) == v(3, .high))
    }

    @Test("Only the lifetime fact locks the window")
    func lockRule() {
        #expect(AdConversionSchema.locksWindow(for: .lifetimePurchased) == true)
        #expect(AdConversionSchema.locksWindow(for: .subscribed) == false)
    }

    // MARK: - Stored state

    @Test("A later launch repeats the stored value")
    func laterLaunchRepeats() async {
        let (defaults, _) = makeSuite()
        let first = FakeConversionUpdater()
        await launch(makeEvents(defaults, updater: first), keys: allKeys, region: false)
        #expect(first.calls == [registered])

        defaults.set(3, forKey: AdConversionWriter.factsKey)
        let second = FakeConversionUpdater()
        await launch(makeEvents(defaults, updater: second), keys: allKeys, region: false)
        #expect(second.calls == [v(3, .high)])
        #expect(second.locks == [false])
    }

    @Test("A stored value with unknown high bits reads only the two known bits")
    func unknownBitsIgnored() async {
        let (defaults, _) = makeSuite()
        defaults.set(0b110000 | 1, forKey: AdConversionWriter.factsKey)
        let updater = FakeConversionUpdater()
        await launch(makeEvents(defaults, updater: updater), keys: allKeys, region: false)
        #expect(updater.calls == [v(1, .medium)])
    }

    // MARK: - Facts

    @Test("Paywall shown and purchase started feed nothing: no call, no stored bit")
    func paywallAndCheckoutFeedNothing() async {
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        await launch(events, keys: allKeys, region: false)
        events.paywallShown()
        events.checkoutStarted(.monthly, price: 3, currencyCode: "USD")
        events.checkoutStarted(.lifetime, price: 9, currencyCode: "USD")
        #expect(updater.calls == [registered])
        #expect(defaults.object(forKey: AdConversionWriter.factsKey) == nil)
    }

    @Test("Monthly bought: fine 1, coarse medium, window open. Lifetime bought: fine 2, coarse high, window locked")
    func singleFacts() async {
        let cases: [(String, Usage.PurchaseProduct, AdConversionValue, Bool)] = [
            ("monthly", .monthly, v(1, .medium), false),
            ("lifetime", .lifetime, v(2, .high), true),
        ]
        for (name, kind, expected, lock) in cases {
            let (defaults, _) = makeSuite()
            let updater = FakeConversionUpdater()
            let events = makeEvents(defaults, updater: updater)
            await launch(events, keys: allKeys, region: false)
            events.purchased(fact(kind, id: 1))
            #expect(updater.calls == [registered, expected], Comment(rawValue: name))
            #expect(updater.locks == [false, lock], Comment(rawValue: name))
        }
    }

    @Test("Both plans: monthly then lifetime gives 1 then 3, locked on the lifetime call only")
    func monthlyThenLifetime() async {
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        await launch(events, keys: allKeys, region: false)
        events.paywallShown()
        events.checkoutStarted(.lifetime, price: 9, currencyCode: "USD")
        events.purchased(fact(.monthly, id: 1))
        events.purchased(fact(.lifetime, id: 2))
        #expect(updater.calls == [registered, v(1, .medium), v(3, .high)])
        #expect(updater.locks == [false, false, true])
        #expect(defaults.integer(forKey: AdConversionWriter.factsKey) == 3)
    }

    @Test("Order does not matter: lifetime then monthly gives 2 then 3, and only the lifetime call locks")
    func lifetimeThenMonthly() async {
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        await launch(events, keys: allKeys, region: false)
        events.purchased(fact(.lifetime, id: 1))
        events.purchased(fact(.monthly, id: 2))
        #expect(updater.calls == [registered, v(2, .high), v(3, .high)])
        #expect(updater.locks == [false, true, false])
    }

    @Test("A repeated fact makes no second call; the value never goes down")
    func repeatedFact() async {
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        await launch(events, keys: allKeys, region: false)
        events.purchased(fact(.monthly, id: 1))
        let count = updater.calls.count
        events.paywallShown()
        events.purchased(fact(.monthly, id: 2))     // a second monthly sale: same bit
        #expect(updater.calls.count == count)
        #expect(updater.calls.last == v(1, .medium))
    }

    @Test("A restore, renewal, refund, family share, other-device and repeated transaction set no bit")
    func nonSalesSetNoBit() async {
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        await launch(events, keys: allKeys, region: false)
        events.purchased(fact(.monthly, id: 1, purchase: false))      // restore or renewal
        events.purchased(fact(.monthly, id: 2, revoked: true))        // refund
        events.purchased(fact(.monthly, id: 3, family: true))         // family share
        events.purchased(fact(.monthly, id: 4, upgraded: true))       // upgraded
        events.purchased(fact(.monthly, id: 5, age: 3 * 24 * 3600))   // stale replay
        events.purchased(fact(.lifetime, id: 6, thisInstall: false))  // another device
        #expect(updater.calls == [registered])
        #expect(defaults.integer(forKey: AdConversionWriter.factsKey) == 0)

        events.purchased(fact(.lifetime, id: 8))
        #expect(updater.calls == [registered, v(2, .high)])
        events.purchased(fact(.lifetime, id: 8))                       // the same transaction again
        #expect(updater.calls.count == 2)
    }

    @Test("A purchase held before the launch decision is written after it, once")
    func heldPurchaseWrites() async {
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        events.purchased(fact(.monthly, id: 1))
        #expect(updater.calls.isEmpty)
        await launch(events, keys: allKeys, region: false)
        #expect(updater.calls == [registered, v(1, .medium)])
    }

    @Test("With Meta as writer no call reaches Apple, but the purchase is stored")
    func metaWriterStoresFactsOnly() async {
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        await launch(events, keys: allKeys, region: true)
        events.paywallShown()
        events.checkoutStarted(.lifetime, price: 9, currencyCode: "USD")
        #expect(defaults.object(forKey: AdConversionWriter.factsKey) == nil)   // paywall and checkout set nothing
        events.purchased(fact(.lifetime, id: 1))
        #expect(updater.calls.isEmpty)
        #expect(defaults.integer(forKey: AdConversionWriter.factsKey) == 2)
    }

    @Test("A value Meta wrote is not lowered when the app becomes the writer in a later launch")
    func laterAppLaunchKeepsMetaPurchase() async {
        let (defaults, _) = makeSuite()
        let metaUpdater = FakeConversionUpdater()
        let first = makeEvents(defaults, updater: metaUpdater)
        await launch(first, keys: allKeys, region: true)      // day 0: Meta writes
        first.purchased(fact(.lifetime, id: 1))

        let appUpdater = FakeConversionUpdater()
        let later = makeEvents(defaults, updater: appUpdater)
        await launch(later, keys: allKeys, region: false)     // day 1: the device region is now off
        #expect(appUpdater.calls == [v(2, .high)])            // not 0 / low
    }

    @Test("A build with no Meta key writes facts too")
    func noMetaKeyWritesFacts() async {
        let (defaults, _) = makeSuite()
        let updater = FakeConversionUpdater()
        let events = makeEvents(defaults, updater: updater)
        await launch(events, keys: noMetaKeys, region: true)
        events.purchased(fact(.monthly, id: 1))
        #expect(updater.calls == [registered, v(1, .medium)])
    }
}
