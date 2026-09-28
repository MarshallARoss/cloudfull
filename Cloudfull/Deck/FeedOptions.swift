//
//  FeedOptions.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CoreGraphics
import Photos
import Combine

/// The feed offers three sorts; no size sort exists. `.random` uses the
/// shuffled deck with repeat cycles. The two date sorts build a plain
/// ordered list (`DeckViewModel.rebuildSortedDeck`).
enum FeedSort: String, Codable, CaseIterable {
    case random
    case dateNewest
    case dateOldest
}

/// The five video kinds the Type section offers. This is an `OptionSet`,
/// not a `Set<enum>`, so the whole selection persists as one `Int` and
/// fits inside one probe token.
///
/// `PHAssetMediaSubtype.videoStreamed` is not included here. It means the
/// original file is still in iCloud, not a kind of video. Including it
/// would filter by download state instead of video kind.
struct FeedTypeOptions: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let video           = FeedTypeOptions(rawValue: 1 << 0)  // no video subtype bit
    static let slomo           = FeedTypeOptions(rawValue: 1 << 1)  // .videoHighFrameRate
    static let timelapse       = FeedTypeOptions(rawValue: 1 << 2)  // .videoTimelapse
    static let screenRecording = FeedTypeOptions(rawValue: 1 << 3)  // .videoScreenRecording
    static let cinematic       = FeedTypeOptions(rawValue: 1 << 4)  // .videoCinematic

    /// Every kind. The default selection is `[]`, which matches every
    /// video. `load(from:)` converts a stored `.all` (`31`) to `[]`.
    static let all: FeedTypeOptions = [.video, .slomo, .timelapse, .screenRecording, .cinematic]

    /// Menu order, top to bottom. `FilterMenuView` builds its rows from
    /// this list, so the menu and the identifiers always agree.
    static let ordered: [(option: FeedTypeOptions, id: String, title: String)] = [
        (.video,           "feed_type_video",           "Video"),
        (.slomo,           "feed_type_slomo",           "Slo-mo"),
        (.timelapse,       "feed_type_timelapse",       "Time-lapse"),
        (.screenRecording, "feed_type_screenrecording", "Screen recording"),
        (.cinematic,       "feed_type_cinematic",       "Cinematic")
    ]
}

// `VideoFacts`, declared in `Cloudfull/Library/PhotoLibraryService.swift`,
// holds every video fact the filter predicate and the sorted list need.
// It is not redeclared here.

/// Every toggled filter must match (AND). An untoggled filter adds no
/// constraint. This includes the Type clause: an empty `types` set is
/// the default and matches every video.
struct FeedFilters: Codable, Equatable, Sendable {
    var shrinkable: Bool = false
    var big: Bool = false
    var long: Bool = false
    /// Matches this calendar date, any year. Shares its rule with the photo
    /// side through `OnThisDate`. See that type for why one definition
    /// must serve two different filtering mechanisms.
    var onThisDate: Bool = false
    var types: FeedTypeOptions = []

    static let none = FeedFilters()

    var isDefault: Bool { self == .none }

    // MARK: - Big (estimated, no size index)

    /// 100 MB, decimal. `Fmt.bytes` formats with `ByteCountFormatter`'s
    /// `.file` count style, which is also decimal. The threshold and the
    /// caption number use the same units.
    static let bigThresholdBytes: Int64 = 100_000_000

    /// Estimated bytes: megapixels × seconds × 5 Mbit/s (about 4K over 20
    /// seconds, or 1080p over 75 seconds). This is an estimate, not a
    /// measurement. No size index exists, because building one costs 5 to
    /// 20 seconds of background PhotoKit reads per 5,000 videos on first
    /// run. That cost is too high for a clean start on a large iCloud
    /// library. The estimate runs about twice too low for 60 fps and
    /// ProRes footage. The caption still shows the real size, so the
    /// user sees the true size next to the filter's guess.
    static let assumedBitsPerMegapixelSecond: Double = 5_000_000

    static func estimatedBytes(_ facts: VideoFacts) -> Int64 {
        let megapixels = Double(facts.pixelWidth) * Double(facts.pixelHeight) / 1_000_000
        guard megapixels > 0, facts.duration.isFinite, facts.duration > 0 else { return 0 }
        let bits = megapixels * facts.duration * assumedBitsPerMegapixelSecond
        return Int64(bits / 8)
    }

    // MARK: - Type

