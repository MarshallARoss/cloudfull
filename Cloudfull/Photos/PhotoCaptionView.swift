//
//  PhotoCaptionView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The caption block under a photo post's actions row, styled like an
/// Instagram caption. Tier-1 fields (line 1) render as soon as
/// `PhotoPostView` has them.
///
/// "…" shows only while a tier-2 request for this post is in flight
/// (`showsPlaceholder`; `PhotoPostView` times it out after 3 s). In
/// every other case with no tier 2, this view shows nothing. This
/// includes never requested, resolved empty, and timed out. A tier 2
/// that landed with every field empty also shows nothing. A missing
/// line reads as "this photo has no camera data"; a permanent "…"
/// reads as broken.
struct PhotoCaptionView: View {
    let tier1: PhotoMetadata.Tier1
    let tier2: PhotoMetadata.Tier2?
    let isCurrent: Bool
    /// True only while a tier-2 load for this post is actually running and
    /// has not passed its timeout. The one thing that may render "…".
    let showsPlaceholder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            dimensionsLine
            cameraLine
            albumsLine
        }
        .padding(.horizontal, 16)
        // This block is its own accessibility container, so a bare
        // identifier on this `VStack` cannot outrank the `photo_meta_*`
        // children. `feed_caption`'s neighbor, the `page_<slot>_`
        // container, exists to avoid the same problem. See
        // `FeedView.pager`'s identifier comment.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isCurrent ? "photo_caption" : "")
    }

    private var dotText: some View {
        Text("·").foregroundStyle(.white.opacity(0.5))
    }

    // MARK: - Line 1: dimensions · format · size (tier 1)

    private var dimensionsLine: some View {
        HStack(spacing: 6) {
            Text(tier1.dimensionsText)
                .accessibilityIdentifier(isCurrent ? "photo_meta_dimensions" : "")
            if !tier1.formatText.isEmpty {
                dotText
                Text(tier1.formatText)
                    .accessibilityIdentifier(isCurrent ? "photo_meta_format" : "")
            }
            dotText
            Text(tier1.sizeText)
                .accessibilityIdentifier(isCurrent ? "photo_meta_size" : "")
        }
        .captionStyle()
    }

    // MARK: - Line 2: camera · lens · exposure (tier 2)

    /// One entry per EXIF field that has a value. A field that came back
    /// empty is dropped from the line, not shown as a permanent "—". The
    /// order is camera, then lens, then exposure.
    private struct CameraField { let identifier: String; let text: String }

    private var cameraFields: [CameraField] {
        guard let tier2, !tier2.needsICloud else { return [] }
        var fields: [CameraField] = []
        if let camera = tier2.cameraText, !camera.isEmpty {
            fields.append(.init(identifier: "photo_meta_camera", text: camera))
        }
        if let lens = tier2.lensText, !lens.isEmpty {
            fields.append(.init(identifier: "photo_meta_lens", text: lens))
        }
        if let exposure = tier2.exposureText, !exposure.isEmpty {
            fields.append(.init(identifier: "photo_meta_exposure", text: exposure))
        }
        return fields
    }

    /// A non-local original has empty `cameraFields` (see the
    /// `needsICloud` guard in `cameraFields`), because
    /// `PhotoMetadata.loadTier2` does not read EXIF for it. This view
    /// shows nothing for it, the same as a local original with no EXIF
    /// values. Neither case shows a placeholder line, only whatever
    /// fields exist.
    @ViewBuilder
    private var cameraLine: some View {
        if tier2 != nil {
            if !cameraFields.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(cameraFields.enumerated()), id: \.offset) { index, field in
                        if index > 0 { dotText }
                        Text(field.text)
                            .accessibilityIdentifier(isCurrent ? field.identifier : "")
                    }
                }
                .captionStyle()
            }
        } else if showsPlaceholder {
            Text("…").captionStyle()
        }
    }

    // MARK: - Line 3: albums (tier 2), omitted once loaded with none

    @ViewBuilder
    private var albumsLine: some View {
        if let tier2 {
            if let albums = tier2.albumsText, !albums.isEmpty {
                Text("In: \(albums)")
                    .captionStyle()
                    .accessibilityIdentifier(isCurrent ? "photo_meta_albums" : "")
            }
        }
        // No `else`: the "…" above already says a load is running. Two
        // placeholder lines for one pending request read as two broken
        // rows.
    }
}

private extension View {
    /// Shared styling for every `PhotoCaptionView` row: 13 pt, monospaced
    /// digits, white at 85% opacity. No shadow: the caption sits on the
    /// feed's solid black background, not over the image, so it needs no
    /// shadow for contrast.
    func captionStyle() -> some View {
        font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.85))
    }
}
