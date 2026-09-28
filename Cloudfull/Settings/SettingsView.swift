//
//  SettingsView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The third chin-nav destination. A plain `List` in the style of the
/// Photos app. This view mounts its own `ChinNavigation` with
/// `bottomBand: 0`. Settings has no 9:16 stage, so the switcher sits on
/// the bottom safe area.
struct SettingsView: View {
    /// No row on this screen writes this key. `PhotoFeedView` reads it
    /// once, in its `.task`, to seed the session-only `isLiveOn` toggle
    /// (`live_toggle`).
    @AppStorage("settings.liveDefaultOn") private var liveDefaultOn = true
    /// Stores true for muted. The "Open unmuted" row shows the inverse.
    /// `CloudfullApp.init()` and `PermissionGateView` read this key as
    /// "muted".
    @AppStorage("settings.openMuted") private var openMuted = false
    @AppStorage(KeepsAlbum.settingKey) private var keepsAlbum = true
    /// `.onAppear` sets this from the current Home Screen icon, so the
    /// row always shows the icon in use.
    @State private var appIcon: AppIconChoice = .blue
    /// Which mode a cold launch lands in. `AppModeStore` reads this once
    /// at launch to pick the first mode. A quick action overrides it for
    /// that launch.
    @AppStorage(AppModeStore.openModeKey) private var openMode = AppMode.videos.rawValue
    /// The daily "On this date" reminder.
    @ObservedObject private var reminder = DailyReminder.shared
    /// The same shared flag `PermissionGateView`'s `.fullScreenCover`
    /// observes. Setting it to false shows the one-time onboarding cover
    /// again at once. See `OnboardingGateState`'s comment for why two
    /// independent readers of the same `UserDefaults` key are not
    /// reliable enough for this button to work.
    @ObservedObject private var onboardingGate = OnboardingGateState.shared
    /// Drives the on-demand welcome screen. See the Help section below.
    @State private var showWelcome = false
    @State private var freeSpaceText = "…"
    #if DEBUG
    /// Backs the DEBUG-only "Diagnostics readouts" row at the bottom.
    @ObservedObject private var diagnostics = DiagnosticsSwitch.shared
    #endif

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationStack {
                List {
                    // An inset grouped `List` draws each `Section` as a
                    // card. Clear the row background, insets, and
                    // separator so the header sits on the page and not
                    // in a card.
                    Section {
                        appHeader
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                    // The daily reminder fires once a day, at a time the
                    // user picks. Turning it on is what asks iOS for
                    // permission; the app never asks at launch.
                    Section {
                        Toggle("Daily \u{201C}On this date\u{201D}", isOn: Binding(
                            get: { reminder.isEnabled },
                            set: { on in
                                if on { Task { await reminder.enable() } } else { reminder.disable() }
                            }
                        ))
                        .accessibilityIdentifier("settings_reminder_enabled")
                        if reminder.isEnabled {
                            DatePicker("Time", selection: $reminder.time, displayedComponents: .hourAndMinute)
                                .accessibilityIdentifier("settings_reminder_time")
                        }
                        if reminder.isDenied {
                            Button("Turn on notifications in iOS Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .accessibilityIdentifier("settings_reminder_open_ios_settings")
                        }
                    } header: {
                        Text("Reminder")
                    }
                    // Default tab and Open unmuted apply at launch. Add
                    // keeps and App icon are one-time choices. One
                    // section holds all four.
                    Section {
                        Picker("Default tab", selection: $openMode) {
                            Text("Videos").tag(AppMode.videos.rawValue)
                            Text("Photos").tag(AppMode.photos.rawValue)
                        }
                        .accessibilityIdentifier("settings_open_mode")
                        // The row shows the inverse of `openMuted`. Do
                        // not rename the key, the `openMutedSetting`
                        // analytics field, or the `settings_open_muted`
                        // identifier.
                        Toggle("Open unmuted", isOn: Binding(
                            get: { !openMuted },
                            set: { openMuted = !$0 }
                        ))
                        .accessibilityIdentifier("settings_open_muted")
                        Toggle("Add keeps to an album", isOn: $keepsAlbum)
                            .accessibilityIdentifier("settings_keeps_album")
                            .onChange(of: keepsAlbum) { _, _ in Usage.shared.settingChanged("keepsAlbum") }
                        Picker("App icon", selection: $appIcon) {
                            ForEach(AppIconChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .accessibilityIdentifier("settings_app_icon")
                        .onChange(of: appIcon) { _, choice in AppIconChoice.apply(choice) }
                    } header: {
                        Text("Preferences")
                    }
                    // This screen shows free space because that is the
                    // app's declared reason for reading it (privacy
                    // reason code 85F4.1). The `.task` reads it off the
                    // main thread each time the view appears.
                    Section("Storage") {
                        HStack {
                            Text("Free space on this iPhone")
                            Spacer()
                            Text(freeSpaceText)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings_free_space")
                        // Read-only. The app has no sync engine, so the
                        // status is always "Local only".
                        HStack {
                            Text("iCloud sync")
                            Spacer()
                            Text("Local only")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings_icloud_status")
                    }
                    // The app has two first-run screens: the welcome
                    // screen before photo access and the tour after it.
                    // After the user grants access, only this section
                    // can show the welcome screen.
                    Section("Help") {
                        Button("Show welcome screen") {
                            showWelcome = true
                        }
                        .accessibilityIdentifier("settings_show_welcome")
                        Button("Show onboarding again") {
                            onboardingGate.hasCompleted = false
                        }
                        .accessibilityIdentifier("settings_reset_onboarding")
                    }
                    #if DEBUG
                    // DEBUG only. The toggle keeps diagnostics readouts
                    // on across relaunches, which includes a relaunch
                    // from the Home Screen.
                    Section {
                        Toggle("Diagnostics readouts", isOn: $diagnostics.isOn)
                            .accessibilityIdentifier("settings_diagnostics")
                    }
                    #endif
                    // The version is not a setting, so it is centered
                    // footnote text in the footer of the last section,
                    // as in Apple's apps.
                    Section {
                        EmptyView()
                    } footer: {
                        Text(versionText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("settings_version")
                    }
                }
                .accessibilityIdentifier("settings_root")     // set on the List itself; this identifier must not change
                // `appHeader` already shows the name and icon at the
                // top. An inline title keeps the name from showing
                // twice.
                .navigationBarTitleDisplayMode(.inline)
                // The switcher stays expanded on Settings and floats
                // over the bottom 90 points. Without this margin, the
                // last rows (Version, Diagnostics) sit under it and
                // cannot be tapped.
                .contentMargins(.bottom, 96, for: .scrollContent)
            }
            ChinNavigation(bottomBand: 0)
        }
        .onAppear {
            Usage.shared.settingsOpened()
            appIcon = AppIconChoice.current   // read the actual icon; do not assume the stored choice took effect
        }
        .task {
            let gb = await Task.detached(priority: .utility) { Usage.freeSpaceGB() }.value
            freeSpaceText = gb == "?" ? "—" : "\(gb) GB"
        }
        .onChange(of: openMode) { _, _ in Usage.shared.settingChanged("defaultTab") }
        .onChange(of: openMuted) { _, _ in Usage.shared.settingChanged("openMuted") }
        .onChange(of: reminder.isEnabled) { _, _ in Usage.shared.settingChanged("dailyReminder") }
        .onChange(of: reminder.time) { _, _ in Usage.shared.settingChanged("dailyReminderHour") }
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeScreenView { showWelcome = false }
        }
    }

    // MARK: - App header

    private var appHeader: some View {
        // Centered, and the screen's only title.
        VStack(spacing: 10) {
            appIconView
            Text("Cloudfull")
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// Shows the app icon, or a placeholder glyph if no image loads.
    @ViewBuilder
    private var appIconView: some View {
        if let appIconImage {
            Image(uiImage: appIconImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            // No icon image loaded.
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .glassEffect(.regular, in: Circle())
        }
    }

    /// Tries three lookups in order: the preview image for the selected
    /// icon, then "AppIcon", then "AppIconPreview". `actool` compiles the
    /// appiconset into `Assets.car`, so these loose preview PNGs are the
    /// reliable source for the icon currently in use.
    private var appIconImage: UIImage? {
        UIImage(named: appIcon.previewResource) ?? UIImage(named: "AppIcon") ?? UIImage(named: "AppIconPreview")
    }

    /// Formats as "Version 1.0 (1)". Falls back to "—" for either half
    /// when a debug scheme's Info.plist omits it.
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }
}
