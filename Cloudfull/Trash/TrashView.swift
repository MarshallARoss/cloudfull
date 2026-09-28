//
//  TrashView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Foundation
import UIKit
import AVFoundation

/// Grid of every item queued for deletion. Restoring an item is instant and
/// local. Only "Empty Bin" touches PhotoKit. It shows one system
/// confirmation for the whole batch. The app does not show its own
/// confirmation in addition to the system one.
///
/// The visual design matches Photos' Recently Deleted screen.
struct TrashView: View {
    @ObservedObject var trashService: TrashService
    @Environment(\.dismiss) private var dismiss

    @State private var isEmptying = false
    @State private var freedMessage: String?
    /// True when a cell's restore attempt fails, for example a SwiftData
    /// save error on a device with no storage left. A failed restore in any
    /// cell sets it. The next successful restore in any cell clears it.
    /// Leaving this sheet also clears it. To retry, the user taps the cell
    /// again.
    @State private var restoreFailed = false
    /// Set when the user taps a cell, so the tap opens a preview instead of
    /// restoring the item immediately. Uses the same `Identifiable`-wrapper
    /// pattern as `FeedView.ShrinkTarget`.
    @State private var previewTarget: PreviewTarget?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private struct PreviewTarget: Identifiable {
        let id: String // assetKey
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if trashService.count > 0 || freedMessage != nil || restoreFailed || trashService.reclaimedBytes > 0 {
                        headerCount
                    }

                    if trashService.entries.isEmpty {
                        ContentUnavailableView(
                            "Bin Is Empty",
                            systemImage: "trash",
                            description: Text("Nothing leaves your Photos app until you empty the bin.")
                        )
                        .padding(.top, 40)
                        .accessibilityIdentifier("trash_empty_state")
                    } else {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(trashService.entries, id: \.assetKey) { entry in
                                TrashCell(
                                    entry: entry,
                                    trashService: trashService,
                                    onRestoreResult: handleRestoreResult,
                                    onPreviewRequested: { Usage.shared.binPreviewOpened(); previewTarget = PreviewTarget(id: entry.assetKey) }
                                )
                            }
                        }
                    }

