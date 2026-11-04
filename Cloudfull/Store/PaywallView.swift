//
//  PaywallView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import StoreKit
import SwiftUI

/// Shown as a `.fullScreenCover(item:)` from `PermissionGateView` (or
/// from `TrashView`, for Empty Bin), dismissable by its close button
/// only (a full-screen cover has no swipe), above whichever screen raised it — a rail tap in either
/// feed, on any Duo pose, or a row in Settings. Every later rail tap
/// reopens it until `Entitlements.access` unlocks.
///
/// The two unlock products are sold through Apple's own `ProductView`,
/// never a custom buy button: StoreKit draws the price, the trial
/// disclosure, and the purchase sheet. This screen only frames them with
/// the owner's own copy, in `PaywallCopy`.
struct PaywallView: View {
    /// Which rail action, or Settings, raised this paywall. Feeds
    /// `PaywallCopy.actionLine(for:)`, the one line specific to why the
    /// user is looking at this screen right now.
    let source: Entitlements.PaywallSource

    @ObservedObject private var entitlements = Entitlements.shared

    @State private var showCancelTrialAlert = false
    @State private var showManageSubscriptions = false
    @State private var showPurchaseFailedAlert = false
    /// Set by `.onInAppPurchaseCompletion` on a `.pending` outcome (Ask
    /// to Buy). Sticky for the rest of this screen's life: a pending
    /// purchase needs a parent's approval, so retrying here would only
    /// start a second request.
    @State private var showAskToBuyPendingDeadEnd = false
    @State private var showRestoreAlert = false
    @State private var restoreAlertMessage = ""

    private static let termsURL = URL(string: "https://cloudfull.app/terms/")!
    private static let privacyURL = URL(string: "https://cloudfull.app/privacy/")!
    private static let supportURL = URL(string: "mailto:fluffy@cloudfull.app")!

    var body: some View {
        screen.modifier(ManageSubscriptionsSheetModifier(
            isPresented: $showManageSubscriptions,
            subscriptionGroupID: entitlements.subscriptionGroupID
        ))
    }

