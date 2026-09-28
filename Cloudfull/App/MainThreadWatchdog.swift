//
//  MainThreadWatchdog.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if DEBUG
import UIKit
import QuartzCore
import os

/// Counts the gaps between display-link callbacks that are longer than
/// `thresholdMs`. A gap is the time that the main thread cannot respond to
/// a swipe. The type compiles only in DEBUG builds.
@MainActor
final class MainThreadWatchdog: ObservableObject {

    static let shared = MainThreadWatchdog()

    /// A gap strictly greater than this counts as a stall.
    static let thresholdMs = 250

    /// The probe ignores gaps that end in the first `settleSeconds` after
    /// arming. Process launch, the SwiftData container opening, the first
    /// deck deal, and the first video decode are one-time costs. Counting
    /// them would make the probe report launch time rather than scrolling
    /// time.
    private static let settleSeconds: CFTimeInterval = 2.0

    /// A gap longer than this is not a stall. It means the process
    /// stopped, not the app, and the probe discards the gap instead of
    /// recording it.
    ///
    /// The display link stops while the app is in the background. The
    /// first tick after the return shows one large gap. The
    /// `didBecomeActiveNotification` observer clears `lastTick`, but the
    /// main queue does not order that block before the tick.
    ///
    /// A suspension gap can be hundreds of seconds. Without this cap, it
    /// replaces the real worst gap in `worstGapMs`.
    ///
    /// 5 s is far above any hitch this probe is for (the threshold is
    /// 250 ms) and far below any real suspension.
    private static let suspensionCeilingMs = 5_000

    /// Number of gaps over `thresholdMs` since arming.
    @Published private(set) var stallCount = 0
    /// The longest gap seen since arming, in whole milliseconds. This
    /// includes gaps under the threshold, so a clean run still carries
    /// evidence ("0 stalls, worst 84 ms") instead of only an absence.
    @Published private(set) var worstGapMs = 0

    /// `tick(_:)` writes only these plain properties, never the
    /// `@Published` values. The display link fires up to 120 times a
    /// second. A publish on each tick re-renders `MainStallProbeView` and
    /// `MainStallReadoutView` at that rate. That work can extend the next
    /// gap and change the number that the probe reports.
    private var stallCountRaw = 0
    private var worstGapRaw = 0
    /// The label of the last `mark(_:)` call recorded before the worst gap:
    /// which step the main thread was in when it stopped ticking. Device
    /// logs need root access from a Mac, so the app records the step
    /// itself. `MainStallReadoutView` shows this value.
    @Published private(set) var worstMark = "-"
    private var worstMarkRaw = "-"
    private var lastMark = "-"
    /// The last six stalls, newest first. Each entry has this shape:
    /// "653ms @itemCache ← pageCurrent ← pageChange [moving]". It shows the
    /// duration, the step the main thread was in, and the two steps before
    /// it. It also shows whether the pager was scrolling at the time.
    /// `MainStallReadoutView` shows this list.
    @Published private(set) var recentStalls: [String] = []
    private var recentStallsRaw: [String] = []
    private var markTrail: [String] = []

    /// Call this at the start of any main-thread step worth blaming. It
    /// costs one string assignment. Release builds compile `wdMark` to
    /// nothing.
    func mark(_ label: StaticString) {
        lastMark = "\(label)"
        markTrail.append(lastMark)
        if markTrail.count > 3 { markTrail.removeFirst(markTrail.count - 3) }
    }
    /// Mirrors `*Raw` into the `@Published` pair above at 1 Hz, far below
    /// the display link's rate, so this timer's own publish cost is
    /// negligible next to a per-tick one. A value up to 1 s stale changes
    /// no assertion: `M9Tests.mainStallReading` already debounces two reads
    /// 0.3 s apart.
    private var mirrorTimer: Timer?

    private var link: CADisplayLink?
    private var proxy: Proxy?
    private var lastTick: CFTimeInterval?
    private var armedAt: CFTimeInterval = 0
    private var didStart = false

    private static let log = Logger(subsystem: "com.cloudfull.app", category: "MainThreadWatchdog")

    private init() {}

    /// Starts the display link. Idempotent: the first call wins, matching
    /// every other one-shot probe in this app. `GateProbes` calls this
    /// once, and it mounts in every authorization state, so a stall in the
    /// permission gate is measurable too.
    func start() {
        guard !didStart else { return }
        didStart = true
        let proxy = Proxy()
        proxy.owner = self
        let link = CADisplayLink(target: proxy, selector: #selector(Proxy.tick(_:)))
        // Add the link in `.common` mode. In `.default` mode, the link
        // stops while a `UIScrollView` tracks a drag. Each swipe then
        // shows as a false stall.
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.link = link
        rearm()

        // A low-rate mirror, not the tick itself — see the doc comment on
        // `stallCountRaw`/`worstGapRaw` above. Added in `.common` mode for
        // the same reason the display link is: a `.default`-mode timer
        // pauses while a `UIScrollView` tracks a drag, and a swipe is
        // exactly when this value needs to keep moving.
        let mirrorTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.mirrorRawValues() }
        }
        RunLoop.main.add(mirrorTimer, forMode: .common)
        self.mirrorTimer = mirrorTimer

