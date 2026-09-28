//
//  FilterMenuView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The top-left filter and sort control. One `Menu` holds four sections:
/// Sort, Filters, Type, and Reset. One badge shows the active filter count.
///
/// Every change goes through `FeedOptionsStore`, which saves it. `FeedView`
/// watches the store and passes the new options to
/// `DeckViewModel.apply(options:)`. This view never touches the deck.
struct FilterMenuView: View {
    @ObservedObject var store: FeedOptionsStore
    /// The ancestor `.accessibilityHidden(isFullscreen)` does not
    /// reliably reach this view on this runtime. So the view clears its
    /// own identifier while `isFullscreen` is true. `bin_open` and the
    /// four rail buttons do the same.
    let isFullscreen: Bool

    var body: some View {
        Menu {
            Section("Sort") {
                sortItem(.random, id: "feed_sort_random", title: "Random")
                sortItem(.dateNewest, id: "feed_sort_datenewest", title: "Newest first")
                sortItem(.dateOldest, id: "feed_sort_dateoldest", title: "Oldest first")
            }
            Section("Filters") {
                toggleItem(id: "feed_filter_shrinkable", title: "Shrinkable",
                           isOn: store.options.filters.shrinkable) { store.toggleShrinkable() }
                toggleItem(id: "feed_filter_big", title: "Big (over 100 MB)",
                           isOn: store.options.filters.big) { store.toggleBig() }
                toggleItem(id: "feed_filter_long", title: "Longer than a minute",
                           isOn: store.options.filters.long) { store.toggleLong() }
                toggleItem(id: "feed_filter_onthisdate", title: "On this date",
                           isOn: store.options.filters.onThisDate) { store.toggleOnThisDate() }
            }
            Section("Type") {
                ForEach(FeedTypeOptions.ordered, id: \.id) { entry in
                    toggleItem(id: entry.id, title: entry.title,
                               isOn: store.options.filters.types.contains(entry.option)) {
                        store.toggleType(entry.option)
                    }
                }
            }
            Section {
                Button(role: .destructive) { store.reset() } label: { Text("Reset") }
                    .disabled(store.options.isDefault)
                    .accessibilityIdentifier("feed_filter_reset")
            }
        } label: {
            pill
        }
        // `.menuStyle(.button)` makes a `Menu` take `.buttonStyle`,
        // `.buttonBorderShape`, `.controlSize`, and `.tint` the same way a
        // plain `Button` does. This gives the control the same glass chrome
        // as its neighbors (`FeedView.muteButton`, `PhotoTopBar.binButton`),
        // with no separate background of its own.
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.white)
        // Sections must not reorder when the menu opens upward. Tests and
        // people find items by their position on screen.
        .menuOrder(.fixed)
        .accessibilityIdentifier(isFullscreen ? "" : "feed_filter_button")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens sort and filter options for the feed")
    }

    // MARK: - The pill

    /// The icon and an optional badge, with no background, frame, or
    /// padding of its own. The `.buttonStyle(.glass)` capsule chrome on
    /// `body` above supplies those, the same way `PhotoTopBar.binButton`'s
    /// label carries no background of its own. `.frame(minHeight: 20)`
    /// matches that label's frame, so the two capsules render at the same
    /// height.
    private var pill: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 15, weight: .medium))
            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("feed_filter_badge")   // on the bare Text
            }
        }
        .foregroundStyle(.white)
        .frame(minHeight: 20)
    }

    private var badgeCount: Int { store.options.badgeCount }

    private var accessibilityLabel: String {
        badgeCount > 0 ? "Filter and sort, \(badgeCount) active" : "Filter and sort"
    }

    // MARK: - Item builders

    /// Sets the identifier on the `Button`, never on the inner `Label` or
    /// `Text`. A container identifier overrides its children's identifiers.
    /// See `FeedView`'s `.accessibilityElement(children: .contain)` comment.
    private func sortItem(_ sort: FeedSort, id: String, title: String) -> some View {
        Button { store.setSort(sort) } label: {
            // An empty `systemImage` is not valid. A checked item uses a
            // `Label`; an unchecked item uses a bare `Text`. This is the
            // standard iOS menu style.
            if store.options.sort == sort {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .accessibilityIdentifier(id)
    }

    private func toggleItem(id: String, title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .accessibilityIdentifier(id)
    }
}
