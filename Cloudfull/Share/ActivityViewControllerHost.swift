//
//  ActivityViewControllerHost.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit

/// A zero-size host that presents and dismisses the system share sheet
/// from `ShareCoordinator.presentedShare`. A `UIActivityViewController`
/// inside a SwiftUI `.sheet` shows as a sheet inside a sheet, so this
/// presents from a bare `UIViewController`. `FeedView` and
/// `PhotoFeedView` each mount it with `frame(width: 0, height: 0)` and
/// `accessibilityIdentifier("share_sheet_host")`.
struct ActivityViewControllerHost: UIViewControllerRepresentable {
    @ObservedObject var coordinator: ShareCoordinator

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    /// Guards on `presentedViewController == nil`. This stops a re-render,
    /// for example a `@Published` change from progress elsewhere in the
    /// feed, from ever double-presenting the sheet. Dismisses only the
    /// activity controller this host itself presented, never any other
    /// sheet the app might have up.
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if let share = coordinator.presentedShare {
            guard uiViewController.presentedViewController == nil else { return }
            let activity = AddToAlbumActivity()
            let controller = UIActivityViewController(activityItems: share.activityItems, applicationActivities: [activity])
            controller.excludedActivityTypes = [
                .assignToContact, .addToReadingList, .print, .openInIBooks,
                .markupAsPDF, .saveToCameraRoll
            ]
            controller.completionWithItemsHandler = { [weak coordinator] activityType, _, _, _ in
                coordinator?.shareSheetFinished(activityType: activityType)
            }
            controller.view.accessibilityIdentifier = "share_sheet"
            // On this iOS version, a compact single-item activity card is
            // not the classic UIKit popover that adapts away on compact
            // width. It stays a true popover on iPhone too, anchored to
            // `sourceView` and `sourceRect`. Setting
            // `modalPresentationStyle = .pageSheet` alone does nothing,
            // and no `UIPopoverPresentationControllerDelegate` adaptation
            // call ever fires for it.
            //
            // Anchor the popover low on the screen. `sourceView` is a
            // zero-size host. Its origin follows the feed's `ZStack`
            // alignment, which is the top of the screen in
            // `PhotoFeedView`. This code converts a point at the true
            // bottom-center of the window into this view's own
            // coordinate space, and uses that as `sourceRect`. The card
            // then anchors there regardless of where the host view
            // itself sits, on either feed.
            controller.modalPresentationStyle = .pageSheet
            if let popover = controller.popoverPresentationController {
                let anchorView = uiViewController.view!
                popover.sourceView = anchorView
                if let window = anchorView.window {
                    let bottomCenter = anchorView.convert(
                        CGPoint(x: window.bounds.midX, y: window.bounds.maxY),
                        from: window
                    )
                    popover.sourceRect = CGRect(origin: bottomCenter, size: .zero)
                }
                popover.permittedArrowDirections = []
                popover.delegate = context.coordinator
            }
            uiViewController.present(controller, animated: true)
        } else if uiViewController.presentedViewController is UIActivityViewController {
            uiViewController.dismiss(animated: true)
        }
    }

    func makeCoordinator() -> PresentationDelegate { PresentationDelegate() }

    /// A safeguard beyond this iOS version (see the popover comment in
    /// `updateUIViewController`). The compact activity card never
    /// actually asks this delegate. But a future OS release, an iPad
    /// build, or a different activity item type might restore the
    /// classic adaptive popover behavior. This forces that case to a
    /// sheet too.
    final class PresentationDelegate: NSObject, UIPopoverPresentationControllerDelegate {
        func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
            .pageSheet
        }

        func adaptivePresentationStyle(
            for controller: UIPresentationController,
            traitCollection: UITraitCollection
        ) -> UIModalPresentationStyle {
            .pageSheet
        }
    }
}
