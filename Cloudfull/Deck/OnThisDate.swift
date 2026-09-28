//
//  OnThisDate.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Filters items to the current calendar date across past years, for both
/// videos and photos.
///
/// One type serves both feeds so that both use the same date rule. The
/// photo deck hands PhotoKit a `PHFetchOptions.predicate` and never sees
/// the assets itself. The video deck tests `VideoFacts` in Swift. If the
/// rules differ, the two feeds show different items for the same date.
enum OnThisDate {

    /// How many years back the predicate reaches. Photography rarely
    /// predates this range, and an unmatched year costs one cheap range
    /// clause. Each year adds one OR clause to the predicate, so this
    /// count sets the predicate size directly.
    static let yearsBack = 40

    /// Returns true when `date` falls on the same month and day as
    /// `reference`, in any year. Today counts: an item from this year
    /// also matches.
    ///
    /// A `nil` date never matches. An asset with no creation date cannot be
    /// placed on a calendar. Including it anyway would put an item in the
    /// feed for a date it does not match.
    static func matches(_ date: Date?, reference: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let date else { return false }
        let a = calendar.dateComponents([.month, .day], from: date)
        let b = calendar.dateComponents([.month, .day], from: reference)
        return a.month == b.month && a.day == b.day
    }

    /// Returns the same rule as an `NSPredicate` that PhotoKit accepts.
    ///
    /// The predicate is an OR of one-day ranges, one per year.
    /// `PHFetchOptions` takes a narrow predicate grammar: it cannot ask for
    /// "the month and day of `creationDate`", only compare the whole date
    /// against constants. The calendar arithmetic happens once, here, and
    /// PhotoKit receives plain date bounds.
    ///
    /// Each range comes from `calendar.date(from:)` with the reference
    /// month and day in that year. On 29 February, a non-leap year
    /// normalizes to 1 March.
    static func fetchPredicate(reference: Date = Date(), calendar: Calendar = .current) -> NSPredicate? {
        let parts = calendar.dateComponents([.year, .month, .day], from: reference)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }

        var ranges: [NSPredicate] = []
        for offset in 0...yearsBack {
            var components = DateComponents()
            components.year = year - offset
            components.month = month
            components.day = day
            guard let start = calendar.date(from: components),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            ranges.append(NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                start as NSDate, end as NSDate
            ))
        }
        guard !ranges.isEmpty else { return nil }
        return NSCompoundPredicate(orPredicateWithSubpredicates: ranges)
    }
}
