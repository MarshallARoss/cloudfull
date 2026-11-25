//
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import AdServices

/// Apple's AdServices answer, reduced to the facts we keep. No click date.
///
/// Apple: "The payload returned does not provide information that identifies a
/// user or device." The answer goes into the usage record beside
/// `installChannel`, so `scripts/usage_report.py` can show which Apple Ads
/// campaign and keyword brought a buyer. Nothing here leaves the phone except
/// Apple's own request below.
struct AppleAdsFacts: Codable, Equatable, Sendable {
    var attribution: Bool
    var campaignId: String?      // JSON integers kept as decimal text
    var adGroupId: String?
    var keywordId: String?
    var claimType: String?
    var conversionType: String?
    var supplyPlacement: String?

    /// UserDefaults Data (JSON of this struct). Present = attribution is done for this install.
    static let storageKey = "ads.appleAds.facts"

    static func stored(in defaults: UserDefaults) -> AppleAdsFacts? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(AppleAdsFacts.self, from: data)
    }

    func store(in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Pure. Parses the 200 body. Not JSON or no "attribution" Bool → nil.
    static func parse(_ body: Data) -> AppleAdsFacts? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let attributed = bool(object["attribution"]) else { return nil }
        // Apple's "not attributed" answer carries only `attribution: false`. Keep
        // nothing else from it, even if a field were present.
        guard attributed else { return AppleAdsFacts(attribution: false) }
        return AppleAdsFacts(
            attribution: true,
            campaignId: text(object["campaignId"]),
            adGroupId: text(object["adGroupId"]),
            keywordId: text(object["keywordId"]),
            claimType: text(object["claimType"]),
            conversionType: text(object["conversionType"]),
            supplyPlacement: text(object["supplyPlacement"]))
    }

    /// Usage fact keys → values (attribution fields become Usage keys). Absent fields are absent keys.
    var usageFacts: [String: String] {
        var facts = ["appleAds.attribution": attribution ? "true" : "false"]
        if let campaignId { facts["appleAds.campaignId"] = campaignId }
        if let adGroupId { facts["appleAds.adGroupId"] = adGroupId }
        if let keywordId { facts["appleAds.keywordId"] = keywordId }
        if let claimType { facts["appleAds.claimType"] = claimType }
        if let conversionType { facts["appleAds.conversionType"] = conversionType }
        if let supplyPlacement { facts["appleAds.supplyPlacement"] = supplyPlacement }
        return facts
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Apple sends ids as JSON integers ("long"). Keep them as decimal text, and
    /// accept a string too. A Bool, a fraction or an empty string is not an id.
    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let decimal = number.stringValue
        return decimal.contains(".") || decimal.contains("e") ? nil : decimal
    }
}

protocol AdServicesTransport: Sendable {
    /// `AAAttribution.attributionToken()` run OFF the main thread (Task.detached in the live one).
    func attributionToken() async throws -> String
    /// POST https://api-adservices.apple.com/api/v1/ , "Content-Type: text/plain", body = token.
    func post(token: String) async throws -> (status: Int, body: Data)
}

struct LiveAdServicesTransport: AdServicesTransport {
    static let endpoint = URL(string: "https://api-adservices.apple.com/api/v1/")!

    func attributionToken() async throws -> String {
        // The call is synchronous and can block on the network, so it never runs on the main actor.
        try await Task.detached(priority: .utility) {
            try AAAttribution.attributionToken()
        }.value
    }

    func post(token: String) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(token.utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }
}

/// Asks Apple once per install which Apple Ads campaign, if any, brought this
/// copy of the app. The facts are stored and written into every later session.
@MainActor
final class AppleAdsAttribution {
    static let shared = AppleAdsAttribution(
        transport: LiveAdServicesTransport(),
        sleep: { try? await Task.sleep(for: $0) },
        defaults: .standard,
        record: { Usage.shared.appleAdsFacts($0) })

    /// Int. Launches whose request reached Apple and got no usable 200. At `maxLaunches`, give up
    /// for good. An offline launch (no token, or a post that threw) is not counted, so five
    /// launches without a network cannot end the attempts.
    static let launchAttemptsKey = "ads.appleAds.launchAttempts"
    static let maxLaunches = 5
    static let attemptsPerLaunch = 3
    /// Apple: "initiate retries at intervals of 5 seconds, with a maximum of three attempts."
    static let retryDelay: Duration = .seconds(5)

    private let transport: any AdServicesTransport
    private let sleep: @Sendable (Duration) async -> Void
    private let defaults: UserDefaults
    private let record: @MainActor (AppleAdsFacts) -> Void
    private var isRunning = false

    init(transport: any AdServicesTransport,
         sleep: @escaping @Sendable (Duration) async -> Void,
         defaults: UserDefaults,
         record: @escaping @MainActor (AppleAdsFacts) -> Void) {
        self.transport = transport
        self.sleep = sleep
        self.defaults = defaults
        self.record = record
    }

    /// The ONE entry point. The launch task calls it only when `appleAdsMayRun`.
    func runIfNeeded() async {
        guard !isRunning else { return }
        guard AppleAdsFacts.stored(in: defaults) == nil else { return }
        let launches = defaults.integer(forKey: Self.launchAttemptsKey)
        guard launches < Self.maxLaunches else { return }
        isRunning = true
        defer { isRunning = false }

        guard let token = try? await transport.attributionToken() else { return }
        var counted = false
        for attempt in 1...Self.attemptsPerLaunch {
            guard let reply = try? await transport.post(token: token) else { return }
            if !counted {
                // Apple answered, so this launch used one of the attempts.
                defaults.set(launches + 1, forKey: Self.launchAttemptsKey)
                counted = true
            }
            switch reply.status {
            case 200:
                // A 200 we cannot read stores nothing, so a later launch may ask again.
                guard let facts = AppleAdsFacts.parse(reply.body) else { return }
                facts.store(in: defaults)
                record(facts)
                return
            case 404:
                // Apple: a 404 can come "if you make an API call too quickly after receiving a valid token."
                if attempt < Self.attemptsPerLaunch { await sleep(Self.retryDelay) }
            default:
                return
            }
        }
    }
}
