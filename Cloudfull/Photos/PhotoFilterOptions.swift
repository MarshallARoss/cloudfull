//
//  PhotoFilterOptions.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Photos
import Combine

/// The photo kinds the Type section offers.
///
/// Mirrors `FeedTypeOptions`: both are an `OptionSet` so the whole
/// selection persists as one `Int`. A photo, like a video, can carry more
/// than one subtype bit at once, for example a Live Photo shot in
/// Portrait mode is both. Matching tests each selected bit. It does not
/// stop at the first bit it finds, because that would hide such a photo
/// from one of its filters.
///
/// "Photo" means exactly "none of the four special bits".
struct PhotoTypeOptions: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let photo      = PhotoTypeOptions(rawValue: 1 << 0)  // no subtype bit at all
    static let live       = PhotoTypeOptions(rawValue: 1 << 1)  // .photoLive
    static let portrait   = PhotoTypeOptions(rawValue: 1 << 2)  // .photoDepthEffect
    static let panorama   = PhotoTypeOptions(rawValue: 1 << 3)  // .photoPanorama
    static let screenshot = PhotoTypeOptions(rawValue: 1 << 4)  // .photoScreenshot

    /// Every kind. rawValue == 31. A stored 31 loads as the empty set.
    static let all: PhotoTypeOptions = [.photo, .live, .portrait, .panorama, .screenshot]

    /// Menu order, top to bottom, with the identifiers the UI tests query.
    static let ordered: [(option: PhotoTypeOptions, id: String, title: String, subtype: PHAssetMediaSubtype?)] = [
        (.photo,      "photo_type_photo",      "Photo",      nil),
        (.live,       "photo_type_live",       "Live Photo", .photoLive),
        (.portrait,   "photo_type_portrait",   "Portrait",   .photoDepthEffect),
        (.panorama,   "photo_type_panorama",   "Panorama",   .photoPanorama),
        (.screenshot, "photo_type_screenshot", "Screenshot", .photoScreenshot),
    ]
}

/// The active photo filters. Every toggled facet must match, using AND.
///
/// Unlike the video side, PhotoKit itself enforces these, not a Swift
/// predicate: they become the `PHFetchOptions.predicate` in
/// `PhotoLibraryPool.makeFetchOptions`. This matters on a large library.
/// A client-side filter must load and reject each asset. Also, the
/// pool's `assetCount` would count the unfiltered library, so every count
/// would be wrong.
struct PhotoFilters: Equatable, Sendable {
    /// An empty set means every kind, the default. Ticking a kind narrows
    /// the selection to it. A stored value of `31` from an older build
    /// reads as `[]`.
    var types: PhotoTypeOptions = []
    /// The Photos app's heart, not this app's own Keep feature.
    var favoritesOnly: Bool = false
    /// This calendar date, any year. See `OnThisDate`.
    var onThisDate: Bool = false

    static let none = PhotoFilters()

    var isDefault: Bool { self == .none }

