//
//  TipJar.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import StoreKit
import os

/// Backs the "Tip jar" section in Settings: three consumable tips a user
/// can buy with no entitlement attached. A tip unlocks nothing, so this
/// type stores no purchase record beyond the in-flight state below.
///
/// `Transaction.updates` can hand this app a transaction outside a direct
/// `purchase(_:)` call, for example one an interrupted launch left
/// unfinished. The listener task started in `init` finishes any verified
/// tip transaction it sees. StoreKit requires every transaction to be
/// finished, or it keeps handing it back on every launch.
@MainActor
final class TipJar: ObservableObject {
    /// The three tip product ids, in App Store Connect naming order. Not
    /// price order; `load()` sorts the loaded products by price.
    static let productIDs = [
        "com.cloudfull.app.tip.1",
        "com.cloudfull.app.tip.10",
        "com.cloudfull.app.tip.100",
    ]

    enum LoadState {
        case loading
        case loaded([Product])
        /// `Product.products(for:)` returned no products, or threw. Both
        /// cases show the same "not available" row; the reason only goes
        /// to the log.
        case unavailable
    }

    /// What `purchase(_:)` did, so the caller can decide whether to show
    /// the thank-you alert. `.cancelled` also covers a verification
    /// failure or a thrown error; none of those are worth telling the
    /// user apart from a plain cancel.
    enum PurchaseOutcome {
        case success
        case cancelled
        case pending
    }

    @Published private(set) var state: LoadState = .loading
    /// The id of the product mid-purchase, if any. Settings disables every
    /// tip button while this is non-nil, so a user cannot start a second
    /// purchase before the first finishes.
    @Published private(set) var purchasingID: String?

    private let logger = Logger(subsystem: "com.cloudfull.app", category: "TipJar")
    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.finishIfVerifiedTip(update)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Load

    /// Fetches the three tip products. Settings calls this from a `.task`,
    /// once per appearance of the tip jar section's owning view.
    func load() async {
        state = .loading
        do {
            let products = try await Product.products(for: Self.productIDs)
            if products.isEmpty {
                logger.error("Product.products(for:) returned no tip products")
                Usage.shared.tipProductsUnavailable(.empty)
                state = .unavailable
            } else {
                state = .loaded(products.sorted { $0.price < $1.price })
            }
        } catch {
            logger.error("Failed to load tip products: \(error.localizedDescription, privacy: .public)")
            Usage.shared.tipProductsUnavailable(.loadFailed)
            state = .unavailable
        }
    }

    // MARK: - Purchase

    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        purchasingID = product.id
        defer { purchasingID = nil }
        // The fixed tier only, never the product's own price or currency.
        let tier = Self.tier(for: product.id)
        if let tier { Usage.shared.tipTapped(tier) }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard let transaction = try? checkVerified(verification) else {
                    logger.error("Tip purchase for \(product.id, privacy: .public) failed verification")
                    if let tier { Usage.shared.tipOutcome(tier, .cancelled) }
                    return .cancelled
                }
                await transaction.finish()
                logger.log("Tip purchase finished for \(product.id, privacy: .public)")
                if let tier { Usage.shared.tipOutcome(tier, .success) }
                return .success
            case .userCancelled:
                if let tier { Usage.shared.tipOutcome(tier, .cancelled) }
                return .cancelled
            case .pending:
                if let tier { Usage.shared.tipOutcome(tier, .pending) }
                return .pending
            @unknown default:
                logger.error("Unknown Product.PurchaseResult case for \(product.id, privacy: .public)")
                if let tier { Usage.shared.tipOutcome(tier, .cancelled) }
                return .cancelled
            }
        } catch {
            logger.error("Tip purchase for \(product.id, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
            if let tier { Usage.shared.tipOutcome(tier, .cancelled) }
            return .cancelled
        }
    }

    /// Maps a product id's last dot-separated part to its analytics tier,
    /// e.g. `com.cloudfull.app.tip.10` → `.ten`. Matches
    /// `SettingsView.tipRowIdentifier(for:)`.
    private static func tier(for productID: String) -> Usage.TipTier? {
        let suffix = productID.split(separator: ".").last.map(String.init) ?? productID
        return Usage.TipTier(rawValue: suffix)
    }

    // MARK: - Transaction.updates

    /// Finishes a verified tip transaction handed to the app outside a
    /// direct `purchase(_:)` call. Ignores anything unverified and
    /// anything that is not one of this jar's products, in case StoreKit
    /// ever routes other transactions through this stream.
    private func finishIfVerifiedTip(_ update: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(update) else {
            logger.error("Ignored an unverified transaction update")
            return
        }
        guard Self.productIDs.contains(transaction.productID) else { return }
        await transaction.finish()
        logger.log("Finished a tip transaction from Transaction.updates: \(transaction.productID, privacy: .public)")
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw VerificationFailure.unverified
        case .verified(let safe):
            return safe
        }
    }

    private enum VerificationFailure: Error {
        case unverified
    }
}
