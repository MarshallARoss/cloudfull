//
//  OrientationMonitor.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftUI
import UIKit
import os
#if DEBUG
import CoreFoundation
#endif

/// The device's physical stance, independent of the app's portrait-locked
/// interface. `UIDeviceOrientation` describes the physical device.
/// `UISupportedInterfaceOrientations` constrains only what the window may
/// adopt, so a portrait-locked app still receives orientation
/// notifications for every physical rotation. This is what makes a
/// fullscreen mode that tracks device rotation possible at all.
enum Stance: Equatable {
    case portrait, landscapeLeft, landscapeRight

    var isLandscape: Bool { self != .portrait }

    /// "portrait", "landscapeLeft", or "landscapeRight": the DEBUG probe's
    /// stance field. The UI tests read this string. Do not use
    /// `String(describing:)`, because it changes if a case name changes.
    var probeName: String {
        switch self {
        case .portrait: return "portrait"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        }
    }

    /// `.landscapeLeft`, where the device's own top edge points
    /// world-left, needs its content rotated clockwise by 90° to read
    /// upright in the user's hand. `.landscapeRight` needs the opposite
    /// rotation.
    var contentRotation: Angle {
        switch self {
        case .portrait:       return .degrees(0)
        case .landscapeLeft:  return .degrees(90)
        case .landscapeRight: return .degrees(-90)
        }
    }
}

/// Publishes the device's physical orientation as a `Stance`, translating
/// `UIDeviceOrientation` into one of three cases. It latches through
/// `.faceUp`, `.faceDown`, and `.unknown` instead of reacting to them. A
/// phone set down on a table keeps whatever fullscreen state was already
/// in progress.
///
/// Do not read `UIDevice.current.orientation` during a SwiftUI body pass.
/// It freezes the view graph. Read it only inside this type. Bodies read
/// `stance`. A notification handler feeds this `@Published` value.
///
/// `FeedView` wires this in: `start()` runs inside its existing `.task`,
/// and `stop()` runs in an `.onDisappear`. `refresh()` also runs
/// directly, once, when the scene returns to `.active`, because
/// device-orientation notifications do not arrive while the app is
/// backgrounded. That is the one place this monitor is polled instead of
/// pushed.
@MainActor
final class OrientationMonitor: ObservableObject {
    @Published private(set) var stance: Stance = .portrait

    private var observer: NSObjectProtocol?
    private var isGenerating = false

    #if DEBUG
    /// Read with
    /// `xcrun simctl spawn <UDID> log stream --predicate 'subsystem == "com.cloudfull.app" and category == "Orientation"' --style compact`
    /// to verify `XCUIDevice.shared.orientation` reaches this process on
    /// this runtime.
    ///
    /// Use `log stream`, not `log show`. The system does not persist
    /// `Logger.debug` messages to the log store, so `log show`, which
    /// reads persisted history, returns nothing here even when the
    /// notification arrived. `log stream` attaches live and sees `.debug`
    /// messages as they are emitted.
    private static let log = Logger(subsystem: "com.cloudfull.app", category: "Orientation")
    #endif

