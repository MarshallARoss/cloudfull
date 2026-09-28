//
//  LivePhotoBundle.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UIKit
import UniformTypeIdentifiers

/// The `.pvt` Live Photo bundle. `<baseName>.pvt/` holds the still, under
/// its own extension, plus `<baseName>.MOV` and `metadata.plist`.
/// `LivePhotoBundleItemSource` hands this bundle to
/// `UIActivityViewController`. This is the path that delivers one real Live
/// Photo, with image and sound, into Messages through the ordinary share
/// sheet. AirDrop and Save Image also work from the same bundle.
///
/// The Share trio's Live pick is this bundle's only caller.
///
/// `metadata.plist` is lowercase and holds exactly one pair:
/// `PFVideoComplementMetadataVersionKey` set to the string "1". Apple does
/// not document this format. The value matches `RhetTbull/makelive` and
/// Apple Developer Forums thread 748082, byte for byte. The type
/// identifier and its conformances come from the system `CoreTypes.bundle`
/// Info.plist. The bundle's type identifier is
/// `com.apple.private.live-photo-bundle`, and it conforms to
/// `com.apple.live-photo`, `com.apple.bundle`, and `com.apple.package`.
enum LivePhotoBundle {
    static let typeIdentifier = "com.apple.private.live-photo-bundle"

    /// Builds the `.pvt` directory and returns its URL. Returns nil, and
    /// logs the failure, on any I/O error. `baseName` names the bundle
    /// directory and both files inside it: `<baseName>.pvt/<baseName>.<ext>`
    /// and `<baseName>.MOV`.
    static func make(still: URL, movie: URL, baseName: String) -> URL? {
        let stillExtension = still.pathExtension.isEmpty ? "HEIC" : still.pathExtension.uppercased()
        guard let directory = makeTemporaryDirectory(baseName: baseName) else { return nil }
        let bundleURL = directory.appendingPathComponent("\(baseName).pvt", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: still,
                to: bundleURL.appendingPathComponent("\(baseName).\(stillExtension)")
            )
            try FileManager.default.copyItem(
                at: movie,
                to: bundleURL.appendingPathComponent("\(baseName).MOV")
            )
            let plist: [String: Any] = ["PFVideoComplementMetadataVersionKey": "1"]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: bundleURL.appendingPathComponent("metadata.plist"))
        } catch {
            log("share_bundle_build_failed_\(error)")
            return nil
        }
        log("share_bundle_built_\(bundleURL.lastPathComponent)")
        return bundleURL
    }

    private static func makeTemporaryDirectory(baseName: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudfullShare", isDirectory: true)
            .appendingPathComponent("bundle-\(baseName)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            log("share_bundle_temp_directory_failed_\(error)")
            return nil
        }
    }

    /// Deletes any `.pvt` package under `tmp/CloudfullShare/` older than one
    /// hour. `ShareCoordinator.purgeShareDirectory()` empties that whole
    /// tree on every launch, so this normally finds nothing. A Messages or
    /// AirDrop hand-off can keep a bundle open across a backgrounding. This
    /// cleanup removes such bundles, so large `.pvt` packages do not
    /// collect between cold starts. `CloudfullApp.init()` calls this once.
    static func cleanupStaleBundles() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudfullShare", isDirectory: true)
        guard let bundleDirectories = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: []
        ) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        var removed = 0
        for directory in bundleDirectories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: []
            ) else { continue }
            for entry in contents where entry.pathExtension == "pvt" {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified < cutoff else { continue }
                try? FileManager.default.removeItem(at: directory)   // Removes the whole parent directory, not just the .pvt entry.
                removed += 1
            }
        }
        log("share_bundle_cleanup_removed_\(removed)")
    }

    private static func log(_ message: String) {
        #if DEBUG
        guard DiagnosticsGate.isOn("-cloudfull-log-share") else { return }
        DiagnosticsLog.shared.log("LivePhotoBundle", message)
        #endif
    }
}

/// The Share trio's Live pick. Hands Messages and AirDrop the `.pvt`
/// bundle, since only those two activities can recompose a package into
/// one Live Photo. Hands every other activity (Mail, Copy, Save Image, and
/// so on) the plain still. Picking Live does not break any other option
/// on the share sheet.
final class LivePhotoBundleItemSource: NSObject, UIActivityItemSource {
    private let pvtURL: URL
    private let stillURL: URL

    private static let bundleActivityTypes: Set<UIActivity.ActivityType> = [.message, .airDrop]

    init(pvtURL: URL, stillURL: URL) {
        self.pvtURL = pvtURL
        self.stillURL = stillURL
    }

    /// Sizes and types the share sheet's initial preview and eligibility
    /// check, before any activity is chosen. The placeholder is the still,
    /// not the `.pvt` bundle. On the simulator, the share sheet cannot
    /// resolve `com.apple.private.live-photo-bundle` from a directory URL.
    /// It reads the still inside the bundle instead. So the header shows
    /// the still's name either way, and the still is the placeholder
    /// proven to work for Messages and AirDrop.
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        stillURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        guard let activityType, Self.bundleActivityTypes.contains(activityType) else {
            return stillURL
        }
        return pvtURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        guard let activityType, Self.bundleActivityTypes.contains(activityType) else {
            return UTType.heic.identifier
        }
        return LivePhotoBundle.typeIdentifier
    }
}
