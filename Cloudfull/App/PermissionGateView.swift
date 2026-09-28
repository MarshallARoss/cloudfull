//
//  PermissionGateView.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Photos
import SwiftData
import UIKit

struct PermissionGateView: View {

    @ObservedObject private var library = PhotoLibraryService.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// True after the first `.active` state of the process. The first
    /// open is the cold start.
    @MainActor private static var hasOpenedThisProcess = false
    /// True from `.background` until the next `.active`. This marks a real
    /// return, not a temporary switch to `.inactive` and back (Control
    /// Center, a banner). SwiftUI resumes through `.background` →
    /// `.inactive` → `.active`, so `oldPhase` alone cannot tell the two
    /// cases apart. A round trip through `.inactive` only does not start
    /// a new session.
    @MainActor private static var wasBackgrounded = false
    /// A gate's "Open Settings" button was tapped. The next `.active` state
    /// records the access level the user returns with.
    @MainActor private static var sentToSettings = false
    @StateObject private var sessionHolder = SessionHolder()
    // The gate state is read here so `authorizedView` only chains the
    // `.fullScreenCover` onto its return value. See `OnboardingGateState`
    // for why a plain `UserDefaults` reader cannot reliably show the
    // cover again from another screen.
    @ObservedObject private var onboardingGate = OnboardingGateState.shared

