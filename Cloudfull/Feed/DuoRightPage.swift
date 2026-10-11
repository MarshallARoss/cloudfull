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
    /// the grid's own live bottom instead (`DuoRightGridBottomKey`,
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
    ///
    /// Owner re-adapt (pose pass, book pose, second round): the
    /// `GeometryReader` background reports this grid's own real,
    /// just-laid-out bottom edge through `DuoRightGridBottomKey` —
    /// see that type's own comment. Replaces a formula that
    /// recomputed the same shape (`rows`/`tileHeight`/`gridHeight`)
    /// by hand from `result.assets.count` alone, published once from
    /// `reload()` after its own async query finished: two
    /// descriptions of the same layout, one of them always a frame or
    /// more behind whatever SwiftUI actually drew. Reading the real
    /// layout directly removes the second description entirely.
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
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: DuoRightGridBottomKey.self, value: proxy.frame(in: .global).maxY)
            }
        )
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

    // MARK: - Grid geometry

    /// `tileWidth`'s own formula — the grid's own `sameDayGrid` is
    /// this type's one caller now that the grid-bottom publish reads
    /// the real laid-out grid instead of recomputing its shape by
    /// hand (see `DuoRightGridBottomKey`).
    private static func tileWidth(forContentWidth width: CGFloat) -> CGFloat {
        max(0, (width - 40 - 2 * 10) / 3)
    }
    private static let tileAspect: CGFloat = 1.55

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
            return
        }
        let resolvedSameDay = await DuoContextQueries.sameDay(around: date, excluding: assetID)
        guard !Task.isCancelled else { return }
        sameDay = resolvedSameDay
        dayKey = Calendar.current.startOfDay(for: date)
        isLoading = false
    }
}

/// `FeedView.duoBookCaption`'s own anchor — the book pose's (4/4W)
/// right-page grid's own real bottom edge, in `.global` space, reported
/// by a `GeometryReader` background on `DuoRightPage.sameDayGrid` (see
/// that function's own comment) and bubbled up to `FeedView`, the
/// nearest ancestor both `DuoRightPage` and the pager (which mounts
/// `FeedPageContent`) sit inside as siblings.
///
/// `reduce` keeps the latest reported value — there is only ever one
/// `DuoRightPage` mounted at a time, so in practice there is only ever
/// one contributor. Resets to `defaultValue` (`nil`) on its own,
/// automatically, whenever `DuoRightPage` (or its grid specifically —
/// the loading/empty branches of `sameDayTab` mount no `GeometryReader`
/// of their own) is not on screen to report a value: SwiftUI recomputes
/// a preference's aggregate from only the views currently in the tree
/// on every pass, so there is no "last known value" to go stale, unlike
/// the async singleton this replaced (`DuoRightPageMetrics`, now
/// deleted) — see `FeedView.duoRightGridBottomY`'s own comment for the
/// bug that forced the replacement.
struct DuoRightGridBottomKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
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
