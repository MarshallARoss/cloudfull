//
//  AdRegion.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import StoreKit
import UIKit

/// Where the three ad SDKs (Meta, Firebase, TikTok) stay off. There is no consent question in
/// the app: in these countries the SDKs simply do not start. Apple Ads attribution is not
/// affected (nothing goes to another company).
///
/// Two signals are used because the App Store storefront alone is not a conclusive test of
/// where a person is. The device region needs no permission and no screen.
enum AdRegion {
    /// ISO 3166-1 alpha-3, as `Storefront.countryCode` gives it. The EU 27, plus Iceland,
    /// Liechtenstein and Norway (the EEA), plus the United Kingdom and Switzerland. Other
    /// European countries (for example SRB, TUR, UKR) are deliberately absent.
    static let offStorefrontCodes: Set<String> = [
        "AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", "DEU", "GRC", "HUN",
        "IRL", "ITA", "LVA", "LTU", "LUX", "MLT", "NLD", "POL", "PRT", "ROU", "SVK", "SVN", "ESP",
        "SWE", "ISL", "LIE", "NOR", "GBR", "CHE",
    ]

    /// The same 32 countries as ISO 3166-1 alpha-2, as `Locale.Region.identifier` gives them.
    static let offDeviceRegionCodes: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU",
        "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES",
        "SE", "IS", "LI", "NO", "GB", "CH",
    ]

    /// What the two signals say. `unknown` is a storefront that is not known yet: the SDKs wait for
    /// it (`AdEvents.launch`) and start late if it turns out to be outside the off-list.
    enum Decision: Equatable, Sendable {
        case allowed, off, unknown
    }

    /// Pure. A device region on the off-list is `off` even when the storefront is unknown. Else an
    /// unknown storefront is `unknown`, a storefront on the off-list is `off`, any other is
    /// `allowed`. An unknown device region leaves the storefront to decide. Compares upper-cased.
    static func decide(storefrontCountryCode: String?, deviceRegionCode: String?) -> Decision {
        if let device = deviceRegion(deviceRegionCode), offDeviceRegionCodes.contains(device.uppercased()) { return .off }
        guard let storefront = storefrontCountryCode, !storefront.isEmpty else { return .unknown }
        return offStorefrontCodes.contains(storefront.uppercased()) ? .off : .allowed
    }

    private static func deviceRegion(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return code
    }

    /// Reads both signals. The storefront read is async, so it never blocks the main thread.
    static func decideNow() async -> Decision {
        decide(storefrontCountryCode: await Storefront.current?.countryCode,
               deviceRegionCode: Locale.current.region?.identifier)
    }

    /// One tick each time the storefront may have become known: StoreKit says it changed, or the app
    /// becomes active again. `AdEvents.launch` reads the decision again on each tick.
    static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let storefront = Task {
                for await _ in Storefront.updates { continuation.yield() }
            }
            let active = Task {
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in
                storefront.cancel()
                active.cancel()
            }
        }
    }
}
