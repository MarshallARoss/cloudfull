//
//  DailyReminder.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Combine
import UserNotifications

/// Sends one local notification a day that opens the app with "On this
/// date" on. Also runs the one-time ask that requests permission for it.
///
/// The app shows its own ask card before the iOS permission prompt. iOS
/// shows its own box only once per install, and a "Don't Allow" answer on
/// it is final until the user changes it in iOS Settings. Only a "Yes" on
/// the app's card triggers the iOS box, so a "Not now" answer costs
/// nothing. The card appears first after the first delete, since nearly
/// every user reaches that point. By then, the user has already used the
/// app in a real way. A "Not now" answer there shows one more card, on
/// the first "You're done for today" screen, then never again. The
/// Settings toggle stays available at all times.
///
/// The notification text is fixed and carries no count, so the app
/// schedules it once as a repeating calendar trigger and never needs to
/// refresh it while the app is closed.
@MainActor
final class DailyReminder: ObservableObject {
    static let shared = DailyReminder()

    static let notificationIdentifier = "cloudfull.daily.onThisDate"
    static let actionKey = "cloudfull.action"
    static let actionOnThisDate = "onThisDate"

    private enum Keys {
        static let enabled = "reminder.enabled"
        static let hour = "reminder.hour"
        static let minute = "reminder.minute"
        static let askStage = "reminder.askStage"
    }

    /// The current stage of the one-time ask. The app persists this value,
    /// so it stays at `.done` until something resets it.
    enum AskStage: Int {
        case never = 0, askedOnce = 1, done = 2
    }

    /// The user's intent to receive the reminder. `true` only after iOS
    /// grants permission.
    @Published private(set) var isEnabled: Bool
    /// The time of day, as a `Date` for `DatePicker`. Only the hour and
    /// minute are kept. A change to this value reschedules the notification
    /// at once.
    @Published var time: Date {
        didSet {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            defaults.set(parts.hour ?? 9, forKey: Keys.hour)
            defaults.set(parts.minute ?? 0, forKey: Keys.minute)
            if isEnabled { schedule() }
        }
    }
    /// True when iOS denies permission. Settings then shows a hint and a
    /// link to iOS Settings.
    @Published private(set) var isDenied = false
    /// True while the ask card shows. `RootView` mounts the card above both
    /// modes.
    @Published private(set) var isAskVisible = false

    private(set) var askStage: AskStage
    private let defaults = UserDefaults.standard
    private let center = UNUserNotificationCenter.current()

    #if DEBUG
    /// A launch argument that resets the ask stage, so a tester can see the
    /// card again on demand, without reinstalling the app. DEBUG only; no
    /// shipped binary carries it.
    static let resetAskArgument = "-cloudfull-reset-reminder-ask"
    #endif

    private init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
        #if DEBUG
        if CommandLine.arguments.contains(Self.resetAskArgument) {
            defaults.set(AskStage.never.rawValue, forKey: Keys.askStage)
        }
        #endif
        askStage = AskStage(rawValue: defaults.integer(forKey: Keys.askStage)) ?? .never
        let hour = defaults.object(forKey: Keys.hour) as? Int ?? 9
        // The default time is 9:02, not 9:00. An off-the-hour time avoids
        // the notification burst that alarms and calendar alerts fire on
        // the hour. The `?? 0` default on the write path above is
        // different: it decomposes a `Date` the user picked, so it must
        // not invent minutes.
        let minute = defaults.object(forKey: Keys.minute) as? Int ?? 2
        time = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
    }

    // MARK: - Enable / disable

    /// Asks iOS for permission. Its box shows at most once per install.
    /// Schedules the notification when allowed. Returns whether the
    /// reminder is now on.
    @discardableResult
    func enable() async -> Bool {
        // The iOS box shows only while the status is `.notDetermined`.
        // Afterwards, `requestAuthorization` just returns the stored answer.
        // This reports the permission answer to `Usage` only when the
        // status was undecided.
        let wasUndecided = await center.notificationSettings().authorizationStatus == .notDetermined
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if wasUndecided { Usage.shared.notificationPermissionAnswered(granted: granted) }
        if granted {
            isEnabled = true
            isDenied = false
            defaults.set(true, forKey: Keys.enabled)
            schedule()
        } else {
            isEnabled = false
            defaults.set(false, forKey: Keys.enabled)
            await refreshAuthorization()
        }
        return granted
    }

    func disable() {
        isEnabled = false
        defaults.set(false, forKey: Keys.enabled)
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
    }

    /// Re-reads iOS's permission answer at launch. The user may have turned
    /// notifications off, or back on, in iOS Settings while the app was
    /// closed. This reschedules an enabled reminder, which is idempotent.
    func refreshAuthorization() async {
        let status = await center.notificationSettings().authorizationStatus
        isDenied = status == .denied
        if isEnabled, status == .authorized { schedule() }
    }

    private func schedule() {
        let content = UNMutableNotificationContent()
        content.title = "On this date"
        content.body = "See what you shot on this day in past years."
        content.sound = .default
        content.userInfo = [Self.actionKey: Self.actionOnThisDate]

        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        let request = UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: trigger)
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
        center.add(request)
    }

    // MARK: - The one-time ask

    /// Called from both delete paths. Waits 1200 ms before showing the card.
    /// That covers the 0.5 s photo delete animation and the video advance,
    /// so the card never appears on top of either.
    func noteFirstDelete() {
        guard askStage == .never, !isEnabled else { return }
        askStage = .askedOnce
        defaults.set(askStage.rawValue, forKey: Keys.askStage)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !self.isEnabled else { return }
            self.isAskVisible = true
        }
    }

    /// The second and last chance to accept, shown on the first "You're
    /// done for today" screen.
    func noteDoneForToday() {
        guard askStage == .askedOnce, !isEnabled, !isAskVisible else { return }
        askStage = .done
        defaults.set(askStage.rawValue, forKey: Keys.askStage)
        isAskVisible = true
    }

    func answerAsk(yes: Bool) async {
        isAskVisible = false
        // `.askedOnce` means this is the first-delete card. `.done` means
        // this is the end-page card.
        Usage.shared.reminderAsk(answer: yes ? .yes : .notNow, at: askStage == .askedOnce ? .firstDelete : .endPage)
        if yes {
            askStage = .done
            defaults.set(askStage.rawValue, forKey: Keys.askStage)
            await enable()
        }
    }

    // MARK: - The tap

    /// Both feeds become "this date, from the start": videos oldest-first
    /// with only the date filter, and photos with only the date filter.
    ///
    /// The tap always switches to the user's default tab, through
    /// `AppModeStore.selectPreferredOpenMode()`, the same call a cold
    /// launch makes. The tab switch happens even when a filtered feed is
    /// not the screen currently showing, such as Settings. The
    /// notification then always opens directly into the correct filtered
    /// feed.
    ///
    /// A tap while already on Photos moves to Videos when Videos is the
    /// default tab, and the reverse also holds. This is intended behavior.
    /// Do not make the tab switch conditional on the current tab.
    func handleNotificationTap() {
        Usage.shared.notificationTap(.daily)
        AppModeStore.shared.selectPreferredOpenMode()
        FeedOptionsStore.shared.applyOnThisDateReminder()
        PhotoOptionsStore.shared.applyOnThisDateReminder()
    }
}
