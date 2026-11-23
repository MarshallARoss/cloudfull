//
//  AdLateStartTests.swift
//  CloudfullTests
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
@testable import Cloudfull

/// Lets a test answer the region question later and tick the storefront-change stream.
@MainActor
final class RegionProbe {
    var decision: AdRegion.Decision = .unknown
    private var continuation: AsyncStream<Void>.Continuation?

    func changes() -> AsyncStream<Void> {
        AsyncStream { self.continuation = $0 }
    }

    func tick(_ next: AdRegion.Decision) {
        decision = next
        continuation?.yield()
    }
}

/// An unknown storefront at launch: the SDKs wait for it and start late, and the events
/// TikTok's SDK no longer logs by itself are logged by the app, once each.
@Suite("AdLateStartTests", .serialized)
@MainActor
struct AdLateStartTests {

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let allKeys = AdKeys(metaAppID: "1", metaClientToken: "t", tiktokAppID: "2", tiktokAccessToken: "a",
                                 hasFirebaseConfig: true, tiktokAppleAppID: "3")
    private var noMetaKeys: AdKeys {
        var keys = allKeys
        keys.metaAppID = nil
        keys.metaClientToken = nil
        return keys
    }

    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "AdLateStartTests.\(UUID().uuidString)")!
    }

    private func goodInput() -> AdGateInput {
        AdGateInput(
            isReleaseBuild: true, isOfficialBuild: true, isSimulator: false, isRunningTests: false,
            debugOverride: false, hasAnyKeys: true, appTransaction: nil, regionAllowsSDKs: false
        )
    }

    private let production = AppTransactionFacts(environment: .production, originalAppVersion: "1.1",
                                                 originalPurchaseDate: nil, isVerified: true)

    private func fact(_ kind: Usage.PurchaseProduct = .lifetime, id: UInt64 = 1) -> AdPurchaseFact {
        AdPurchaseFact(kind: kind, transactionID: id, purchaseDate: fixedNow.addingTimeInterval(-60),
                       price: Decimal(string: "9.99"), currencyCode: "USD")
    }

    /// Starts `launch` in a task and waits until it is waiting for the storefront.
    private func startWaiting(_ events: AdEvents, probe: RegionProbe, keys: AdKeys) async -> Task<Void, Never> {
        let production = production
        let task = Task { @MainActor in
            await events.launch(input: goodInput(), keys: keys,
                                appTransaction: { production },
                                region: { probe.decision },
                                regionChanges: { probe.changes() },
                                startAppleAds: {})
        }
        for _ in 0..<2000 where !events.waitingForRegion { await Task.yield() }
        return task
    }

    // MARK: - Late start

    @Test("Unknown storefront, then allowed: nothing starts at first, the held purchase is sent once after the start")
    func lateStartAllowed() async {
        let defaults = makeSuite()
        let sink = FakeAdSink()
        let events = AdEvents(defaults: defaults, now: { fixedNow }, makeSinks: { _ in [sink] })
        let probe = RegionProbe()
        let task = await startWaiting(events, probe: probe, keys: allKeys)
        #expect(events.waitingForRegion)
        #expect(sink.started.isEmpty)
        events.purchased(fact(.monthly, id: 7))
        #expect(sink.events.isEmpty)

        probe.tick(.allowed)
        await task.value
        #expect(sink.started == [allKeys])
        #expect(events.isSending)
        #expect(!events.waitingForRegion)
        #expect(sink.events.count == 1)
        guard case .subscribed(let purchase)? = sink.events.first else {
            Issue.record("Expected one subscribed event, got \(sink.events)")
            return
        }
        #expect(purchase.kind == .monthly)
        events.purchased(fact(.monthly, id: 7))     // the same transaction again
        #expect(sink.events.count == 1)
    }

    @Test("An answer that is still unknown keeps waiting; the next known answer starts the sinks")
    func stillUnknownKeepsWaiting() async {
        let sink = FakeAdSink()
        let events = AdEvents(defaults: makeSuite(), now: { fixedNow }, makeSinks: { _ in [sink] })
        let probe = RegionProbe()
        let task = await startWaiting(events, probe: probe, keys: allKeys)
        probe.tick(.unknown)
        for _ in 0..<50 { await Task.yield() }
        #expect(sink.started.isEmpty)
        #expect(events.waitingForRegion)
        probe.tick(.allowed)
        await task.value
        #expect(sink.started.count == 1)
    }

    @Test("Unknown storefront, then an off region: no sink starts, the held purchase is dropped, the referrer is cleared")
    func lateStartOff() async {
        let defaults = makeSuite()
        defaults.set("https://example.com", forKey: "source_url")
        let sink = FakeAdSink()
        let events = AdEvents(defaults: defaults, now: { fixedNow }, makeSinks: { _ in [sink] })
        let probe = RegionProbe()
        let task = await startWaiting(events, probe: probe, keys: allKeys)
        #expect(defaults.string(forKey: "source_url") == "https://example.com")   // not cleared while waiting
        events.purchased(fact(.lifetime, id: 3))

        probe.tick(.off)
        await task.value
        #expect(sink.started.isEmpty)
        #expect(sink.events.isEmpty)
        #expect(!events.isSending)
        #expect(defaults.object(forKey: "source_url") == nil)
        events.purchased(fact(.lifetime, id: 4))    // later purchases are dropped too
        #expect(sink.events.isEmpty)
    }

    @Test("A second late-start call starts no sink again")
    func neverStartsTwice() async {
        let sink = FakeAdSink()
        let events = AdEvents(defaults: makeSuite(), now: { fixedNow }, makeSinks: { _ in [sink] })
        let probe = RegionProbe()
        let task = await startWaiting(events, probe: probe, keys: allKeys)
        probe.tick(.allowed)
        await task.value
        events.startAfterRegionKnown(AdGateResult(sdksMayStart: true, appleAdsMayRun: true), keys: allKeys)
        events.apply(AdGateResult(sdksMayStart: true, appleAdsMayRun: true), keys: allKeys)
        #expect(sink.started.count == 1)
    }

    @Test("Start the SDKs late only when the gate allowed it: an off device region starts nothing and waits for nothing")
    func offDeviceRegionDoesNotWait() async {
        let sink = FakeAdSink()
        let events = AdEvents(defaults: makeSuite(), now: { fixedNow }, makeSinks: { _ in [sink] })
        var asked = false
        await events.launch(input: goodInput(), keys: allKeys,
                            appTransaction: { production },
                            region: { .off },
                            regionChanges: { asked = true; return AsyncStream { _ in } },
                            startAppleAds: {})
        #expect(!asked)
        #expect(!events.waitingForRegion)
        #expect(sink.started.isEmpty)
    }

    @Test("Unknown storefront with no keys waits for nothing")
    func noKeysDoesNotWait() async {
        let events = AdEvents(defaults: makeSuite(), now: { fixedNow }, makeSinks: { _ in [] })
        var asked = false
        let keys = AdKeys(metaAppID: nil, metaClientToken: nil, tiktokAppID: nil, tiktokAccessToken: nil,
                      hasFirebaseConfig: false, tiktokAppleAppID: nil)
        var input = goodInput()
        input.hasAnyKeys = false
        await events.launch(input: input, keys: keys,
                            appTransaction: { production },
                            region: { .unknown },
                            regionChanges: { asked = true; return AsyncStream { _ in } },
                            startAppleAds: {})
        #expect(!asked)
        #expect(!events.waitingForRegion)
    }

    // MARK: - Conversion value writer in the late path

    @Test("Late start with a Meta key: the app does not write while it waits; Meta writes after the start, the app only stores")
    func lateStartMetaTakesOver() async {
        let defaults = makeSuite()
        let updater = FakeConversionUpdater()
        let sink = FakeAdSink()
        let events = AdEvents(defaults: defaults, now: { fixedNow }, makeSinks: { _ in [sink] },
                              conversionUpdater: updater)
        let probe = RegionProbe()
        let task = await startWaiting(events, probe: probe, keys: allKeys)
        #expect(!events.appIsWriter)                      // Meta may still start: a write now could lower its value
        #expect(updater.calls.isEmpty)
        events.purchased(fact(.monthly, id: 1))           // held for the sinks
        #expect(updater.calls.isEmpty)

        probe.tick(.allowed)
        await task.value
        #expect(!events.appIsWriter)                      // Meta's SDK writes from here
        #expect(updater.calls.isEmpty)
        #expect(sink.events.count == 1)                   // the held purchase reached the sinks
        #expect(defaults.integer(forKey: AdConversionWriter.factsKey) == 1)   // stored, no call
        events.purchased(fact(.lifetime, id: 2))
        #expect(updater.calls.isEmpty)                    // the app no longer writes
        #expect(defaults.integer(forKey: AdConversionWriter.factsKey) == 3)
        #expect(sink.events.count == 2)
    }

    @Test("Late off region with a Meta key: the app registers then and counts the held purchase")
    func lateOffWithMetaKeyAppWrites() async {
        let updater = FakeConversionUpdater()
        let events = AdEvents(defaults: makeSuite(), now: { fixedNow }, makeSinks: { _ in [FakeAdSink()] },
                              conversionUpdater: updater)
        let probe = RegionProbe()
        let task = await startWaiting(events, probe: probe, keys: allKeys)
        #expect(updater.calls.isEmpty)
        events.purchased(fact(.lifetime, id: 1))
        probe.tick(.off)
        await task.value
        #expect(events.appIsWriter)
        #expect(updater.calls == [AdConversionValue(fine: 0, coarse: .low), AdConversionValue(fine: 2, coarse: .high)])
        #expect(updater.locks == [false, true])
    }

    @Test("Without a Meta key the app is the writer in the wait and counts a held purchase at once")
    func noMetaKeyCountsHeldPurchaseAtOnce() async {
        let updater = FakeConversionUpdater()
        let events = AdEvents(defaults: makeSuite(), now: { fixedNow }, makeSinks: { _ in [FakeAdSink()] },
                              conversionUpdater: updater)
        let probe = RegionProbe()
        let task = await startWaiting(events, probe: probe, keys: noMetaKeys)
        #expect(updater.calls == [AdConversionValue(fine: 0, coarse: .low)])
        events.purchased(fact(.monthly, id: 1))
        #expect(updater.calls.last == AdConversionValue(fine: 1, coarse: .medium))    // before the region is known
        probe.tick(.allowed)
        await task.value
        #expect(updater.calls.count == 2)                                             // the replay adds no second call
    }

    @Test("Paywall shown and purchase started during the wait reach the sinks after a late start, and are dropped in an off region")
    func funnelEventsHeld() async {
        for (decision, expected) in [(AdRegion.Decision.allowed, 2), (.off, 0)] {
            let sink = FakeAdSink()
            let events = AdEvents(defaults: makeSuite(), now: { fixedNow }, makeSinks: { _ in [sink] })
            let probe = RegionProbe()
            let task = await startWaiting(events, probe: probe, keys: allKeys)
            events.paywallShown()
            events.checkoutStarted(.monthly, price: 2.99, currencyCode: "USD")
            #expect(sink.events.isEmpty)
            probe.tick(decision)
            await task.value
            #expect(sink.events.count == expected)
            if expected == 2 {
                #expect(sink.events.first == .paywallShown)
            }
        }
    }

    @Test("Late start without a Meta key: the app keeps writing; a late off region keeps it writing too")
    func lateStartNoMetaKeyAndOff() async {
        for (decision, keys) in [(AdRegion.Decision.allowed, noMetaKeys), (.off, allKeys)] {
            let updater = FakeConversionUpdater()
            let events = AdEvents(defaults: makeSuite(), now: { fixedNow }, makeSinks: { _ in [FakeAdSink()] },
                                  conversionUpdater: updater)
            let probe = RegionProbe()
            let task = await startWaiting(events, probe: probe, keys: keys)
            probe.tick(decision)
            await task.value
            #expect(events.appIsWriter)
            events.purchased(fact(.lifetime, id: 5))
            #expect(updater.calls == [AdConversionValue(fine: 0, coarse: .low), AdConversionValue(fine: 2, coarse: .high)])
            #expect(updater.locks == [false, true])
        }
    }

    // MARK: - TikTok: the events TikTok no longer logs by itself

    @Test("TikTok automatic events: install once, launch every time, retention once on the next day")
    func tiktokAutomaticEvents() {
        let defaults = makeSuite()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(TikTokAutomaticEvents.due(defaults: defaults, now: day0, calendar: calendar) == ["InstallApp", "LaunchAPP"])
        #expect(TikTokAutomaticEvents.due(defaults: defaults, now: day0.addingTimeInterval(3600), calendar: calendar) == ["LaunchAPP"])
        let day1 = day0.addingTimeInterval(24 * 3600)
        #expect(TikTokAutomaticEvents.due(defaults: defaults, now: day1, calendar: calendar) == ["2Dretention", "LaunchAPP"])
        #expect(TikTokAutomaticEvents.due(defaults: defaults, now: day1.addingTimeInterval(60), calendar: calendar) == ["LaunchAPP"])
        let day3 = day0.addingTimeInterval(3 * 24 * 3600)
        #expect(TikTokAutomaticEvents.due(defaults: defaults, now: day3, calendar: calendar) == ["LaunchAPP"])
    }

    @Test("TikTok retention alone (the foreground check) fires once on day 1")
    func tiktokRetentionOnForeground() {
        let defaults = makeSuite()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!TikTokAutomaticEvents.retentionDue(defaults: defaults, now: day0, calendar: calendar))   // no install mark yet
        _ = TikTokAutomaticEvents.due(defaults: defaults, now: day0, calendar: calendar)
        #expect(!TikTokAutomaticEvents.retentionDue(defaults: defaults, now: day0.addingTimeInterval(60), calendar: calendar))
        let day1 = day0.addingTimeInterval(24 * 3600)
        #expect(TikTokAutomaticEvents.retentionDue(defaults: defaults, now: day1, calendar: calendar))
        #expect(!TikTokAutomaticEvents.retentionDue(defaults: defaults, now: day1.addingTimeInterval(60), calendar: calendar))
        #expect(TikTokAutomaticEvents.due(defaults: defaults, now: day1.addingTimeInterval(120), calendar: calendar) == ["LaunchAPP"])
    }

    @Test("TikTok retention is not logged on day 3, even if the app was closed on day 1")
    func tiktokNoLateRetention() {
        let defaults = makeSuite()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = TikTokAutomaticEvents.due(defaults: defaults, now: day0, calendar: calendar)
        #expect(TikTokAutomaticEvents.due(defaults: defaults, now: day0.addingTimeInterval(3 * 24 * 3600), calendar: calendar) == ["LaunchAPP"])
    }

    @Test("TikTok: one purchase fact reaches TikTok one time, even if StoreKit delivers it twice")
    func tiktokPurchaseOnce() async {
        let defaults = makeSuite()
        let log = AdEventsTests.TikTokHookLog()
        let events = AdEvents(defaults: defaults, now: { fixedNow }, makeSinks: { _ in [TikTokAdSink(hooks: log.hooks)] })
        events.apply(AdGateResult(sdksMayStart: true, appleAdsMayRun: true), keys: allKeys)
        events.purchased(fact(.lifetime, id: 9))
        events.purchased(fact(.lifetime, id: 9))
        #expect(log.tracked.map(\.0) == ["Purchase"])
        #expect(log.tracked.first?.1["value"] as? String == "9.99")
    }
}
