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
/// §3b: the "Same day" 3×3 grid (week fallback). Owner re-adapt after
/// seeing the book pose on the sim: "we don't need the picker for same
/// day and biggest at the top of 4. remove that" — the Biggest tab and
/// its segmented picker are gone; `DuoContextQueries.biggestOfWeek`
/// itself stays (untouched, in that file), unused by this view now but
/// not deleted, in case a future screen wants it.
///
/// Mounted ONCE by `FeedView`, in `DuoLayout.rightPage`'s own rect, for
/// the centred page only — `design/duo/duo_audit_apple_checklist.md`
/// §2: "a hoisted shared panel is the correct architecture for the
/// secondary content ... it describes the CURRENT item, not a page."
/// Never per-page inside `FeedPageContent`: with up to three pages
/// mounted in the ±1 preload window, a per-page instance would run
/// this view's PhotoKit queries three times over for content only the
/// centred page's own rect ever shows.
///
/// The book's own video stays on the left page throughout: tapping a
/// tile never changes which page is centred, only which asset plays
/// there next (`DeckViewModel.insertNext`, via `onPlay`).
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
    /// Plays `assetID` next on the LEFT page — `FeedView
    /// .playNextFromRightPage`, which wraps `DeckViewModel.insertNext`
    /// and the pager's own `advanceTargetID`/`advanceNonce` scroll
    /// (§3b's own words: "F then runs the existing … scroll").
    let onPlay: (String) -> Void

    @ObservedObject private var resolver = AssetKeyResolver.shared

    @State private var sameDay: DuoContextQueries.SameDayResult?
    /// The day key `DuoContextQueries.thumbnail(for:dayKey:side:)`
    /// caches under — `sameDay.referenceDate`'s start of day, or
    /// `weekInterval.start` after a fallback, same key for every tile
    /// on one render so a video change evicts the whole page's images
    /// together. `nil` until the first `reload()` completes.
    @State private var dayKey: Date?
    @State private var isLoading = false

    /// Owner re-adapt (pose pass, book pose): the right page's own
    /// header + grid, with no picker above it any more, start right at
    /// `rect`'s own top — the 80pt bottom clearance the first build
    /// reserved here for `FeedPageContent.duoBookCaption`'s own
    /// screen-bottom anchor is gone too, now that the caption follows
    /// the grid's own live bottom instead (`DuoRightPageMetrics`,
    /// below) rather than sitting at a fixed spot this view would
    /// otherwise have to dodge.
    private var contentRect: CGRect { rect }

    var body: some View {
        ScrollView(.vertical) {
            sameDayTab
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .frame(width: contentRect.width, height: contentRect.height, alignment: .top)
        .position(x: contentRect.midX, y: contentRect.midY)
        .task(id: currentAssetID) { await reload() }
        .onChange(of: trashService.count) { _, _ in Task { await reload() } }
        .onDisappear { DuoRightPageMetrics.shared.gridBottomY = nil }
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
        let tileWidth = Self.tileWidth(forContentWidth: contentRect.width)
        let tileSize = CGSize(width: tileWidth, height: tileWidth * Self.tileAspect)
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

    // MARK: - Grid geometry (shared with `DuoRightPageMetrics`)

    /// `tileWidth`'s own formula, pulled out so both the grid itself
    /// and the grid-bottom publish below (which needs it before any
    /// tile has actually laid out) read one definition.
    private static func tileWidth(forContentWidth width: CGFloat) -> CGFloat {
        max(0, (width - 40 - 2 * 10) / 3)
    }
    private static let tileAspect: CGFloat = 1.55
    /// The header line's own height plus the `VStack(spacing: 10)`
    /// gap above the grid — hand-measured (13pt semibold's own line
    /// height, about 18pt, plus that 10pt spacing), the same
    /// "measured/wireframe, no API" category `DuoLayout`'s own pose-
    /// table constants already use. Flagged for the owner's own look
    /// at the sim, same as those.
    private static let headerBlockHeight: CGFloat = 28

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

    /// Resolves the centred page's own creation date, then runs the
    /// query — `DuoContextQueries` does the narrowing; this view never
    /// enumerates the library itself. The date lookup is one
    /// `PHAsset.fetchAssets(withLocalIdentifiers:)` call, off main, the
    /// same primitive `PhotoLibraryService.fetchAsset(_:)` already is
    /// elsewhere in this file's sibling `DuoContextQueries`.
    private func reload() async {
        isLoading = true
        let assetID = currentAssetID
        let date = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.fetchAsset(assetID)?.creationDate
        }.value
        guard !Task.isCancelled else { return }
        guard let date else {
            sameDay = nil
            dayKey = nil
            isLoading = false
            DuoRightPageMetrics.shared.gridBottomY = nil
            return
        }
        let resolvedSameDay = await DuoContextQueries.sameDay(around: date, excluding: assetID)
        guard !Task.isCancelled else { return }
        sameDay = resolvedSameDay
        dayKey = Calendar.current.startOfDay(for: date)
        isLoading = false
        publishGridBottom(assetCount: resolvedSameDay.assets.count)
    }

    /// Owner re-adapt (pose pass): the date + "4K · 0:04 · 14 KB"
    /// caption used to sit fixed at the screen's own bottom edge;
    /// the wireframe puts it directly UNDER the grid instead, "small
    /// gap, e.g. 16pt." `FeedPageContent.duoBookCaption` is a
    /// per-page view with no direct binding to this, the one
    /// globally-mounted right page, so this publishes the grid's own
    /// live bottom edge (window space, the same space `rect` itself
    /// is in) through `DuoRightPageMetrics.shared` — the same
    /// cross-view sharing shape `AssetKeyResolver.shared`/
    /// `ScrollPhaseGate.shared` already use elsewhere in this app for
    /// exactly this kind of structurally-separate-view state.
    ///
    /// Follows a 2-row or 3-row grid (or fewer): `rows` is `0` for an
    /// empty result (no grid at all, caption falls back), else
    /// `⌈assetCount / 3⌉`.
    private func publishGridBottom(assetCount: Int) {
        guard assetCount > 0 else {
            DuoRightPageMetrics.shared.gridBottomY = nil
            return
        }
        let rows = Int((Double(assetCount) / 3.0).rounded(.up))
        let tileWidth = Self.tileWidth(forContentWidth: contentRect.width)
        let tileHeight = tileWidth * Self.tileAspect
        let gridHeight = CGFloat(rows) * tileHeight + CGFloat(max(0, rows - 1)) * 10
        let gridTop = contentRect.minY + 16 + Self.headerBlockHeight
        DuoRightPageMetrics.shared.gridBottomY = gridTop + gridHeight
    }
}

/// See `DuoRightPage.publishGridBottom`'s own comment: the grid's live
/// bottom edge, shared from the one globally-mounted `DuoRightPage` to
/// every per-page `FeedPageContent.duoBookCaption` that needs it.
@MainActor
final class DuoRightPageMetrics: ObservableObject {
    static let shared = DuoRightPageMetrics()
    /// Window-space y, or `nil` when there is no loaded grid to anchor
    /// against (not yet loaded, no active right page, or an empty
    /// result) — `duoBookCaption` falls back to its own old
    /// screen-bottom anchor in that case.
    @Published var gridBottomY: CGFloat?
    private init() {}
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
