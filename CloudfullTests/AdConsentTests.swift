//
//  AdConsentTests.swift
//  CloudfullTests
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import Cloudfull

/// Records what `AdConsentStore` does, and lets a test say whether the screen is calm.
@MainActor
private final class Recorder {
    var shown = 0
    var answers: [(yes: Bool, from: Usage.AdConsentFrom)] = []
    var changed = 0
    var calm = true

    var effects: AdConsentEffects {
        AdConsentEffects(
            recordShown: { [self] in shown += 1 },
            recordAnswer: { [self] yes, from in answers.append((yes, from)) },
            answerChanged: { [self] in changed += 1 },
            isCalm: { [self] in calm }
        )
    }
}

@Suite("AdConsentTests", .serialized)
@MainActor
struct AdConsentTests {
    /// Own suite, never `.standard`. The caller removes the domain at the end.
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "AdConsentTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func makeStore(_ defaults: UserDefaults, country: String?, _ recorder: Recorder) -> AdConsentStore {
        AdConsentStore(
            defaults: defaults,
            storefrontCountryCode: { country },
            effects: recorder.effects,
            delay: .milliseconds(5)
        )
    }

    /// A store on a required storefront with the question turned on.
    private func askingStore(_ defaults: UserDefaults, _ recorder: Recorder) async -> AdConsentStore {
        let store = makeStore(defaults, country: "FRA", recorder)
        _ = await store.loadRegion()
        store.enableQuestion()
        return store
    }

    // MARK: - Region

    @Test func everyRequiredCodeAsksInAnyCase() {
        #expect(AdConsent.requiredCountryCodes.count == 32)
        for code in AdConsent.requiredCountryCodes {
            #expect(AdConsent.region(forCountryCode: code) == .required, "\(code)")
            #expect(AdConsent.region(forCountryCode: code.lowercased()) == .required, "\(code) lower")
        }
    }

    @Test func britainAndSwitzerlandAsk() {
        #expect(AdConsent.region(forCountryCode: "GBR") == .required)
        #expect(AdConsent.region(forCountryCode: "CHE") == .required)
    }

    @Test func outsideTheEEAUKAndSwitzerlandDoesNotAsk() {
        // SRB, TUR, UKR, ALB, MDA, RUS are European but outside the EEA.
        for code in ["USA", "CAN", "JPN", "AUS", "BRA", "SRB", "TUR", "UKR", "ALB", "MDA", "RUS"] {
            #expect(AdConsent.region(forCountryCode: code) == .notRequired, "\(code)")
        }
    }

    @Test func unknownStorefrontFailsClosed() async {
        #expect(AdConsent.region(forCountryCode: nil) == .unknown)
        #expect(AdConsent.region(forCountryCode: "") == .unknown)
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let recorder = Recorder()
        let store = makeStore(defaults, country: nil, recorder)
        #expect(await store.loadRegion() == .unknown)
        store.enableQuestion()
        #expect(store.asksForConsent == false)
        await store.considerShowingCard()
        #expect(store.isCardVisible == false)
    }

    @Test func noQuestionOutsideRequiredStorefronts() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let recorder = Recorder()
        let store = makeStore(defaults, country: "USA", recorder)
        #expect(await store.loadRegion() == .notRequired)
        store.enableQuestion()   // even a wrong call must not ask
        #expect(store.asksForConsent == false)
        await store.considerShowingCard()
        #expect(store.isCardVisible == false)
        #expect(recorder.shown == 0)
    }

    // MARK: - Card

    @Test func noCardUntilTheQuestionIsEnabled() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let recorder = Recorder()
        let store = makeStore(defaults, country: "FRA", recorder)
        #expect(await store.loadRegion() == .required)
        await store.considerShowingCard()
        #expect(store.isCardVisible == false)
        #expect(recorder.shown == 0)
    }

    @Test func cardShowsOnceWhenCalm() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let recorder = Recorder()
        let store = await askingStore(defaults, recorder)
        await store.considerShowingCard()
        #expect(store.isCardVisible)
        #expect(defaults.bool(forKey: AdConsent.cardShownKey))
        #expect(recorder.shown == 1)
        // Two more calls while it is visible do not record it again.
        await store.considerShowingCard()
        #expect(recorder.shown == 1)
    }

    @Test func cardWaitsWhileTheScreenIsNotCalm() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let recorder = Recorder()
        recorder.calm = false
        let store = await askingStore(defaults, recorder)
        await store.considerShowingCard()
        #expect(store.isCardVisible == false)
        #expect(defaults.bool(forKey: AdConsent.cardShownKey) == false)
        recorder.calm = true
        await store.considerShowingCard()
        #expect(store.isCardVisible)
    }

    @Test func cardIsOfferedOneTimeOnly() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = Recorder()
        let store = await askingStore(defaults, first)
        await store.considerShowingCard()
        #expect(store.isCardVisible)
        // A new launch on the same defaults, answer still "not asked".
        let second = Recorder()
        let relaunched = await askingStore(defaults, second)
        await relaunched.considerShowingCard()
        #expect(relaunched.isCardVisible == false)
        #expect(second.shown == 0)
        #expect(relaunched.answer == .notAsked)
    }

    @Test func noCardOnceAnswered() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let recorder = Recorder()
        let store = await askingStore(defaults, recorder)
        store.answerFromSettings(yes: false)
        await store.considerShowingCard()
        #expect(store.isCardVisible == false)
    }

    // MARK: - Answer

    @Test func cardAnswerIsStoredAndSendsTheChangeSignal() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let recorder = Recorder()
        let store = await askingStore(defaults, recorder)
        await store.considerShowingCard()
        store.answerFromCard(yes: true)
        #expect(store.isCardVisible == false)
        #expect(store.answer == .yes)
        #expect(defaults.string(forKey: AdConsent.answerKey) == "yes")
        #expect(recorder.answers.count == 1)
        #expect(recorder.answers.first?.yes == true)
        #expect(recorder.answers.first?.from == .card)
        #expect(recorder.changed == 1)
    }

    @Test func answerPersistsAcrossStores() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = await askingStore(defaults, Recorder())
        store.answerFromCard(yes: false)
        let again = makeStore(defaults, country: "FRA", Recorder())
        #expect(again.answer == .no)
    }

    @Test func settingsChangeSendsTheSignalAndSameAnswerDoesNot() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let recorder = Recorder()
        let store = await askingStore(defaults, recorder)
        store.answerFromSettings(yes: true)
        #expect(store.answer == .yes)
        #expect(recorder.answers.last?.from == .settings)
        #expect(recorder.changed == 1)
        store.answerFromSettings(yes: true)   // same answer: no effect
        #expect(recorder.changed == 1)
        #expect(recorder.answers.count == 1)
        store.answerFromSettings(yes: false)  // a later "no" is a change
        #expect(store.answer == .no)
        #expect(recorder.changed == 2)
        #expect(defaults.string(forKey: AdConsent.answerKey) == "no")
    }

    @Test func absentOrBadStoredAnswerReadsAsNotAsked() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(makeStore(defaults, country: "FRA", Recorder()).answer == .notAsked)
        defaults.set("garbage", forKey: AdConsent.answerKey)
        #expect(makeStore(defaults, country: "FRA", Recorder()).answer == .notAsked)
    }

    /// A relaunch with a stored answer: the Settings row must still exist, the card must not show,
    /// and the user must be able to change the answer (design/ADS_REPAIR.md, H-H1 and I-I1).
    @Test func storedAnswerKeepsSettingsRowAndAllowsWithdrawal() async {
        for stored in [AdConsentAnswer.yes, .no] {
            let (defaults, name) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(stored.rawValue, forKey: AdConsent.answerKey)
            defaults.set(true, forKey: AdConsent.cardShownKey)
            let recorder = Recorder()
            let store = await askingStore(defaults, recorder)
            await store.considerShowingCard()
            #expect(store.answer == stored)
            #expect(store.asksForConsent, "the Settings row shows after a stored \(stored)")
            #expect(store.isCardVisible == false)
            #expect(recorder.shown == 0)

            store.answerFromSettings(yes: stored == .no)   // withdraw a yes, or turn a no into a yes
            #expect(store.answer == (stored == .yes ? .no : .yes))
            #expect(recorder.changed == 1)
        }
    }
}