                    if !trashService.entries.isEmpty {
                        footerExplainer
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Disables the whole grid, including every restore button, for
            // the entire batch delete, not only the Empty Bin button.
            // Without this, a restore tapped while `emptyBin()` awaits
            // `PHPhotoLibrary.performChanges` removes the row from the queue
            // while PhotoKit is still deleting the asset. The app then shows
            // the item as restored, but PhotoKit still deletes it.
            .disabled(isEmptying)
            .navigationTitle("Bin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isEmptying)
                }
                ToolbarItem(placement: .bottomBar) { emptyButton }
            }
        }
        .presentationDragIndicator(.visible)
        // The batch delete is irreversible once it starts. A swipe dismiss
        // during the delete lets the user believe they can still restore
        // an item that PhotoKit is about to delete.
        .interactiveDismissDisabled(isEmptying)
        // The failed-restore banner applies only to one visit of this sheet.
        // Leaving the sheet clears it, so a stale message does not appear
        // the next time the bin opens.
        .onDisappear { restoreFailed = false }
        .sheet(item: $previewTarget) { target in
            TrashPreviewView(assetKey: target.id, trashService: trashService)
        }
        // Runs each time this sheet appears, because `.sheet(isPresented:)`
        // makes a new `TrashView` each time. It checks which queued assets
        // still exist in the library immediately.
        .task { await trashService.refreshLiveness() }
    }

    /// A `false` result means the restore save failed, so the row is still
    /// queued. The banner then tells the user to tap the cell again. A
    /// `true` result, from any cell, clears the banner.
    private func handleRestoreResult(_ succeeded: Bool) {
        if succeeded {
            restoreFailed = false
        } else {
            restoreFailed = true
            AccessibilityNotification.Announcement("Couldn't restore that video. Tap it again.").post()
        }
    }

    // MARK: - Header count

    private var headerCount: some View {
        VStack(spacing: 2) {
            Text(countLine)
            if let freedMessage {
                Text(freedMessage)
            }
            // reclaimedBytes is the total bytes Empty Bin has freed across
            // all sessions. UI tests find this pill by
            // `shrink_saved_counter`. Do not rename the identifier.
            if trashService.reclaimedBytes > 0 {
                Text("\(Fmt.bytes(trashService.reclaimedBytes)) reclaimed all time")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .feedGlass(in: Capsule())
                    .padding(.top, 4)
                    .accessibilityIdentifier("shrink_saved_counter")
                    .accessibilityLabel("\(Fmt.bytes(trashService.reclaimedBytes)) reclaimed all time, across every bin empty")
            }
            if restoreFailed {
                Text("Couldn't restore that video. Tap it again.")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("trash_restore_failed")
            }
        }
        .font(.footnote)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // Do not add an `.accessibilityIdentifier` to this VStack. A
        // container identifier replaces the identifier of each child. It
        // would hide `shrink_saved_counter` on the pill and
        // `trash_restore_failed` on the banner.
        //
        // The same issue applies to `trash_preview_` and `trash_restore_`
        // later in this file.
    }

    /// Builds the count line: "x videos · y photos · <bytes>". It leaves
    /// out a kind with a zero count. It adds "About " before the bytes
    /// when a size is an estimate. Each kind uses singular or plural as
    /// needed.
    private var countLine: String {
        guard trashService.count > 0 else { return "" }
        let prefix = trashService.hasEstimatedSizes ? "About " : ""
        var kindParts: [String] = []
        let videoCount = trashService.videoCount
        let photoCount = trashService.photoCount
        if videoCount > 0 {
            kindParts.append("\(videoCount) \(videoCount == 1 ? "video" : "videos")")
        }
        if photoCount > 0 {
            kindParts.append("\(photoCount) \(photoCount == 1 ? "photo" : "photos")")
        }
        let kinds = kindParts.joined(separator: " \u{00B7} ")
        return "\(kinds) \u{00B7} \(prefix)\(Fmt.bytes(trashService.pendingBytes))"
    }

    // MARK: - Empty Bin button

    private var emptyButton: some View {
        Button(role: .destructive) {
            Task { await performEmpty() }
        } label: {
            if isEmptying {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Emptying\u{2026}")
                }
            } else {
                Text("Empty Bin")
            }
        }
        .tint(.red)   // `role: .destructive` alone does not render red in the bottom bar.
        .disabled(trashService.count == 0 || isEmptying)
        .accessibilityIdentifier("trash_empty")
        .accessibilityLabel("Empty bin")
        .accessibilityHint(trashService.count > 0
            ? "Deletes \(trashService.count) videos from Photos. iOS asks you to confirm."
            : "No videos are queued")
    }

    // MARK: - Footer explainer

    /// Shown only while the bin holds at least one item.
    private var footerExplainer: some View {
        Text("Emptying the bin moves these to Recently Deleted in Photos. They stay there 30 days, or until you delete them from there.")
        .accessibilityIdentifier("trash_explainer")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    /// Calls `emptyBin()`, which calls PhotoKit's delete. This is the only
    /// point in this screen where the system confirmation dialog appears.
    /// A `nil` result means the user canceled the dialog, PhotoKit failed,
    /// or the queue is not safe to delete. In each case the queue does not
    /// change. An empty result means none of the queued ids still resolved
    /// in the library, so the delete frees nothing.
    private func performEmpty() async {
        isEmptying = true
        Usage.shared.binEmptyAttempted()   // Counts each Empty Bin tap. Compare with `binEmptied` to find how many users cancel the system dialog.
        // Record the bytes for each id before the delete. Do not read
        // `trashService.pendingBytes` after it. PhotoKit skips an id that
        // no longer resolves. The freed-space message counts only deleted
        // ids.
        let entriesBeingFreed = trashService.entries
        let deletedIDs = await trashService.emptyBin()
        isEmptying = false
        guard let deletedIDs, !deletedIDs.isEmpty else { return }

        let freedEntries = entriesBeingFreed.filter { deletedIDs.contains($0.assetKey) }
        // Uses the same `max(bytes - replacementBytes, 0)` expression as
        // `TrashService.pendingBytes` and `reclaimedBytes`. This message
        // and the reclaimed pill then show the same figure.
        let freedBytes = freedEntries.reduce(Int64(0)) { $0 + max($1.bytes - $1.replacementBytes, 0) }
        let isEstimated = freedEntries.contains { $0.isEstimatedBytes }
        let prefix = isEstimated ? "About " : ""
        // iOS keeps a deleted asset in Photos > Recently Deleted for 30
        // days. The storage becomes free after that. The message says
        // "will free up" so it matches what Settings > iPhone Storage
        // shows now.
        withAnimation {
            freedMessage = "\(prefix)\(Fmt.bytes(freedBytes)) will free up once Photos empties Recently Deleted (up to 30 days)."
        }

        // The sheet stays open after Empty Bin finishes and shows the
        // freed message and the reclaimed counter. The Done button or a
        // swipe down closes the sheet.
    }

}

