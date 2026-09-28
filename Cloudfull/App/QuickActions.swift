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
        if let item = connectionOptions.shortcutItem {
            Self.open(item)
        }
    }

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
