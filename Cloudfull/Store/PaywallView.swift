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
/// only (a full-screen cover has no swipe), above whichever screen raised it
/// — a rail tap in either feed, on any Duo pose, or a row in Settings.
/// Every later rail tap reopens it until `Entitlements.access` unlocks.
///
/// The look is the feed's own: a night sky with one soft cloud glow,
/// Liquid Glass cards, a rounded headline like the app icon's face.
/// The two unlock products are sold through Apple's `ProductView`, in a
/// custom `ProductViewStyle` (`PaywallCardStyle`) that draws the card and
/// calls `configuration.purchase()`; StoreKit still draws the purchase
/// sheet and still reports through `.onInAppPurchaseStart/Completion`.
/// Every word on the screen comes from `PaywallCopy`.
struct PaywallView: View {
    /// Which rail action, or Settings, raised this paywall. Recorded in
    /// analytics by `Entitlements.require`; the screen itself reads the
    /// same for every source (owner, 2026-11-03).
    let source: Entitlements.PaywallSource

    @ObservedObject private var entitlements = Entitlements.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// Drives the staggered reveal on first appearance.
    @State private var revealed = false

    private static let termsURL = URL(string: "https://cloudfull.app/terms/")!
    private static let privacyURL = URL(string: "https://cloudfull.app/privacy/")!
    private static let supportURL = URL(string: "mailto:fluffy@cloudfull.app")!
    private static let supportPageURL = URL(string: "https://cloudfull.app/support/")!

    /// The brand sky blue, the same value as `AccentColor`.
    static let sky = Color(red: 0x81 / 255, green: 0xD3 / 255, blue: 0xFE / 255)

    var body: some View {
        screen.modifier(ManageSubscriptionsSheetModifier(
            isPresented: $showManageSubscriptions,
            subscriptionGroupID: entitlements.subscriptionGroupID
        ))
    }

    private var screen: some View {
        ZStack(alignment: .topTrailing) {
            NightSky()

            // The column fills the screen, so the link row sits on the
            // bottom edge and the blocks breathe. On a short screen or
            // with large text the column grows past it and scrolls.
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        hero
                            .reveal(revealed, order: 0, reduceMotion: reduceMotion)
                        Spacer(minLength: 28)
                        if showsPaymentIssueBanner {
                            paymentIssueBanner
                                .reveal(revealed, order: 1, reduceMotion: reduceMotion)
                                .padding(.bottom, 16)
                        }
                        productSection
                            .reveal(revealed, order: 1, reduceMotion: reduceMotion)
                        Spacer(minLength: 28)
                        messageCard
                            .reveal(revealed, order: 2, reduceMotion: reduceMotion)
                        Spacer(minLength: 22)
                        linkRow
                            .reveal(revealed, order: 3, reduceMotion: reduceMotion)
                        // 1.2: "Have a code?" row (.offerCodeRedemption) goes here
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 56)   // clears the close button
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("paywall_root")
            }

            closeButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { revealed = true }
        // `paywall_root` goes on the ScrollView above, not on the ZStack:
        // an identifier on a bare stack is pushed down onto every child,
        // and would overwrite the close button's `paywall_close`.
        // `Usage.purchase(_:.started)` fires from `purchaseStarted`, not
        // from `Entitlements.handlePurchase`, so a start is counted once.
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
            case Self.supportPageURL: Usage.shared.paywallLink(.supportPage)
            default: break
            }
            return .systemAction
        })
    }

    // MARK: - Close

    private var closeButton: some View {
        Button {
            entitlements.dismissPaywall()
            Usage.shared.paywallLink(.close)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .feedGlassButton(in: .circle)
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .padding(.trailing, 20)
        .accessibilityIdentifier("paywall_close")
        .accessibilityLabel("Close")
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Self.sky)
                .shadow(color: Self.sky.opacity(0.55), radius: 22, x: 0, y: 6)
                .padding(.bottom, 4)
            // App Review 3.1.2 compares the billed price with any "free"
            // or trial wording: the price must be at least as prominent.
            // The card price below is 32 pt bold; this title is 32 pt, so
            // the price is as big as anything else on the screen, and the
            // owner's title must not say "free" (see the copy table).
            Text(PaywallCopy.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text(PaywallCopy.body)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(3)
        }
    }

    // MARK: - Products / dead ends

    /// Why the product cards are hidden in favor of a plain message and a
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
            VStack(spacing: 14) {
                Image(systemName: deadEnd == .askToBuyPending ? "hourglass" : "icloud.slash")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text(deadEndText(deadEnd))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(deadEndIdentifier(deadEnd))
                if deadEnd != .askToBuyPending {
                    Button(PaywallCopy.tryAgain) {
                        Task { await entitlements.refresh() }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Self.sky)
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("paywall_try_again")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 20)
            .feedGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        } else {
            VStack(spacing: 14) {
                ProductView(id: StoreProducts.monthly)
                    .productViewStyle(PaywallCardStyle(
                        eyebrow: PaywallCopy.monthlyEyebrow,
                        period: PaywallCopy.monthlyPeriod,
                        caption: subscribeCaption,
                        button: PaywallCopy.subscribeButton,
                        captionIdentifier: "paywall_terms_text"
                    ))
                    .accessibilityIdentifier("paywall_monthly")
                ProductView(id: StoreProducts.lifetime)
                    .productViewStyle(PaywallCardStyle(
                        eyebrow: PaywallCopy.lifetimeEyebrow,
                        period: PaywallCopy.lifetimePeriod,
                        caption: PaywallCopy.buyLabel,
                        button: PaywallCopy.buyButton
                    ))
                    .accessibilityIdentifier("paywall_lifetime")
            }
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
        HStack(spacing: 12) {
            Image(systemName: "creditcard.trianglebadge.exclamationmark")
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(PaywallCopy.paymentIssue)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .accessibilityIdentifier("paywall_payment_issue")
                Button(PaywallCopy.settingsRowManageSubscription) {
                    showManageSubscriptions = true
                    entitlements.manageSubscriptionsOpened()
                }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("paywall_manage_subscription")
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Message card and link row

    /// The owner's own note, as a quiet card: one person, one address,
    /// no sales voice.
    private var messageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PaywallCopy.support)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .lineSpacing(2)
            Link(destination: Self.supportURL) {
                HStack(spacing: 6) {
                    Image(systemName: "envelope.fill")
                    Text(PaywallCopy.supportLinkLabel)
                }
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Self.sky)
            }
            .accessibilityIdentifier("paywall_support")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .feedGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Restore, Terms, Privacy, Support: the last row, on the bottom edge.
    private var linkRow: some View {
        HStack(spacing: 22) {
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

            Link(PaywallCopy.supportPageLinkLabel, destination: Self.supportPageURL)
                .accessibilityIdentifier("paywall_support_page")
        }
        .font(.system(.footnote, design: .rounded).weight(.semibold))
        .foregroundStyle(.white.opacity(0.7))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Product card style

/// A Cloudfull product card around Apple's own purchase flow. StoreKit
/// loads the product, draws the purchase sheet, and reports the result
/// through the `.onInAppPurchase…` modifiers on `PaywallView`; this style
/// only draws the card and calls `configuration.purchase()`.
///
/// The price is the biggest text on the whole screen (32 pt bold), which
/// is what App Review's price-prominence rule asks for.
private struct PaywallCardStyle: ProductViewStyle {
    let eyebrow: String
    let period: String
    let caption: String
    let button: String
    var captionIdentifier: String = ""

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased())
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.55))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                priceText(configuration)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(period)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

            // For the monthly card this is Apple's 3.1.2 disclosure: trial
            // length, then price and period, then "cancel any time" — all
            // numbers read from the product, never typed.
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(captionIdentifier)

            Button {
                configuration.purchase()
            } label: {
                Text(button)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.glassProminent)
            .tint(PaywallView.sky)
            .foregroundStyle(.black)
            .disabled(configuration.product == nil)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .feedGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    @ViewBuilder
    private func priceText(_ configuration: Configuration) -> some View {
        switch configuration.state {
        case .success(let product):
            Text(product.displayPrice)
        case .loading:
            Text("—").redacted(reason: .placeholder)
        default:
            Text("—")
        }
    }
}

// MARK: - Background

/// A night sky: black, a deep blue rise at the top, and one soft cloud
/// glow in the brand blue. No image, no texture file, so it costs
/// nothing to load and nothing on a 200k-item library.
private struct NightSky: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.07, blue: 0.13), .black],
                startPoint: .top, endPoint: .bottom
            )
            Circle()
                .fill(PaywallView.sky.opacity(0.28))
                .frame(width: 420, height: 420)
                .blur(radius: 110)
                .offset(x: -140, y: -260)
            Circle()
                .fill(Color(red: 1.0, green: 0.72, blue: 0.56).opacity(0.10))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: 170, y: 420)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Reveal

private extension View {
    /// The staggered appearance on first show: each block fades and rises
    /// in order. With Reduce Motion on, everything is simply there.
    func reveal(_ shown: Bool, order: Int, reduceMotion: Bool) -> some View {
        let on = shown || reduceMotion
        return self
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 18)
            .animation(
                reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86).delay(0.06 * Double(order)),
                value: shown
            )
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