/// One grid cell: a thumbnail that opens a preview, plus its own small
/// restore glyph.
///
/// A tap on the cell opens a looping preview (`TrashPreviewView`), as in
/// the Recently Deleted screen in Photos. Only an explicit control removes
/// an item from the queue: the glyph here, or Restore inside the preview
/// sheet.
///
/// `trash_restore_<assetKey>` must stay on a directly tappable restore
/// control. `M2TrashTests.testTrashQueueRestoreEmpty` taps
/// `app.buttons["trash_restore_<id>"]` and checks that the button
/// disappears. The identifier lives on `restoreGlyph`.
private struct TrashCell: View {
    let entry: TrashEntry
    let trashService: TrashService
    /// Receives the result of each restore attempt from this cell.
    /// `TrashView` uses it to show or clear the failure banner.
    let onRestoreResult: (Bool) -> Void
    /// Called when the user taps the cell anywhere except the restore
    /// glyph.
    let onPreviewRequested: () -> Void

    @State private var thumbnail: UIImage?
    @State private var durationText = ""
    private let library = PhotoLibraryService.shared

    /// True when neither the stored key nor the cloud key names a live
    /// asset now. Reads `trashService.isLive(assetKey:)`. A row is dormant
    /// only after a liveness check confirms the asset is missing.
    /// `entry.dormantSince` only controls when the row leaves the queue.
    private var isDormant: Bool {
        !trashService.isLive(assetKey: entry.assetKey)
    }

    /// Duration applies only to a video. `PHAsset.duration` reads 0 for a
    /// photo, so the overlay and label skip duration entirely for a photo
    /// row instead of showing "0:00".
    private var isVideo: Bool { entry.mediaKind != TrashMediaKind.photo.rawValue }
    private var mediaNoun: String { isVideo ? "Video" : "Photo" }

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail, !isDormant {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.4)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                // A photo shows no duration badge, not even a dash, matching
                // Photos' Recently Deleted grid, which badges only videos.
                if isVideo {
                    Text(isDormant ? "\u{2014}" : durationText)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.trailing, 5)
                        .padding(.bottom, 4)
                }
            }
            .overlay(alignment: .topTrailing) { restoreGlyph }
            // `replacementBytes` is the size of the 1080p copy that replaced
            // this original. It is zero for a row that did not come from a
            // shrink. A positive value marks a row whose original the user
            // did not choose to delete directly.
            .overlay(alignment: .topLeading) {
                if entry.replacementBytes > 0 {
                    Text("Shrunk")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.leading, 4)
                        .padding(.top, 4)
                        .accessibilityIdentifier("trash_shrunk_\(entry.assetKey)")
                        .accessibilityLabel("Shrunk: the original of a video Cloudfull replaced with a smaller copy")
                }
            }
            .overlay(alignment: .top) {
                if isDormant {
                    Text("Not available right now")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.top, 4)
                        .accessibilityIdentifier("trash_dormant_\(entry.assetKey)")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // A dormant asset does not resolve, so no preview can
                // load. The `.task` below skips the thumbnail and
                // duration fetch for the same reason.
                guard !isDormant else { return }
                onPreviewRequested()
            }
            .task {
                // A dormant row's stored key names nothing right now. Skip
                // the PhotoKit fetch instead of fetching a thumbnail or
                // duration that comes back empty.
                guard !isDormant else { return }
                thumbnail = await library.thumbnail(for: entry.assetKey, side: 200)
                if isVideo {
                    durationText = Fmt.duration(library.asset(for: entry.assetKey)?.duration ?? 0)
                }
            }
            // Uses `.accessibilityElement(children: .contain)` so
            // `trash_preview_` stays on the cell only. A bare identifier
            // on this group replaces child identifiers, which hides
            // `trash_restore_<assetKey>` on `restoreGlyph`.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trash_preview_\(entry.assetKey)")
            .accessibilityLabel(isDormant
                ? "\(mediaNoun), not available right now"
                : (isVideo ? "\(mediaNoun), \(durationText)" : mediaNoun))
            .accessibilityHint(isDormant ? "" : "Opens a preview of this \(mediaNoun.lowercased())")
            // Do not add `.isButton` or a default `.accessibilityAction`
            // to this container. Either one makes the container a leaf
            // element. A leaf element hides `trash_restore_<assetKey>`,
            // and VoiceOver cannot reach Restore. A named action gives
            // the preview.
            .accessibilityAction(named: "Preview") {
                guard !isDormant else { return }
                onPreviewRequested()
            }
    }

    /// The one directly tappable restore control on this cell. It is a
    /// separate `Button` in an overlay. SwiftUI sends a tap in its frame
    /// to this button, not to the cell's `onTapGesture`.
    private var restoreGlyph: some View {
        Button {
            let restored = trashService.restore(assetID: entry.assetKey)
            if restored { Usage.shared.binRestore() }
            withAnimation { onRestoreResult(restored) }
        } label: {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 18))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.35))
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("trash_restore_\(entry.assetKey)")
        .accessibilityLabel(isDormant
            ? "Restore \(mediaNoun.lowercased()), not available right now"
            : (isVideo ? "Restore \(mediaNoun.lowercased()), \(durationText)" : "Restore \(mediaNoun.lowercased())"))
        .accessibilityHint("Removes this \(mediaNoun.lowercased()) from the trash queue")
    }
}

