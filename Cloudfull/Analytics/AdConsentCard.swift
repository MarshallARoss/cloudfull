//
//  AdConsentCard.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The one-time ad-measurement question, for storefronts in the EEA, the UK
/// and Switzerland. It has the same look as `ReminderAskCard` and uses the
/// same `FeedCard`. `AdConsentStore` decides when it shows. All words are
/// placeholders; the owner writes the final text.
struct AdConsentCard: View {
    let onAnswer: (Bool) -> Void

    var body: some View {
        FeedCard(identifier: "ad_consent_card") {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 30))
                .foregroundStyle(.white)
            // OWNER COPY: placeholder
            Text("Measure our ads?")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            // OWNER COPY: placeholder
            Text("If you came from an ad, Cloudfull can tell the ad network when you buy. You can change this in Settings.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                // OWNER COPY: placeholder
                Button("No") { onAnswer(false) }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("ad_consent_no")
                // OWNER COPY: placeholder
                Button("Yes") { onAnswer(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("ad_consent_yes")
            }
            .padding(.top, 4)
        }
    }
}
