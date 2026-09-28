//
//  OnboardingView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Controls whether the one-time onboarding cover (`OnboardingView`) is
/// allowed to appear. This is a hard constraint. Every UI test launches
/// with `-cloudfull-reset-deck-state`. If onboarding ever covered the
/// feed during one of those launches, the UI test suite would break.
/// None of `page_`, `pool_total_`, `rail_*`, and similar identifiers
/// would be reachable behind the cover.
enum OnboardingGate {
    static let storageKey = "onboarding.hasCompleted"

    /// True when onboarding must never appear. This is compiled out of
    /// release builds entirely, exactly like
    /// `CloudfullApp.resetStateArgument`, so no shipped binary carries a
    /// way to skip first-run.
    static var isSuppressedByLaunchArgument: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-cloudfull-reset-deck-state")
        #else
        return false
        #endif
    }
}

/// A single, shared, published source of truth for whether onboarding has
/// completed. `PermissionGateView` and `SettingsView` both read and write
/// this same live object, rather than each holding an independent
/// `@AppStorage(OnboardingGate.storageKey)` reader. Two separate
/// property-wrapper instances on the same UserDefaults key do not reliably
/// notify each other. A write from Settings must reach
/// `PermissionGateView`'s `.fullScreenCover` as a synchronous, unambiguous
/// update, not rely on UserDefaults to re-render a different view in time.
///
/// The value still round-trips through `UserDefaults.standard` at
/// `OnboardingGate.storageKey`. `CloudfullApp`'s
/// `-cloudfull-reset-deck-state` path writes that key directly, before
/// this object is constructed, and this object reads it correctly on
/// first access.
@MainActor
final class OnboardingGateState: ObservableObject {
    static let shared = OnboardingGateState()

    @Published var hasCompleted: Bool {
        didSet {
            guard hasCompleted != oldValue else { return }
            UserDefaults.standard.set(hasCompleted, forKey: OnboardingGate.storageKey)
        }
    }

    private init() {
        hasCompleted = UserDefaults.standard.bool(forKey: OnboardingGate.storageKey)
    }
}

/// A one-time "how it works" pass shown as a `.fullScreenCover` over the
/// feed the first time photo access is granted. It appears after the
/// permission gate, not before. The gate's not-determined state already
/// carries the short value proposition.
/// `FeedUITestCase.grantPhotoAccessIfAsked()` also requires
/// `app.buttons["Allow photo access"]` to be reachable within 3 seconds
/// of launch, which rules out any screen appearing ahead of it.
struct OnboardingView: View {
    let onComplete: () -> Void

    // Calling this alongside `onComplete()` (see `actions` below) closes
    // the cover through SwiftUI's own dismissal API, rather than relying
    // only on `onComplete` flipping the bound flag. A `.fullScreenCover`
    // can be dismissed solely by mutating its `isPresented` source from
    // inside the presented content, never through `dismiss()`. That can
    // leave the presentation's coordinator out of sync with that state. A
    // later flip back to "should present", such as Settings' "Show
    // onboarding again", can then fail to re-open it. Using the real
    // dismiss action here removes that risk.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Welcome to Cloudfull")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("onboarding_title")        // Do not change this identifier.

                    Text("Cloudfull shuffles the videos already on your phone. Keep what matters. Let the rest go.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("onboarding_subtitle")     // Do not change this identifier.

                    VStack(alignment: .leading, spacing: 22) {
                        row("hand.draw", "Swipe", "One video at a time, in a random order.", id: "onboarding_row_swipe")
                        row("heart", "Keep", "A kept video is shielded. Cloudfull can never delete it.", id: "onboarding_row_keep")
                        row("arrow.down.right.and.arrow.up.left", "Shrink", "Turn a 4K video into HD. Same memory, a fraction of the space.", id: "onboarding_row_shrink")
                        row("trash", "Clear", "Deletes gather in the bin. One tap empties it.", id: "onboarding_row_clear")
                        // Onboarding needs a Photos page too, since Photos is
                        // a destination in the app's bottom tab bar, alongside
                        // Videos. This card follows the same shape as the
                        // four rows above it.
                        row("photo.on.rectangle", "Photos too", "Swipe through photos the same way. Turn Live Photos on or off, and Keep, Share, and Delete all still use the one bin.", id: "onboarding_row_photos")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 56)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) { actions }
        .accessibilityIdentifier("onboarding_root")        // Do not change this identifier.
        .onAppear { Usage.shared.onboarding("shown") }
    }

    // MARK: - Rows

    /// A twin of `gateLayout`'s `featureRow`: a 26pt SF Symbol in `.tint`,
    /// a `.headline` title, and `.subheadline` `.secondary` body text.
    /// Uses outline symbols only, with no per-row tint colour, since
    /// Apple's welcome rows use a single accent.
    private func row(_ symbol: String, _ title: String, _ body: String, id: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .frame(width: 34)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button("Continue") {
                Usage.shared.onboarding("completed")
                onComplete()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .accentButtonLabel()
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("onboarding_cta")     // Do not change this identifier.
            .accessibilityLabel("Continue")
            .accessibilityHint("Closes this introduction and starts the feed")
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
    }
}
