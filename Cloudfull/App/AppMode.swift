//
//  AppMode.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

// The three chin-nav destinations. Raw values form the DEBUG
// `mode_<rawValue>` probe suffix and the accessibility identifier suffix
// on the three expanded chin-nav tabs. Do not rename a case without
// checking every `mode_` and `chin_nav_` site.
//
// `LiquidSegmentedControl<Selection: Hashable>`
// (`ChinTabSegmentedControl.swift`) generalizes the chin nav's segmented
// control over any selection type. `AppMode` conforms to `Hashable` so it
// can be that control's selection type.
enum AppMode: String, CaseIterable, Sendable, Hashable {
    case videos, photos, settings
}

/// The mode the app opens to is a setting. A cold launch reads
/// `settings.openMode` once, here, and defaults to `.videos` when it is
/// unset or names a mode that cannot be a start (`.settings`).
///
/// A warm resume keeps the live mode instead, because this object lives
/// for the whole process. It is a singleton, not view state, so
/// switching `RootView`'s mounted child never resets it. The one
/// exception is a notification tap. It calls `preferredOpenMode()`
/// again and switches to that mode. The app can be in the background on
/// a tab where the on-this-date filter does not show.
///
/// A home-screen quick action (`QuickActions`) also overrides the live
/// mode for that one open. It uses its own explicit mode: the icon the
/// user long-pressed, not this preference.
@MainActor
final class AppModeStore: ObservableObject {
    static let shared = AppModeStore()

    /// The `@AppStorage` key `SettingsView`'s "Open to" row writes. Stores
    /// a raw `AppMode` value.
    static let openModeKey = "settings.openMode"

    @Published private(set) var mode: AppMode = AppModeStore.preferredOpenMode()

    private init() {}

    /// The only place that stops the app from opening to Settings.
    /// Reads `settings.openMode` and falls back to `.videos` when it is
    /// unset or names `.settings`, which cannot be a start.
    ///
    /// `init` above calls this on a cold launch, and
    /// `selectPreferredOpenMode()` below calls it on a notification tap
    /// on a warm app. Do not copy this guard into either call site. Keep
    /// it here so that every new entry point gets it.
    static func preferredOpenMode() -> AppMode {
        guard let raw = UserDefaults.standard.string(forKey: openModeKey),
              let mode = AppMode(rawValue: raw), mode != .settings else { return .videos }
        return mode
    }

    func select(_ mode: AppMode) {
        self.mode = mode
    }

    /// Jumps to the user's default tab regardless of the live mode.
    /// `handleNotificationTap()` calls this because a notification names
    /// no mode of its own. Without it, a tap that lands while the app is
    /// backgrounded on Settings would apply the on-this-date filter to two
    /// feeds the user cannot see.
    func selectPreferredOpenMode() {
        select(Self.preferredOpenMode())
    }
}

/// The root mode switch. `PermissionGateView.authorizedView` mounts this
/// view. A plain `switch` on `AppModeStore.shared.mode` unmounts the
/// mode that is not current. This is deliberate: it stops video
/// playback on leaving Videos. Each mode keeps its position because
/// `DeckViewModel` and `PhotoDeck` outlive this view. `FeedView`
/// survives the access-downgrade remount path (`performStart` →
/// `reconcileAfterRemount`) the same way.
struct RootView: View {
    @ObservedObject private var modeStore = AppModeStore.shared
    @ObservedObject private var reminder = DailyReminder.shared
    private let deck: DeckViewModel
    private let trash: TrashService
    private let shrink: ShrinkService

    init(deck: DeckViewModel, trash: TrashService, shrink: ShrinkService) {
        self.deck = deck
        self.trash = trash
        self.shrink = shrink
    }

    var body: some View {
        ZStack {
            switch modeStore.mode {
            case .videos:
                FeedView(viewModel: deck, trashService: trash, shrinkService: shrink)
            case .photos:
                PhotoFeedView(trashService: trash)
            case .settings:
                SettingsView()
            }
            // The one-time reminder ask sits above whichever mode is
            // active, so both modes show the same card.
            if reminder.isAskVisible {
                ReminderAskCard { yes in
                    Task { await reminder.answerAsk(yes: yes) }
                }
            }
            #if DEBUG
            modeProbe
            // The stall readout must be visible in Photos mode too, not
            // only over the video feed, so it reports the same numbers
            // from either side. Mounted here, above every mode, at full
            // screen size. See `MainStallReadoutView`'s own comment for
            // why it could not stay inside the 1×1 `GateProbes` stack.
            MainStallReadoutView()
            #endif
        }
    }

    #if DEBUG
    /// `mode_<videos|photos|settings>`. Matches every other 1×1 probe
    /// (`poolCountProbe` and others): invisible, always present in a
    /// DEBUG build, and absent from release builds.
    private var modeProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("mode_\(modeStore.mode.rawValue)")
    }
    #endif
}
