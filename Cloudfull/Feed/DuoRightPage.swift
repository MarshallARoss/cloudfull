//
//  DuoRightPage.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Photos

/// The Duo book pose's (4/4W) right page — `design/duo/duo_build_spec.md`
/// §3b: the "Same day" 3×3 grid and the "Biggest" list, as two tabs of
/// one page, remembered in `@AppStorage("duo.rightPage")`.
///
/// Mounted ONCE by `FeedView`, in `DuoLayout.rightPage`'s own rect, for
/// the centred page only — `design/duo/duo_audit_apple_checklist.md`
/// §2: "a hoisted shared panel is the correct architecture for the
/// secondary content ... it describes the CURRENT item, not a page."
/// Never per-page inside `FeedPageContent`: with up to three pages
/// mounted in the ±1 preload window, a per-page instance would run
/// this view's PhotoKit queries three times over for content only the
/// centred page's own rect ever shows. `FeedPageContent`'s own
/// `duoBookCaption` (the metadata line "under the grid") stays exactly
/// where it already was — this view leaves clearance for it rather
/// than drawing over it; see `contentRect`.
///
/// The book's own video stays on the left page throughout: tapping a
/// tile or a row never changes which page is centred, only which
/// asset plays there next (`DeckViewModel.insertNext`, via `onPlay`).
struct DuoRightPage: View {
    /// The centred page's own asset id — `FeedView`'s own
    /// `currentPageID` resolved to a deck entry. Every query below
    /// re-runs when this changes (`reload()`, via `.task(id:)`).
    let currentAssetID: String
    /// `DuoLayout.rightPage`'s own rect for this frame — `nil` (this
    /// view unmounted) whenever the book pose has no active division
    /// to anchor against; `FeedView` is the one caller that checks
    /// that before mounting this view at all.
    let rect: CGRect
    let viewModel: DeckViewModel
    @ObservedObject var trashService: TrashService
    @ObservedObject var shrinkService: ShrinkService
    /// Plays `assetID` next on the LEFT page — `FeedView
    /// .playNextFromRightPage`, which wraps `DeckViewModel.insertNext`
    /// and the pager's own `advanceTargetID`/`advanceNonce` scroll
    /// (§3b's own words: "F then runs the existing … scroll").
    let onPlay: (String) -> Void
    /// Opens the shrink confirm sheet for `assetID` — the same
    /// `FeedView.requestShrink(assetID:)` the rail's own Shrink button
    /// already calls.
    let onRequestShrink: (String) -> Void
    /// Queues or restores `assetID` — `FeedView
    /// .handleRightPageDelete`, the Biggest list's own mirror of
    /// `FeedPageContent.handleTrashTap` (same guards, same trash
    /// queue), minus that function's own `onAdvanceRequested()`: a
    /// list row is never the page the pager is centred on, so there is
    /// nothing to advance away from.
    let onDelete: (DuoContextQueries.BiggestAsset) -> Void

    @AppStorage("duo.rightPage") private var selectedTabRaw = Tab.sameDay.rawValue
    @ObservedObject private var resolver = AssetKeyResolver.shared

    @State private var sameDay: DuoContextQueries.SameDayResult?
    @State private var biggest: DuoContextQueries.BiggestResult?
    /// The day key `DuoContextQueries.thumbnail(for:dayKey:side:)`
    /// caches under — `sameDay.referenceDate`'s start of day, or
    /// `weekInterval.start` after a fallback, same key for every tile
    /// on one render so a video change evicts the whole page's images
    /// together. `nil` until the first `reload()` completes.
    @State private var dayKey: Date?
    @State private var isLoading = false

    private enum Tab: String, CaseIterable { case sameDay, biggest }
    private var selectedTab: Tab { Tab(rawValue: selectedTabRaw) ?? .sameDay }