    var body: some View {
        ZStack {
            Group {
                switch library.authStatus {
                case .notDetermined:
                    notDeterminedView
                case .authorized:
                    authorizedView
                case .limited:
                    limitedView
                case .denied, .restricted:
                    deniedView
                @unknown default:
                    deniedView
                }
            }
            #if DEBUG
            // `GateProbes` mounts here, not in `FeedView`. This keeps the
            // probes readable in every authorization state, including
            // `.limited` and `.denied`, where `authorizedView` never
            // builds an `AuthorizedSession` or a `TrashService`. The
            // probes it shows are `space_probe_`, `trash_rows_`,
            // `trash_entry_`, `rowcount_`, and `rowcountnil_`.
            //
            // `GateProbes` reads no session, so it cannot create an
            // `AuthorizedSession` during a body pass. See
            // `SessionHolder`'s comment below for why that guarantee
            // matters.
            GateProbes()
            #endif
        }
        // PhotoKit sends no notification when the user changes access in
        // Settings. Without this check, `authStatus` stays stale, for
        // example after a downgrade to limited access, until a full
        // relaunch.
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                library.refreshAuthStatus()
            }
            // One session per real foreground. A change from `.inactive`
            // to `.active` — Control Center, a notification banner, a
            // glance at the app switcher — is not a new session.
            if newPhase == .active, Self.wasBackgrounded || !Self.hasOpenedThisProcess {
                Self.wasBackgrounded = false
                // One "open" event per foreground, with the current
                // default settings. `cold` is true only for the first
                // open of the process.
                Usage.shared.appOpened(
                    cold: !Self.hasOpenedThisProcess,
                    defaultTab: UserDefaults.standard.string(forKey: AppModeStore.openModeKey) ?? AppMode.videos.rawValue,
                    openMuted: UserDefaults.standard.bool(forKey: "settings.openMuted"),
                    liveDefaultOn: UserDefaults.standard.object(forKey: "settings.liveDefaultOn") as? Bool ?? true,
                    reminderOn: DailyReminder.shared.isEnabled,
                    reminderHour: DailyReminder.shared.isEnabled ? Calendar.current.component(.hour, from: DailyReminder.shared.time) : nil
                )
                Self.hasOpenedThisProcess = true
                Usage.shared.uploadPending()   // retries an upload that the last background period stopped
                let v = FeedOptionsStore.shared.options
                Usage.shared.filtersInForce(
                    mode: .videos, sort: String(describing: v.sort),
                    filters: [v.filters.shrinkable ? "shrinkable" : nil, v.filters.big ? "big" : nil, v.filters.long ? "long" : nil, v.filters.onThisDate ? "onThisDate" : nil].compactMap { $0 },
                    types: FeedTypeOptions.ordered.filter { v.filters.types.contains($0.option) }.map { $0.id.replacingOccurrences(of: "feed_type_", with: "") }
                )
                let po = PhotoOptionsStore.shared.options
                Usage.shared.filtersInForce(
                    mode: .photos, sort: String(describing: po.sort),
                    filters: [po.filters.favoritesOnly ? "favorites" : nil, po.filters.onThisDate ? "onThisDate" : nil].compactMap { $0 },
                    types: PhotoTypeOptions.ordered.filter { po.filters.types.contains($0.option) }.map { $0.id.replacingOccurrences(of: "photo_type_", with: "") }
                )
            } else if newPhase == .background {
                Self.wasBackgrounded = true
                if let trash = sessionHolder.current?.trash {   // reads in-memory data only, does not query PhotoKit
                    Usage.shared.binState(items: trash.entries.count, bytes: trash.pendingBytes)
                }
                Usage.shared.flush()
            }
            // Records the access level the user has after they return
            // from the Settings app after a gate's "Open Settings" button.
            if newPhase == .active, Self.sentToSettings {
                Self.sentToSettings = false
                Usage.shared.accessAfterSettingsReturn(library.authStatus)
            }
        }
        .onChange(of: library.authStatus, initial: true) { _, status in
            switch status {
            case .notDetermined: Usage.shared.gateShown(.welcome)
            case .limited: Usage.shared.gateShown(.limited)
            case .denied, .restricted: Usage.shared.gateShown(.denied)
            default: break
            }
        }
        // This modifier sits here, deliberately outside `authorizedView`.
        // That computed property re-evaluates on every body pass, for
        // example on every `scenePhase` change. The launcher owns its own
        // 2-second delay and authorization guard, so this runs safely
        // even while the gate still shows a state before authorization.
        //
        // Use `.task(id: library.authStatus)`, not a bare `.task`. The
        // outer `Group` keeps one identity for all cases of the switch
        // above, so a bare `.task` runs only once. A launch that starts
        // `.notDetermined` then gets no backfill after the user grants
        // access.
        .task(id: library.authStatus) {
            await CloudKeyBackfillLauncher.shared.runIfNeeded(container: modelContext.container)
        }
    }

    // MARK: - States

    /// Builds the deck, trash, and shrink services together. It wires the
    /// cross-service edges the UI layer owns:
    ///   - Queuing a video for deletion also removes it from the deck's
    ///     future, so it never reappears while it sits in the trash.
    ///   - Liking a video also clears any pending trash entry for it. A
    ///     like always overrides a queued delete, and `TrashService` owns
    ///     that row, not `DeckViewModel`.
    ///   - Restoring a video from the trash makes it eligible again.
    ///     `DeckViewModel`'s cached pool count and exhaustion latch have
    ///     no other way to learn this.
    ///   - A shrink job that reaches a confirmed save queues the original
    ///     video for deletion through the same trash path. This gives it
    ///     the bin badge, the space chip, and deck exclusion.
    /// Unliking a video needs no matching deck edit beyond what it already
    /// does internally, so no callback is wired for it.
    ///
    /// `authorizedView` re-evaluates on every body pass. Do not construct
    /// the services there unconditionally, or each pass builds a new,
    /// unused set.
    ///
    /// `sessionHolder` owns the one session and builds it lazily on first
    /// access. Construction happens synchronously inside the first
    /// `authorizedView` evaluation, and `FeedView` mounts in that same
    /// pass. A UI test (`testResumesSavedPositionAfterRelaunch`) depends
    /// on this timing. Do not move this construction into a `.task`.
    ///
    /// The holder stores the session in a plain property, not in
    /// `@State`, because SwiftUI does not allow a `@State` change during
    /// body evaluation. The holder publishes nothing, so reading it
    /// mid-body invalidates nothing.
    private var authorizedView: some View {
        let activeSession = sessionHolder.session(library: .shared, modelContext: modelContext)
        return RootView(deck: activeSession.deck, trash: activeSession.trash, shrink: activeSession.shrink)
            // One-time onboarding, presented after photo access is
            // granted. The DEBUG launch argument
            // `-cloudfull-reset-deck-state` suppresses the cover. Every
            // UI test uses that argument, so the tests see the feed
            // only.
            .fullScreenCover(isPresented: Binding(
                get: { !onboardingGate.hasCompleted && !OnboardingGate.isSuppressedByLaunchArgument },
                set: { if !$0 { onboardingGate.hasCompleted = true } }
            )) {
                OnboardingView { onboardingGate.hasCompleted = true }
            }
    }

    // MARK: - Permission gate states

    /// The welcome screen's content, defined in one place.
    ///
    /// The app has two first-run screens: this one, shown before photo
    /// access is granted, and `OnboardingView`, the tour shown after.
    /// Settings can open either screen. Both read from this single
    /// definition, so their text stays the same.
    static let welcomeTitle = "Welcome to Cloudfull"
    static let welcomeMessage = "Cloudfull shuffles the videos already in your library so you can rediscover them and clear space."
    // Anonymous usage counts leave the device. Photos and videos never do.
    static let welcomeFootnote = "No account. Your photos and videos stay in your library."
    static let welcomeRows: [GateRow] = [
        GateRow(symbol: "shuffle", title: "Shuffled", body: "Every video in your library, in a random order."),
        GateRow(symbol: "heart", title: "Keep", body: "A kept video is shielded. Cloudfull can never delete it."),
        GateRow(symbol: "arrow.down.right.and.arrow.up.left", title: "Shrink", body: "Turn a 4K video into HD. Same memory, a fraction of the space."),
        GateRow(symbol: "plus.rectangle.on.rectangle", title: "Add to album", body: "File a photo or video into any album, without leaving the feed."),
    ]

    private var notDeterminedView: some View {
        gateLayout(
            title: Self.welcomeTitle,
            message: Self.welcomeMessage,
            rows: Self.welcomeRows,
            primaryTitle: "Allow photo access",
            // Do not attach an identifier to this button.
            // `FeedUITestCase` finds this button by its visible title,
            // `app.buttons["Allow photo access"]`. An identifier changes
            // how XCUITest resolves that subscript and breaks the gated
            // UI tests. Pass `nil` here.
            primaryIdentifier: nil,
            primaryAction: {
                Task {
                    // Records the seconds spent on the welcome screen.
                    // Records the permission answer.
                    // Records the seconds the system prompt took to answer.
                    Usage.shared.gateLeft(.welcome, via: "continue")
                    let asked = Date()
                    let status = await library.requestAccess()
                    Usage.shared.permissionAnswered(status, secondsToAnswer: Int(Date().timeIntervalSince(asked)))
                }
            },
            footnote: Self.welcomeFootnote
        ) {
            EmptyView()
        }
    }

    private var limitedView: some View {
        gateLayout(
            title: "Cloudfull Needs Your Whole Library",
            message: "You picked a few photos to share. Cloudfull shuffles everything you have, so it needs full access to find your videos.",
            rows: [],
            primaryTitle: "Open Settings",
            primaryIdentifier: "permission_limited_settings",
            primaryAction: openSettings,
            footnote: "In Settings, choose Photos → All Photos."
        ) {
            limitedSteps
        }
    }

    private var deniedView: some View {
        gateLayout(
            title: "Photo Access Is Off",
            message: "Cloudfull only reads the videos already on your phone. Without access there is nothing to show.",
            rows: [],
            primaryTitle: "Open Settings",
            primaryIdentifier: "permission_denied_settings",
            primaryAction: openSettings,
            footnote: "In Settings, turn on Photos → All Photos."
        ) {
            EmptyView()
        }
    }

    /// The numbered step list shown only in the `.limited` state. Without
    /// it, "Open Settings" alone leaves the user in Settings with no
    /// indication which toggle to change.
    private var limitedSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1.  Tap Open Settings")
            Text("2.  Choose Photos")
            Text("3.  Choose All Photos")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("permission_limited_steps")     // do not change this identifier; tests depend on it
        .accessibilityLabel("Step 1, tap Open Settings. Step 2, choose Photos. Step 3, choose All Photos.")
    }

    // MARK: - Shared layout

    private func gateLayout<Extra: View>(
        title: String,
        message: String,
        rows: [GateRow],
        primaryTitle: String,
        primaryIdentifier: String?,
        primaryAction: @escaping () -> Void,
        footnote: String?,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title)
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text(message)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(rows) { row in featureRow(row) }
                    }
                    extra()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 48)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .modifier(OptionalAccessibilityIdentifier(id: primaryIdentifier))
                if let footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
    }

    private func featureRow(_ row: GateRow) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: row.symbol)
                .font(.system(size: 26))
                .frame(width: 34)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.headline)
                Text(row.body).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Usage.shared.gateLeft(library.authStatus == .limited ? .limited : .denied, via: "openSettings")
        Self.sentToSettings = true
        UIApplication.shared.open(url)
    }
}

