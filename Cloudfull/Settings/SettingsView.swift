//
//  SettingsView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import StoreKit
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
    /// Owns the tip jar's product list and purchase state. `TipJar` is an
    /// `ObservableObject`, like the rest of this file's stores, so it is
    /// a `@StateObject` rather than plain `@State`: that is what makes a
    /// `@Published` change (a load finishing, a purchase starting)
    /// invalidate this view.
    @StateObject private var tipJar = TipJar()
    /// Shows the thank-you alert after a successful tip purchase.
    @State private var showTipThankYou = false
    #if DEBUG
    /// Backs the DEBUG-only "Diagnostics readouts" row at the bottom.
    @ObservedObject private var diagnostics = DiagnosticsSwitch.shared
    #endif

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationStack {
                // Each section is its own computed property. One `body`
                // holding every `Section` inline was slow enough for
                // SourceKit to give up type-checking it; splitting the
                // list this way keeps each piece small for the compiler.
                List {
                    appHeaderSection
                    reminderSection
                    preferencesSection
                    storageSection
                    assistanceSection
                    tipJarSection
                    otherProjectsSection
                    #if DEBUG
                    diagnosticsSection
                    #endif
                    versionSection
                }
                .accessibilityIdentifier("settings_root")     // set on the List itself; this identifier must not change
                // Switches are green by default. The tint makes them
                // use the accent color, like the buttons and links.
                .tint(.accentColor)
                // Catches every `Link` on this screen in one place, so a
                // new link row needs no new gesture wiring to be counted.
                // Always lets the system open the URL; this only observes.
                .environment(\.openURL, OpenURLAction { url in
                    if let link = SettingsLinks.link(for: url) {
                        Usage.shared.settingsLinkTapped(link)
                    }
                    return .systemAction
                })
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
        .task {
            await tipJar.load()
        }
        .onChange(of: openMode) { _, _ in Usage.shared.settingChanged("defaultTab") }
        .onChange(of: openMuted) { _, _ in Usage.shared.settingChanged("openMuted") }
        .onChange(of: reminder.isEnabled) { _, _ in Usage.shared.settingChanged("dailyReminder") }
        .onChange(of: reminder.time) { _, _ in Usage.shared.settingChanged("dailyReminderHour") }
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeScreenView { showWelcome = false }
        }
        .alert("Thank you!", isPresented: $showTipThankYou) {
            Button("OK") {}
        } message: {
            Text("Your tip helps keep Cloudfull going.")
        }
    }

    // MARK: - Sections

    // An inset grouped `List` draws each `Section` as a card. Clear the
    // row background, insets, and separator so the header sits on the
    // page and not in a card.
    private var appHeaderSection: some View {
        Section {
            appHeader
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
        }
    }

    // The daily reminder fires once a day, at a time the user picks.
    // Turning it on is what asks iOS for permission; the app never asks
    // at launch.
    private var reminderSection: some View {
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
                    Usage.shared.settingsOpenIOSSettingsTapped()
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .accessibilityIdentifier("settings_reminder_open_ios_settings")
            }
        } header: {
            Text("Reminder")
        }
    }

    // Default tab and Open unmuted apply at launch. Add keeps and App
    // icon are one-time choices. One section holds all four.
    private var preferencesSection: some View {
        Section {
            Picker("Default tab", selection: $openMode) {
                Text("Videos").tag(AppMode.videos.rawValue)
                Text("Photos").tag(AppMode.photos.rawValue)
            }
            .accessibilityIdentifier("settings_open_mode")
            // The row shows the inverse of `openMuted`. Do not rename
            // the key, the `openMutedSetting` analytics field, or the
            // `settings_open_muted` identifier.
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
    }

    // This screen shows free space because that is the app's declared
    // reason for reading it (privacy reason code 85F4.1). The `.task`
    // reads it off the main thread each time the view appears.
    private var storageSection: some View {
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
            // Read-only. The app has no sync engine, so the status is
            // always "Local only".
            HStack {
                Text("iCloud sync")
                Spacer()
                Text("Local only")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings_icloud_status")
        }
    }

    // The app has two first-run screens: the welcome screen before
    // photo access and the tour after it. After the user grants access,
    // only this section can show the welcome screen. The links after
    // the buttons (website, contact, privacy policy, and public source
    // code) each open Safari.
    private var assistanceSection: some View {
        Section("Assistance") {
            Button("Show welcome screen") {
                Usage.shared.showWelcomeTapped()
                showWelcome = true
            }
            .accessibilityIdentifier("settings_show_welcome")
            Button("Show onboarding again") {
                Usage.shared.showOnboardingAgainTapped()
                onboardingGate.hasCompleted = false
            }
            .accessibilityIdentifier("settings_reset_onboarding")
            Link(destination: SettingsLinks.website) {
                linkRow("Cloudfull website")
            }
            .accessibilityIdentifier("settings_website")
            Link(destination: SettingsLinks.support) {
                linkRow("Contact")
            }
            .accessibilityIdentifier("settings_support")
            Link(destination: SettingsLinks.privacy) {
                linkRow("Privacy policy")
            }
            .accessibilityIdentifier("settings_privacy")
            Link(destination: SettingsLinks.sourceCode) {
                linkRow("Contribute to the source code")
            }
            .accessibilityIdentifier("settings_source_code")
        }
    }

    // An optional Apple In-App Purchase tip. Tips are consumables:
    // StoreKit grants no entitlement for one, so this section has
    // nothing to unlock or restore.
    private var tipJarSection: some View {
        Section {
            tipJarContent
        } header: {
            Text("Tip jar")
        }
    }

    // Other apps by the same developer.
    private var otherProjectsSection: some View {
        Section("Check out Marshall’s other projects") {
            Link(destination: SettingsLinks.feelsMusic) {
                linkRow("Feels Music")
            }
            .accessibilityIdentifier("settings_project_feels")
            Link(destination: SettingsLinks.guestBets) {
                linkRow("GuestBets")
            }
            .accessibilityIdentifier("settings_project_guestbets")
            Link(destination: SettingsLinks.carlyAndTheUniverse) {
                linkRow("Carly and the Universe")
            }
            .accessibilityIdentifier("settings_project_carly")
            Link(destination: SettingsLinks.tabzTech) {
                linkRow("Tabz Tech")
            }
            .accessibilityIdentifier("settings_project_tabztech")
            Link(destination: SettingsLinks.barkBarkBark) {
                linkRow("BarkBarkBark")
            }
            .accessibilityIdentifier("settings_project_barkbarkbark")
        }
    }

    #if DEBUG
    // DEBUG only. The toggle keeps diagnostics readouts on across
    // relaunches, which includes a relaunch from the Home Screen.
    private var diagnosticsSection: some View {
        Section {
            Toggle("Diagnostics readouts", isOn: $diagnostics.isOn)
                .accessibilityIdentifier("settings_diagnostics")
        }
    }
    #endif

    // The version is not a setting, so it is centered footnote text in
    // the footer of the last section, as in Apple's apps.
    private var versionSection: some View {
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

    /// One outbound-link row, used by the "Assistance" and "Check out Marshall’s
    /// other projects" sections: the title, then an outbound-link
    /// glyph, as in Apple's Settings app.
    private func linkRow(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: "arrow.up.right")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tip jar

    /// The tip jar section's body: a loading row while `TipJar.load()`
    /// runs, one segmented row of all three products once loaded, or a
    /// plain "not available" row. A StoreKit failure never hides the
    /// rest of this list; it only leaves this one section with a quiet
    /// row.
    @ViewBuilder
    private var tipJarContent: some View {
        switch tipJar.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("settings_tip_jar")
        case .unavailable:
            Text("Tips are not available right now.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings_tip_unavailable")
        case .loaded(let products):
            tipSegmentRow(products)
        }
    }

    /// One row, split into three equal-width segments, one per product.
    /// A thin divider marks the seam between segments; the whole row
    /// shares one rounded outline in the accent color, like a plain
    /// segmented control.
    private func tipSegmentRow(_ products: [Product]) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<products.count, id: \.self) { index in
                if index > 0 {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: 1, height: 20)
                }
                tipSegmentButton(products[index])
            }
        }
        .disabled(tipJar.purchasingID != nil)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 1)
        )
        .accessibilityIdentifier("settings_tip_jar")
    }

    /// One segment of `tipSegmentRow`: a price-only label in plain
    /// accent-colored text. This control draws its own outline instead
    /// of `.borderedProminent`, so it needs no black-label workaround.
    private func tipSegmentButton(_ product: Product) -> some View {
        let label = tipLabel(for: product)
        return Button {
            purchaseTip(product)
        } label: {
            Text(label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityIdentifier(tipRowIdentifier(for: product))
        .accessibilityLabel("Tip \(label)")
    }

    /// The price alone, for example "$1" or "$10", with no trailing
    /// ".00". Uses the product's own currency and locale, so this reads
    /// correctly outside the US too.
    private func tipLabel(for product: Product) -> String {
        product.price.formatted(product.priceFormatStyle.precision(.fractionLength(0...2)))
    }

    /// Maps a product id's last dot-separated part to its row identifier:
    /// `com.cloudfull.app.tip.10` becomes `settings_tip_10`.
    private func tipRowIdentifier(for product: Product) -> String {
        let suffix = product.id.split(separator: ".").last.map(String.init) ?? product.id
        return "settings_tip_\(suffix)"
    }

    /// Starts a tip purchase and shows the thank-you alert on success.
    /// Runs as its own `Task` so the button action stays synchronous.
    private func purchaseTip(_ product: Product) {
        Task {
            let outcome = await tipJar.purchase(product)
            if case .success = outcome {
                Haptics.tap()
                showTipThankYou = true
            }
        }
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

/// The URLs shown in the "Assistance" and "Check out Marshall’s other projects"
/// sections, kept in one place so each one only needs fixing once.
private enum SettingsLinks {
    static let website = URL(string: "https://cloudfull.app")!
    static let support = URL(string: "https://cloudfull.app/support/")!
    static let privacy = URL(string: "https://cloudfull.app/privacy/")!
    static let sourceCode = URL(string: "https://github.com/MarshallARoss/cloudfull")!
    static let feelsMusic = URL(string: "https://feelsmusic.com/")!
    static let guestBets = URL(string: "https://guestbets.com/")!
    static let carlyAndTheUniverse = URL(string: "https://www.carlyandtheuniverse.com/")!
    static let tabzTech = URL(string: "https://tabztech.com/")!
    static let barkBarkBark = URL(string: "https://barkbarkbark.app/")!

    /// Maps a tapped URL back to its fixed link name, for the `OpenURLAction`
    /// on the Settings list. `nil` for any URL not in this file — none is
    /// ever counted under a raw string.
    static func link(for url: URL) -> Usage.SettingsLink? {
        switch url {
        case website: return .website
        case support: return .contact
        case privacy: return .privacy
        case sourceCode: return .sourceCode
        case feelsMusic: return .feelsMusic
        case guestBets: return .guestBets
        case carlyAndTheUniverse: return .carlyAndTheUniverse
        case tabzTech: return .tabzTech
        case barkBarkBark: return .barkBarkBark
        default: return nil
        }
    }
}
