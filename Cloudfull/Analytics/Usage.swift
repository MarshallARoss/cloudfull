//
//  Usage.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import AVFoundation
import CloudKit
import CoreTelephony
import Network
import Photos
import UIKit

/// Records anonymous usage counts and uploads them to CloudKit.
///
/// The app writes one `UsageSession` record per session, from foreground to
/// background, at roughly 1 to 5 KB each. `scripts/usage_report.py` sums
/// sessions into days. Counting is a dictionary increment on the main
/// actor. Nothing here touches PhotoKit, SwiftData, or the network on the
/// main thread. The session saves to UserDefaults on a debounce, so a
/// crash loses at most two seconds of data. A finished session stays
/// queued until an upload succeeds.
///
/// A record never holds an asset id, a file name, a photo's date, a place,
/// an album name, or anything typed by the user. It holds only counts,
/// exact numbers, and choices, with no bucketing. The app calls no
/// tracking API (App Store guideline 5.1.2). Every value is first-party
/// data, joined with nothing outside the app.
///
/// Upload goes to the container named by `containerID`, which matches
/// `Cloudfull.entitlements`. The simulator and XCTest-hosted test runs
/// never upload.
@MainActor
final class Usage {
    static let shared = Usage()

    // MARK: - Event vocabulary

    enum Mode: String { case videos, photos }
    enum ActionKind: String { case keep, unkeep, delete, share, album, shrink }
    enum ActionSource: String { case rail, doubleTap }
    enum KeepFollowup: String { case swipe, stay, back }
    enum ModeSwitchVia: String { case chin, quickAction, notification, endPage }
    enum ReminderAskAt: String { case firstDelete, endPage }
    enum ReminderAnswer: String { case yes, notNow }
    enum EndPageTap: String { case keepScrolling, toPhotos, toVideos }
    enum ShareTarget: String {
        case messages, mail, save, airDrop, copy, album, cancelled
        case instagram, whatsapp, telegram, signal, facebook, messenger, snapchat, tiktok, x, threads, discord, slack, reddit, pinterest
        case notes, files, print, reminders, shortcuts, markup, other
    }

    /// Maps Apple's activity identifier to a family.
    ///
    /// Every system activity has a fixed `com.apple.UIKit.activity.*` id.
    /// A third-party app shows up under its own bundle id. An unmapped id
    /// returns `other` and counts its raw id alongside it, so the
    /// mapping can grow later.
    static func shareTarget(for raw: String?, albumType: String) -> ShareTarget {
        guard let raw else { return .cancelled }
        if raw == albumType { return .album }
        let r = raw.lowercased()
        // Apple's own activities
        if r.hasSuffix("activity.message") || r.contains("mobilesms") { return .messages }
        if r.hasSuffix("activity.mail") || r.contains("mobilemail") { return .mail }
        if r.contains("savetocameraroll") { return .save }
        if r.hasSuffix("activity.airdrop") || r.contains("airdrop") { return .airDrop }
        if r.hasSuffix("activity.copytopasteboard") || r.contains("pasteboard") { return .copy }
        if r.hasSuffix("activity.print") { return .print }
        if r.hasSuffix("activity.markupasPDF".lowercased()) || r.contains("markup") { return .markup }
        if r.contains("mobilenotes") || r.contains("notes.sharingextension") { return .notes }
        if r.contains("documentmanager") || r.contains("savetofiles") || r.contains("com.apple.files") { return .files }
        if r.contains("reminders") { return .reminders }
        if r.contains("shortcuts") { return .shortcuts }
        // Third-party bundle ids, matched by substring
        if r.contains("burbn") || r.contains("instagram") { return .instagram }
        if r.contains("whatsapp") { return .whatsapp }
        if r.contains("telegra") { return .telegram }
        if r.contains("signal") { return .signal }
        if r.contains("facebook.messenger") || r.contains("messenger") { return .messenger }
        if r.contains("facebook") { return .facebook }
        if r.contains("snapchat") { return .snapchat }
        if r.contains("tiktok") || r.contains("musically") || r.contains("zhiliaoapp") { return .tiktok }
        if r.contains("twitter") || r.contains("atebits") { return .x }
        if r.contains("threads") || r.contains("barcelona") { return .threads }
        if r.contains("discord") { return .discord }
        if r.contains("slack") { return .slack }
        if r.contains("reddit") { return .reddit }
        if r.contains("pinterest") { return .pinterest }
        return .other
    }
    enum Gate: String { case welcome, limited, denied }

    /// The mode the user is in right now.
    ///
    /// `creditModeSeconds` must credit the mode that is ending. A read of
    /// `AppModeStore` races the switch. Thus this type keeps its own copy
    /// of the mode. A site with no mode of its own, such as share or
    /// album, reads this too.
    private(set) var mode: Mode = .videos
    static var currentMode: Mode { shared.mode }