    private var screen: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    productSection
                    if showsPaymentIssueBanner {
                        paymentIssueBanner
                    }
                    termsText
                    linksSection
                    // 1.2: "Have a code?" row (.offerCodeRedemption) goes here
                }
                .padding(.horizontal, 20)
                .padding(.top, 44)   // clears the close button
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("paywall_root")

            closeButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // `paywall_root` goes on the ScrollView below, not on this
        // ZStack: an identifier on a bare stack is pushed down onto every
        // child, and would overwrite the close button's `paywall_close`.
        // `Usage.purchase(_:.started)` moves here, from the top of
        // `Entitlements.handlePurchase`, so a start is counted once, not
        // once here and once there.
        .onInAppPurchaseStart { product in
            entitlements.purchaseStarted(product)
        }
        .onInAppPurchaseCompletion { product, result in
            Task {
                let outcome = await entitlements.handlePurchase(product, result)
                switch outcome {
                case .success:
                    break   // the access flip clears paywallRequest and drops the cover
                case .successCancelTrialPrompt:
                    showCancelTrialAlert = true
                case .unverified, .failed:
                    showPurchaseFailedAlert = true
                case .userCancelled:
                    break
                case .pending:
                    showAskToBuyPendingDeadEnd = true
                }
            }
        }
        .alert("", isPresented: $showCancelTrialAlert) {
            Button(PaywallCopy.cancelTrialButton) {
                showManageSubscriptions = true
                entitlements.manageSubscriptionsOpened()
            }
            .accessibilityIdentifier("paywall_cancel_trial_alert")
            Button(PaywallCopy.alertOK, role: .cancel) {
                entitlements.clearPaywall()
            }
        } message: {
            Text(PaywallCopy.cancelTrialPrompt)
        }
        // The lifetime purchase already unlocked access; the cover stayed
        // up only for the prompt above. Once Apple's manage sheet closes,
        // the cover goes too.
        .onChange(of: showManageSubscriptions) { _, isShown in
            if !isShown, entitlements.access.isUnlocked { entitlements.clearPaywall() }
        }
        .alert("", isPresented: $showPurchaseFailedAlert) {
            Button(PaywallCopy.alertOK, role: .cancel) {}
        } message: {
            Text(PaywallCopy.purchaseFailedAlert)
        }
        .alert("", isPresented: $showRestoreAlert) {
            Button(PaywallCopy.alertOK, role: .cancel) {}
                .accessibilityIdentifier("paywall_restore_alert")
        } message: {
            Text(restoreAlertMessage)
        }
        // Catches every outbound `Link` on this screen in one place, the
        // same pattern `SettingsView` uses for its own links.
        .environment(\.openURL, OpenURLAction { url in
            switch url {
            case Self.termsURL: Usage.shared.paywallLink(.terms)
            case Self.privacyURL: Usage.shared.paywallLink(.privacy)
            case Self.supportURL: Usage.shared.paywallLink(.support)
            default: break
            }
            return .systemAction
        })
    }

    // MARK: - Header

    private var closeButton: some View {
        Button {
            entitlements.dismissPaywall()
            Usage.shared.paywallLink(.close)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .accessibilityIdentifier("paywall_close")
        .accessibilityLabel("Close")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // App Review 3.1.2 compares the billed price with any "free"
            // or trial wording: the price must be at least as prominent.
            // The title is the only text larger than the ProductView's
            // price, so the owner's title must not say "free" (see the
            // copy table). The trial caption is a footnote under the row.
            Text(PaywallCopy.title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(PaywallCopy.actionLine(for: source))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(PaywallCopy.body)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(PaywallCopy.ongoingValueLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Products / dead ends

    /// Why the ProductViews are hidden in favor of a plain message and a
    /// Try Again button. Checked in this order: a pending Ask to Buy, once
    /// set, is sticky and outranks everything else; then a failed product
    /// load, then payments being off. A billing-retry subscription is NOT
    /// a dead end: the products stay visible (lifetime is still a way
    /// out), with the payment banner and a Manage Subscription button
    /// above them.
    private enum DeadEnd {
        case productsFailed, paymentsOff, askToBuyPending
    }

    private var deadEnd: DeadEnd? {
        if showAskToBuyPendingDeadEnd { return .askToBuyPending }
        if entitlements.productsLoadFailed { return .productsFailed }
        if !entitlements.canMakePayments { return .paymentsOff }
        return nil
    }

    @ViewBuilder
    private var productSection: some View {
        if let deadEnd {
            VStack(spacing: 12) {
                Text(deadEndText(deadEnd))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(deadEndIdentifier(deadEnd))
                Button(PaywallCopy.tryAgain) {
                    Task { await entitlements.refresh() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("paywall_try_again")
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    ProductView(id: StoreProducts.monthly)
                        .productViewStyle(.compact)
                        .accessibilityIdentifier("paywall_monthly")
                    // StoreKit's compact row prints only the price and
                    // period ("$2.99, Every Month"), never the trial. This
                    // caption carries the trial length and the price, both
                    // read from the product, into the owner's sentence.
                    Text(subscribeCaption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    ProductView(id: StoreProducts.lifetime)
                        .productViewStyle(.compact)
                        .accessibilityIdentifier("paywall_lifetime")
                    Text(PaywallCopy.buyLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// `PaywallCopy.subscribeLabel` with the trial length and the price
    /// filled from the loaded product, or the no-trial sentence when the
    /// user is not eligible. Falls back to the plain price when the
    /// product has not loaded.
    private var subscribeCaption: String {
        let monthly = entitlements.products.first { $0.id == StoreProducts.monthly }
        let price = monthly?.displayPrice ?? ""
        guard entitlements.isEligibleForTrial, let offer = monthly?.subscription?.introductoryOffer else {
            return String(format: PaywallCopy.subscribeNoTrialLabel, price)
        }
        return String(format: PaywallCopy.subscribeLabel, Self.trialLengthText(offer.period), price)
    }

    /// "7 days" for a `P1W` or `P7D` offer; falls back to the unit name
    /// for anything else, so no trial length is ever hard-coded.
    private static func trialLengthText(_ period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day: return "\(period.value) day\(period.value == 1 ? "" : "s")"
        case .week: return "\(period.value * 7) days"
        case .month: return "\(period.value) month\(period.value == 1 ? "" : "s")"
        case .year: return "\(period.value) year\(period.value == 1 ? "" : "s")"
        @unknown default: return "\(period.value)"
        }
    }

    private func deadEndText(_ deadEnd: DeadEnd) -> String {
        switch deadEnd {
        case .productsFailed: return PaywallCopy.deadEndProductsFailed
        case .paymentsOff: return PaywallCopy.deadEndPaymentsOff
        case .askToBuyPending: return PaywallCopy.deadEndAskToBuyPending
        }
    }

    private func deadEndIdentifier(_ deadEnd: DeadEnd) -> String {
        switch deadEnd {
        case .productsFailed: return "paywall_dead_end_products"
        case .paymentsOff: return "paywall_dead_end_payments"
        case .askToBuyPending: return "paywall_dead_end_ask_to_buy"
        }
    }

    // MARK: - Payment issue banner

    /// Shown whenever the monthly subscription's own status is mid
    /// billing retry. The products stay on screen under it.
    private var showsPaymentIssueBanner: Bool {
        entitlements.subscriptionStatus?.state == .inBillingRetryPeriod
    }

    private var paymentIssueBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PaywallCopy.paymentIssue)
                .font(.footnote)
                .foregroundStyle(.white)
                .accessibilityIdentifier("paywall_payment_issue")
            Button(PaywallCopy.settingsRowManageSubscription) {
                showManageSubscriptions = true
                entitlements.manageSubscriptionsOpened()
            }
            .font(.footnote.bold())
            .foregroundStyle(.white)
            .accessibilityIdentifier("paywall_manage_subscription")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Terms / links

    private var termsText: some View {
        Text(PaywallCopy.terms)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("paywall_terms_text")
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Button(PaywallCopy.settingsRowRestore) {
                    Usage.shared.paywallLink(.restore)
                    Task {
                        let outcome = await entitlements.restore()
                        switch outcome {
                        case .restored: restoreAlertMessage = PaywallCopy.restoreRestored
                        case .nothingFound: restoreAlertMessage = PaywallCopy.restoreNothingFound
                        case .failed: restoreAlertMessage = PaywallCopy.restoreFailed
                        }
                        showRestoreAlert = true
                    }
                }
                .disabled(entitlements.isRestoring)
                .accessibilityIdentifier("paywall_restore")

                Link(PaywallCopy.termsLinkLabel, destination: Self.termsURL)
                    .accessibilityIdentifier("paywall_terms")

                Link(PaywallCopy.privacyLinkLabel, destination: Self.privacyURL)
                    .accessibilityIdentifier("paywall_privacy")
            }
            .font(.footnote)

            HStack(spacing: 4) {
                Text(PaywallCopy.support)
                Link(PaywallCopy.supportLinkLabel, destination: Self.supportURL)
                    .accessibilityIdentifier("paywall_support")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    PaywallView(source: .keep)
}

/// Wraps `.manageSubscriptionsSheet`, falling back to the whole-app
/// overload when `subscriptionGroupID` is not yet known — only `Product`
/// knows its own group id, and the monthly product may not have loaded
/// yet. Shared by `PaywallView` and `SettingsView`, the two screens that
/// show this sheet.
struct ManageSubscriptionsSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let subscriptionGroupID: String?

    func body(content: Content) -> some View {
        if let subscriptionGroupID {
            content.manageSubscriptionsSheet(isPresented: $isPresented, subscriptionGroupID: subscriptionGroupID)
        } else {
            content.manageSubscriptionsSheet(isPresented: $isPresented)
        }
    }
}
