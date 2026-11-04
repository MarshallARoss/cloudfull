//
//  AccessOverride.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

// Every type in this file is DEBUG-only.
#if DEBUG
/// A Settings-picked override of `Entitlements.access`, for exercising
/// every paywall state without a sandbox purchase. Persists across
/// launches in `UserDefaults`, the same pattern `DiagnosticsSwitch` uses.
///
/// DEBUG-only: no release binary carries a way to fake its own entitlement
/// state. `Entitlements.refresh()` reads this only when
/// `StoreProducts.isOfficialBuild` is true.
@MainActor
final class AccessOverride: ObservableObject {
    static let shared = AccessOverride()
    static let storageKey = "debug.accessOverride"

    enum Value: String, CaseIterable {
        /// The default. No fixed value, but in Xcode's StoreKit
        /// environment the app is simply unlocked, so every existing UI
        /// test and a contributor's simulator run see no paywall.
        case auto
        /// Run the real resolver against the real StoreKit facts, also
        /// in Xcode's StoreKit environment. This is the setting for the
        /// end-to-end purchase check in the simulator with
        /// `Cloudfull.storekit`.
        case real
        case unknown, none, trial, monthly, lifetime, grandfathered
    }

    @Published var value: Value {
        didSet {
            UserDefaults.standard.set(value.rawValue, forKey: Self.storageKey)
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        // This assignment happens in `init`, so it does not trigger
        // `didSet`. The read loads the stored value; it does not write a
        // new one.
        value = stored.flatMap(Value.init(rawValue:)) ?? .auto
    }
}
#endif
