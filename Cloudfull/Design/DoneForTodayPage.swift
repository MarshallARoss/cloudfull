//
//  DoneForTodayPage.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The shape shared by the two cards that go with the daily reminder.
/// The same card recipe as `FeedView.noMatchesState`: glass, a 16 pt
/// radius, and a 320 pt maximum width. It sits over a dim that blocks
/// taps on the feed beneath. `FeedView` uses the same dim for its
/// "Updating feed…" state.
private struct FeedCard<Content: View>: View {
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 10, content: { content })
                .padding(16)
                .frame(maxWidth: 320)
                .feedGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .transition(.opacity)
    }
}

/// The last page of a feed under "On this date." The feed shows each
/// item once, then ends, rather than scrolling forever. The title on
/// screen is "That's history."
///
/// This uses `OnboardingView`'s layout, not a glass card: a large title,
/// plain text, and two large buttons at the bottom, on the plain
/// background. The video pager mounts it as one more page; the photo
/// feed mounts it as one full-height last row.
struct DoneForTodayPage: View {
    /// Which feed this is the end of, passed in rather than derived from
    /// a label.
    let mode: Usage.Mode
    let onReset: () -> Void
    /// Each page offers a button that switches to the other mode.
    let otherModeTitle: String
    let onGoToOtherMode: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // Centered text with no symbol. Nothing shows below the two buttons.
            VStack(spacing: 16) {
                Text("That\u{2019}s history")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("You\u{2019}ve seen everything from \(Date().formatted(.dateTime.month(.wide).day())).")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button("Keep scrolling", action: onReset)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("done_today_reset")
                Button(otherModeTitle, action: onGoToOtherMode)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("done_today_other_mode")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 120)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("done_today_page")
        .onAppear {
            DailyReminder.shared.noteDoneForToday()
            Usage.shared.onThisDateEndReached(mode: mode)
        }
    }
}

/// The one-time ask. See `DailyReminder` for when it shows and why it
/// uses a custom card rather than the system notification prompt.
/// Unlike `DoneForTodayPage`, this card shows as a modal over the
/// current feed.
struct ReminderAskCard: View {
    let onAnswer: (Bool) -> Void

    var body: some View {
        FeedCard(identifier: "reminder_ask_card") {
            Image(systemName: "bell.badge")
                .font(.system(size: 30))
                .foregroundStyle(.white)
            // The headline uses `.headline`. The subhead uses `.footnote`
            // at 85% white.
            Text("Want a daily \u{201C}On this day\u{201D}?")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Once a day, sort what you shot on this date over the years. Takes a minute.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Not now") { onAnswer(false) }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("reminder_ask_no")
                Button("Yes") { onAnswer(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("reminder_ask_yes")
            }
            .padding(.top, 4)
        }
    }
}
