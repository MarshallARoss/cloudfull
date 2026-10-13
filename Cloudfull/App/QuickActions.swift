//
//  QuickActions.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit
import UserNotifications
import os

/// A long press on the home-screen icon opens Cloudfull directly to Photos
/// or Videos. A setting in Settings sets which mode is the default.
///
/// This file defines the two home-screen quick actions and the one place
/// that turns one into a mode. They are dynamic shortcut items
/// (`UIApplication.shortcutItems`), not an Info.plist array. This target
/// generates its Info.plist from build settings, and a shortcut list has
/// no `INFOPLIST_KEY_` spelling. A hand-written plist for these two rows
/// would be a second file to keep in step with the generated one.
///
/// Both quick actions go through `AppModeStore.shared.select`, the same
/// call the chin nav makes, so a quick action is exactly a tap on that
/// tab.
enum QuickActions {
    private static let prefix = "com.cloudfull.app.open."

    /// Registers the two items. This is idempotent. It is not called from
    /// `CloudfullApp.init()`: items set that early, before
    /// `didFinishLaunching`, never appear on the icon's menu. This runs
    /// once launch has finished, and again whenever the scene becomes
    /// active, so the list also survives anything that cleared it.
    @MainActor
    static func install() {
        UIApplication.shared.shortcutItems = [
            item(for: .videos, title: "Videos", systemImage: "play.rectangle"),
            item(for: .photos, title: "Photos", systemImage: "photo"),
        ]
    }

    /// The mode a shortcut names, or `nil` for one this build does not know.
    static func mode(for item: UIApplicationShortcutItem) -> AppMode? {
        guard item.type.hasPrefix(prefix) else { return nil }
        let raw = String(item.type.dropFirst(prefix.count))
        let mode = AppMode(rawValue: raw)
        return mode == .settings ? nil : mode
    }

    private static func item(for mode: AppMode, title: String, systemImage: String) -> UIApplicationShortcutItem {
        UIApplicationShortcutItem(
            type: prefix + mode.rawValue,
            localizedTitle: title,
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: systemImage),
            userInfo: nil
        )
    }
}

/// The app delegate. It names the scene delegate, because SwiftUI's
/// lifecycle has no hook for a quick action. It also installs the quick
/// actions and handles the daily reminder notifications.
final class CloudfullAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        QuickActions.install()
        // Set before launch finishes. Otherwise a notification tap that
        // cold-starts the app is delivered to nobody.
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in await DailyReminder.shared.refreshAuthorization() }
        return true
    }

    /// The pre-iOS 27 counterpart of
    /// `CloudfullSceneDelegate.supportedInterfaceOrientations(for:)`.
    /// `UIWindowScene.h` in the iOS 27.1 SDK marks that scene-delegate
    /// method iOS 27.0+ only; `IPHONEOS_DEPLOYMENT_TARGET` is 26.0
    /// (`project.pbxproj`), so on iOS 26 the system never calls it at
    /// all and falls back to this older, app-delegate-level method
    /// instead — without this override, iOS 26 would see no mask
    /// override and read the Info.plist's `UISupportedInterfaceOrientations`
    /// directly, which now lists all three orientations (landscape
    /// included) for every screen, not only the ones that opt in.
    ///
    /// Same `RotationPolicy.shared.allowsLandscape` the scene delegate
    /// reads, same `.allButUpsideDown` / `.portrait` formula — one
    /// source of truth for the mask, asked for through whichever of the
    /// two system methods this OS version actually calls.
    /// `RotationPolicy.requestUpdate()` already calls
    /// `setNeedsUpdateOfSupportedInterfaceOrientations()` (iOS 16+) on
    /// every `allowsLandscape` change, which re-queries through
    /// whichever method applies, so no separate invalidation path is
    /// needed here for iOS 26.
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        RotationPolicy.shared.allowsLandscape ? .allButUpsideDown : .portrait
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = CloudfullSceneDelegate.self
        return configuration
    }
}

/// The daily reminder's banner and tap.
extension CloudfullAppDelegate: UNUserNotificationCenterDelegate {
    /// Shown even while the app is in the foreground. A reminder that
    /// arrives while the user is already in Cloudfull is still worth a
    /// banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if userInfo[DailyReminder.actionKey] as? String == DailyReminder.actionOnThisDate {
            Task { @MainActor in DailyReminder.shared.handleNotificationTap() }
        }
        completionHandler()
    }
}