    /// Leaves `FeedPageContent.duoBookCaption`'s own clearance at the
    /// bottom of the page (its text sits bottom-leading, "bottom 30,"
    /// a two-line block about 50pt tall) — approximated, not measured
    /// against a real caption render; flagged for the owner's own look
    /// at the sim, the same category of approximation this file's
    /// sibling `DuoLayout` functions already flag their own numbers
    /// with.
    private var contentRect: CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - 80))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Right page content", selection: Binding(
                get: { selectedTab },
                set: { selectedTabRaw = $0.rawValue }
            )) {
                Text("Same day").tag(Tab.sameDay)
                Text("Biggest").tag(Tab.biggest)
            }
            .pickerStyle(.segmented)
            .colorScheme(.dark)
            .accessibilityIdentifier("duo_right_page_tabs")

            ScrollView(.vertical) {
                switch selectedTab {
                case .sameDay: sameDayTab
                case .biggest: biggestTab
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .frame(width: contentRect.width, height: contentRect.height, alignment: .top)
        .position(x: contentRect.midX, y: contentRect.midY)
        .task(id: currentAssetID) { await reload() }
        .onChange(of: trashService.count) { _, _ in Task { await reload() } }
        .onChange(of: shrinkService.jobs.count) { _, _ in Task { await reload() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duo_right_page")
    }

    // MARK: - Same day

    @ViewBuilder
    private var sameDayTab: some View {
        if let sameDay, let dayKey {
            VStack(alignment: .leading, spacing: 10) {
                Text(sameDayHeader(sameDay))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                sameDayGrid(sameDay, dayKey: dayKey)
            }
        } else if isLoading {
            ProgressView().tint(.white).padding(.top, 20)
        }
    }

    /// 3×3, "tile width `(pageWidth − 40 − 2·10)/3`, height ×1.55, gap
    /// 10" (§3b). `pageWidth` is `contentRect.width`, measured live —
    /// never a fixed page size.
    private func sameDayGrid(_ result: DuoContextQueries.SameDayResult, dayKey: Date) -> some View {
        let tileWidth = max(0, (contentRect.width - 40 - 2 * 10) / 3)
        let tileSize = CGSize(width: tileWidth, height: tileWidth * 1.55)
        let columns = Array(repeating: GridItem(.fixed(tileWidth), spacing: 10), count: 3)
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(result.assets) { asset in
                SameDayTile(asset: asset, dayKey: dayKey, tileSize: tileSize) {
                    onPlay(asset.id)
                }
                .accessibilityIdentifier("duo_right_tile_\(asset.id)")
            }
        }
    }

    /// "Same day · Jun 8", or "Same week · Jun 3–9" once
    /// `usedWeekFallback` is true (§3b's own examples).
    private func sameDayHeader(_ result: DuoContextQueries.SameDayResult) -> String {
        if result.usedWeekFallback, let interval = result.weekInterval {
            let start = interval.start
            let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return "Same week · \(Self.monthDayFormatter.string(from: start))–\(Self.dayFormatter.string(from: lastDay))"
        }
        return "Same day · \(Self.monthDayFormatter.string(from: result.referenceDate))"
    }

    // MARK: - Biggest

    @ViewBuilder
    private var biggestTab: some View {
        if let biggest, let dayKey {
            if biggest.items.isEmpty {
                Text("Nothing this week")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 20)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(biggest.items) { asset in
                        BiggestRow(
                            asset: asset,
                            dayKey: dayKey,
                            isLiked: resolver.isShielded(asset.id),
                            isQueued: trashService.isQueued(asset.id),
                            isJobbed: shrinkService.isJobbed(asset.id),
                            onPlay: { onPlay(asset.id) },
                            onShrink: { onRequestShrink(asset.id) },
                            onDelete: { onDelete(asset) }
                        )
                        .accessibilityIdentifier("duo_right_biggest_\(asset.id)")
                    }
                }
            }
        } else if isLoading {
            ProgressView().tint(.white).padding(.top, 20)
        }
    }

    // MARK: - Load

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()

    /// Resolves the centred page's own creation date, then runs both
    /// queries in parallel — `DuoContextQueries` does the narrowing;
    /// this view never enumerates the library itself. The date lookup
    /// is one `PHAsset.fetchAssets(withLocalIdentifiers:)` call, off
    /// main, the same primitive `PhotoLibraryService.fetchAsset(_:)`
    /// already is elsewhere in this file's sibling `DuoContextQueries`.
    private func reload() async {
        isLoading = true
        let assetID = currentAssetID
        let date = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.fetchAsset(assetID)?.creationDate
        }.value
        guard !Task.isCancelled else { return }
        guard let date else {
            sameDay = nil
            biggest = nil
            dayKey = nil
            isLoading = false
            return
        }
        async let sameDayResult = DuoContextQueries.sameDay(around: date, excluding: assetID)
        async let biggestResult = DuoContextQueries.biggestOfWeek(around: date)
        let resolvedSameDay = await sameDayResult
        let resolvedBiggest = await biggestResult
        guard !Task.isCancelled else { return }
        sameDay = resolvedSameDay
        biggest = resolvedBiggest
        dayKey = Calendar.current.startOfDay(for: date)
        isLoading = false
    }
}

