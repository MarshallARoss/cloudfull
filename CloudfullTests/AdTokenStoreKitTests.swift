//
//  AdTokenStoreKitTests.swift
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

/// The "this install" mark, proved with real StoreKit transactions. The paywall buys with
/// `AdEvents.purchaseOptions()`; these tests buy with the same set through `SKTestSession` and read
/// the verified transaction back.
///
/// These tests are part of `EntitlementsStoreKitTests` (an extension), so they share its
/// `.serialized` trait. Both groups use the simulator's one StoreKit store. Two separate suites
/// run in parallel in Swift Testing, and one cleared the store under the other.
extension EntitlementsStoreKitTests {
    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "AdTokenStoreKitTests.\(UUID().uuidString)")!
    }

    private func makeEvents(_ defaults: UserDefaults, sink: FakeAdSink) -> AdEvents {
        let events = AdEvents(defaults: defaults, now: { Date() }, makeSinks: { _ in [sink] })
        events.apply(AdGateResult(sdksMayStart: true, appleAdsMayRun: true),
                     keys: AdKeys(metaAppID: "1", metaClientToken: "t", tiktokAppID: nil, tiktokAccessToken: nil,
                                  hasFirebaseConfig: false))
        return events
    }

    /// Buys `productID` and returns the verified transaction StoreKit Test made.
    private func buy(_ productID: String, options: Set<Product.PurchaseOption>) async throws -> Transaction {
        try await session.buyProduct(identifier: productID, options: options)
    }

    @Test("Monthly bought with the paywall's options carries the install token and counts as this install")
    func monthlyCarriesToken() async throws {
        defer { tearDown() }
        let defaults = makeSuite()
        let token = AdEvents.installAccountToken(defaults: defaults)
        let transaction = try await buy(StoreProducts.monthly, options: AdEvents.purchaseOptions(defaults: defaults))
        #expect(transaction.appAccountToken == token)

        let fact = AdPurchaseFact(transaction, kind: .monthly, installToken: token)
        #expect(fact.isFromThisInstall)
        #expect(fact.isPurchaseReason)
        #expect(AdEvents.shouldSend(fact, now: Date(), alreadySent: []))

        let sink = FakeAdSink()
        let events = makeEvents(defaults, sink: sink)
        events.purchased(fact)
        #expect(sink.events.count == 1)
        if case .subscribed(let purchase)? = sink.events.first {
            #expect(purchase.kind == .monthly)
        } else {
            Issue.record("Expected a subscribed event, got \(sink.events)")
        }
    }

    @Test("Lifetime bought with the paywall's options carries the install token and counts as this install")
    func lifetimeCarriesToken() async throws {
        defer { tearDown() }
        let defaults = makeSuite()
        let token = AdEvents.installAccountToken(defaults: defaults)
        let transaction = try await buy(StoreProducts.lifetime, options: AdEvents.purchaseOptions(defaults: defaults))
        #expect(transaction.appAccountToken == token)

        let fact = AdPurchaseFact(transaction, kind: .lifetime, installToken: token)
        #expect(fact.isFromThisInstall)
        #expect(AdEvents.shouldSend(fact, now: Date(), alreadySent: []))

        let sink = FakeAdSink()
        let events = makeEvents(defaults, sink: sink)
        events.purchased(fact)
        #expect(sink.events.count == 1)
        if case .lifetimePurchased(let purchase)? = sink.events.first {
            #expect(purchase.kind == .lifetime)
        } else {
            Issue.record("Expected a lifetimePurchased event, got \(sink.events)")
        }
    }

    @Test("A purchase with no token is not this install: no fact counts, nothing is sent")
    func noTokenIsNotThisInstall() async throws {
        defer { tearDown() }
        let defaults = makeSuite()
        let token = AdEvents.installAccountToken(defaults: defaults)
        for productID in [StoreProducts.monthly, StoreProducts.lifetime] {
            let transaction = try await buy(productID, options: [])
            #expect(transaction.appAccountToken == nil)
            let kind: Usage.PurchaseProduct = productID == StoreProducts.monthly ? .monthly : .lifetime
            let fact = AdPurchaseFact(transaction, kind: kind, installToken: token)
            #expect(!fact.isFromThisInstall)
            #expect(!AdEvents.shouldSend(fact, now: Date(), alreadySent: []))

            let sink = FakeAdSink()
            makeEvents(defaults, sink: sink).purchased(fact)
            #expect(sink.events.isEmpty)
        }
    }

    @Test("A purchase that carries another install's token is not this install")
    func otherInstallToken() async throws {
        defer { tearDown() }
        let otherDevice = makeSuite()
        let thisDevice = makeSuite()
        let transaction = try await buy(StoreProducts.lifetime, options: AdEvents.purchaseOptions(defaults: otherDevice))
        let fact = AdPurchaseFact(transaction, kind: .lifetime, installToken: AdEvents.installAccountToken(defaults: thisDevice))
        #expect(!fact.isFromThisInstall)
        #expect(!AdEvents.shouldSend(fact, now: Date(), alreadySent: []))
    }
}