/// Preview of an item in the bin, as in the Recently Deleted screen in
/// Photos. A video loops and starts muted. A photo shows as a still
/// image. The only actions are Restore (the same `TrashService.restore`
/// that the cell glyph calls) and Close.
private struct TrashPreviewView: View {
    let assetKey: String
    @ObservedObject var trashService: TrashService
    @Environment(\.dismiss) private var dismiss

    private let library = PhotoLibraryService.shared
    @State private var player = AVPlayer()
    @State private var isMuted = true
    @State private var loadFailed = false
    @State private var endObserver: NSObjectProtocol?
    /// Holds the loaded image for a photo entry, since a photo has no
    /// player item.
    @State private var photo: UIImage?

    private var isPhoto: Bool {
        trashService.entries.first { $0.assetKey == assetKey }?.mediaKind == TrashMediaKind.photo.rawValue
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if loadFailed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                        Text(isPhoto ? "Couldn't load this photo" : "Couldn't load this video")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                } else if isPhoto {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFit()
                            .accessibilityIdentifier("preview_photo")
                    } else {
                        ProgressView().tint(.white)
                    }
                } else {
                    TrashPreviewPlayerView(player: player)
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A photo has no sound, so the toolbar has no mute item.
                // Do not hide the item instead, because a hidden item
                // draws an empty glass capsule.
                if !isPhoto {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isMuted.toggle()
                            player.isMuted = isMuted
                        } label: {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        .accessibilityIdentifier("preview_mute_toggle")
                        .accessibilityLabel(isMuted ? "Sound off" : "Sound on")
                        .accessibilityHint("Double tap to turn sound \(isMuted ? "on" : "off")")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Restore") {
                        if trashService.restore(assetID: assetKey) { Usage.shared.binRestore() }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("preview_restore")
                    .accessibilityLabel("Restore")
                    .accessibilityHint(isPhoto ? "Removes this photo from the trash queue" : "Removes this video from the trash queue")

                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("preview_close")
                        .accessibilityLabel("Close")
                        .accessibilityHint("Closes this preview without changing the trash queue")
                }
                .padding()
                .background(.bar)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            if isPhoto {
                // Loads the photo at screen size with aspect fit. It uses
                // the same fetch as the bin thumbnails. The service does
                // the fetch off the main thread.
                let side = UIScreen.main.bounds.height * UIScreen.main.scale
                guard let image = await library.thumbnail(for: assetKey, side: side, contentMode: .aspectFit) else {
                    loadFailed = true
                    return
                }
                photo = image
                return
            }
            guard let item = await library.playerItem(for: assetKey) else {
                loadFailed = true
                return
            }
            player.replaceCurrentItem(with: item)
            player.isMuted = isMuted
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    player.seek(to: .zero)
                    player.play()
                }
            }
            player.play()
        }
        .onDisappear {
            player.pause()
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
        }
    }
}

/// An `AVPlayerLayer` view for `TrashPreviewView`. It shows aspect-fit
/// video on black with no AVKit controls, like `PlayerPageView`. It does
/// not reuse the private player view in `PlayerPageView`, because this
/// preview needs no scrubbing, preloading, or fullscreen.
private struct TrashPreviewPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> TrashPreviewPlayerContainerView {
        let view = TrashPreviewPlayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: TrashPreviewPlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

private final class TrashPreviewPlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }
}