// MARK: - Same day tile

private struct SameDayTile: View {
    let asset: DuoContextQueries.ContextAsset
    let dayKey: Date
    let tileSize: CGSize
    let action: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(Color.white.opacity(0.08))
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: tileSize.width, height: tileSize.height)
                        .clipped()
                }
                Text(Fmt.duration(asset.duration))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(5)
            }
            .frame(width: tileSize.width, height: tileSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: asset.id) {
            thumbnail = await DuoContextQueries.thumbnail(for: asset.id, dayKey: dayKey, side: tileSize.width * 2)
        }
        .accessibilityLabel("Play video, \(Fmt.duration(asset.duration)) long")
        .accessibilityHint("Plays next on the left page")
    }
}

// MARK: - Biggest row

private struct BiggestRow: View {
    let asset: DuoContextQueries.BiggestAsset
    let dayKey: Date
    let isLiked: Bool
    let isQueued: Bool
    let isJobbed: Bool
    let onPlay: () -> Void
    let onShrink: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: UIImage?

    /// "Disable both for kept videos," plus the same `isJobbed` guard
    /// `FeedPageContent.handleTrashTap` enforces before ever queuing a
    /// video `ShrinkService` is mid-export on — see that function's
    /// own comment for the race this avoids.
    private var canShrink: Bool {
        !isLiked && !isQueued && !isJobbed
            && Fmt.isAboveShrinkThreshold(CGSize(width: asset.pixelWidth, height: asset.pixelHeight))
    }
    private var canDelete: Bool { !isLiked && !isJobbed }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// "Jun 6 · 2:41" (§3b).
    private var dateLabel: String {
        let date = asset.creationDate.map(Self.dateFormatter.string(from:)) ?? ""
        let duration = Fmt.duration(asset.duration)
        return [date, duration].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Size, bold, "~" prefix when `AssetSize.isEstimated` — the same
    /// prefix `PhotoLibraryService`'s own byte-text helper uses.
    private var sizeLabel: String {
        (asset.size.isEstimated ? "~" : "") + Fmt.bytes(asset.size.bytes)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                HStack(spacing: 10) {
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.08))
                        if let thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(dateLabel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(sizeLabel)
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play video, \(dateLabel), \(sizeLabel)")
            .accessibilityHint("Plays next on the left page")

            Button(action: onShrink) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(canShrink ? .white : .white.opacity(0.3))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!canShrink)
            .accessibilityLabel("Shrink")

            Button(action: onDelete) {
                Image(systemName: isQueued ? "trash.fill" : "trash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(canDelete ? .white : .white.opacity(0.3))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
            .accessibilityLabel(isQueued ? "Queued for deletion" : "Delete")
        }
        .task(id: asset.id) {
            thumbnail = await DuoContextQueries.thumbnail(for: asset.id, dayKey: dayKey, side: 88)
        }
    }
}