    /// Begins generating device-orientation notifications. UIKit
    /// reference-counts this internally; `stop()` balances it. Registers
    /// the observer, then reads the current orientation once immediately,
    /// so `stance` is never stale between `start()` returning and the
    /// first notification arriving.
    func start() {
        guard observer == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        isGenerating = true
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` above guarantees this closure runs on the
            // main queue, so it is safe to assume MainActor isolation
            // here. Same shape as `PlayerHolder`'s own notification
            // observers.
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        refresh()
        #if DEBUG
        startDebugForceObserver()
        #endif
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        if isGenerating {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            isGenerating = false
        }
        #if DEBUG
        stopDebugForceObserver()
        #endif
    }

    /// Re-reads `UIDevice.current.orientation` and republishes only when
    /// `stance` actually changes. A `.faceUp`, `.faceDown`, or `.unknown`
    /// reading maps to "no change", so it never triggers a spurious
    /// downstream update.
    func refresh() {
        let next = Self.stance(for: UIDevice.current.orientation, latching: stance)
        guard next != stance else { return }
        stance = next
        #if DEBUG
        Self.log.debug("orientation_\(next.probeName, privacy: .public)")
        #endif
    }

    /// `.portraitUpsideDown` maps to `.portrait` on purpose: the app
    /// cannot present upside-down, and "not sideways" is the accurate
    /// reading. `.faceUp`, `.faceDown`, and `.unknown` latch whatever
    /// stance was already published.
    private static func stance(for orientation: UIDeviceOrientation, latching previous: Stance) -> Stance {
        switch orientation {
        case .portrait, .portraitUpsideDown:
            return .portrait
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .faceUp, .faceDown, .unknown:
            return previous
        @unknown default:
            return previous
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if isGenerating {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        #if DEBUG
        stopDebugForceObserver()
        #endif
    }

    // MARK: - DEBUG forced orientation
    //
    // On the iOS 26.5 simulator, `XCUIDevice.shared.orientation` and
    // Simulator rotation do not reach `UIDevice.current.orientation`.
    // These Darwin notifications set `stance` directly. They test the
    // code after `stance`, not real device rotation.
    //
    // Uses a Darwin notification, not `NotificationCenter`, because the UI
    // test process and the app process are different OS processes. An
    // in-process `NotificationCenter.default.post` from a test target
    // could never reach this instance. Reach a booted simulator with
    // `xcrun simctl spawn booted notifyutil -p <name>`. This needs no
    // Info.plist change and no app-side URL scheme.
    //
    // This proves that every system downstream of `stance` runs through
    // the identical code path a real rotation would drive. That includes
    // `isFullscreen`, the rotated canvas, `FullscreenPlayerChrome`, the
    // hidden global chrome, disabled paging, and the dismiss latch. It
    // does not prove that a real physical rotation reaches this app on
    // this runtime.
    #if DEBUG
    private static let debugForcePortraitName = "com.cloudfull.app.debug.orientationStance.portrait"
    private static let debugForceLandscapeLeftName = "com.cloudfull.app.debug.orientationStance.landscapeLeft"
    private static let debugForceLandscapeRightName = "com.cloudfull.app.debug.orientationStance.landscapeRight"

    // These functions only pass an opaque pointer to a C API. They touch
    // no main-actor state. `nonisolated` lets `deinit` call
    // `stopDebugForceObserver()`.
    //
    // `CFNotificationCenter` does not retain the observer. `passRetained`
    // keeps `self` alive while the observer is registered. Only
    // `stopDebugForceObserver()` releases that retain.
    private nonisolated(unsafe) var debugForceObserverRetained = false

    private nonisolated func startDebugForceObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passRetained(self).toOpaque()
        debugForceObserverRetained = true
        let callback: CFNotificationCallback = { _, observerPtr, name, _, _ in
            guard let observerPtr, let name else { return }
            let monitor = Unmanaged<OrientationMonitor>.fromOpaque(observerPtr).takeUnretainedValue()
            let next: Stance
            switch name.rawValue as String {
            case OrientationMonitor.debugForceLandscapeLeftName:
                next = .landscapeLeft
            case OrientationMonitor.debugForceLandscapeRightName:
                next = .landscapeRight
            default:
                next = .portrait
            }
            // The Darwin callback fires on an arbitrary thread. Move to
            // the main actor before touching `@Published` state, the same
            // way every real notification handler in this file does
            // through `queue: .main`. `Task { @MainActor in ... }`, not
            // `DispatchQueue.main.async`, makes the closure body
            // MainActor-isolated at compile time, not only at runtime.
            Task { @MainActor in
                monitor.applyDebugForcedStance(next)
            }
        }
        CFNotificationCenterAddObserver(
            center, observer, callback, Self.debugForcePortraitName as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, observer, callback, Self.debugForceLandscapeLeftName as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, observer, callback, Self.debugForceLandscapeRightName as CFString, nil, .deliverImmediately
        )
    }

    private nonisolated func stopDebugForceObserver() {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
        // Balances the `passRetained` in `startDebugForceObserver()`
        // above. This guard stops `stop()`, or `deinit`, from
        // over-releasing `self` when no prior `start()` ran
        // `startDebugForceObserver()`.
        if debugForceObserverRetained {
            Unmanaged.passUnretained(self).release()
            debugForceObserverRetained = false
        }
    }

    /// Sets `stance` only when it changes, like `refresh()`. Logs with an
    /// `orientation_forced_` prefix, so a log shows forced readings apart
    /// from real ones.
    private func applyDebugForcedStance(_ next: Stance) {
        guard next != stance else { return }
        stance = next
        Self.log.debug("orientation_forced_\(next.probeName, privacy: .public)")
    }
    #endif
}
