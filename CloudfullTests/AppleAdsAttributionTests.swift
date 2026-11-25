//
//  AppleAdsAttributionTests.swift
//  CloudfullTests
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
@testable import Cloudfull

/// No network, no real wait, no `.shared`, no `UserDefaults.standard`.
/// The transport and the clock are fakes.
final class FakeAdServicesTransport: AdServicesTransport, @unchecked Sendable {
    var token: Result<String, Error> = .success("t")
    var replies: [Result<(status: Int, body: Data), Error>] = []
    var tokens = 0
    var posts = 0
    var postedTokens: [String] = []
    func attributionToken() async throws -> String { tokens += 1; return try token.get() }
    func post(token: String) async throws -> (status: Int, body: Data) {
        defer { posts += 1 }
        postedTokens.append(token)
        // An unscripted extra post is a failed expectation, not a crash of the test host.
        guard posts < replies.count else { throw Boom() }
        return try replies[posts].get()
    }
}

actor SleepRecorder {
    private(set) var delays: [Duration] = []
    func add(_ d: Duration) { delays.append(d) }
}

private struct Boom: Error {}

private let attributedBody = Data("""
{"attribution":true,"orgId":40669820,"campaignId":542370539,"conversionType":"Download",
 "clickDate":"2024-10-08T17:17Z","claimType":"Click","adGroupId":542317095,"countryOrRegion":"US",
 "keywordId":87675432,"adId":542317136,"supplyPlacement":"APPSTORE_SEARCH_RESULTS"}
""".utf8)
private let notAttributedBody = Data(#"{"attribution":false}"#.utf8)

@Suite("AppleAdsAttributionTests", .serialized)
@MainActor
struct AppleAdsAttributionTests {

    @MainActor private struct Rig {
        let suite: String
        let defaults: UserDefaults
        let transport = FakeAdServicesTransport()
        let sleeps = SleepRecorder()
        let recorded = Box()
        let sut: AppleAdsAttribution
        @MainActor final class Box { var facts: [AppleAdsFacts] = [] }

        init(attempts: Int? = nil) {
            suite = "AppleAdsAttributionTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            if let attempts { defaults.set(attempts, forKey: AppleAdsAttribution.launchAttemptsKey) }
            let transport = self.transport, sleeps = self.sleeps, recorded = self.recorded
            sut = AppleAdsAttribution(
                transport: transport,
                sleep: { d in await sleeps.add(d) },
                defaults: defaults,
                record: { recorded.facts.append($0) })
        }
        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }

    private func ok(_ body: Data) -> Result<(status: Int, body: Data), Error> { .success((200, body)) }
    private func status(_ code: Int) -> Result<(status: Int, body: Data), Error> { .success((code, Data())) }

    @Test("404, 404, 200: three posts, two 5 s sleeps, facts stored and recorded")
    func retryThenSuccess() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.transport.replies = [status(404), status(404), ok(attributedBody)]
        await rig.sut.runIfNeeded()
        #expect(rig.transport.posts == 3)
        #expect(rig.transport.tokens == 1)
        #expect(rig.transport.postedTokens == ["t", "t", "t"])
        #expect(await rig.sleeps.delays == [.seconds(5), .seconds(5)])
        #expect(AppleAdsFacts.stored(in: rig.defaults)?.campaignId == "542370539")
        #expect(rig.recorded.facts.count == 1)
    }

    @Test("404 on the first try, 200 on the second: one sleep")
    func successOnSecondAttempt() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.transport.replies = [status(404), ok(notAttributedBody)]
        await rig.sut.runIfNeeded()
        #expect(rig.transport.posts == 2)
        #expect(await rig.sleeps.delays == [.seconds(5)])
        #expect(AppleAdsFacts.stored(in: rig.defaults) == AppleAdsFacts(attribution: false))
    }

    @Test("404 three times: three posts, two sleeps, nothing stored, one launch used")
    func threeNotFound() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.transport.replies = [status(404), status(404), status(404)]
        await rig.sut.runIfNeeded()
        #expect(rig.transport.posts == 3)
        #expect(await rig.sleeps.delays.count == 2)
        #expect(AppleAdsFacts.stored(in: rig.defaults) == nil)
        #expect(rig.recorded.facts.isEmpty)
        #expect(rig.defaults.integer(forKey: AppleAdsAttribution.launchAttemptsKey) == 1)
    }

    @Test("A later launch asks again after a failed one")
    func laterLaunchTriesAgain() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.transport.replies = [status(404), status(404), status(404), ok(attributedBody)]
        await rig.sut.runIfNeeded()
        #expect(AppleAdsFacts.stored(in: rig.defaults) == nil)
        await rig.sut.runIfNeeded()
        #expect(rig.transport.posts == 4)
        #expect(AppleAdsFacts.stored(in: rig.defaults)?.attribution == true)
        #expect(rig.defaults.integer(forKey: AppleAdsAttribution.launchAttemptsKey) == 2)
    }

    @Test("Once per install: after a 200 the next call posts nothing")
    func oncePerInstall() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.transport.replies = [ok(attributedBody)]
        await rig.sut.runIfNeeded()
        await rig.sut.runIfNeeded()
        #expect(rig.transport.posts == 1)
        #expect(rig.transport.tokens == 1)
        #expect(rig.recorded.facts.count == 1)
    }

    @Test("Once per install across a new object on the same defaults")
    func oncePerInstallAcrossObjects() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.transport.replies = [ok(notAttributedBody)]
        await rig.sut.runIfNeeded()
        let second = FakeAdServicesTransport()
        let again = AppleAdsAttribution(transport: second, sleep: { _ in }, defaults: rig.defaults, record: { _ in })
        await again.runIfNeeded()
        #expect(second.tokens == 0)
        #expect(second.posts == 0)
    }

    @Test("maxLaunches reached: no token, no post")
    func launchesUsedUp() async {
        let rig = Rig(attempts: AppleAdsAttribution.maxLaunches); defer { rig.cleanUp() }
        await rig.sut.runIfNeeded()
        #expect(rig.transport.tokens == 0)
        #expect(rig.transport.posts == 0)
    }

    @Test("One launch short of maxLaunches still runs")
    func lastLaunchRuns() async {
        let rig = Rig(attempts: AppleAdsAttribution.maxLaunches - 1); defer { rig.cleanUp() }
        rig.transport.replies = [ok(attributedBody)]
        await rig.sut.runIfNeeded()
        #expect(rig.transport.posts == 1)
    }

    @Test("Token error: no post, no facts, launch not counted (offline launches cannot end the attempts)")
    func tokenError() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.transport.token = .failure(Boom())
        await rig.sut.runIfNeeded()
        #expect(rig.transport.posts == 0)
        #expect(AppleAdsFacts.stored(in: rig.defaults) == nil)
        #expect(rig.recorded.facts.isEmpty)
        #expect(rig.defaults.integer(forKey: AppleAdsAttribution.launchAttemptsKey) == 0)
    }

    @Test("Offline launches (a thrown post) are never counted, so a sixth launch still asks")
    func offlineLaunchesDoNotUseUpAttempts() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.transport.replies = [.failure(Boom()), .failure(Boom()), .failure(Boom()), .failure(Boom()),
                                 .failure(Boom()), ok(attributedBody)]
        for launch in 1...(AppleAdsAttribution.maxLaunches + 1) {
            await rig.sut.runIfNeeded()
            if launch <= AppleAdsAttribution.maxLaunches {
                #expect(rig.defaults.integer(forKey: AppleAdsAttribution.launchAttemptsKey) == 0)
            }
        }
        // The sixth launch reached Apple, so only now is one attempt used.
        #expect(rig.defaults.integer(forKey: AppleAdsAttribution.launchAttemptsKey) == 1)
        #expect(rig.transport.posts == AppleAdsAttribution.maxLaunches + 1)
        #expect(AppleAdsFacts.stored(in: rig.defaults)?.attribution == true)
    }

    @Test("A thrown post, or 400 or 500, stops this launch without a retry or false facts")
    func otherFailuresStop() async {
        for reply in [Result<(status: Int, body: Data), Error>.failure(Boom()), status(400), status(500)] {
            let rig = Rig(); defer { rig.cleanUp() }
            rig.transport.replies = [reply, ok(attributedBody)]
            await rig.sut.runIfNeeded()
            #expect(rig.transport.posts == 1)
            #expect(await rig.sleeps.delays.isEmpty)
            #expect(AppleAdsFacts.stored(in: rig.defaults) == nil)
        }
    }

    @Test("A 200 that is not readable stores nothing")
    func unreadable200() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.transport.replies = [ok(Data("not json".utf8))]
        await rig.sut.runIfNeeded()
        #expect(AppleAdsFacts.stored(in: rig.defaults) == nil)
        #expect(rig.recorded.facts.isEmpty)
    }

    @Test("Apple's tap-through payload becomes facts: ids as text, no click date")
    func parseAttributed() throws {
        let facts = try #require(AppleAdsFacts.parse(attributedBody))
        #expect(facts == AppleAdsFacts(attribution: true, campaignId: "542370539", adGroupId: "542317095",
                                       keywordId: "87675432", claimType: "Click", conversionType: "Download",
                                       supplyPlacement: "APPSTORE_SEARCH_RESULTS"))
        #expect(facts.usageFacts == [
            "appleAds.attribution": "true", "appleAds.campaignId": "542370539", "appleAds.adGroupId": "542317095",
            "appleAds.keywordId": "87675432", "appleAds.claimType": "Click", "appleAds.conversionType": "Download",
            "appleAds.supplyPlacement": "APPSTORE_SEARCH_RESULTS",
        ])
    }

    @Test("Search Match payload has no keywordId: the key is absent")
    func parseWithoutKeyword() throws {
        let body = Data(#"{"attribution":true,"campaignId":1,"adGroupId":2,"claimType":"Click","conversionType":"Redownload"}"#.utf8)
        let facts = try #require(AppleAdsFacts.parse(body))
        #expect(facts.keywordId == nil)
        #expect(facts.usageFacts["appleAds.keywordId"] == nil)
        #expect(facts.usageFacts["appleAds.conversionType"] == "Redownload")
    }

    @Test("attribution false: only appleAds.attribution = false")
    func parseNotAttributed() throws {
        let facts = try #require(AppleAdsFacts.parse(notAttributedBody))
        #expect(facts.usageFacts == ["appleAds.attribution": "false"])
        // Extra fields beside `false` are ignored.
        let odd = try #require(AppleAdsFacts.parse(Data(#"{"attribution":false,"campaignId":5}"#.utf8)))
        #expect(odd.usageFacts == ["appleAds.attribution": "false"])
    }

    @Test("Not JSON, or no Bool attribution: nil")
    func parseRejects() {
        #expect(AppleAdsFacts.parse(Data("x".utf8)) == nil)
        #expect(AppleAdsFacts.parse(Data("{}".utf8)) == nil)
        #expect(AppleAdsFacts.parse(Data(#"{"attribution":"yes"}"#.utf8)) == nil)
        #expect(AppleAdsFacts.parse(Data(#"{"attribution":1}"#.utf8)) == nil)
    }

    @Test("Stored facts round-trip through UserDefaults")
    func storeRoundTrip() {
        let suite = "AppleAdsAttributionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppleAdsFacts.stored(in: defaults) == nil)
        let facts = AppleAdsFacts(attribution: true, campaignId: "9", keywordId: "8")
        facts.store(in: defaults)
        #expect(AppleAdsFacts.stored(in: defaults) == facts)
    }
}