    /// The `NSPredicate` PhotoKit runs, or nil when nothing is filtered.
    ///
    /// `PHFetchOptions` accepts only a narrow predicate grammar: `favorite
    /// == YES`, and bitwise tests against `mediaSubtypes`. The predicate
    /// negates every special bit at once to express "Photo". There is no
    /// "plain photo" subtype to test for directly.
    var fetchPredicate: NSPredicate? {
        var clauses: [NSPredicate] = []

        if favoritesOnly {
            clauses.append(NSPredicate(format: "favorite == YES"))
        }

        if onThisDate, let dateClause = OnThisDate.fetchPredicate() {
            clauses.append(dateClause)
        }

        if !types.isEmpty {
            var typeClauses: [NSPredicate] = []
            for entry in PhotoTypeOptions.ordered where types.contains(entry.option) {
                if let subtype = entry.subtype {
                    typeClauses.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", subtype.rawValue))
                } else {
                    typeClauses.append(NSPredicate(format: "(mediaSubtypes & %d) == 0", Self.specialSubtypeMask))
                }
            }
            // This is empty only when `types` holds no known bit. Return
            // nil (no filter) in that case.
            guard !typeClauses.isEmpty else { return nil }
            clauses.append(NSCompoundPredicate(orPredicateWithSubpredicates: typeClauses))
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.count == 1 ? clauses[0] : NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
    }

    /// Every special bit the Type section knows about, OR-ed together.
    /// "Photo" has none of these bits set.
    private static let specialSubtypeMask: Int = PhotoTypeOptions.ordered
        .compactMap { $0.subtype?.rawValue }
        .reduce(0) { $0 | Int($1) }
}

/// Three sorts, no size sort: the photo twin of `FeedSort`
/// (Cloudfull/Deck/FeedOptions.swift). `random` uses the random deck. The
/// two date sorts page the same `PHFetchResult` in order through
/// `PhotoLibraryPool.page`, and do not track seen photos.
enum PhotoSort: String, Codable, CaseIterable {
    case random
    case dateNewest
    case dateOldest
}

/// The active photo options: sort plus filters. The photo twin of
/// `FeedOptions` (Cloudfull/Deck/FeedOptions.swift).
///
/// `probeToken`, `isDefault`, and `badgeCount` live here rather than on
/// `PhotoFilters`, mirroring where `FeedOptions` keeps its own. A menu
/// badge and a deck signature both describe the whole selection, sort
/// included. A second copy of any of the three could disagree with this
/// one. `PhotoFilters.isDefault` still exists on its own, the same way
/// `DeckViewModel.refreshIndex` reads `FeedFilters.isDefault` directly.
struct PhotoOptions: Equatable, Sendable {
    var sort: PhotoSort = .random
    var filters: PhotoFilters = .none

    static let `default` = PhotoOptions()

    var isDefault: Bool { self == .default }

    /// How many facets are non-default: the number shown in the button's
    /// badge. Adds 1 for a non-Random sort, mirroring
    /// `FeedOptions.badgeCount`.
    var badgeCount: Int {
        var count = 0
        if sort != .random { count += 1 }
        if !filters.types.isEmpty { count += 1 }
        if filters.favoritesOnly { count += 1 }
        if filters.onThisDate { count += 1 }
        return count
    }

    /// The whole selection as one token, for the DEBUG probe and the deck
    /// signature. Mirrors `FeedOptions.probeToken`: one function, so the
    /// two readers can never disagree. Shape:
    /// "<sort>_<favorites01><onthisdate01>t<typesRawValue>". The default
    /// reads "random_00t0".
    var probeToken: String {
        "\(sort.rawValue)_\(filters.favoritesOnly ? 1 : 0)\(filters.onThisDate ? 1 : 0)t\(filters.types.rawValue)"
    }
}

/// The single source of truth for the photo options, and the only
/// writer of their `UserDefaults` keys. The photo twin of
/// `FeedOptionsStore`. It is `.shared` for the same reason: `PhotoDeck`
/// must read the options before it deals, and it has no view to read them
/// from.
@MainActor
final class PhotoOptionsStore: ObservableObject {
    static let shared = PhotoOptionsStore()

    @Published private(set) var options: PhotoOptions

