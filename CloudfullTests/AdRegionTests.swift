//
//  AdRegionTests.swift
//  CloudfullTests
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
@testable import Cloudfull

@Suite("AdRegionTests")
struct AdRegionTests {

    @Test("Every listed country is off by storefront and by device region")
    func everyListedCountryIsOff() {
        #expect(AdRegion.offStorefrontCodes.count == 32)
        #expect(AdRegion.offDeviceRegionCodes.count == 32)
        for code in AdRegion.offStorefrontCodes {
            #expect(!AdRegion.sdksMayStart(storefrontCountryCode: code, deviceRegionCode: nil), "storefront \(code)")
        }
        for code in AdRegion.offDeviceRegionCodes {
            #expect(!AdRegion.sdksMayStart(storefrontCountryCode: "USA", deviceRegionCode: code), "device \(code)")
        }
    }

    @Test("The alpha-3 and alpha-2 lists describe the same 32 countries")
    func listsMatch() {
        let pairs: [(String, String)] = [
            ("AUT", "AT"), ("BEL", "BE"), ("BGR", "BG"), ("HRV", "HR"), ("CYP", "CY"), ("CZE", "CZ"),
            ("DNK", "DK"), ("EST", "EE"), ("FIN", "FI"), ("FRA", "FR"), ("DEU", "DE"), ("GRC", "GR"),
            ("HUN", "HU"), ("IRL", "IE"), ("ITA", "IT"), ("LVA", "LV"), ("LTU", "LT"), ("LUX", "LU"),
            ("MLT", "MT"), ("NLD", "NL"), ("POL", "PL"), ("PRT", "PT"), ("ROU", "RO"), ("SVK", "SK"),
            ("SVN", "SI"), ("ESP", "ES"), ("SWE", "SE"), ("ISL", "IS"), ("LIE", "LI"), ("NOR", "NO"),
            ("GBR", "GB"), ("CHE", "CH"),
        ]
        #expect(Set(pairs.map(\.0)) == AdRegion.offStorefrontCodes)
        #expect(Set(pairs.map(\.1)) == AdRegion.offDeviceRegionCodes)
    }

    @Test("The United Kingdom and Switzerland are off")
    func ukAndSwitzerland() {
        #expect(!AdRegion.sdksMayStart(storefrontCountryCode: "GBR", deviceRegionCode: "GB"))
        #expect(!AdRegion.sdksMayStart(storefrontCountryCode: "CHE", deviceRegionCode: "CH"))
    }

    @Test("A European country outside the EEA is on; the United States is on")
    func allowedCountries() {
        #expect(AdRegion.sdksMayStart(storefrontCountryCode: "SRB", deviceRegionCode: "RS"))
        #expect(AdRegion.sdksMayStart(storefrontCountryCode: "USA", deviceRegionCode: "US"))
    }

    @Test("An unknown storefront is off, whatever the device region says")
    func unknownStorefront() {
        #expect(!AdRegion.sdksMayStart(storefrontCountryCode: nil, deviceRegionCode: "US"))
        #expect(!AdRegion.sdksMayStart(storefrontCountryCode: nil, deviceRegionCode: nil))
        #expect(!AdRegion.sdksMayStart(storefrontCountryCode: "", deviceRegionCode: "US"))
    }

    @Test("The two signals must agree: one off signal turns the SDKs off")
    func signalsCombine() {
        #expect(!AdRegion.sdksMayStart(storefrontCountryCode: "USA", deviceRegionCode: "DE"))
        #expect(!AdRegion.sdksMayStart(storefrontCountryCode: "DEU", deviceRegionCode: "US"))
    }

    @Test("An unknown device region leaves the storefront to decide")
    func unknownDeviceRegion() {
        #expect(AdRegion.sdksMayStart(storefrontCountryCode: "USA", deviceRegionCode: nil))
        #expect(AdRegion.sdksMayStart(storefrontCountryCode: "USA", deviceRegionCode: ""))
        #expect(!AdRegion.sdksMayStart(storefrontCountryCode: "FRA", deviceRegionCode: nil))
    }

    @Test("Codes compare without regard to case")
    func caseInsensitive() {
        #expect(!AdRegion.sdksMayStart(storefrontCountryCode: "deu", deviceRegionCode: nil))
        #expect(!AdRegion.sdksMayStart(storefrontCountryCode: "usa", deviceRegionCode: "de"))
        #expect(AdRegion.sdksMayStart(storefrontCountryCode: "usa", deviceRegionCode: "us"))
    }
}
