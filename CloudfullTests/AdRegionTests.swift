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
            #expect(AdRegion.decide(storefrontCountryCode: code, deviceRegionCode: nil) != .allowed, "storefront \(code)")
        }
        for code in AdRegion.offDeviceRegionCodes {
            #expect(AdRegion.decide(storefrontCountryCode: "USA", deviceRegionCode: code) != .allowed, "device \(code)")
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
        #expect(AdRegion.decide(storefrontCountryCode: "GBR", deviceRegionCode: "GB") != .allowed)
        #expect(AdRegion.decide(storefrontCountryCode: "CHE", deviceRegionCode: "CH") != .allowed)
    }

    @Test("A European country outside the EEA is on; the United States is on")
    func allowedCountries() {
        #expect(AdRegion.decide(storefrontCountryCode: "SRB", deviceRegionCode: "RS") == .allowed)
        #expect(AdRegion.decide(storefrontCountryCode: "USA", deviceRegionCode: "US") == .allowed)
    }

    @Test("An unknown storefront is off, whatever the device region says")
    func unknownStorefront() {
        #expect(AdRegion.decide(storefrontCountryCode: nil, deviceRegionCode: "US") != .allowed)
        #expect(AdRegion.decide(storefrontCountryCode: nil, deviceRegionCode: nil) != .allowed)
        #expect(AdRegion.decide(storefrontCountryCode: "", deviceRegionCode: "US") != .allowed)
    }

    @Test("The two signals must agree: one off signal turns the SDKs off")
    func signalsCombine() {
        #expect(AdRegion.decide(storefrontCountryCode: "USA", deviceRegionCode: "DE") != .allowed)
        #expect(AdRegion.decide(storefrontCountryCode: "DEU", deviceRegionCode: "US") != .allowed)
    }

    @Test("An unknown device region leaves the storefront to decide")
    func unknownDeviceRegion() {
        #expect(AdRegion.decide(storefrontCountryCode: "USA", deviceRegionCode: nil) == .allowed)
        #expect(AdRegion.decide(storefrontCountryCode: "USA", deviceRegionCode: "") == .allowed)
        #expect(AdRegion.decide(storefrontCountryCode: "FRA", deviceRegionCode: nil) != .allowed)
    }

    @Test("Codes compare without regard to case")
    func caseInsensitive() {
        #expect(AdRegion.decide(storefrontCountryCode: "deu", deviceRegionCode: nil) != .allowed)
        #expect(AdRegion.decide(storefrontCountryCode: "usa", deviceRegionCode: "de") != .allowed)
        #expect(AdRegion.decide(storefrontCountryCode: "usa", deviceRegionCode: "us") == .allowed)
    }

    @Test("decide: an unknown storefront is unknown; an off device region wins over it")
    func decideUnknown() {
        #expect(AdRegion.decide(storefrontCountryCode: nil, deviceRegionCode: "US") == .unknown)
        #expect(AdRegion.decide(storefrontCountryCode: nil, deviceRegionCode: nil) == .unknown)
        #expect(AdRegion.decide(storefrontCountryCode: nil, deviceRegionCode: "DE") == .off)
        #expect(AdRegion.decide(storefrontCountryCode: "USA", deviceRegionCode: "US") == .allowed)
        #expect(AdRegion.decide(storefrontCountryCode: "GBR", deviceRegionCode: nil) == .off)
    }
}