/// A single feature row inside `gateLayout`.
/// Internal, not private: `WelcomeScreenView` below renders the same
/// rows, so Settings can show the welcome screen on demand without a
/// second copy of the content.
struct GateRow: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let body: String
}

/// Applies `.accessibilityIdentifier(id)` only when `id` is not nil. Used
/// by the not-determined state's primary button, which must stay a plain
/// `Button` resolvable only by its exact visible title.
private struct OptionalAccessibilityIdentifier: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

/// Owns the single `AuthorizedSession` for one mounted `PermissionGateView`.
/// Held as a `@StateObject`, so it survives every body pass. The session it
/// builds on first access is the only session the view tree will ever see.
///
/// It publishes nothing, deliberately. `session(library:modelContext:)`
/// runs inside `authorizedView`, during body evaluation. An
/// `objectWillChange` fired from there would be the illegal state mutation
/// this holder exists to prevent.
private final class SessionHolder: ObservableObject {
    private var stored: AuthorizedSession?
    /// The session, if one exists. Use this for reads that must not create one.
    var current: AuthorizedSession? { stored }

    @MainActor
    func session(library: PhotoLibraryService, modelContext: ModelContext) -> AuthorizedSession {
        if let stored { return stored }
        let created = AuthorizedSession(library: library, modelContext: modelContext)
        stored = created
        return created
    }
}

