//
//  AlbumPickerView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit

/// A picker that adds one item to an album, modeled on the Photos Add
/// to Album screen. `FeedView` and `PhotoFeedView` present it.
/// `assetID` is the item to add.
struct AlbumPickerView: View {
    let assetID: String
    @ObservedObject var coordinator: ShareCoordinator
    @Environment(\.dismiss) private var dismiss

    /// The list lives in `AlbumListCache`, not here. This view only
    /// renders it, so the sheet opens without a new fetch. An add made
    /// here is still on top the next time it opens.
    @ObservedObject private var cache = AlbumListCache.shared
    @State private var isWorking = false
    /// `nil` while working on the New Album action, or not working at
    /// all. Set to the tapped row's album id while adding to an existing
    /// album, so the progress indicator lands on the one row that is busy.
    @State private var workingAlbumID: String?
    @State private var isNamingNewAlbum = false
    @State private var newAlbumTitle = ""
    @State private var errorMessage: String?
    /// Filters the existing-albums section only. The New Album action is
    /// always visible whatever the user types, since a search that finds
    /// nothing is exactly when making a new album is useful.
    @State private var searchText = ""
    /// Stored in AppStorage, so the choice stays after the sheet closes.
    @AppStorage("albumPicker.sortOrder") private var sortOrder = AlbumSortOrder.recent

