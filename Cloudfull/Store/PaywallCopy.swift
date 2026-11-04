//
//  PaywallCopy.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Every string here is owner copy. In a value that `String(format:)`
/// fills (the ones whose comment names `%@` slots), a literal percent
/// sign must be written `%%`, and every slot must stay.
enum PaywallCopy {

    // MARK: - Paywall body

    static let title = "Purchase Cloudfull"
    static let body = "Subscribe or buy to delete, keep, share, organize your media, shrink videos, and more."
    static let ongoingValueLine = "Monthly keeps the updates and new features coming."

    // MARK: - Product captions

    /// Two `%@` slots: the trial length ("7 days"), then the localized
    /// price ("$2.99"). Example shape: "%@ free, then %@ a month."
    static let subscribeLabel = "%@ free, then %@ a month. Cancel or purchase anytime."
    /// One `%@` slot: the localized price. Shown when Apple says the
    /// user is not eligible for the trial (used it before).
    static let subscribeNoTrialLabel = "%@ a month. Cancel or purchase anytime."
    static let buyLabel = "Buy forever now. Nothing renews."
    /// The small label above each card's price, and the word after it.
    static let monthlyEyebrow = "Monthly"
    static let monthlyPeriod = "per month"
    static let lifetimeEyebrow = "Lifetime"
    static let lifetimePeriod = "one payment"
    /// The purchase buttons inside the cards. The price sits above them,
    /// bigger, so neither says "free".
    static let subscribeButton = "Subscribe"
    static let buyButton = "Buy once"

    // MARK: - Terms footnote

    static let terms = "7 days free, then $2.99 a month until you cancel in Settings. Lifetime is one payment. Buying Lifetime during a trial does not cancel the trial."

    // MARK: - Cancel-trial prompt (after a lifetime purchase while a trial auto-renews)

    static let cancelTrialPrompt = "You own Cloudfull now. Your monthly plan still renews until you cancel it."
    static let cancelTrialButton = "Cancel my plan"

    // MARK: - Payment issue banner

    static let paymentIssue = "Your last payment did not go through."

    // MARK: - Dead-end states (hide the ProductViews, show a Try again button)

    static let deadEndProductsFailed = "The App Store did not answer."
    static let deadEndPaymentsOff = "Purchases are turned off on this iPhone."
    static let deadEndAskToBuyPending = "Waiting for approval."
    /// Unused since billing retry is no longer a dead end; kept so the
    /// copy table stays stable. Remove once the owner's copy lands.
    static let deadEndBillingRetry = "Your last payment did not go through."
    static let tryAgain = "Try again"

    // MARK: - Support

    static let support = "Questions about Cloudfull or pricing? Message me."

    // MARK: - Restore outcomes

    static let restoreRestored = "Welcome back. You are unlocked."
    static let restoreNothingFound = "No purchase found for this Apple ID."
    static let restoreFailed = "Could not reach the App Store."

    // MARK: - Settings status row

    static let settingsStatusNone = "Subscribe or buy to keep, delete, share, shrink, and more."
    static let settingsStatusUnknown = "Checking your purchase…"
    /// Takes one `%@`: the trial's end date.
    static let settingsStatusTrial = "Free trial · ends %@"
    /// Takes one `%@`: the next renewal date.
    static let settingsStatusMonthlyRenews = "Monthly · renews %@"
    /// Takes one `%@`: the date the subscription ends.
    static let settingsStatusMonthlyCancelled = "Monthly · cancelled, ends %@"
    static let settingsStatusLifetime = "Lifetime"
    static let settingsStatusGrandfathered = "Unlocked. Thanks for buying early."
    static let settingsStatusPaymentWarning = "Payment problem. Check Manage subscription."
    static let settingsStatusLifetimeStillRenewing = "Your monthly plan still renews. Cancel it to stop the charge."

    // MARK: - Settings rows

    static let settingsRowUnlock = "Unlock Cloudfull…"
    static let settingsRowManageSubscription = "Manage subscription"
    static let settingsRowBuyLifetime = "Buy Lifetime instead…"
    static let settingsRowRestore = "Restore Purchases"
    static let settingsRowTerms = "Terms of Use"
    /// The header of the Settings section that holds the status row.
    static let settingsSectionHeader = "Subscription"

    // MARK: - Added beyond the brief's key list
    //
    // Two generic alert strings the brief's key list did not name, but a
    // compiling alert needs: a dismiss button for the purchase-failed
    // alert and the restore alert (each a single button, same as the
    // cancel-trial alert's own single `cancelTrialButton`), and the
    // purchase-failed alert's own message. All three are still owner
    // copy.

    /// The purchase-failed alert's message, shown for `.unverified` and
    /// `.failed` outcomes.
    static let purchaseFailedAlert = "The purchase did not go through."
    /// A generic acknowledge/dismiss button, reused by the
    /// purchase-failed alert and the restore alert (both in
    /// `PaywallView`) and the restore alert in `SettingsView`.
    static let alertOK = "OK"
    /// The three short `Link` labels in `PaywallView`'s own links row.
    /// `terms` above is the longer footnote paragraph; these are the
    /// one- or two-word link texts next to it.
    static let termsLinkLabel = "Terms"
    static let privacyLinkLabel = "Privacy"
    static let supportLinkLabel = "Message Marshall"
    /// The website support page, in the footer link row.
    static let supportPageLinkLabel = "Support"

    // MARK: - Per-source action line

    /// The line naming what unlocking lets the user do, specific to
    /// whichever rail action raised the paywall. Owner dictates one line
    /// per `Entitlements.PaywallSource` case; the owner edits them in context.
    static func actionLine(for source: Entitlements.PaywallSource) -> String {
        switch source {
        case .settings: return "Unlock the actions. Scrolling stays free."
        default: return "That one needs Cloudfull."
        }
    }
}