    // Actions
    func action(_ kind: ActionKind, source: ActionSource, mode: Mode) {
        bump("action.\(mode.rawValue).\(kind.rawValue)")
        if kind == .keep { bump("keepSource.\(mode.rawValue).\(source.rawValue)") }
        if kind == .delete { noteFirstAction(); firstEver("delete"); noteDelete(mode: mode) }
        if kind == .keep { noteFirstAction(); firstEver("keep") }
        if kind == .share || kind == .album || kind == .shrink { noteFirstAction() }
    }
    func keepFollowup(_ result: KeepFollowup) { bump("afterPhotoKeep.\(result.rawValue)") }
    func modeSwitch(to mode: Mode, via: ModeSwitchVia) {
        bump("modeSwitch.\(via.rawValue)"); bump("modeSwitchTo.\(mode.rawValue)")
        creditModeSeconds()
        self.mode = mode
    }
    /// Seconds spent in the mode that is ending, credited to it.
    private func creditModeSeconds() {
        guard let since = modeSince else { return }
        bump("secondsIn.\(mode.rawValue)", by: Int(Date().timeIntervalSince(since)))
        modeSince = Date()
    }
    /// Records the sort, the filters, and the types in force at open as
    /// facts. `sort.*` is set only for a mode that has a sort.
    func filtersInForce(mode: Mode, sort: String? = nil, filters: [String], types: [String]) {
        if let sort { set("sort.\(mode.rawValue)", sort) }
        set("filters.\(mode.rawValue)", filters.joined(separator: ","))
        set("types.\(mode.rawValue)", types.joined(separator: ","))
    }
    /// Records which filter flipped, and whether it turned on or off.
    func filterToggled(mode: Mode, name: String, on: Bool) { bump("\(on ? "filterOn" : "filterOff").\(mode.rawValue).\(name)") }
    func sortChanged(mode: Mode, name: String) { bump("sortChanged.\(mode.rawValue).\(name)") }
    func filterChange(mode: Mode) { bump("filterChange.\(mode.rawValue)"); postsSeenSinceFilter = 0 }
    func filterReset(mode: Mode) { bump("filterReset.\(mode.rawValue)"); bump("postsSeenBeforeFilterReset.\(mode.rawValue)", by: postsSeenSinceFilter); postsSeenSinceFilter = 0 }
    func onThisDateEndReached(mode: Mode) { bump("onThisDateEndPage.\(mode.rawValue).reached") }
    func onThisDateEnd(mode: Mode, tap: EndPageTap) { bump("onThisDateEndPage.\(mode.rawValue).\(tap.rawValue)") }
    func reminderAsk(answer: ReminderAnswer, at: ReminderAskAt) { bump("dailyReminderAsk.\(at.rawValue).\(answer.rawValue)") }
    func notificationPermissionAnswered(granted: Bool) { bump(granted ? "notificationPermission.allowed" : "notificationPermission.denied") }
    enum NotificationKind: String { case daily }
    /// One flag plus a kind, so a future notification type becomes a new
    /// value, not a new key.
    func notificationTap(_ kind: NotificationKind) {
        bump("notificationTap.\(kind.rawValue)")
        set("openedFromNotification", "1"); set("notificationKind", kind.rawValue)
        notificationTapAt = Date()
    }
    func pullRefresh(mode: Mode) { bump("pullRefresh.\(mode.rawValue)") }
    func pinch() { bump("photoPinchZoom") }
    func holdFastForward() { bump("video.fastForwardHold") }
    func scrub() { bump("video.scrub") }
    /// Counts each tap, not the resulting state.
    func muteToggled(nowMuted: Bool) { bump(nowMuted ? "muteButton.muted" : "muteButton.unmuted") }
    func liveToggled(nowOn: Bool) { bump(nowOn ? "liveSwitch.turnedOn" : "liveSwitch.turnedOff") }
    /// The app has no hold gesture on a Live Photo. A play is an auto-play
    /// when the photo is near the center of the screen, or a single-tap
    /// replay.
    func livePlayed(byTap: Bool) { bump(byTap ? "livePlay.tap" : "livePlay.auto") }
    func switcherOpened() { bump("modeSwitcherOpened") }
    func keepTapNoop(mode: Mode) { bump("keepTapOnAlreadyKept.\(mode.rawValue)") }
    func shrinkSheetOpened() { bump("shrink.sheet") }
    func shrinkCancelled() { bump("shrink.cancel") }
    /// How a started shrink ended: `done`, `failed`, `originalKept.<liked|cancelled|queueRefused>`.
    func shrinkOutcome(_ outcome: String) { bump("shrink.\(outcome)") }
    /// Exact bytes a finished shrink saved, summed by the report script
    /// into the total storage saved.
    func shrinkSaved(bytes: Int64) { bump("bytesFreed.byShrink", by: Int(clamping: bytes)); bump("bytesFreed.total", by: Int(clamping: bytes)) }
    func binOpened() { bump("bin.open") }
    func binPreviewOpened() { bump("bin.preview") }
    func albumPickerCancelled() { bump("album.cancel") }
    func settingsOpened() { bump("settingsOpened") }
    func settingChanged(_ name: String) { bump("setting.\(name)") }
    func fullscreenEntered() { bump("video.rotatedToFullscreen") }
    func quickAction(mode: Mode) { bump("quickAction.\(mode.rawValue)") }

