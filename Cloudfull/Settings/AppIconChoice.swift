//
//  AppIconChoice.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Lets the user pick between two app icons from a Settings row.
///
/// Both icons show the same cloud mark on two different backgrounds.
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` declares the alternate
/// icon, and `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS` includes
/// it in the build. Both icons live in the asset catalog, not as loose
/// files in the bundle.
///
/// iOS shows its own alert on every icon change. A public API cannot
/// suppress this alert.
@MainActor
enum AppIconChoice: String, CaseIterable, Identifiable {
    /// The blue background. This is the primary icon, and passes `nil` to
    /// `setAlternateIconName`.
    case blue
    /// The white background.
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: return "Blue"
        case .light: return "White"
        }
    }

    /// The value `setAlternateIconName` expects. `nil` means return to the
    /// primary icon.
    var alternateName: String? {
        switch self {
        case .blue: return nil
        case .light: return "AppIconLight"
        }
    }

    /// The bundled preview image for the Settings row. The catalog's own
    /// icons compile into `Assets.car` and cannot load by name at runtime,
    /// so each icon needs a separate preview image.
    var previewResource: String {
        switch self {
        case .blue: return "AppIconPreview"
        case .light: return "AppIconLightPreview"
        }
    }

    /// The icon currently shown on the Home Screen.
    static var current: AppIconChoice {
        guard let name = UIApplication.shared.alternateIconName else { return .blue }
        return AppIconChoice.allCases.first { $0.alternateName == name } ?? .blue
    }

    /// Applies the chosen icon. Does nothing when that icon is already
    /// set, so opening Settings does not trigger the system alert by
    /// itself.
    static func apply(_ choice: AppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        guard UIApplication.shared.alternateIconName != choice.alternateName else { return }
        UIApplication.shared.setAlternateIconName(choice.alternateName) { error in
            Task { @MainActor in
                if error == nil {
                    Usage.shared.appIconChanged(to: choice.rawValue)
                } else {
                    Usage.shared.appIconChangeFailed()
                }
            }
        }
    }
}