    /// How `sortOrder` arranges the album list.
    enum AlbumSortOrder: String, CaseIterable, Identifiable {
        case recent, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recent: return "Recent"
            case .name: return "Alphabetical"
            }
        }
    }

    /// Case- and diacritic-insensitive, matching anywhere in the title, so
    /// "hol" finds "Summer Holiday". Sorted afterwards, so a search narrows
    /// the same ordering rather than reshuffling it.
    private var matchingAlbums: [PhotoLibraryService.AlbumSummary] {
        let list = cache.albums ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? list : list.filter {
            $0.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        // `.recent` needs no work here. `AlbumListCache` already hands the
        // list over newest-first, and keeps it that way as the user adds.
        // Because of this order, the picker does not need to fetch again.
        let ordered: [PhotoLibraryService.AlbumSummary]
        switch sortOrder {
        case .recent:
            ordered = filtered
        case .name:
            ordered = filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return ordered
    }

    /// The main list, minus whatever the pinned section is already showing.
    private var listedAlbums: [PhotoLibraryService.AlbumSummary] {
        guard let pinnedID = cache.pinnedNewAlbumID else { return matchingAlbums }
        return matchingAlbums.filter { $0.id != pinnedID }
    }

    /// The just-created album, when there is one and the search is not
    /// filtering it out. Kept out of the main list below so it cannot appear
    /// twice.
    private var pinnedAlbum: PhotoLibraryService.AlbumSummary? {
        guard let id = cache.pinnedNewAlbumID else { return nil }
        return matchingAlbums.first { $0.id == id }
    }

    /// True before the first fetch and while the cache refreshes. This is
    /// different from an empty album list.
    private var isLoading: Bool { cache.albums == nil || cache.isLoading }

    var body: some View {
        NavigationStack {
            List {
                // The New Album button is in the toolbar. This section
                // shows its progress indicator and the error text, which
                // a toolbar cannot show.
                if isWorking && workingAlbumID == nil {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                                .accessibilityIdentifier("album_picker_progress")
                            Spacer()
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("album_picker_error")
                    }
                }

                if isLoading {
                    Section {
                        loadingRow
                    }
                } else {
                    // The album just made gets its own section at the top,
                    // whatever the sort order says, so the user can find
                    // it at once. See `AlbumListCache.pinnedNewAlbumID`
                    // for how long it lasts.
                    if let pinned = pinnedAlbum {
                        Section("Just Created") {
                            Button { Task { await add(to: pinned) } } label: { albumRow(pinned) }
                                .accessibilityIdentifier("album_picker_pinned_\(pinned.id)")
                                .accessibilityLabel(pinned.title)
                                .accessibilityHint("Adds this item to \(pinned.title)")
                        }
                    }
                }
                if !listedAlbums.isEmpty {
                    Section(searchText.isEmpty ? sortOrder.title : "Matches") {
                        ForEach(listedAlbums) { album in
                            Button { Task { await add(to: album) } } label: { albumRow(album) }
                                .accessibilityIdentifier("album_picker_row_\(album.id)")
                                .accessibilityLabel(album.title)
                                .accessibilityHint("Adds this item to \(album.title)")
                        }
                    }
                } else if !(cache.albums ?? []).isEmpty {
                    // Searched, and nothing matched. Says so rather than
                    // leaving a blank list, which reads as a load that failed.
                    Section {
                        Text("No album matches “\(searchText)”.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("album_picker_no_matches")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search albums")
            // Every row here is a `Button`. SwiftUI shows button labels in
            // the accent color. `.tint(.primary)` on the List shows album
            // names as plain text, as Photos does. Cancel in the toolbar
            // keeps the accent color.
            .tint(.primary)
            .listStyle(.insetGrouped)
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { Usage.shared.albumPickerCancelled(); dismiss() }
                        .disabled(isWorking)
                        .accessibilityIdentifier("album_picker_cancel")
                }
                // Do not add `.buttonStyle(.glass)`. On iOS 26 a
                // navigation bar already renders its own buttons as
                // circular glass. Adding the style makes the bar one
                // accessibility group. VoiceOver and UI tests then cannot
                // find the toolbar buttons.
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isNamingNewAlbum = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("album_picker_new")
                    .accessibilityLabel("New Album")
                    .accessibilityHint("Creates an album and adds this item to it")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(AlbumSortOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }
                        .onChange(of: sortOrder) { _, _ in Usage.shared.albumSortChanged() }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("album_picker_sort")
                    .accessibilityLabel("Sort albums")
                }
            }
            .overlay { if (cache.albums ?? []).isEmpty && !isLoading { emptyState } }
            .disabled(isWorking)
        }
        .presentationDragIndicator(.visible)
        // Do not let a swipe dismiss the sheet during a write. `TrashView`
        // uses the same rule during `isEmptying`.
        .interactiveDismissDisabled(isWorking)
        .accessibilityIdentifier("album_picker_root")
        // No fetching from here. The app fills the cache at launch and
        // when it returns to the foreground. `prewarm()` fetches only if
        // the cache is empty. `pickerBecameVisible()` stops a background
        // refresh while the picker shows.
        .task { AlbumListCache.shared.prewarm() }
        .onAppear { AlbumListCache.shared.pickerBecameVisible() }
        .onDisappear { AlbumListCache.shared.pickerBecameHidden() }
        .alert("New Album", isPresented: $isNamingNewAlbum) {
            TextField("Title", text: $newAlbumTitle)
                .accessibilityIdentifier("album_picker_new_name_field")
            Button("Cancel", role: .cancel) { newAlbumTitle = "" }
                .accessibilityIdentifier("album_picker_new_cancel")
            Button("Save") { Task { await createAndAdd(title: newAlbumTitle) } }
                .accessibilityIdentifier("album_picker_new_save")
        } message: {
            Text("Enter a name for this album.")
        }
    }

    // MARK: - Row

    private func albumRow(_ album: PhotoLibraryService.AlbumSummary) -> some View {
        HStack(spacing: 12) {
            AlbumThumbnail(assetID: album.keyAssetID, side: 44)
            Text(album.title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if isWorking && workingAlbumID == album.id {
                // Each row uses its own identifier, unlike the bare
                // "album_picker_progress" name used above. A shared
                // identifier would make a single-element query fail if
                // two spinners showed at once.
                ProgressView()
                    .accessibilityIdentifier("album_picker_progress_\(album.id)")
            }
        }
        .accessibilityElement(children: .ignore)
    }

    /// The row that shows while `isLoading` is true.
    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("album_picker_loading")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Albums", systemImage: "rectangle.stack")
        } description: {
            Text("You don't have any albums yet. Tap + to create one.")
        }
        .accessibilityIdentifier("album_picker_empty_state")
    }

    // MARK: - Actions

    private func add(to album: PhotoLibraryService.AlbumSummary) async {
        guard !isWorking else { return }
        isWorking = true
        workingAlbumID = album.id
        errorMessage = nil
        let ok = await coordinator.addToAlbum(assetID: assetID, albumID: album.id)
        if ok { Usage.shared.albumAdded(new: false) }
        isWorking = false
        workingAlbumID = nil
        if ok {
            // Straight to the top of the in-memory list, with no refetch.
            AlbumListCache.shared.noteAdded(albumID: album.id)
            dismiss()
        } else {
            errorMessage = "Couldn't add this item to the album."
        }
    }

    /// Trims whitespace and does nothing on an empty result. PhotoKit
    /// permits duplicate album titles, so this function adds no uniqueness
    /// check here either; the system has none.
    private func createAndAdd(title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        newAlbumTitle = ""
        guard !trimmed.isEmpty, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        let newAlbumID = await coordinator.createAlbumAndAdd(assetID: assetID, title: trimmed)
        isWorking = false
        if let newAlbumID {
            // Straight to the top, with no refetch: it is by definition the
            // album most recently added to.
            AlbumListCache.shared.noteCreated(albumID: newAlbumID, title: trimmed, keyAssetID: assetID)
            Usage.shared.albumAdded(new: true)
            Usage.shared.action(.album, source: .rail, mode: Usage.currentMode)   // The create-new path is an album action too.
            dismiss()
        } else {
            errorMessage = "Couldn't add this item to the album."
        }
    }
}

/// Uses `PhotoLibraryService.thumbnail(for:side:)`, as `TrashView` does.
/// Shows a quaternary rounded rectangle with a glyph until the image
/// loads.
private struct AlbumThumbnail: View {
    let assetID: String?
    let side: CGFloat

    @State private var image: UIImage?
    private let library = PhotoLibraryService.shared

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.quaternary)
            .frame(width: side, height: side)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: assetID) {
                guard let assetID else { image = nil; return }
                image = await library.thumbnail(for: assetID, side: side)
            }
    }
}