    /// The kinds this asset belongs to. A video can carry more than one
    /// subtype bit, so this method returns a set. Matching checks for a
    /// non-empty intersection, not a first-match rule; a first-match rule
    /// would hide a slo-mo screen recording from one of its own filters.
    /// "Video" means none of the four subtype bits are set.
    static func types(of facts: VideoFacts) -> FeedTypeOptions {
        var out: FeedTypeOptions = []
        if facts.mediaSubtypes.contains(.videoHighFrameRate) { out.insert(.slomo) }
        if facts.mediaSubtypes.contains(.videoTimelapse) { out.insert(.timelapse) }
        if facts.mediaSubtypes.contains(.videoScreenRecording) { out.insert(.screenRecording) }
        if facts.mediaSubtypes.contains(.videoCinematic) { out.insert(.cinematic) }
        if out.isEmpty { out.insert(.video) }
        return out
    }

    // MARK: - The predicate

    /// The single place a video is judged against the active filters. This
    /// method is pure and does few allocations. It runs once per library
    /// asset, for each options change and each library snapshot, never
    /// from a SwiftUI body.
    ///
    /// It calls `Fmt.isAboveShrinkThreshold` (in
    /// `Cloudfull/Design/DesignSystem.swift`), so the feed and the
    /// caption use the same shrink rule.
    func matches(_ facts: VideoFacts) -> Bool {
        if shrinkable,
           !Fmt.isAboveShrinkThreshold(CGSize(width: facts.pixelWidth, height: facts.pixelHeight)) {
            return false
        }
        if big, FeedFilters.estimatedBytes(facts) <= FeedFilters.bigThresholdBytes {
            return false
        }
        if long, !(facts.duration > 60) {
            return false
        }
        if onThisDate, !OnThisDate.matches(facts.creationDate) {
            return false
        }
        // An empty type selection matches every kind.
        if !types.isEmpty, FeedFilters.types(of: facts).isDisjoint(with: types) {
            return false
        }
        return true
    }
}

struct FeedOptions: Codable, Equatable, Sendable {
    var sort: FeedSort = .random
    var filters: FeedFilters = .none

    static let `default` = FeedOptions()

    var isDefault: Bool { self == .default }

    /// The number of non-default facets. This is the count shown in the
    /// button's badge, from 0 through 6. One point comes from a
    /// non-Random sort, one from each toggled filter, and one from any
    /// Type change.
    var badgeCount: Int {
        var count = 0
        if sort != .random { count += 1 }
        if filters.shrinkable { count += 1 }
        if filters.big { count += 1 }
        if filters.long { count += 1 }
        if filters.onThisDate { count += 1 }
        if !filters.types.isEmpty { count += 1 }
        return count
    }

    /// The whole selection as one token, with no underscore inside a
    /// field. One function serves two uses, so they can never disagree.
    /// It builds the `feed_options_` probe's payload, and it forms the
    /// deck-signature key that tells the app at launch whether it may
    /// still replay a saved random cycle.
    ///
    /// Shape: "<sort>_<shrinkable01><big01><long01><onThisDate01>t<typesRawValue>".
    /// The default reads "random_0000t0". Update `M8Tests` if this shape
    /// changes. It asserts these exact strings.
    var probeToken: String {
        let flags = "\(filters.shrinkable ? 1 : 0)\(filters.big ? 1 : 0)\(filters.long ? 1 : 0)\(filters.onThisDate ? 1 : 0)"
        return "\(sort.rawValue)_\(flags)t\(filters.types.rawValue)"
    }
}

/// The one owner of the live options and the only writer of their
/// `UserDefaults` keys. This uses `.shared`, the same pattern as
/// `PhotoLibraryService.shared` and `AssetKeyResolver.shared`. See
/// `PhotoLibraryService`'s comment for the reasoning behind a shared
/// instance instead of one per session.
///
/// A store, rather than six `@AppStorage` properties on the menu view,
/// exists because `DeckViewModel.start()` must read the options before
/// it deals the launch deck. `DeckViewModel.start()` has no view to
/// read the options from. One store that both sides read removes this
/// ordering hazard.
///
/// The store writes six plain values under `feed.`-prefixed keys, with
/// no encoding. The keys are easy to inspect, and the deck can read
/// them without a view.
@MainActor
final class FeedOptionsStore: ObservableObject {
    static let shared = FeedOptionsStore()

    @Published private(set) var options: FeedOptions