    /// These `UserDefaults` keys do not change. The `photo.` prefix keeps
    /// them from colliding with the video side's `feed.` keys.
    enum Key {
        static let types = "photo.filter.types"           // Int, PhotoTypeOptions.rawValue
        static let favorites = "photo.filter.favorites"   // Bool
        static let onThisDate = "photo.filter.onthisdate" // Bool
        static let sort = "photo.sort"                    // String, PhotoSort.rawValue
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // Resets deck-affecting state before a UI test suite run. A
        // leftover filter or sort would silently narrow or reorder the
        // photo pool for every later test in the same run. Nothing in
        // that test's own log would explain why. Mirrors
        // `FeedOptionsStore`'s own reset.
        if ProcessInfo.processInfo.arguments.contains("-cloudfull-reset-deck-state") {
            defaults.removeObject(forKey: Key.types)
            defaults.removeObject(forKey: Key.favorites)
            defaults.removeObject(forKey: Key.onThisDate)
            defaults.removeObject(forKey: Key.sort)
        }
        #endif
        self.options = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> PhotoOptions {
        var options = PhotoOptions.default
        if let raw = defaults.string(forKey: Key.sort), let sort = PhotoSort(rawValue: raw) {
            options.sort = sort
        }
        // A missing key keeps the default, the empty set, which means
        // every kind. A stored 31 (all five bits) also loads as the empty
        // set.
        if defaults.object(forKey: Key.types) != nil {
            let raw = defaults.integer(forKey: Key.types)
            options.filters.types = raw == PhotoTypeOptions.all.rawValue ? [] : PhotoTypeOptions(rawValue: raw)
        }
        options.filters.favoritesOnly = defaults.bool(forKey: Key.favorites)
        options.filters.onThisDate = defaults.bool(forKey: Key.onThisDate)
        return options
    }

    // MARK: - Mutation (the menu's only entry points)

    /// Turns one kind on or off. Removing the last kind gives the empty
    /// set, which means every kind.
    func toggleType(_ type: PhotoTypeOptions) {
        if let entry = PhotoTypeOptions.ordered.first(where: { $0.option == type }) {
            Usage.shared.filterToggled(mode: .photos, name: entry.id.replacingOccurrences(of: "photo_type_", with: ""), on: !options.filters.types.contains(type))
        }
        update {
            if $0.filters.types.contains(type) {
                $0.filters.types.remove(type)   // Clearing the last kind means everything again.
            } else {
                $0.filters.types.insert(type)
            }
        }
    }

    func toggleFavoritesOnly() { Usage.shared.filterToggled(mode: .photos, name: "favorites", on: !options.filters.favoritesOnly); update { $0.filters.favoritesOnly.toggle() } }
    func toggleOnThisDate() { Usage.shared.filterToggled(mode: .photos, name: "onThisDate", on: !options.filters.onThisDate); update { $0.filters.onThisDate.toggle() } }
    /// A plain assignment: the photo twin of `FeedOptionsStore.setSort`.
    /// Logs a sort change only when the sort is different.
    func setSort(_ sort: PhotoSort) {
        if sort != options.sort { Usage.shared.sortChanged(mode: .photos, name: sort.rawValue) }
        update { $0.sort = sort }
    }
    /// What the daily reminder's tap sets: only "on this date", every
    /// kind. The photo twin of `FeedOptionsStore.applyOnThisDateReminder`.
    /// Not a user edit, so it does not count as a `filterChange`.
    ///
    /// Also sets `.dateOldest`, matching what the video side's own
    /// reminder tap sets. The oldest photo of the day shows first, not a
    /// random order.
    func applyOnThisDateReminder() {
        update(counted: false) {
            $0 = .default
            $0.sort = .dateOldest
            $0.filters.onThisDate = true
        }
    }

    func reset() {
        if options != .default { Usage.shared.filterReset(mode: .photos) }   // Log a reset only when options change. A reset does not also log a filterChange.
        update(counted: false) { $0 = .default }
    }

    /// `counted`: a user edit of the menu counts as a `filterChange`. A
    /// reset or the reminder's preset does not.
    private func update(counted: Bool = true, _ mutate: (inout PhotoOptions) -> Void) {
        var next = options
        mutate(&next)
        guard next != options else { return }
        options = next
        if counted { Usage.shared.filterChange(mode: .photos) }
        defaults.set(next.sort.rawValue, forKey: Key.sort)
        defaults.set(next.filters.types.rawValue, forKey: Key.types)
        defaults.set(next.filters.favoritesOnly, forKey: Key.favorites)
        defaults.set(next.filters.onThisDate, forKey: Key.onThisDate)
    }
}