        // The display link stops in the background. Clear `lastTick` so
        // that the first tick after the return starts a new measurement.
        // This does not always run before that tick; `suspensionCeilingMs`
        // handles the other case.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { MainThreadWatchdog.shared.lastTick = nil }
        }
    }

    /// `FeedView` calls this when the feed appears. The call does nothing
    /// unless the launch arguments contain `-cloudfull-reset-stalls`. With
    /// that argument, it sets the counters to zero and restarts the settle
    /// window. A test then measures the feed, not the launch.
    func feedDidAppear() {
        guard ProcessInfo.processInfo.arguments.contains(CloudfullApp.resetStallsArgument) else { return }
        stallCountRaw = 0
        worstGapRaw = 0
        worstMarkRaw = "-"
        recentStallsRaw = []
        // Mirror immediately rather than waiting up to 1 s for the timer,
        // so a reset test that reads the probe right away sees zero, not a
        // stale pre-reset value.
        mirrorRawValues()
        rearm()
    }

    private func rearm() {
        lastTick = nil
        armedAt = CACurrentMediaTime() + Self.settleSeconds
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let previous = lastTick
        lastTick = now
        guard let previous, previous >= armedAt else { return }
        let gapMs = Int(((now - previous) * 1000).rounded())
        // This is a suspension, not a stall. Discard it without touching
        // `worstGapRaw` — see `suspensionCeilingMs`. `lastTick` is already
        // set to `now` above, so the next tick measures from here and the
        // probe simply resumes.
        guard gapMs <= Self.suspensionCeilingMs else { return }
        // Plain stores only. Do not write a `@Published` value here. See
        // `stallCountRaw`.
        if gapMs > worstGapRaw { worstGapRaw = gapMs; worstMarkRaw = lastMark }
        guard gapMs > Self.thresholdMs else { return }
        stallCountRaw += 1
        let trail = markTrail.reversed().joined(separator: " ← ")
        let moving = ScrollPhaseGate.shared.isScrolling ? " [moving]" : " [idle]"
        recentStallsRaw.insert("\(gapMs)ms @\(trail)\(moving)", at: 0)
        if recentStallsRaw.count > 6 { recentStallsRaw.removeLast(recentStallsRaw.count - 6) }
        // One line per stall, so an Instruments trace on the device can
        // line the watchdog's count up against a Hangs trace by timestamp.
        Self.log.notice("main_stall_\(gapMs, privacy: .public)ms_count_\(self.stallCountRaw, privacy: .public)_at_\(self.lastMark, privacy: .public)")
        // Diagnostics file log: the same n/ms/mark-trail shape
        // `recentStallsRaw` already keeps for the on-screen readout, gated
        // on the Settings switch. This call runs on the main actor, the
        // same as `tick(_:)` itself, so reading
        // `DiagnosticsSwitch.shared.isOn` directly here is safe.
        if DiagnosticsSwitch.shared.isOn {
            DiagnosticsLog.shared.log("MainThreadWatchdog", "stall_n_\(stallCountRaw)_ms_\(gapMs)_at_\(lastMark)_trail_\(trail)\(moving)")
        }
    }

    /// The only writer of the `@Published` values, at 1 Hz — see the doc
    /// comment on `stallCountRaw` above. Each write is conditional, so a
    /// quiet second with no change publishes nothing.
    private func mirrorRawValues() {
        if stallCount != stallCountRaw { stallCount = stallCountRaw }
        if worstGapMs != worstGapRaw { worstGapMs = worstGapRaw }
        if worstMark != worstMarkRaw { worstMark = worstMarkRaw }
        if recentStalls != recentStallsRaw { recentStalls = recentStallsRaw }
    }

    /// `CADisplayLink` retains its target, so the target is a proxy that
    /// holds the watchdog weakly. The callback always arrives on the run
    /// loop the link was added to — the main one — which is what
    /// `MainActor.assumeIsolated` asserts here, the same pattern
    /// `PlayerHolder`'s notification observers use.
    private final class Proxy: NSObject {
        weak var owner: MainThreadWatchdog?
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { owner?.tick(link) }
        }
    }
}

/// Marks the current step for the watchdog — see `MainThreadWatchdog.mark(_:)`.
@MainActor func wdMark(_ label: StaticString) { MainThreadWatchdog.shared.mark(label) }
#else
@MainActor @inline(__always) func wdMark(_ label: StaticString) {}
#endif