    // These key strings persist on device and must not change. The
    // `feed.` prefix matches the existing `feed.isMuted`.
    enum Key {
        static let sort = "feed.sort"                       // String, FeedSort.rawValue
        static let shrinkable = "feed.filter.shrinkable"    // Bool
        static let big = "feed.filter.big"                  // Bool
        static let long = "feed.filter.long"                // Bool
        static let onThisDate = "feed.filter.onthisdate"    // Bool
        static let types = "feed.filter.types"              // Int, FeedTypeOptions.rawValue
        // Do not reuse `feed.filter.kept`. Old installs can hold an
        // unread `Bool` under it.
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // `-cloudfull-reset-deck-state` erases the SwiftData store so a
        // test suite starts on a fresh deck. It must also reset the
        // options. Otherwise, a filter left on from an earlier test
        // narrows the pool for every test that runs after it in the same
        // process. That earlier test's own log gives no clue why.
        // `CloudfullApp` resets onboarding for the same reason. The
        // block also clears the deck signature and sorted cursor so the
        // first deal matches the reset options.
        if ProcessInfo.processInfo.arguments.contains("-cloudfull-reset-deck-state") {
            for key in [Key.sort, Key.shrinkable, Key.big, Key.long, Key.onThisDate, Key.types] {
                defaults.removeObject(forKey: key)
            }
            defaults.removeObject(forKey: DeckViewModel.deckSignatureKey)
            defaults.removeObject(forKey: DeckViewModel.sortedCursorKey)
        }
        #endif
        self.options = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> FeedOptions {
        var options = FeedOptions.default
        if let raw = defaults.string(forKey: Key.sort), let sort = FeedSort(rawValue: raw) {
            options.sort = sort
        }
        options.filters.shrinkable = defaults.bool(forKey: Key.shrinkable)
        options.filters.big = defaults.bool(forKey: Key.big)
        options.filters.long = defaults.bool(forKey: Key.long)
        options.filters.onThisDate = defaults.bool(forKey: Key.onThisDate)
        // A missing key is read as the struct's own default, the empty
        // set, so a first launch matches every video, not none.
        if defaults.object(forKey: Key.types) != nil {
            let stored = FeedTypeOptions(rawValue: defaults.integer(forKey: Key.types))
            // Convert a stored `.all` to `[]`, which also means every
            // kind, so the badge shows the default.
            options.filters.types = stored == .all ? [] : stored
        }
        return options
    }

    // MARK: - Mutation (the menu's only entry points)

    func setSort(_ sort: FeedSort) { if sort != options.sort { Usage.shared.sortChanged(mode: .videos, name: sort.rawValue) }; update { $0.sort = sort } }
    func toggleShrinkable() { Usage.shared.filterToggled(mode: .videos, name: "shrinkable", on: !options.filters.shrinkable); update { $0.filters.shrinkable.toggle() } }
    func toggleBig() { Usage.shared.filterToggled(mode: .videos, name: "big", on: !options.filters.big); update { $0.filters.big.toggle() } }
    func toggleLong() { Usage.shared.filterToggled(mode: .videos, name: "long", on: !options.filters.long); update { $0.filters.long.toggle() } }
    func toggleOnThisDate() { Usage.shared.filterToggled(mode: .videos, name: "onThisDate", on: !options.filters.onThisDate); update { $0.filters.onThisDate.toggle() } }
    /// The preset for a daily-reminder tap: oldest-first sort, only the
    /// On this date filter, all video types. It does not count as a
    /// `filterChange`.
    func applyOnThisDateReminder() {
        update(counted: false) {
            $0 = .default
            $0.sort = .dateOldest
            $0.filters.onThisDate = true
        }
    }

    func toggleType(_ type: FeedTypeOptions) {
        if let entry = FeedTypeOptions.ordered.first(where: { $0.option == type }) {
            Usage.shared.filterToggled(mode: .videos, name: entry.id.replacingOccurrences(of: "feed_type_", with: ""), on: !options.filters.types.contains(type))
        }
        update {
            if $0.filters.types.contains(type) {
                $0.filters.types.remove(type)
            } else {
                $0.filters.types.insert(type)
            }
        }
    }

    func reset() {
        if options != .default { Usage.shared.filterReset(mode: .videos) }   // a reset is not also a change; a no-op reset counts as nothing
        update(counted: false) { $0 = .default }
    }

    /// `counted` is true for a user edit of the menu, which counts as a
    /// `filterChange`. It is false for a reset or the reminder's preset.
    private func update(counted: Bool = true, _ mutate: (inout FeedOptions) -> Void) {
        var next = options
        mutate(&next)
        guard next != options else { return }
        options = next
        persist(next)
        if counted { Usage.shared.filterChange(mode: .videos) }
    }

    private func persist(_ options: FeedOptions) {
        defaults.set(options.sort.rawValue, forKey: Key.sort)
        defaults.set(options.filters.shrinkable, forKey: Key.shrinkable)
        defaults.set(options.filters.big, forKey: Key.big)
        defaults.set(options.filters.long, forKey: Key.long)
        defaults.set(options.filters.onThisDate, forKey: Key.onThisDate)
        defaults.set(options.filters.types.rawValue, forKey: Key.types)
    }
}