    // Feed
    func postSeen(mode: Mode) { bump("postsSeen.\(mode.rawValue)"); postsSeenSinceFilter += 1 }
    func swipe(mode: Mode, up: Bool) {
        bump("swipes.\(mode.rawValue)"); if up { bump("swipesBack.\(mode.rawValue)") }
        // Counts the first swipe within 5 seconds of a delete, back or
        // forward.
        if let last = lastDelete, Date().timeIntervalSince(last.at) < 5 {
            bump("afterDelete.\(last.mode.rawValue).\(up ? "back" : "swipe")")   // counted under the mode the delete happened in
            lastDelete = nil
        }
    }
    /// Starts the 5-second window after a delete. `swipe` counts a swipe
    /// inside the window. If no swipe occurs, the window counts as `stay`.
    private func noteDelete(mode: Mode) {
        let at = Date()
        // A delete inside the previous delete's window counts as that
        // delete's `stay` outcome: the user stayed and acted.
        if let previous = lastDelete, at.timeIntervalSince(previous.at) < 5 {
            bump("afterDelete.\(previous.mode.rawValue).stay", userEvent: false)
        }
        lastDelete = (at, mode)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.lastDelete?.at == at else { return }   // a swipe, or a newer delete, already claimed this window
            self.lastDelete = nil
            self.bump("afterDelete.\(mode.rawValue).stay", userEvent: false)   // the app noticed this, not the user
        }
    }
    /// Records the exact size of a deleted item as the key, so the report
    /// script can compute average resolution and length. A zero width or
    /// height counts as `deleted.<mode>.sizeUnknown`.
    func deleted(mode: Mode, width: Int, height: Int, durationMs: Int = 0) {
        guard width > 0, height > 0 else { bump("deleted.\(mode.rawValue).sizeUnknown"); return }   // deleted before its facts loaded
        bump("deleted.\(mode.rawValue).res.\(width)x\(height)")
        if mode == .videos { bump("deleted.videos.durationMsSum", by: durationMs); bump("deleted.videos.durationCount") }
    }
    /// Counts items of one kind leaving the bin: the total, and the ones
    /// whose size was known, with their bytes. `bytesSum ÷ sizedItemCount`
    /// gives the average size of a deleted video or photo.
    func binEmptied(mode: Mode, items: Int, sizedItems: Int, bytes: Int64) {
        bump("bin.emptied.\(mode.rawValue).itemCount", by: items)
        bump("bin.emptied.\(mode.rawValue).sizedItemCount", by: sizedItems)
        bump("bin.emptied.\(mode.rawValue).bytesSum", by: Int(clamping: bytes))
    }
    /// Records the size the feed actually played, read from the player
    /// item, not the asset's own resolution. Apple does not publish the
    /// on-device proxy size, so this measures it. Compare against
    /// `deleted.videos.res.*`, which carries the asset's true size.
    func videoServed(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        bump("video.served.\(width)x\(height)", userEvent: false)
    }
    /// Reads AVFoundation's own log for a clip that finished on screen.
    ///
    /// `droppedFrames` with no `stalls` shows that another task uses the
    /// video decoder. The shrink exporter is the probable cause. A buffer
    /// counter cannot detect this. `video.secondsLogged` is the
    /// denominator: N drops across two seconds is a very different thing
    /// from N drops across ten minutes.
    func videoPlaybackLog(stalls: Int, droppedFrames: Int, secondsWatched: Double) {
        // Logged every time, even with no trouble. Without this, a zero
        // cannot be told apart from a clip with no log at all, and the two
        // mean different things.
        bump("video.clipsLogged", userEvent: false)
        if secondsWatched.isFinite, secondsWatched > 0 {
            bump("video.secondsLogged", by: Int(secondsWatched.rounded()), userEvent: false)
        }
        guard stalls > 0 || droppedFrames > 0 else { return }
        if stalls > 0 { bump("video.logStalls", by: stalls, userEvent: false) }
        if droppedFrames > 0 { bump("video.droppedFrames", by: droppedFrames, userEvent: false) }
        bump("video.clipsWithTrouble", userEvent: false)
    }
    /// A clip that played but returned no access log at all. `accessLog()`
    /// is Apple's network log, and it can be nil for a local file. A zero
    /// in `clipsWithTrouble` means the playback was clean only when this
    /// count is also low.
    func videoNoPlaybackLog() { bump("video.clipsNoLog", userEvent: false) }
    /// The clip ran out of buffered data while it played.
    func videoStalledMidPlay() { bump("video.stalledMidPlay") }
    /// A feed video reached its end and started over while still on screen.
    func videoLooped() { bump("video.loops", userEvent: false) }
    /// Records the bin as it stands when the app leaves the foreground, so
    /// the report can find users who never clear it.
    func binState(items: Int, bytes: Int64) { set("binItemsAtEnd", String(items)); set("binBytesAtEnd", String(bytes)) }

    // Bin
    /// Counts a tap on "Empty Bin". iOS then shows its own confirm sheet.
    /// Compare this count with `binEmptied` to find how many users cancel.
    func binEmptyAttempted() { bump("bin.emptyTapped") }
    func binEmpty(bytes: Int64, oldestDays: Int) {
        bump("bin.emptiedCount")
        // Exact byte counts. `bytesFreed.total` sums deleted and shrink
        // bytes, so the total storage saved does not depend on reading
        // both fields together.
        bump("bytesFreed.byDelete", by: Int(clamping: bytes)); bump("bytesFreed.total", by: Int(clamping: bytes))
        raise("bin.emptiedOldestDaysMax", to: oldestDays)   // the largest age, in days, of an item in the bin when the user empties it
        firstEver("binEmpty")
    }
    /// A tap on Restore in the bin. A Keep that pulls an item back out
    /// does not count here; see `keepPulledFromBin`.
    func binRestore() { bump("bin.restore") }
    /// Counts a Keep on an item that is in the bin queue. The Keep removes
    /// the item from the queue.
    func keepPulledFromBin(mode: Mode) { bump("keepPulledFromBin.\(mode.rawValue)") }
    /// Counts a second trash tap that removes the item from the bin queue
    /// in the feed.
    func unqueuedInFeed(mode: Mode) { bump("unqueuedInFeed.\(mode.rawValue)") }

    // Share / album
    /// Counts the share sheet opening. `action.<mode>.share` counts only
    /// a sheet that finishes on a real target. A cancelled sheet is not
    /// a share.
    func shareSheetOpened() { bump("shareSheetOpened.\(mode.rawValue)"); noteFirstAction() }
    func shareFinished(_ target: ShareTarget, raw: String? = nil) {
        bump("shareTarget.\(target.rawValue)")
        if target != .cancelled, target != .album { bump("action.\(mode.rawValue).share") }
        // Counts the raw activity identifier or third-party bundle id
        // every time. The report uses these counts to check and extend
        // the family map.
        if let raw { bump("shareTargetRaw.\(raw.prefix(64))") }
    }
    func shareFailed() { bump("shareFailed") }
    /// The kind shared: `movie` (video feed), `still` / `live` / `liveMovie` (photo feed).
    func shareKind(_ kind: String) { bump("shareKind.\(kind)") }
    func albumAdded(new: Bool) { bump(new ? "album.new" : "album.existing") }
    func albumSortChanged() { bump("album.sortChanged") }
    // Which app icon the user picked, and a failure to set it.
    func appIconChanged(to name: String) { bump("appIcon.\(name)") }
    func appIconChangeFailed() { bump("appIcon.failed") }
    // The "Cloudfull keeps" album that a Keep writes to.
    func keepAlbumAdded(alreadyThere: Bool) { bump(alreadyThere ? "keepAlbum.alreadyThere" : "keepAlbum.added", userEvent: false) }
    func keepAlbumRemoved() { bump("keepAlbum.removed", userEvent: false) }
    func keepAlbumFailed() { bump("keepAlbum.failed", userEvent: false) }

    // First run and gates
    func gateShown(_ gate: Gate) { bump("gateScreen.\(gate.rawValue).shown"); gateShownAt = Date() }
    func gateLeft(_ gate: Gate, via: String) {
        bump("gateScreen.\(gate.rawValue).\(via)")
        if let at = gateShownAt { bump("gateScreen.\(gate.rawValue).seconds", by: Int(Date().timeIntervalSince(at))) }
        gateShownAt = nil
    }
    /// One mapping for every photo-permission fact and field.
    nonisolated static func permissionName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "full"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notAsked"
        @unknown default: return "other"
        }
    }
    /// The user answered iOS's "Allow access to your photos?" sheet this
    /// session. `photoPermissionAtStart` holds the permission at open,
    /// which is `notAsked` on a first run. These counts record the choice.
    func permissionAnswered(_ status: PHAuthorizationStatus, secondsToAnswer: Int) {
        let name = Self.permissionName(status)
        bump("photoPermission.\(name)"); bump("photoPermission.seconds", by: secondsToAnswer)
    }
    func accessAfterSettingsReturn(_ status: PHAuthorizationStatus) {
        set("photoPermissionAfterSettings", Self.permissionName(status))
    }
    func onboarding(_ step: String) { bump("onboarding.\(step)") }

    // Waiting
    func loadingTap(mode: Mode) { bump("loadingTaps.\(mode.rawValue)") }
    /// Time to the first post on screen. Counted only when the whole deal
    /// happened inside this foreground. A deal that began in an earlier
    /// session would otherwise include the time the app spent suspended,
    /// inflating the measurement.
    func firstDeal(mode: Mode, ms: Int) {
        guard current.facts["firstLoadMs.\(mode.rawValue)"] == nil else { return }
        guard Date().addingTimeInterval(-Double(ms) / 1000) >= current.startedAt else {
            bump("firstLoadSpannedSessions.\(mode.rawValue)"); return
        }
        set("firstLoadMs.\(mode.rawValue)", String(ms))
    }

    // Health
    func photoLoadFailed() { bump("photoLoadFailedCount") }
    func videoLoadFailed() { bump("videoLoadFailedCount") }
    func slowDownload() { bump("slowDownloadCount") }
    func stallsSoFar(_ count: Int) { set("mainThreadStallsOver250ms", String(count)) }

    /// Call once per session, with the current defaults, so the session
    /// counts each default once, not on every tap.
    func appOpened(cold: Bool, defaultTab: String, openMuted: Bool, liveDefaultOn: Bool, reminderOn: Bool, reminderHour: Int?) {
        beginSession(cold: cold)
        set("defaultTabSetting", defaultTab)
        set("openMutedSetting", openMuted ? "1" : "0")
        set("liveDefaultSetting", liveDefaultOn ? "1" : "0")
        set("dailyReminderSetting", reminderOn ? "1" : "0")
        if let reminderHour { set("dailyReminderHourSetting", String(reminderHour)) }
        // The album picker's Recent / Alphabetical choice.
        set("albumSort", UserDefaults.standard.string(forKey: "albumPicker.sortOrder") ?? "recent")
        set("keepsAlbumSetting", KeepsAlbum.shared.isOn ? "1" : "0")
        set("appIconSetting", AppIconChoice.current.rawValue)
        if let hour = reminderHour, reminderOn {
            let now = Calendar.current.component(.hour, from: Date())
            let apart = abs(now - hour)
            if min(apart, 24 - apart) <= 1 { bump("openedNearDailyReminder") }   // 23:30 vs a 00:00 reminder is near
        }
    }

    // MARK: - The session record

    struct Session: Codable {
        var install: String
        var id: String
        var startedAt: Date
        var endedAt: Date?
        var coldStart: Bool
        var app: String
        var ios: String
        var device: String
        var counts: [String: Int] = [:]
        var facts: [String: String] = [:]
        /// The time of the session's last save. This marks the end of a
        /// session the process did not get to close, such as a crash, a
        /// kill, or a dead battery.
        var lastSeenAt: Date?
        /// The exact library count, read once at the end of the session,
        /// in `flush`.
        var libraryCount: Int?
    }

    fileprivate(set) var current: Session
    private var saveTask: Task<Void, Never>?
    private var firstActionAt: Date?
    /// The 5-second after-delete window: when it started, and in which
    /// feed. A swipe in the other feed after a mode switch still counts
    /// as this delete's outcome.
    private var lastDelete: (at: Date, mode: Mode)?
    /// The last counted event. `sessionSeconds - lastEventSeconds` gives
    /// the idle tail, such as a phone left on a stand with the screen
    /// never locked. A screen lock ends the session on its own.
    private var lastEventAt: Date?
    private var notificationTapAt: Date?
    private var gateShownAt: Date?
    private var volumeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    /// False until the first `.active` of the process (see `beginSession`).
    private var sessionHasBegun = false
    /// When the current mode began, for seconds-per-mode.
    private var modeSince: Date?
    private var postsSeenSinceFilter = 0
    private let defaults = UserDefaults.standard
    private static let currentKey = "usage.session.current"
    private static let installKey = "usage.install"
    private static let installedAtKey = "usage.installedAt"
    private static let sessionCountKey = "usage.sessionCount"        // sessions begun on this phone, ever
    private static let pendingKey = "usage.session.pending"   // finished, not yet uploaded
    private static let firstsKey = "usage.firsts"             // e.g. "delete" maps to the day index of its first occurrence

    private init() {
        let install = defaults.string(forKey: Self.installKey) ?? {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: Self.installKey)
            UserDefaults.standard.set(Date(), forKey: Self.installedAtKey)
            return id
        }()
        // Close a session that a crash or a kill left open. Its end time
        // is `lastSeenAt`, not now, because the phone can stay off for a
        // long time.
        if let data = defaults.data(forKey: Self.currentKey),
           var stale = try? JSONDecoder().decode(Session.self, from: data), stale.endedAt == nil {
            let endedAt = stale.lastSeenAt ?? stale.startedAt
            stale.endedAt = endedAt
            stale.facts["endReason"] = "crashOrKill"
            stale.facts["sessionSeconds"] = String(Int(endedAt.timeIntervalSince(stale.startedAt)))
            Self.appendPending(stale, defaults: defaults)
        }
        current = Self.freshSession(install: install, cold: true)
        // `beginSession` replaces this session on the first `.active`. It
        // holds any event that occurs before then, such as a quick-action
        // launch.
    }

    private static func freshSession(install: String, cold: Bool) -> Session {
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingCString: $0) ?? "?" }
        }
        return Session(install: install, id: UUID().uuidString, startedAt: Date(), endedAt: nil, coldStart: cold,
                       app: app, ios: UIDevice.current.systemVersion, device: machine)
    }

    private func beginSession(cold: Bool) {
        // A cold launch may already have counts from before the first
        // `.active`, such as a quick action or a notification tap. Those
        // counts belong to this session, so the code carries them forward
        // instead of ending them.
        var carried: (counts: [String: Int], facts: [String: String])?
        if current.endedAt == nil, cold, !sessionHasBegun {
            carried = (current.counts, current.facts)
        } else if current.endedAt == nil, !current.counts.isEmpty || !current.facts.isEmpty {
            endSession(by: "reopen")
        }
        current = Self.freshSession(install: current.install, cold: cold)
        if let carried { current.counts = carried.counts; current.facts = carried.facts }
        sessionHasBegun = true
        firstActionAt = nil
        lastEventAt = nil
        notificationTapAt = nil
        gateShownAt = nil
        lastDelete = nil
        postsSeenSinceFilter = 0
        modeSince = Date()
        mode = AppModeStore.shared.mode == .photos ? .photos : .videos
        current.facts["startHour"] = String(Calendar.current.component(.hour, from: Date()))
        current.facts["startWeekday"] = String(Calendar.current.component(.weekday, from: Date()))
        current.facts["utcOffsetMinutes"] = String(TimeZone.current.secondsFromGMT() / 60)
        // The time zone identifier (for example America/Chicago) is the
        // most specific location the app can know without a location
        // prompt, which it never asks for.
        current.facts["timeZone"] = TimeZone.current.identifier
        current.facts["daysSinceInstall"] = String(Self.daysSinceInstall(defaults: defaults))
        // 0 on the very first session of this phone, like
        // `daysSinceInstall`. The report script divides other counts by
        // this one to compute rates.
        let before = defaults.integer(forKey: Self.sessionCountKey)
        defaults.set(before + 1, forKey: Self.sessionCountKey)
        current.facts["sessionsBefore"] = String(before)
        current.facts["openedFromNotification"] = current.facts["openedFromNotification"] ?? "0"   // always written, like every other flag
        current.facts["lowPowerAtStart"] = ProcessInfo.processInfo.isLowPowerModeEnabled ? "1" : "0"
        current.facts["reduceMotion"] = UIAccessibility.isReduceMotionEnabled ? "1" : "0"
        current.facts["textSize"] = UIApplication.shared.preferredContentSizeCategory.rawValue.replacingOccurrences(of: "UICTContentSizeCategory", with: "")
        current.facts["darkModeSetting"] = UITraitCollection.current.userInterfaceStyle == .dark ? "1" : "0"
        current.facts["language"] = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "?"
        current.facts["country"] = Locale.current.region?.identifier ?? "?"
        // The network path at the start of the session, plus any change
        // during it. Signal strength has no public API and is not read.
        startNetworkWatch()
        // Volume and the audio route. The ring/silent switch has no
        // public API and is not guessed at. AVFoundation and PhotoKit
        // reads happen off the main actor and merge into the session when
        // they return.
        let sessionID = current.id
        Task.detached(priority: .utility) {
            let free = Self.freeSpaceGB()
            let audio = AVAudioSession.sharedInstance()
            let volume = String(format: "%.2f", audio.outputVolume)
            let route = Self.routeName(audio.currentRoute)
            let permission = Self.permissionName(PHPhotoLibrary.authorizationStatus(for: .readWrite))
            await MainActor.run {
                let me = Usage.shared
                guard me.current.id == sessionID, me.current.endedAt == nil else { return }
                me.current.facts["volumeAtStart"] = volume
                me.current.facts["audioRouteAtStart"] = route
                me.current.facts["photoPermissionAtStart"] = permission
                me.current.facts["freeSpaceGBAtStart"] = free
                me.markDirty()
            }
        }
        volumeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { _ in
            let route = Self.routeName(AVAudioSession.sharedInstance().currentRoute)   // off main: the queue is nil
            Task { @MainActor in
                let me = Usage.shared
                guard me.current.endedAt == nil else { return }
                let last = me.current.facts["audioRouteAtEnd"] ?? me.current.facts["audioRouteAtStart"]
                guard last != route else { return }
                me.bump("audioRouteChanges", userEvent: false)
                me.current.facts["audioRouteAtEnd"] = route   // `audioRouteAtStart` stays what it was
            }
        }
        markDirty()
    }

    private func endSession(by: String) {
        guard current.endedAt == nil else { return }
        creditModeSeconds()
        if let volumeObserver { NotificationCenter.default.removeObserver(volumeObserver) }
        volumeObserver = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        current.endedAt = Date()
        current.facts["endReason"] = by
        current.facts["sessionSeconds"] = String(Int(current.endedAt!.timeIntervalSince(current.startedAt)))
        if let firstActionAt {
            current.facts["secondsToFirstAction"] = String(Int(firstActionAt.timeIntervalSince(current.startedAt)))
        }
        if let lastEventAt {
            current.facts["lastEventSeconds"] = String(Int(lastEventAt.timeIntervalSince(current.startedAt)))
        }
        if let notificationTapAt, let firstActionAt, firstActionAt > notificationTapAt {
            current.facts["notificationToFirstAction"] = String(Int(firstActionAt.timeIntervalSince(notificationTapAt)))
        }
        Self.appendPending(current, defaults: defaults)
        isDirty = false   // nothing may re-save the ended session as "current"
        defaults.removeObject(forKey: Self.currentKey)
        saveTask?.cancel()   // stop the 2 s save loop with the session; `markDirty` starts a new one
        saveTask = nil
    }

    private func noteFirstAction() { if firstActionAt == nil { firstActionAt = Date() } }

    /// Records the days from install to a first event, once ever, as a
    /// fact on the session where it happened.
    private func firstEver(_ what: String) {
        guard current.endedAt == nil else { return }   // a sealed session cannot take the fact; do not stamp the first either
        var firsts = defaults.dictionary(forKey: Self.firstsKey) as? [String: Int] ?? [:]
        guard firsts[what] == nil else { return }
        let days = Self.daysSinceInstall(defaults: defaults)
        firsts[what] = days
        defaults.set(firsts, forKey: Self.firstsKey)
        current.facts["daysToFirst.\(what)"] = String(days)
        markDirty()
    }

    private static func daysSinceInstall(defaults: UserDefaults) -> Int {
        let at = defaults.object(forKey: installedAtKey) as? Date ?? Date()
        return Calendar.current.dateComponents([.day], from: at, to: Date()).day ?? 0
    }

    /// A count that keeps the biggest value seen this session, not a sum.
    private func raise(_ key: String, to n: Int) {
        guard current.endedAt == nil else { return }
        current.counts[key] = max(current.counts[key] ?? 0, n)
        lastEventAt = Date()
        markDirty()
    }

    /// Pass `userEvent: false` for something the phone did on its own,
    /// such as a Wi-Fi drop or a route change. It still counts, but it is
    /// not the user being active.
    fileprivate func bump(_ key: String, by n: Int = 1, userEvent: Bool = true) {
        guard current.endedAt == nil else { return }   // an ended session is sealed
        current.counts[key, default: 0] += n
        if userEvent { lastEventAt = Date() }
        markDirty()
    }

    private func set(_ key: String, _ value: String) {
        guard current.endedAt == nil else { return }
        current.facts[key] = value
        markDirty()
    }

    /// True when the session has changed since the last save.
    private var isDirty = false
    // Use one long-lived loop and a dirty flag, not a task per bump. A
    // task per bump can allocate twice per page during a fast scroll,
    // which adds avoidable overhead. Encoding the small session struct
    // costs microseconds. The write itself runs on UserDefaults' own
    // background queue.
    fileprivate func markDirty() {
        isDirty = true
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in
            var tick = 0
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                tick += 1
                // Save every 30 s even when idle, so `lastSeenAt` limits
                // the length of a crashed session. A ten-minute video with
                // no tap then counts as ten minutes, not zero.
                if self.isDirty || tick % 15 == 0 { self.isDirty = false; self.saveNow() }
            }
        }
    }

    private func saveNow() {
        guard current.endedAt == nil else { return }
        current.lastSeenAt = Date()
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: Self.currentKey)
        }
    }

    private static func appendPending(_ session: Session, defaults: UserDefaults) {
        var list = (defaults.data(forKey: pendingKey)).flatMap { try? JSONDecoder().decode([Session].self, from: $0) } ?? []
        list.append(session)
        if list.count > 60 { list.removeFirst(list.count - 60) }   // keep at most 60 sessions, so the queue stays bounded on a phone that can never upload
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: pendingKey) }
    }

    // MARK: - Upload

    /// The iCloud container, matching `Cloudfull.entitlements`. `nil`
    /// turns uploads off.
    ///
    /// This is a plain constant because an `INFOPLIST_KEY_` for a custom
    /// key is silently dropped by Xcode's generated Info.plist, and
    /// `SecTask` is macOS-only.
    static let containerID: String? = "iCloud.com.cloudfull.app"

    /// Called when the app goes to the background. Ends the session,
    /// queues it, and uploads everything queued, off the main actor.
    /// A failure is silent. The next call tries again, so a phone that is
    /// not signed in to iCloud never uploads.
    func flush() {
        #if DEBUG
        stallsSoFar(MainThreadWatchdog.shared.stallCount)
        #endif
        // Free space at the end lives in `facts`, at both start and end,
        // not as a field. Dropping it later then needs no schema change.
        // Then the code seals and sends the session.
        //
        // Claim the background task here, before the off-main reads. The
        // PhotoKit count and the upload must finish in the time iOS
        // grants. If they do not, the next launch records the session as
        // `crashOrKill`.
        let bgBox = BackgroundTaskBox()
        bgBox.id = UIApplication.shared.beginBackgroundTask(withName: "usage-flush") {
            bgBox.end()
            Task { @MainActor in Usage.shared.uploadTask?.cancel(); Usage.shared.uploadTask = nil }
        }
        let sessionID = current.id
        Task.detached(priority: .userInitiated) {
            let free = Self.freeSpaceGB()
            let count = Self.libraryCount()   // exact, at the end of the session, after this session's deletes
            await MainActor.run {
                let me = Usage.shared
                // Only the session that was current when the app left the
                // foreground gets sealed here. If the user returned first,
                // a new session already exists, and this must not end it.
                if me.current.id == sessionID, me.current.endedAt == nil {
                    me.current.facts["freeSpaceGBAtEnd"] = free
                    me.current.libraryCount = count
                    me.endSession(by: "background")
                }
                me.uploadPending(reusing: bgBox)
            }
        }
    }

    /// Sends every queued session. Called on background, after the
    /// session ends, and on foreground, so a send that iOS cut short
    /// retries while the app is awake.
    ///
    /// Pass `reusing` when `flush` already holds a background task. A
    /// foreground retry with no existing task claims its own.
    func uploadPending(reusing existing: BackgroundTaskBox? = nil) {
        #if targetEnvironment(simulator)
        existing?.end()
        return
        #else
        guard let containerID = Self.containerID,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { existing?.end(); return }
        // Only one upload loop runs at a time. Cancel a loop that iOS
        // suspended, and start a new one. A duplicate save of the same
        // record id is safe because of `.allKeys`.
        uploadTask?.cancel()
        guard let data = defaults.data(forKey: Self.pendingKey),
              let sessions = try? JSONDecoder().decode([Session].self, from: data), !sessions.isEmpty else { existing?.end(); return }
        #if DEBUG
        DiagnosticsLog.shared.log("Usage", "upload_begin_\(sessions.count)")
        #endif
        // iOS grants only a few seconds after backgrounding. Ask for that
        // time explicitly. End the task in the expiration handler: iOS
        // kills an app that ignores expiration, with the code 0x8badf00d.
        let bgBox = existing ?? BackgroundTaskBox()
        if existing == nil {
            bgBox.id = UIApplication.shared.beginBackgroundTask(withName: "usage-upload") {
                bgBox.end()
                Task { @MainActor in Usage.shared.uploadTask?.cancel(); Usage.shared.uploadTask = nil }
            }
        }
        let token = UUID()
        uploadToken = token
        uploadTask = Task.detached(priority: .userInitiated) { [sessions] in
            defer { bgBox.end() }
            // A session that ended without `flush`, such as after a reopen
            // or a crash, has no library count. Use one read here as its
            // value.
            let fallback = sessions.contains { $0.libraryCount == nil } ? Self.libraryCount() : nil
            let db = CKContainer(identifier: containerID).publicCloudDatabase
            var uploaded: [String] = []
            for session in sessions {
                let record = CKRecord(recordType: "UsageSession", recordID: CKRecord.ID(recordName: session.id))
                record["installId"] = session.install
                record["startedAt"] = session.startedAt
                record["endedAt"] = session.endedAt ?? session.startedAt
                record["coldStart"] = session.coldStart ? 1 : 0   // CloudKit has no Bool: 0/1
                record["schema"] = 3
                record["app"] = session.app
                record["ios"] = session.ios
                record["device"] = session.device
                record["libraryCount"] = session.libraryCount ?? fallback ?? -1   // exact count, or -1 when never read
                // Store the values that the report groups rows by as
                // CloudKit fields. Store all other values in the `counts`
                // and `facts` JSON strings.
                record["sessionSeconds"] = Int(session.facts["sessionSeconds"] ?? "") ?? Int((session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt))
                record["daysSinceInstall"] = Int(session.facts["daysSinceInstall"] ?? "") ?? -1
                record["country"] = session.facts["country"] ?? "?"
                record["photoPermissionAtStart"] = session.facts["photoPermissionAtStart"] ?? "?"
                record["endReason"] = session.facts["endReason"] ?? "?"
                if let counts = try? JSONEncoder().encode(session.counts) { record["counts"] = String(decoding: counts, as: UTF8.self) }
                // A fact already promoted to a field above is not repeated in the JSON string.
                var blobFacts = session.facts
                for key in Self.promotedFacts { blobFacts.removeValue(forKey: key) }
                if let facts = try? JSONEncoder().encode(blobFacts) { record["facts"] = String(decoding: facts, as: UTF8.self) }
                let op = CKModifyRecordsOperation(recordsToSave: [record])
                op.savePolicy = .allKeys
                op.qualityOfService = .userInitiated
                op.configuration.timeoutIntervalForRequest = 20
                let outcome: UploadOutcome = await withCheckedContinuation { cont in
                    op.modifyRecordsResultBlock = { result in
                        switch result {
                        case .success:
                            #if DEBUG
                            DiagnosticsLog.shared.log("Usage", "upload_ok_\(session.id.prefix(8))_counts_\(session.counts.count)")
                            #endif
                            cont.resume(returning: .sent)
                        case .failure(let error):
                            #if DEBUG
                            DiagnosticsLog.shared.log("Usage", "upload_failed_\(session.id.prefix(8))_\((error as NSError).code)_\(error.localizedDescription.replacingOccurrences(of: " ", with: "_"))")
                            #endif
                            cont.resume(returning: Self.isPermanent(error) ? .rejected : .retryLater)
                        }
                    }
                    db.add(op)
                }
                if Task.isCancelled { break }
                if outcome == .retryLater { break }   // keep order; retry the rest next time
                uploaded.append(session.id)   // either sent, or rejected for good and dropped rather than retried forever
            }
            await MainActor.run {
                Usage.shared.noteUploaded(uploaded)
                if Usage.shared.uploadToken == token { Usage.shared.uploadTask = nil }
            }
        }
        #endif
    }

    fileprivate var uploadTask: Task<Void, Never>?
    /// Identifies which loop owns `uploadTask`, so a cancelled loop
    /// cannot clear its replacement's handle.
    private var uploadToken = UUID()

    private enum UploadOutcome { case sent, rejected, retryLater }

    /// True for an error that CloudKit returns every time for the same
    /// record. Examples are a schema mismatch, a record that is too big,
    /// and a bad container. The next call retries any other error, such
    /// as a network failure, a quota limit, or no iCloud sign-in.
    /// Treating a permanent error as retryable would let one bad record
    /// block the whole queue forever.
    nonisolated private static func isPermanent(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        switch ck.code {
        case .invalidArguments, .serverRejectedRequest, .limitExceeded, .badContainer, .badDatabase, .missingEntitlement, .constraintViolation:
            return true
        default:
            return false
        }
    }

    /// Facts that are also real CloudKit fields. Write each one once, as
    /// a field, and remove it from the facts JSON string.
    private static let promotedFacts: Set<String> = ["sessionSeconds", "daysSinceInstall", "country", "photoPermissionAtStart", "endReason"]

    /// Ends a background task exactly once, from any thread.
    final class BackgroundTaskBox: @unchecked Sendable {
        var id: UIBackgroundTaskIdentifier = .invalid
        private let lock = NSLock()
        func end() {
            lock.lock(); let id = self.id; self.id = .invalid; lock.unlock()
            guard id != .invalid else { return }
            Task { @MainActor in UIApplication.shared.endBackgroundTask(id) }
        }
    }

    private func noteUploaded(_ ids: [String]) {
        guard !ids.isEmpty, let data = defaults.data(forKey: Self.pendingKey),
              var list = try? JSONDecoder().decode([Session].self, from: data) else { return }
        list.removeAll { ids.contains($0.id) }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.pendingKey) }
    }

    /// Free space in GB, rounded to one decimal place, for the Settings
    /// row and the session. Runs off main. Reads the home volume's
    /// available capacity for important usage.
    nonisolated static func freeSpaceGB() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return "?" }
        return String(format: "%.1f", Double(free) / 1_000_000_000)
    }

    // MARK: - Library size

    /// Exact library count. Runs off main. A fetch result's `count` does
    /// not enumerate the library.
    nonisolated private static func libraryCount() -> Int? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }
        return PHAsset.fetchAssets(with: PHFetchOptions()).count
    }


    private func startNetworkWatch() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let name: String
            if path.status != .satisfied { name = "none" }
            else if path.usesInterfaceType(.wifi) { name = "wifi" }
            else if path.usesInterfaceType(.cellular) { name = Self.radioName() }
            else if path.usesInterfaceType(.wiredEthernet) { name = "wired" }
            else { name = "other" }
            let expensive = path.isExpensive, constrained = path.isConstrained
            Task { @MainActor in
                let me = Usage.shared
                guard me.current.endedAt == nil else { return }
                if me.current.facts["networkAtStart"] == nil {
                    me.current.facts["networkAtStart"] = name
                    me.current.facts["networkExpensive"] = expensive ? "1" : "0"
                    me.current.facts["lowDataMode"] = constrained ? "1" : "0"
                } else if (me.current.facts["networkAtEnd"] ?? me.current.facts["networkAtStart"]) != name {
                    // The monitor fires on every small path change. Only a
                    // change of kind, such as wifi to LTE or LTE to none,
                    // counts as a change here.
                    me.bump("networkChanges", userEvent: false)
                    me.current.facts["networkAtEnd"] = name
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.cloudfull.usage.network", qos: .utility))
        pathMonitor = monitor
    }

    /// Returns 5G, LTE, 3G, 2G, or "cell" for the current data radio.
    /// iOS 16 removed the carrier name. No public API gives signal bars.
    nonisolated private static func radioName() -> String {
        guard let radio = CTTelephonyNetworkInfo().serviceCurrentRadioAccessTechnology?.values.first else { return "cell" }
        switch radio {
        case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA: return "5G"
        case CTRadioAccessTechnologyLTE: return "LTE"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA: return "3G"
        case CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyGPRS: return "2G"
        default: return "cell"
        }
    }

    nonisolated private static func routeName(_ route: AVAudioSessionRouteDescription) -> String {
        guard let port = route.outputs.first?.portType else { return "?" }
        switch port {
        case .builtInSpeaker: return "speaker"
        case .headphones: return "wired"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "bluetooth"
        case .airPlay: return "airplay"
        case .carAudio: return "car"
        default: return port.rawValue
        }
    }

}
