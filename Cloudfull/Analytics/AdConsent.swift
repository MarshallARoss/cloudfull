//
//  AdConsent.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import StoreKit

/// The user's answer to the one-time ad-measurement question.
enum AdConsentAnswer: String, Sendable, Equatable, CaseIterable {
    case notAsked, yes, no
}

/// Whether this storefront needs the question. `unknown` means
/// `Storefront.current` was nil, and it fails closed.
enum AdConsentRegion: Sendable, Equatable {
    case notRequired, required, unknown
}

enum AdConsent {
    /// Raw `AdConsentAnswer`. Absent means `.notAsked`.
    static let answerKey = "ads.consent.answer"
    /// Bool. True once the card has been on screen one time. Never reset in Release.
    static let cardShownKey = "ads.consent.cardShown"
    #if DEBUG
    /// Clears both keys at launch, like `DailyReminder.resetAskArgument`.
    /// DEBUG only; no shipped binary carries it.
    static let resetArgument = "-cloudfull-reset-ad-consent"
    #endif

    /// ISO 3166-1 alpha-3, as `Storefront.countryCode` gives it. The EU 27,
    /// plus Iceland, Liechtenstein and Norway (the EEA), plus the UK and
    /// Switzerland. Other European storefronts (for example SRB, TUR, UKR)
    /// are deliberately absent.
    static let requiredCountryCodes: Set<String> = [
        "AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", "DEU", "GRC", "HUN",
        "IRL", "ITA", "LVA", "LTU", "LUX", "MLT", "NLD", "POL", "PRT", "ROU", "SVK", "SVN", "ESP",
        "SWE", "ISL", "LIE", "NOR", "GBR", "CHE",
    ]

    /// Pure. nil or empty gives `.unknown` (fails closed). Compares upper-cased.
    static func region(forCountryCode code: String?) -> AdConsentRegion {
        guard let code, !code.isEmpty else { return .unknown }
        return requiredCountryCodes.contains(code.uppercased()) ? .required : .notRequired
    }
}

/// Side effects the store causes. They are injected so a test touches no singleton.
struct AdConsentEffects {
    /// `Usage.shared.adConsentShown()`
    var recordShown: @MainActor () -> Void
    /// `Usage.shared.adConsentAnswered(yes:from:)`
    var recordAnswer: @MainActor (_ yes: Bool, _ from: Usage.AdConsentFrom) -> Void
    /// `AdEvents.shared.consentDidChange()`
    var answerChanged: @MainActor () -> Void
    /// True when nothing else is on screen: onboarding is done, no paywall,
    /// no reminder card.
    var isCalm: @MainActor () -> Bool

    @MainActor static let live = AdConsentEffects(
        recordShown: { Usage.shared.adConsentShown() },
        recordAnswer: { yes, from in Usage.shared.adConsentAnswered(yes: yes, from: from) },
        answerChanged: { AdEvents.shared.consentDidChange() },
        isCalm: {
            OnboardingGateState.shared.hasCompleted
                && Entitlements.shared.paywallRequest == nil
                && !DailyReminder.shared.isAskVisible
        }
    )
}

/// Keeps the one-time ad-measurement answer and decides when the card shows.
/// The answer reaches the ad facade in one way only: `effects.answerChanged()`.
/// This type imports and calls no ad SDK.
@MainActor
final class AdConsentStore: ObservableObject {
    static let shared = AdConsentStore(
        defaults: .standard,
        storefrontCountryCode: { await Storefront.current?.countryCode },
        effects: .live
    )

    private let defaults: UserDefaults
    private let storefrontCountryCode: @Sendable () async -> String?
    private let effects: AdConsentEffects
    private let delay: Duration
    private var regionLoaded = false

    /// `delay` is the wait before the card shows. A test passes a short one.
    init(defaults: UserDefaults,
         storefrontCountryCode: @escaping @Sendable () async -> String?,
         effects: AdConsentEffects,
         delay: Duration = .milliseconds(1200)) {
        self.defaults = defaults
        self.storefrontCountryCode = storefrontCountryCode
        self.effects = effects
        self.delay = delay
        #if DEBUG
        if CommandLine.arguments.contains(AdConsent.resetArgument) {
            defaults.removeObject(forKey: AdConsent.answerKey)
            defaults.removeObject(forKey: AdConsent.cardShownKey)
        }
        #endif
        answer = AdConsentAnswer(rawValue: defaults.string(forKey: AdConsent.answerKey) ?? "") ?? .notAsked
    }

    @Published private(set) var answer: AdConsentAnswer
    @Published private(set) var region: AdConsentRegion = .unknown
    /// Set only by `AdEvents`, through `enableQuestion()`: this install could
    /// start the SDKs if the user says yes. It drives the card and the Settings row.
    @Published private(set) var asksForConsent = false
    @Published private(set) var isCardVisible = false

    /// Reads the storefront one time, sets `region`, and returns it. The read
    /// is async, so it never blocks the main thread.
    func loadRegion() async -> AdConsentRegion {
        if regionLoaded { return region }
        let code = await storefrontCountryCode()
        region = AdConsent.region(forCountryCode: code)
        regionLoaded = true
        return region
    }

    /// Called by `AdEvents` only. It turns the question on, then offers the card.
    /// It does nothing unless the storefront is one that needs the question,
    /// so a caller mistake cannot ask a user outside Europe.
    func enableQuestion() {
        guard region == .required else { return }
        asksForConsent = true
        Task { await considerShowingCard() }
    }

    private var cardMayShow: Bool {
        asksForConsent
            && answer == .notAsked
            && !defaults.bool(forKey: AdConsent.cardShownKey)
            && !isCardVisible
            && effects.isCalm()
    }

    /// Shows the card when every condition holds. It waits, checks again, then
    /// shows. The second check runs on the main actor with no gap before the
    /// write, so two calls in flight show the card one time.
    func considerShowingCard() async {
        guard cardMayShow else { return }
        try? await Task.sleep(for: delay)
        guard cardMayShow else { return }
        isCardVisible = true
        defaults.set(true, forKey: AdConsent.cardShownKey)
        effects.recordShown()
    }

    /// Card button. It hides the card and stores the answer.
    func answerFromCard(yes: Bool) {
        isCardVisible = false
        store(yes: yes, from: .card)
    }

    /// Settings toggle. It has no effect when the answer does not change.
    func answerFromSettings(yes: Bool) {
        let new: AdConsentAnswer = yes ? .yes : .no
        guard new != answer else { return }
        store(yes: yes, from: .settings)
    }

    private func store(yes: Bool, from: Usage.AdConsentFrom) {
        let new: AdConsentAnswer = yes ? .yes : .no
        answer = new
        defaults.set(new.rawValue, forKey: AdConsent.answerKey)
        effects.recordAnswer(yes, from)
        effects.answerChanged()
    }
}
