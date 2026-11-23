//
//  AdRegion.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import StoreKit

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

    /// Pure. The SDKs may start only when the storefront is known and not on the list, and the
    /// device region, when known, is not on the list. An unknown storefront fails closed. An
    /// unknown device region leaves the storefront to decide. Compares upper-cased.
    static func sdksMayStart(storefrontCountryCode: String?, deviceRegionCode: String?) -> Bool {
        guard let storefront = storefrontCountryCode, !storefront.isEmpty else { return false }
        if offStorefrontCodes.contains(storefront.uppercased()) { return false }
        if let device = deviceRegionCode, !device.isEmpty,
           offDeviceRegionCodes.contains(device.uppercased()) { return false }
        return true
    }

    /// Reads both signals once. The storefront read is async, so it never blocks the main thread.
    static func sdksMayStartNow() async -> Bool {
        sdksMayStart(storefrontCountryCode: await Storefront.current?.countryCode,
                     deviceRegionCode: Locale.current.region?.identifier)
    }
}
