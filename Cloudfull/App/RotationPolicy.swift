//
//  RotationPolicy.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// The single switch deciding whether the app's window may rotate into
/// landscape right now — decision A, real interface rotation with a
/// dynamic orientation mask
/// (`design/duo/duo_audit_apple_checklist.md` §3). What
/// `CloudfullSceneDelegate.supportedInterfaceOrientations(for:)` returns
/// every time the system asks, and what `FeedView`'s own
/// `allowsLandscape` (R4) writes every time its own value changes.
///
/// A plain `@MainActor` singleton, not a SwiftUI `@Published` property:
/// the scene delegate that reads it is a bare `UIWindowSceneDelegate`,
/// with no SwiftUI environment to subscribe through, and no view of its
/// own to re-render. `FeedView` still owns the actual DECISION
/// (`allowsLandscape`'s own formula lives there); this type only carries
/// that one bit across to UIKit and pokes the system to re-ask.
///
/// R3's own build (Decision C) wires this end to end — the Info.plist
/// orientations, the scene delegate override, this type — but keeps
/// `allowsLandscape` fixed at its default, `false`, so the mask always
/// resolves to `.portrait` and nothing visibly changes yet. R4 is the
/// step that lets `FeedView` drive it from the active page's own
/// content.
@MainActor
final class RotationPolicy {
    static let shared = RotationPolicy()

    /// Mirrors into `UIInterfaceOrientationMask.allButUpsideDown` (true)
    /// or `.portrait` (false) in `supportedInterfaceOrientations(for:)`.
    /// Fixed `false` until R4.
    private(set) var allowsLandscape = false {
        didSet {
            guard allowsLandscape != oldValue else { return }
            requestUpdate()
        }
    }

    /// Set once, from `CloudfullSceneDelegate.scene(_:willConnectTo:)`.
    /// Weak: this singleton outlives any one scene, and
    /// `TARGETED_DEVICE_FAMILY = 1` means there is only ever the one.
    weak var scene: UIWindowScene?

    private init() {}

    /// `FeedView`'s one write path. A same-value write is a no-op — see
    /// `didSet`'s own guard — so a caller may call this on every body
    /// pass without flooding the system with redundant rotation
    /// requests.
    func update(allowsLandscape: Bool) {
        self.allowsLandscape = allowsLandscape
    }

    /// Tells the system to re-ask `supportedInterfaceOrientations(for:)`
    /// right away, rather than waiting for some unrelated rotation event
    /// to notice the mask changed (`UIViewController.h:391`, iOS 16).
    ///
    /// Owner bug (pose pass): closed + a TALL video still rotated to
    /// landscape, and stayed landscape — rail gone — even after the
    /// hinge finished closing and this type's own `allowsLandscape`
    /// read back `false`. `setNeedsUpdateOfSupportedInterfaceOrientations`
    /// alone only affects the NEXT system-driven rotation query; it
    /// never corrects a window that is ALREADY in an orientation the
    /// mask no longer allows. The hinge close passes through
    /// `.partiallyOpen` on its way to `.closed` — `FeedView
    /// .allowsLandscape`'s own `hingeStatus == .partial` clause allows
    /// landscape there BY DESIGN, for the 1H → tent flow — so a window
    /// can commit to landscape during that brief window and then simply
    /// never be told to leave it once the hinge finishes closing.
    /// `requestGeometryUpdate` is the active counterpart: unlike the
    /// invalidation call, it asks the system to move the window to a
    /// given orientation NOW. Calling both, every time `allowsLandscape`
    /// changes — not only on a close — means a page/pose change that
    /// disallows landscape self-corrects immediately too, not just on
    /// the next incidental rotation.
    private func requestUpdate() {
        guard let scene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let preferred: UIInterfaceOrientationMask = allowsLandscape ? .allButUpsideDown : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: preferred)) { error in
            #if DEBUG
            print("[RotationPolicy] requestGeometryUpdate failed: \(error)")
            #endif
        }
    }
}
