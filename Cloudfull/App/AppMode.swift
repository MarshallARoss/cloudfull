//
//  AppMode.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

// The three tab destinations. Raw values form the DEBUG `mode_<rawValue>`
// probe suffix. Do not rename a case without checking every `mode_` site.
//
// Owner re-adapt: these used to also be the chin nav's own segmented-
// control values (`ChinTabSegmentedControl.swift`, now deleted) and the
// `chin_nav_<rawValue>` accessibility identifier suffix. `RootView`'s
// own `TabView` now switches on this enum directly as each `Tab`'s own
// `value:`.
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

    /// Writes `mode`, then fires `Usage.shared.modeSwitch(to:via:)` for
    /// `via` when `mode` actually names a trackable `Usage.Mode`
    /// (`.settings` does not). The three call sites that already knew
    /// their own `via` before this type existed —
    /// `QuickActions.open(_:)`, the two "done for today" page links —
    /// keep calling `Usage.shared.modeSwitch` directly themselves and
    /// pass no `via` here, so this never double-counts their own
    /// switch. `RootView`'s own `TabView` selection binding is this
    /// method's one caller that DOES pass `via` — see that binding's
    /// own comment.
    func select(_ mode: AppMode, via: Usage.ModeSwitchVia) {
        if let usageMode = Usage.Mode(rawValue: mode.rawValue), usageMode != Usage.currentMode {
            Usage.shared.modeSwitch(to: usageMode, via: via)
        }
        select(mode)
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

/// The root tab switch. `PermissionGateView.authorizedView` mounts this
/// view.
///
/// Owner re-adapt, "every iPhone": this used to be a plain `switch` on
/// `AppModeStore.shared.mode` that UNMOUNTED the mode that was not
/// current — deliberately, since that was what stopped video playback
/// on leaving Videos. It is now a system `TabView`, replacing the old
/// chin nav (`ChinNavigation.swift`, now deleted) with Apple's own tab
/// bar: on the Duo's closed display and the inner display in landscape
/// (toolbar vertical edge on), it lands in the vertical bar column,
/// the same spot the Duo Home Screen's own Search button sits; on pose
/// 5 (vertical bar off) and a regular iPhone, it is the standard
/// floating bottom bar. Apple's own default placement throughout — no
/// custom positioning here.
///
/// `TabView` keeps all three tabs mounted at once, so the OLD
/// "unmounting stops playback" guarantee is gone. `FeedView` now stops
/// its own playback by mode instead — see `FeedView.isFeedSuspended`'s
/// own `modeStore.mode != .videos` term — and `PhotoFeedView` now
/// starts/stops its own background downloads the same way (see
/// `PhotoDeck.suspendBackgroundWork`'s own call site there). Each
/// mode's own view model (`DeckViewModel`/`PhotoDeck`) already outlived
/// this view before this change; nothing about that changes.
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

    /// `TabView`'s own selection binding. `get` always reads the one
    /// source of truth (`AppModeStore.shared.mode`), so an external
    /// mode change — `QuickActions`, a notification tap, a "done for
    /// today" page's own link — updates which tab is shown without
    /// this `set` ever running: SwiftUI calls a `Binding`'s `set` only
    /// when something assigns to the BINDING itself, never when the
    /// underlying source it reads changes on its own. `set` therefore
    /// fires only when the system tab bar itself changes the selection
    /// — a direct tap — exactly `ChinNavigation.selectAnimated`'s own
    /// "chin" analytics meaning, now carried by `AppModeStore
    /// .select(_:via:)` instead of a parallel call here.
    private var modeBinding: Binding<AppMode> {
        Binding(
            get: { modeStore.mode },
            set: { modeStore.select($0, via: .chin) }
        )
    }

    var body: some View {
        ZStack {
            TabView(selection: modeBinding) {
                Tab("Videos", systemImage: "video", value: AppMode.videos) {
                    FeedView(viewModel: deck, trashService: trash, shrinkService: shrink)
                }
                Tab("Photos", systemImage: "photo.on.rectangle", value: AppMode.photos) {
                    PhotoFeedView(trashService: trash)
                }
                Tab("Settings", systemImage: "gearshape", value: AppMode.settings) {
                    SettingsView()
                }
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