/// Receives the quick action on both paths: a cold launch, where
/// `connectionOptions.shortcutItem` holds the item, and a warm launch,
/// through `performActionFor`.
final class CloudfullSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // `RotationPolicy.shared` outlives any one scene connection; this
        // just hands it the one scene it needs to poke when its own
        // `allowsLandscape` changes. See that type's own comment.
        if let windowScene = scene as? UIWindowScene {
            RotationPolicy.shared.scene = windowScene
        }
        if let item = connectionOptions.shortcutItem {
            Self.open(item)
        }
    }

    /// Decision A, real interface rotation with a dynamic orientation
    /// mask (`design/duo/duo_audit_apple_checklist.md` §3). Replaces the
    /// app's `UISupportedInterfaceOrientations` Info.plist value for
    /// this scene — see that key's own build-setting comment in
    /// `project.pbxproj`, which now lists all three orientations so this
    /// override has landscape to grant.
    ///
    /// `RotationPolicy.shared` is the one switch; see its own doc
    /// comment. R3's own build keeps `allowsLandscape` fixed at `false`
    /// — the mask always resolves to `.portrait`, no visible change yet.
    /// R4 is the step that lets `FeedView` drive it from the active
    /// page's own content.
    ///
    /// Confirmed against `UIWindowScene.h` in the iOS 27.1 SDK: the
    /// Objective-C selector is the single-parameter
    /// `supportedInterfaceOrientationsForWindowScene:`, which Swift
    /// imports as `supportedInterfaceOrientations(for:)` — NOT
    /// `windowScene(_:supportedInterfaceOrientationsFor:)`, the shape of
    /// the older, two-argument `UIApplicationDelegate` method
    /// (`application(_:supportedInterfaceOrientationsFor:)`) this is
    /// easy to confuse it with. Verified by compiling a conforming type
    /// against the real SDK, not assumed from the header's prose alone.
    /// Owner bug (closed + a tall video still rotating to landscape):
    /// `hinge-closed-0` at the moment of the bad rotation rules out
    /// the `.partial`-hinge pass-through this file's own
    /// `RotationPolicy` comment blamed first. Before guessing again,
    /// this logs what the system is ACTUALLY asking and what this
    /// method ACTUALLY answers, every single call — not only the
    /// SwiftUI-state-driven snapshots `PlayerPageView.logRotationPose`
    /// already takes. Same `"Rotation"` log category, so
    /// `xcrun simctl spawn <UDID> log stream --predicate 'subsystem ==
    /// "com.cloudfull.app" and category == "Rotation"'` interleaves
    /// both. `windowScene.session.persistentIdentifier` and the
    /// screen's own size are logged specifically to answer whether
    /// the closed/outer display is a SEPARATE `UIWindowScene` this
    /// override is never consulted for — if the outer display's own
    /// rotation is never preceded by a `mask_` line here, that is the
    /// root cause, not anything `allowsLandscape` itself computes.
    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
        let allowsLandscape = RotationPolicy.shared.allowsLandscape
        let mask: UIInterfaceOrientationMask = allowsLandscape ? .allButUpsideDown : .portrait
        #if DEBUG
        if DiagnosticsGate.isOn("-cloudfull-log-rotation") {
            let screenSize = windowScene.screen.bounds.size
            let message = "mask_\(allowsLandscape ? "allButUpsideDown" : "portrait")"
                + "_allowsLandscape-\(allowsLandscape)_scene-\(windowScene.session.persistentIdentifier)"
                + "_screen-\(Int(screenSize.width))x\(Int(screenSize.height))"
            Self.rotationMaskLog.notice("\(message, privacy: .public)")
            DiagnosticsLog.shared.log("Rotation", message)
        }
        #endif
        return mask
    }

    #if DEBUG
    private static let rotationMaskLog = Logger(subsystem: "com.cloudfull.app", category: "Rotation")
    #endif

    func sceneDidBecomeActive(_ scene: UIScene) {
        QuickActions.install()
    }

    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(Self.open(shortcutItem))
    }

    @discardableResult
    private static func open(_ item: UIApplicationShortcutItem) -> Bool {
        guard let mode = QuickActions.mode(for: item) else { return false }
        if let usageMode = Usage.Mode(rawValue: mode.rawValue) {
            Usage.shared.quickAction(mode: usageMode)
            Usage.shared.modeSwitch(to: usageMode, via: .quickAction)
        }
        AppModeStore.shared.select(mode)
        return true
    }
}
