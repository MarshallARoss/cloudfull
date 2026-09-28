//
//  ShrinkConfirmView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The confirm sheet shown before a shrink job is queued. It shows the
/// current size, the estimated 1080p size, and the space saved. No system
/// dialog appears at this stage. Trashing the original is the only
/// irreversible step; it happens later, through the existing bin flow,
/// which has its own confirmation.
struct ShrinkConfirmView: View {
    let assetID: String
    @ObservedObject var shrinkService: ShrinkService
    @Environment(\.dismiss) private var dismiss

    private let library = PhotoLibraryService.shared

    // Resolved once in `.task`, not as computed properties.
    // `shrinkService` is `@ObservedObject`, so this sheet re-renders on
    // every `ShrinkService.jobs` publish. That can happen several times
    // a second during an unrelated export. A computed property would
    // repeat several `PHAsset` and `PHAssetResource` calls on each
    // re-render. Neither value can change while this sheet is open,
    // because the asset's dimensions and size are read once, before any
    // job exists for it. Caching them once is correct, not only faster.
    @State private var resolvedPixelSize: CGSize = .zero
    @State private var resolvedEstimate: (currentBytes: Int64, estimatedBytes: Int64) = (0, 0)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    infoRow("Current", currentValue)
                    infoRow("After", afterValue)
                    savedRow
                } header: {
                    formatBadges
                } footer: {
                    Text("The 1080p copy keeps this video's date and location. The original moves to the bin once the copy is saved. If the copy would not be meaningfully smaller, Cloudfull keeps the original and tells you.")
                }
                .accessibilityIdentifier("shrink_size_bars")
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Shrink Video")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                actions
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task {
            resolvedPixelSize = library.pixelSize(for: assetID)
            resolvedEstimate = shrinkService.estimate(assetID: assetID)
        }
    }

    // MARK: - Format badges

    private var formatBadges: some View {
        HStack(spacing: 6) {
            badge(sourceResolutionLabel)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            badge("HD")
            Spacer()
        }
        .textCase(nil)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("shrink_resolution_pill")
        .accessibilityLabel("\(sourceResolutionLabel) to HD, 1080p")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - Info rows

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var currentValue: String {
        "\(sourceResolutionLabel) \u{00B7} \(Fmt.bytes(resolvedEstimate.currentBytes))"
    }

    private var afterValue: String {
        "1080p \u{00B7} \(Fmt.bytes(resolvedEstimate.estimatedBytes))"
    }

    // MARK: - Savings row

    private var savedRow: some View {
        HStack {
            Text("You save")
            Spacer()
            Text("About " + Fmt.bytes(savedBytes))
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shrink_saved_hero")
        .accessibilityLabel("Saves about \(Fmt.bytes(savedBytes))")
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            Button("Shrink to HD") {
                shrinkService.enqueue(assetID: assetID)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .accentButtonLabel()
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("shrink_confirm")
            .accessibilityLabel("Shrink")
            .accessibilityHint("Exports a 1080p copy and queues the original for deletion once the copy is saved")

            Button("Cancel") {
                Usage.shared.shrinkCancelled()
                dismiss()
            }
                .buttonStyle(.plain)
                .accessibilityIdentifier("shrink_cancel")
                .accessibilityLabel("Cancel")
                .accessibilityHint("Closes this sheet without shrinking the video")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.bar)
    }

    // MARK: - Derived values

    private var savedBytes: Int64 {
        max(resolvedEstimate.currentBytes - resolvedEstimate.estimatedBytes, 0)
    }

    /// A readable resolution label for the resolution pill and the
    /// "Current" row, from the cached `resolvedPixelSize`.
    private var sourceResolutionLabel: String {
        Fmt.resolution(resolvedPixelSize)
    }
}