/// The one `DeckViewModel`, `TrashService`, and `ShrinkService` set for an
/// authorized session. Cross-service closures capture the services
/// weakly, so no retain cycle forms and ARC can free the session.
@MainActor
private final class AuthorizedSession {
    let deck: DeckViewModel
    let trash: TrashService
    let shrink: ShrinkService

    init(library: PhotoLibraryService, modelContext: ModelContext) {
        let deck = DeckViewModel(library: library, modelContext: modelContext)
        let trash = TrashService(library: library, modelContext: modelContext)
        let shrink = ShrinkService(library: library)
        trash.onQueued = { [weak deck] assetID in
            deck?.removeFromFuture(assetID: assetID)
        }
        trash.onRestored = { [weak deck] _ in
            deck?.refreshPoolAfterExternalChange()
            // The shared bin can restore either a video or a photo.
            // `PhotoDeck.poolCount` (`photo_pool_`) must recover exactly
            // like the video pool does, not only the next time Photos
            // mode rebuilds its deck.
            PhotoDeck.shared.refreshPoolAfterExternalChange()
        }
        // Wiring `onEmptied` directly makes the deck's pool-count
        // recovery unconditional. Without it, recovery would depend on
        // the PhotoKit deletion also firing `handleLibraryChange`.
        trash.onEmptied = { [weak deck] _ in
            deck?.refreshPoolAfterExternalChange()
            PhotoDeck.shared.refreshPoolAfterExternalChange()
        }
        deck.onLiked = { [weak trash] assetID in
            // A keep overrides a queued delete: liking an asset already
            // queued pulls it back out of the trash. This records its
            // own usage count, separate from `bin.restore`.
            if trash?.restore(assetID: assetID) == true { Usage.shared.keepPulledFromBin(mode: .videos) }
        }
        // Reuses the trash service's existing badge, space chip, and
        // deck-exclusion logic, through `onQueued`, instead of
        // duplicating it here.
        // This closure fires only after `ShrinkService` confirms the new
        // 1080p asset's save; the original is never queued before that.
        //
        // The `Bool` return matters. `queue` returns `false` when the
        // user liked the asset during the export. `ShrinkService` then
        // reports `.doneOriginalKept`, not a move to the bin.
        shrink.onOriginalReadyToTrash = { [weak trash] originalID, replacementBytes in
            trash?.queue(assetID: originalID, replacementBytes: replacementBytes) ?? false
        }
        // Lets `ShrinkService` refuse to start the export, or stop just
        // before the irreversible save, for an asset the user liked in
        // the meantime. Without this check, the export would finish and
        // produce an unwanted copy before the like could stop it. See
        // the guards in `runJob`.
        shrink.isAssetLiked = { [weak deck] assetID in
            deck?.isLiked(assetID) ?? false
        }
        self.deck = deck
        self.trash = trash
        self.shrink = shrink
    }
}

// MARK: - Welcome screen, on demand

/// The permission gate's welcome screen, presentable from Settings.
///
/// The gate itself appears only while photo access is `.notDetermined`.
/// Once a user grants access, the gate becomes unreachable. This view
/// shows the same content on demand.
///
/// Its button says "Done" rather than "Allow photo access".
/// Access is already granted by the time anyone reaches this screen, so
/// asking again would do nothing.
struct WelcomeScreenView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(PermissionGateView.welcomeTitle)
                            .font(.largeTitle.weight(.bold))
                        Text(PermissionGateView.welcomeMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(PermissionGateView.welcomeRows) { row in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: row.symbol)
                                    .font(.system(size: 20, weight: .medium))
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).font(.headline)
                                    Text(row.body).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 60)
            }
            VStack(spacing: 12) {
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("welcome_done")
                Text(PermissionGateView.welcomeFootnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("welcome_screen")
    }
}
