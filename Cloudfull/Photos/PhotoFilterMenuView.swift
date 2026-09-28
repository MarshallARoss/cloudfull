//
//  PhotoFilterMenuView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The Photos top bar's filter control.
///
/// The photo counterpart of `FilterMenuView`, and deliberately the same shape:
/// one `Menu`, sections, one badge, and every change goes through a store
/// that saves it.
///
/// The Sort section is opt-in, and random stays the default, the same as
/// `FilterMenuView`'s own Sort section. `PhotoDeck` deals random windows
/// from a lazy `PHFetchResult`. A date sort pages the same fetch result
/// in order (`PhotoLibraryPool.page`, `PhotoDeck.dealSortedWindow`).
struct PhotoFilterMenuView: View {
    @ObservedObject var store: PhotoOptionsStore

    var body: some View {
        Menu {
            Section("Sort") {
                sortItem(.random, id: "photo_sort_random", title: "Random")
                sortItem(.dateNewest, id: "photo_sort_datenewest", title: "Newest first")
                sortItem(.dateOldest, id: "photo_sort_dateoldest", title: "Oldest first")
            }
            Section("Filters") {
                toggleItem(
                    id: "photo_filter_favorites",
                    title: "Favorites",
                    isOn: store.options.filters.favoritesOnly
                ) { store.toggleFavoritesOnly() }
                toggleItem(
                    id: "photo_filter_onthisdate",
                    title: "On this date",
                    isOn: store.options.filters.onThisDate
                ) { store.toggleOnThisDate() }
            }
            Section("Type") {
                ForEach(PhotoTypeOptions.ordered, id: \.id) { entry in
                    toggleItem(
                        id: entry.id,
                        title: entry.title,
                        isOn: store.options.filters.types.contains(entry.option)
                    ) { store.toggleType(entry.option) }
                }
            }
            Section {
                Button(role: .destructive) { store.reset() } label: { Text("Reset") }
                    .disabled(store.options.isDefault)
                    .accessibilityIdentifier("photo_filter_reset")
            }
        } label: {
            pill
        }
        // The same recipe as `FilterMenuView`. See its own comment for
        // why a `Menu` here takes `.buttonStyle` rather than carrying a
        // second glass background of its own.
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityIdentifier("photo_filter_button")
        .accessibilityLabel("Filters")
        .accessibilityValue(
            store.options.isDefault ? "No filters" : "\(store.options.badgeCount) active"
        )
    }

    /// The same as `FilterMenuView.pill`, except for the badge's
    /// identifier. The two buttons are the same control on two screens,
    /// and must not drift apart.
    private var pill: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 15, weight: .medium))
            if store.options.badgeCount > 0 {
                Text("\(store.options.badgeCount)")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("photo_filter_badge")   // on the bare Text
            }
        }
        .foregroundStyle(.white)
        .frame(minHeight: 20)
    }

    /// The same shape as `FilterMenuView.sortItem`: the identifier goes on
    /// the `Button`, never the inner `Label` or `Text`. See that method's
    /// own comment on why a container identifier would override it.
    private func sortItem(_ sort: PhotoSort, id: String, title: String) -> some View {
        Button { store.setSort(sort) } label: {
            if store.options.sort == sort {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .accessibilityIdentifier(id)
    }

    /// A checkmark row. This uses `Button`, not `Toggle`, for the same
    /// reason as the video menu. Inside a `Menu`, a `Toggle` renders its
    /// own switch and closes the menu on every tap. Toggling three types
    /// would then need three separate openings of the menu.
    private func toggleItem(
        id: String,
        title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: isOn ? "checkmark" : "")
        }
        .accessibilityIdentifier(id)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
