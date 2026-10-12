//
//  DuoLayout.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit

/// Which of the iPhone Duo's physical poses this frame is in — see
/// `design/DUO_POSES.md` for the pictures and names this mirrors.
/// `classify(...)` (below `DuoLayout.current`) is the one place that
/// derives this from the SDK's own geometry; nothing else in the app
/// re-derives a pose from raw hinge/size-class/window values, so every
/// pose fix lands in one function.
///
/// `.regularPhone` is also the value a regular iPhone — and any OS
/// below iOS 27.1 — always reports (`DuoLayout.none.pose`), which is
/// what keeps every `pose != .regularPhone` gate a true no-op there.
enum DuoPose: String {
    case regularPhone, closed, tent, openWide, book, openTall, laptop
}

/// A plain mirror of `DeviceHinge.Status` (`.closed`/`.partiallyOpen`/
/// `.fullyOpen`), kept as its own stored-property-friendly enum because
/// `DeviceHinge.Status` itself is `@available(iOS 27.1, *)` — see
/// `ToolbarVerticalEdgeReader`'s own comment on why an `@available` type
/// cannot back a stored property on a type whose deployment target is
/// lower. `HingeReader` below is the one place that converts between the
/// two.
enum DuoHingeStatus: String {
    case closed, partial, full
}

/// One frame's worth of iPhone Duo geometry, read once per feed from the
/// root `GeometryProxy` and the environment, then threaded down through
/// parameters exactly the way `safeAreaTop` already is (see
/// `FeedView.body`'s own `GeometryReader`). Every consumer in that frame
/// gets the same numbers; nothing downstream re-measures on its own.
///
/// On a regular iPhone — and on any OS below iOS 27.1, where the iPhone
/// Duo APIs this type reads do not exist — every field is the plain
/// "no Duo furniture" value: `barEdge` is `nil`, `barWidth` is 0, both
/// reserved-region frames are `nil`. `isClosedBar` is then `false` and
/// `availableRect`/`stageRect` return the full container, so a caller
/// that plugs this struct's numbers into its own geometry gets back
/// exactly what it would have computed without this type existing. That
/// is what keeps regular iPhones pixel-identical to `main`: only
/// `current(proxy:toolbarVerticalEdge:)`, the one spot that calls the
/// new SDK, needs `#available`.
struct DuoLayout {
    /// Which edge the system vertical bar (the closed Duo's time +
    /// connectivity column) sits on, from
    /// `EnvironmentValues.toolbarVerticalEdge`. Non-nil means the bar is
    /// showing — the iPhone Duo's closed screen today, nothing else.
    /// `nil` on a regular iPhone and on an open Duo.
    let barEdge: HorizontalEdge?

    /// The bar's own width: the matching leading/trailing safe-area
    /// inset on `barEdge`'s side. Zero whenever `barEdge` is `nil`.
    let barWidth: CGFloat

    /// The first active `.occlusion` reserved region this frame reports
    /// (the inner camera), or `nil` when none is active.
    let occlusion: CGRect?

    /// The first active `.division` reserved region this frame reports
    /// (the fold), or `nil` when the device is not partially open.
    let division: CGRect?

    /// This frame's classified pose — see `DuoPose` and `classify(...)`
    /// below. Every new Duo branch gates on `pose != .regularPhone`
    /// (spec hard rule), never on `barEdge`/`division`/`hinge`
    /// directly, so a regular iPhone's path is decided by this one
    /// field.
    let pose: DuoPose

    /// A plain mirror of `DeviceHingeContext.hinge?.status`, read by
    /// `HingeReader` and threaded down the same way `barEdge` already
    /// is. `nil` until the first `onHingeChange` delivery, which has no
    /// `initial:` parameter — see `HingeReader`'s own comment — or on a
    /// device/OS with no hinge at all.
    let hinge: DuoHingeStatus?

    /// `DeviceHinge.angle.degrees` alongside `hinge`, for the
    /// `-cloudfull-log-rotation` probe only; nothing in `classify(...)`
    /// reads this, only `hinge` itself.
    let hingeDegrees: Double?

    /// Round 2 debug probe only (Opus diagnosis): the raw `.division`
    /// reserved region this frame reports, queried with
    /// `.includeInactive` and left in `proxy`'s OWN local coordinate
    /// space — before the window-space offset `current(...)` applies
    /// to `division` itself, and before that function's own
    /// containment filter. `-cloudfull-log-rotation` prints this
    /// alongside `division`/`safeAreaInsets` so a future containment-
    /// filter false negative (like the book pose misreading as a tent,
    /// R1's own bug) shows the raw SDK reading next to the filtered
    /// one instead of only the filtered one. Nothing in `classify(...)`
    /// reads this field; it exists for the log line alone.
    let debugRawDivision: CGRect?
    /// Round 2 debug probe only: this frame's own `safeAreaInsets`,
    /// alongside `debugRawDivision` for the same log line.
    let debugSafeAreaInsets: EdgeInsets

    /// Mirrored-layout round: true when every horizontal rule in this
    /// file should read LEADING where it otherwise reads TRAILING —
    /// Apple's own rule for an app whose vertical bar sits on the
    /// leading edge (a Split View-left app; also 1V upside down), same
    /// idea as the owner's own manual left-handed preference. Set once,
    /// in `current(...)` below, from three sources, in order: the
    /// DEBUG-only `-cloudfull-force-mirror` flag (`DuoForceMirror.isOn`,
    /// for testing on the Duo sim with no real leading-bar
    /// configuration to switch into); the SYSTEM's own
    /// `toolbarVerticalEdge == .leading` (never overridden by the
    /// setting below — the bar's own real side always wins when there
    /// IS one); and, only when there is no bar at all
    /// (`toolbarVerticalEdge == nil` — a regular iPhone, or the Duo's
    /// own bar-off poses 5/6), the owner's manual
    /// `leftHandedControls` setting (`SettingsView`'s own "Left-handed
    /// controls" toggle, read live the same way every other `current(...)`
    /// parameter already is — this struct itself stays a pure value
    /// with no `UserDefaults`/`AppStorage` read of its own).
    ///
    /// Every function below that hardcodes a `.trailing`-only formula —
    /// `railColumn`'s own open (pose 5) branch, `ringCenteredColumnX`'s
    /// trailing-inset arithmetic, `statusBlock`'s trailing-half check,
    /// `openWideWideVideoBox`'s left-bezel box — reads this field to
    /// flip, rather than re-deriving "which edge" from `barEdge` a
    /// second time; `barEdge`-generic functions that already switch on
    /// `column.edge` (`availableRect`, `railColumnRect`, `railVisualEdge`,
    /// `chromeColumnRect`, `rightPage`) need no change at all — flipping
    /// the EDGE `railColumn` reports is what drives them.
    ///
    /// Not yet wired into the book/laptop PAGE-level questions
    /// (`stageRect`'s own `.book`/`.laptop` branches, `bookWideVideoRect`,
    /// `rightPage`'s own left/right-page choice, the laptop deck's own
    /// x-axis row functions) — which page becomes "the stage" when
    /// mirrored is a real open design question (does the fold itself
    /// ever move, or only which side of it holds the video?), flagged
    /// back to the team rather than guessed at here.
    let isMirrored: Bool

    /// `barEdge != nil`. The spelling most call sites reach for when all
    /// they need is the yes/no, not which edge.
    var isClosedBar: Bool { barEdge != nil }

    /// The "no Duo furniture" value: every field at its plain default.
    /// A regular iPhone's `FeedView`/`PhotoFeedView` can hand this
    /// straight to a child that expects a `DuoLayout` without ever
    /// calling `current(proxy:toolbarVerticalEdge:horizontalSizeClass:verticalSizeClass:hinge:hingeDegrees:leftHandedControls:)`.
    /// `pose` is `.regularPhone` here — the hard rule every new branch
    /// gates on. `isMirrored` is `false` — a regular iPhone with the
    /// setting off (the default) must stay pixel-identical, and this
    /// value is only ever handed out before `current(...)` has had a
    /// chance to read the setting at all (the very first frame, on an
    /// OS below iOS 27.1).
    static let none = DuoLayout(barEdge: nil, barWidth: 0, occlusion: nil, division: nil,
                                pose: .regularPhone, hinge: nil, hingeDegrees: nil,
                                debugRawDivision: nil, debugSafeAreaInsets: EdgeInsets(),
                                isMirrored: false)

    /// Reads this frame's Duo geometry from `proxy` and the
    /// already-resolved `toolbarVerticalEdge` environment value.
    ///
    /// Call this once, at the same root `GeometryReader` that already
    /// measures `safeAreaTop`, and thread the result down as a
    /// parameter. The caller reads `toolbarVerticalEdge` itself (an
    /// `@Environment(\.toolbarVerticalEdge)` property gated the same
    /// way), because that key only exists from iOS 27.1 and an
    /// `EnvironmentValues` extension cannot be read from inside a
    /// plain, unavailable-gated function — only from a View's own
    /// environment-reading context.
    /// `horizontalSizeClass`, `verticalSizeClass`, and `hinge` are the
    /// classifier's three extra inputs — see `classify(...)` below for
    /// what each decides. The caller reads all three itself
    /// (`@Environment(\.horizontalSizeClass)`, `@Environment(\.verticalSizeClass)`,
    /// and `HingeReader`'s stored state) for the same reason it already
    /// reads `toolbarVerticalEdge` itself: only a View's own
    /// environment/state context can read them.
    ///
    /// There is no `stanceIsLandscape`/device-orientation input here —
    /// the owner's Apple-checklist audit (`design/duo/duo_audit_apple_checklist.md`,
    /// Decision B) replaced it with the window's own shape
    /// (`proxy.size`), which `classify(...)` already has from
    /// `containerSize`. No layout in this app reads device orientation.
    ///
    /// `leftHandedControls` is the mirrored-layout round's own extra
    /// input: `SettingsView`'s own "Left-handed controls" setting,
    /// read live by the caller (`@AppStorage("settings.leftHandedControls")`,
    /// the same "the caller reads it, this function only takes the
    /// value" rule every other parameter here already follows) and
    /// folded into `isMirrored` below.
    @available(iOS 27.1, *)
    static func current(
        proxy: GeometryProxy,
        toolbarVerticalEdge: HorizontalEdge?,
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        hinge: DuoHingeStatus?,
        hingeDegrees: Double?,
        leftHandedControls: Bool
    ) -> DuoLayout {
        let insets = proxy.safeAreaInsets
        let measuredWidth: CGFloat
        switch toolbarVerticalEdge {
        case .leading: measuredWidth = insets.leading
        case .trailing: measuredWidth = insets.trailing
        case nil: measuredWidth = 0
        }
        // Known Apple bug, FB24906205 (broken-rule note): a LEADING
        // bar's own safe-area inset is not always carried by the
        // window — `insets.leading` can read `0` even while the bar is
        // genuinely showing there. A zero-width column would overlap
        // the real system bar instead of sitting beside it, so this
        // falls back to `Self.fallbackBarWidth` — the TRAILING case's
        // own measured width (84pt, every bar-on reading this file has
        // ever taken), the one configuration actually confirmed — the
        // moment a real leading-bar reading on real hardware shows a
        // non-zero `insets.leading`, this fallback simply never
        // triggers again. `-cloudfull-log-rotation` should flag
        // whenever this branch fires (print a `barFallback` field) so a
        // real device check does not need to go looking for it.
        let width = (toolbarVerticalEdge == .leading && measuredWidth <= 0) ? Self.fallbackBarWidth : measuredWidth
        // Mirrored-layout round: the bar's own real side always wins
        // over the manual setting when there IS a bar — the setting
        // only ever applies with no bar at all (`toolbarVerticalEdge
        // == nil` — a regular iPhone, or the Duo's own bar-off poses 5
        // and 6). `DuoForceMirror.isOn` (`-cloudfull-force-mirror`,
        // DEBUG only) forces this `true` regardless of either signal,
        // for testing every pose's own mirrored geometry on the Duo
        // sim without a real leading-bar configuration to switch into.
        let isMirrored = DuoForceMirror.isOn
            || toolbarVerticalEdge == .leading
            || (toolbarVerticalEdge == nil && leftHandedControls)
        // Round 2 (Opus diagnosis): `reservedRegions` reports each
        // frame relative to THIS view's own local origin — `proxy`'s
        // own (0, 0), which sits `insets.top`/`insets.leading` below
        // and right of the window's own true top-left, since `proxy`
        // (`FeedView`'s root `GeometryReader`) does not ignore the
        // safe area. A region physically at the window's own top edge
        // (a camera cutout, say) therefore reports a NEGATIVE y here —
        // confirmed on the sim, pose 5: `occ-535,-82,134,82`, exactly
        // `insets.top` (82) short of the `0` its real position is.
        // Every function elsewhere in this file, and every caller that
        // feeds one a `containerSize`, assumes window-space frames —
        // `chromeColumnRect`/`statusBlock`/`railColumn`'s own occlusion
        // reads, `FeedView.overlayControls`'s own reconstructed
        // `fullWindow`, this struct's own stored `occlusion`/`division`
        // — so this is the one place that offset is corrected, once,
        // before anything downstream ever sees these frames.
        let windowSize = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                                 height: proxy.size.height + insets.top + insets.bottom)
        func toWindowSpace(_ frame: CGRect) -> CGRect {
            frame.offsetBy(dx: insets.leading, dy: insets.top)
        }
        // The default query (no `.includeInactive`) already reports only
        // active regions, but the explicit filter documents that intent
        // at the call site and costs nothing if the SDK's default ever
        // changes.
        let occlusionFrame = (proxy.reservedRegions(kind: .occlusion).first(where: \.isActive)?.frame).map(toWindowSpace)
        // Build 1 fix, re-adapted round 2: the owner's own sim readings
        // caught a division frame from the INNER display's own
        // coordinate space (669 pt wide) reported once while this
        // frame's own window was still the OUTER display's compact
        // 466-pt one — a stale cross-display reading, one layout pass
        // behind the window size that already changed. Such a frame
        // does not fit inside this frame's own window at all (its far
        // edge lands past this window's own edge), so
        // `book`/`laptop`'s `division.height > division.width` test
        // must never see it: a plain `nil` here, same as "no fold
        // active," is what every other `division` reader downstream
        // (`DuoLayout.division` itself, and anything that reads it off
        // this frame's `DuoLayout`) already expects. `CGRect.contains`
        // is the containment test — not `intersects`, which the bad
        // frame above would still pass, since its leading edge does
        // overlap this window's own leading edge even though its
        // trailing edge does not.
        //
        // Round 2: this filter now tests against `windowSize`, not the
        // old `proxy.size` — the Opus diagnosis's own root cause for
        // the book pose misreading as a tent. The book's division is a
        // near-full-height vertical line; `proxy.size.height` (the
        // safe-area-shrunk content height) is shorter than the WINDOW'S
        // own full height by exactly the top/bottom insets, so the old
        // bounds could reject a perfectly real, in-window division
        // whenever its own height came within that margin of the
        // window's. `insetBy(dx: -1, dy: -1)` gives the comparison a
        // 1pt tolerance against rounding, the same way a hand-off
        // between two independently-measured geometry passes often
        // needs one.
        let windowBounds = CGRect(origin: .zero, size: windowSize).insetBy(dx: -1, dy: -1)
        let rawDivisionFrame = (proxy.reservedRegions(kind: .division).first(where: \.isActive)?.frame).map(toWindowSpace)
        let divisionFrame = rawDivisionFrame.flatMap { (frame: CGRect) -> CGRect? in
            windowBounds.contains(frame) ? frame : nil
        }
        let pose = classify(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            containerSize: windowSize,
            division: divisionFrame,
            barEdge: toolbarVerticalEdge,
            hinge: hinge
        )
        // Round 2 debug probe only (`debugRawDivision`'s own comment):
        // the SAME raw query, but `.includeInactive` and left in
        // `proxy`'s own un-offset local space — a diagnostic snapshot
        // of what the SDK reported before either correction above,
        // for `-cloudfull-log-rotation` to print next to the corrected
        // `division` on the next pass.
        let debugRawDivision = proxy.reservedRegions(kind: .division, options: .includeInactive).first?.frame
        return DuoLayout(
            barEdge: toolbarVerticalEdge,
            barWidth: toolbarVerticalEdge == nil ? 0 : width,
            occlusion: occlusionFrame,
            division: divisionFrame,
            pose: pose,
            hinge: hinge,
            hingeDegrees: hingeDegrees,
            debugRawDivision: debugRawDivision,
            debugSafeAreaInsets: insets,
            isMirrored: isMirrored
        )
    }

    /// The pose classifier — "classify from the space we have" (Decision
    /// B, `design/duo/duo_audit_apple_checklist.md` §4), replacing an
    /// earlier version that read `horizontalSizeClass == .regular` alone
    /// as "this is the Duo's inner display." The owner's Apple-checklist
    /// audit flagged that as its own rule violation (F2: "size class does
    /// not identify the device") — a 17 Pro resized large enough in
    /// iPhone Mirroring also reads `.regular` width, so a single-axis
    /// test alone can misclassify a resizable window as an open Duo. This
    /// function reads geometry and traits only, never a device name or
    /// which physical display is active, in a fixed order where each
    /// rule decides only what the signal in front of it can actually
    /// prove:
    ///
    /// 1. An active `division` means the device is partially open —
    ///    checked ahead of any size-class test, since the division
    ///    reserved region only ever appears there, on either display, at
    ///    any size class. A division taller than it is wide is the fold
    ///    read top-to-bottom (a book spine down the middle): `.book`. A
    ///    division wider than tall is the fold read left-to-right (a
    ///    laptop hinge along the bottom): `.laptop`. See this file's
    ///    "Fold-orientation check" in the build spec for the 951×669 /
    ///    669×951 arithmetic this falls out of.
    /// 2. No division, a `.partial` hinge, a window wider than it is
    ///    tall, and NOT both size classes regular at once is the tent
    ///    (pose 2) — a nightstand candidate; until the nightstand
    ///    actually engages, it still lays out like rule 4 below. The
    ///    window's own shape (`containerSize`) is what decides the
    ///    wide/tall part, not a device stance: Apple's own rule (F1,
    ///    this file's header comment) is no layout from device
    ///    orientation, and real interface rotation (the audit's
    ///    Decision A) already makes `containerSize.width >
    ///    containerSize.height` the correct, geometry-only reading of
    ///    "this window is sideways" — nothing here reads
    ///    `UIDevice.current.orientation` or a `Stance`.
    ///
    ///    Round 2 (Opus diagnosis): the size-class exclusion is new.
    ///    Apple's own tech talk (111461) gives the INNER display's own
    ///    size classes as regular/regular always, the OUTER's as
    ///    compact in at least one axis always — the tent is the OUTER
    ///    display standing up, so it can never read regular/regular.
    ///    Without this exclusion, the INNER display briefly reads a
    ///    `.partial` hinge and a wide window too, while open and
    ///    folding past the point a `.division` is still active (the
    ///    book-to-wide-open transition passes through exactly this
    ///    shape) — misreading that moment as the tent instead of
    ///    falling through to rule 3's own `.openWide`.
    /// 3. No division, no tent: BOTH size classes regular at once is the
    ///    fully-open case — `.openWide` if the window is wider than
    ///    tall, else `.openTall`. Both axes together, not
    ///    `horizontalSizeClass` alone (F2's own fix): a landscape window
    ///    that is wide but not also tall enough to read `.regular` in
    ///    height (a short Mirroring window, or the Duo's own OUTER
    ///    display, which never goes `.regular` in either axis) falls
    ///    through to rule 4 instead, same as a regular iPhone would.
    /// 4. Anything else — any compact axis, on either size class — is
    ///    the phone family: `.closed` when there is Duo furniture to say
    ///    so (`barEdge` or a non-nil `hinge`), else a plain
    ///    `.regularPhone`. A regular iPhone's own window reads compact
    ///    in at least one axis in every orientation, so it can never
    ///    reach rules 1–3 at all — decided purely by its own proportions
    ///    and traits, never by a name.
    private static func classify(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        containerSize: CGSize,
        division: CGRect?,
        barEdge: HorizontalEdge?,
        hinge: DuoHingeStatus?
    ) -> DuoPose {
        if let division {
            return division.height > division.width ? .book : .laptop
        }
        let isFullyOpenSizeClass = horizontalSizeClass == .regular && verticalSizeClass == .regular
        if hinge == .partial, containerSize.width > containerSize.height, !isFullyOpenSizeClass {
            return .tent
        }
        if isFullyOpenSizeClass {
            return containerSize.width > containerSize.height ? .openWide : .openTall
        }
        if barEdge != nil || hinge != nil {
            return .closed
        }
        return .regularPhone
    }

    /// The rectangle, inside a container of `containerSize`, that
    /// excludes the rail column — see `railColumn(containerSize:safeAreaTop:)`
    /// for what that is in each case. Anything that must stay clear of
    /// it — `stageRect` below — uses this instead of the full
    /// container.
    ///
    /// Deliberately does NOT also reserve the top chrome's own band
    /// out of the height, for either column source: the owner's own
    /// review of the open-tall pose asked for exactly the opposite —
    /// "pose 5 should pretty much look like pose 1" — where the top
    /// chrome OVERLAYS the video's own top edge, the same as every
    /// other pose, rather than pushing the video down into its own
    /// band below a separate chrome row. An earlier version reserved
    /// that band here specifically for the open column, once its width
    /// stopped doing so as a side effect of being sized to "whatever a
    /// 9:16 stage leaves over" (see `railColumn`'s own comment on its
    /// open branch for why that sizing changed); this undoes that
    /// reservation, so the open column now behaves exactly like the
    /// closed bar column
    /// already did — no height carve-out, chrome overlaid on the
    /// stage, `StageGeometry.downShift`'s own small natural band (from
    /// the stage's own aspect ratio) the only clearance either case
    /// ever gets.
    ///
    /// Returns the full container unchanged when no column applies, so
    /// a regular iPhone's math is untouched.
    func availableRect(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect {
        guard let column = railColumn(containerSize: containerSize, safeAreaTop: safeAreaTop) else {
            return CGRect(origin: .zero, size: containerSize)
        }
        switch column.edge {
        case .leading:
            return CGRect(x: column.width, y: 0,
                          width: max(0, containerSize.width - column.width),
                          height: containerSize.height)
        case .trailing:
            return CGRect(x: 0, y: 0,
                          width: max(0, containerSize.width - column.width),
                          height: containerSize.height)
        }
    }

    /// DEBUG-guides only (`-cloudfull-duo-guides`): this frame's own
    /// STRUCTURAL stage area — the box a video is FIT into, not the
    /// aspect-dependent FITted rect itself (that always exactly equals
    /// the video's own rect, by definition, and could never show a
    /// gap). `FeedView`'s own `pagerBackground` and `PlayerPageView`'s
    /// per-page background both colour this rect differently from
    /// their own surroundings, so a video's real, opaque pixels covering
    /// less of it than expected shows through as a gap — owner: "I
    /// can't tell if the laptop video sits flush on the fold."
    ///
    /// `.laptop` — `[0, W] × [0, division.minY]`, the SAME box
    /// `stageRect`'s own `.laptop` branch FITs into. `.book` — the left
    /// page, `[0, division.minX] × [0, H]`, the same box `stageRect`'s
    /// own `.book` tall-video branch FITs into; the right page (the
    /// grid) is deliberately left out of this rect. `.openWide` with
    /// `isWideVideo` — `openWideWideVideoBox`, the SAME (tighter) box
    /// `openWideWideVideoRect` FITs into for a wide video there, not
    /// the wider `availableRect` fallback (owner: "tighten the debug
    /// red area in pose 3 to the real stage box"). Every other case
    /// (1V, 5, pose 3's own TALL-video case, `.tent`) — `availableRect`,
    /// the structural box their own stage branches FIT into before an
    /// aspect ratio narrows it further. `.regularPhone` returns `nil`
    /// — this tool is for Duo pose work specifically, and a regular
    /// iPhone's own stage is never in question here.
    ///
    /// `isWideVideo` only ever changes `.openWide`'s own answer — every
    /// other case ignores it. Defaults to `false`: `FeedView
    /// .pagerBackground`'s own shared, PAGER-level background has no
    /// per-page video to ask about (its own doc comment), so it always
    /// reads the wider, pose-3-tall-video-shaped fallback; only
    /// `PlayerPageView`'s own PER-PAGE background, which does know
    /// `useVideoAspect`, can pass the real answer.
    func debugStageArea(containerSize: CGSize, safeAreaTop: CGFloat, isWideVideo: Bool = false) -> CGRect? {
        switch pose {
        case .laptop:
            guard let division else { return nil }
            return CGRect(x: 0, y: 0, width: containerSize.width, height: division.minY)
        case .book:
            guard let division else { return nil }
            return bookStagePageBox(division: division, containerSize: containerSize)
        case .openWide where isWideVideo:
            return openWideWideVideoBox(containerSize: containerSize, safeAreaTop: safeAreaTop)
        case .regularPhone:
            return nil
        default:
            return availableRect(containerSize: containerSize, safeAreaTop: safeAreaTop)
        }
    }

    /// The largest `aspectRatio` (width ÷ height) box that fits inside
    /// `availableRect(containerSize:safeAreaTop:)`, centred there.
    /// Defaults to 9:16 (`9.0 / 16.0`), the fixed portrait video stage
    /// every call site but one still wants.
    ///
    /// On a regular iPhone `availableRect` is the full container, which
    /// is always taller (relative to its width) than the default 16:9,
    /// so this reduces to the old width-derived box exactly: `width` is
    /// the binding side there, matching `PlayerPageView`'s pre-Duo
    /// stage. On the Duo's closed screen, once the bar column is
    /// excluded, height can become the binding side instead, which is
    /// what keeps the stage from overflowing the squat screen. On an
    /// open Duo wide enough for a computed column (same function), this
    /// same centring is what turns the leftover width, once
    /// `railColumn`'s own computed column is removed from it, into even
    /// margins on both sides of the stage — see that function's own
    /// open-branch comment for why that is the goal, not a flush-left
    /// stage.
    ///
    /// The non-default `aspectRatio` is step 6's own addition: an open
    /// Duo turned sideways really rotates its window (see
    /// `PlayerPageView.windowIsLandscape`), and a horizontal video
    /// shown there must FIT its own shape, not the portrait stage every
    /// other screen wants. `PlayerPageView.body` passes the loaded
    /// video's real aspect ratio exactly when that applies, and the
    /// default everywhere else.
    ///
    /// Build 3 addition: `.openWide` and `.book` get their own stage
    /// box once `aspectRatio >= 1` — a landscape video, the only case
    /// `PlayerPageView.useVideoAspect` ever passes a non-default
    /// `aspectRatio` for — matching the round-3 wireframes
    /// (`DUO_POSES.md`, pose 3/4W rows): the chrome column and (for
    /// `.book`) the fold both carve space this function's generic
    /// `availableRect` path has no way to know about, since that path
    /// only ever excludes the rail/bar column. `aspectRatio >= 1`
    /// (never read outside this function) is the one signal available
    /// here for "this is the landscape-video sub-case," so the
    /// function stays a drop-in replacement at its one call site
    /// rather than growing a second parameter every caller would need
    /// to pass. `.openWide`'s own TALL-video case (the default
    /// `aspectRatio`) falls through to the generic `availableRect`
    /// path unchanged — see `openWideWideVideoRect`'s own comment for
    /// why that case already reads correctly from the generic math,
    /// with nothing special to do. `.book`'s own TALL-video case
    /// does need its own box, just not its own named function: "FIT
    /// 9:16 full height, centred in `[0, division.minX]`" below —
    /// `division.minX`, not the bar column, is what bounds the left
    /// page, since the fold sits well inside where the bar column
    /// would start to matter.
    func stageRect(containerSize: CGSize, safeAreaTop: CGFloat, aspectRatio: CGFloat = 9.0 / 16.0) -> CGRect {
        if pose == .openWide, aspectRatio >= 1 {
            return openWideWideVideoRect(containerSize: containerSize, safeAreaTop: safeAreaTop, aspectRatio: aspectRatio)
        }
        if pose == .book, let division {
            // Mirrored-layout round: the stage is always the page AWAY
            // from the rail/chrome, never a fixed left/right page — the
            // fold's own real position (`division`) does not move, only
            // which of its two pages the bar sits beside does. `rightPage(...)`
            // (the OTHER page — the grid) mirrors the same way, from the
            // same principle.
            return aspectRatio >= 1
                ? bookWideVideoRect(division: division, containerSize: containerSize, aspectRatio: aspectRatio)
                : fitRect(in: bookStagePageBox(division: division, containerSize: containerSize),
                          aspectRatio: aspectRatio)
        }
        if pose == .laptop, let division {
            // Build 8b: "FIT 9:16 in `[0, W] × [safeAreaTop + 10,
            // division.minY − 14]`, centred x" (the per-pose table's own
            // words for pose 6).
            //
            // Owner re-adapt (pose pass): "widescreens don't take up
            // the whole top half. they should." `useVideoAspect`
            // (`PlayerPageView`) now passes the video's own real
            // aspect for a landscape video here too, the same way it
            // already does for `.openWide`/`.book`/`.openTall` — this
            // box (`[0, W] × [safeAreaTop + 10, division.minY − 14]`)
            // is unchanged, still the full upright half, small-gap
            // inset; only the `aspectRatio` `fitRect` below now FITs
            // correctly reflects the video's own real shape, so a
            // 16:9 video binds on WIDTH (runs edge to edge) instead of
            // height (pillarboxed to a ~190pt-wide sliver, the owner's
            // own report, from FITting a wide video's real pixels
            // against the WRONG, default 9:16 box). A tall video still
            // reads the 9:16 default (`useVideoAspect` is `false` for
            // it), so it is unaffected — "tall videos stay as they
            // are."
            //
            // Owner re-adapt: the video should go all the way to the
            // top of the window — the box's own top is `0`, not
            // `safeAreaTop + 10`, the same full-bleed rule 1V/5 already
            // follow (system status draws OVER the video there too,
            // not beside it). Nothing interactive mounts above the
            // fold in this pose, so there is nothing under that status
            // area for a tap to miss.
            //
            // Owner re-adapt (two corrections this round, own words:
            // "the video can go lower," then "I misread — anchored to
            // the BOTTOM"): the video anchors to the BOTTOM of this
            // upright half, sitting ON the fold, not floating inside
            // it with a gap on both sides. The box's own bottom is now
            // `division.minY` itself — flush with the fold's own top
            // edge, the old 14pt clearance removed. Checked nothing
            // else reads that 14pt: `laptopBottomRect`, and everything
            // below the fold it anchors (scrubber, caption, rail row,
            // pager), starts at `division.maxY`, the fold's own OTHER
            // edge, never this one; the iCloud ring mounted inside
            // this stage positions itself off the stage's own rect,
            // not a hand-measured number, so it rides along with this
            // box with nothing further to fix. A height-bound (tall)
            // video already FITs the box's own full height, nothing
            // more to anchor. A width-bound (wide) video no longer
            // centres vertically — pinned to the box's own BOTTOM
            // instead (`fitted.height < box.height`, `fitRect`'s own
            // width-bound case, with a small tolerance), so it sits on
            // the fold with the whole leftover gap pushed to the TOP,
            // above the video, never splitting it front and back.
            let top: CGFloat = 0
            let bottom = max(top, division.minY)
            let box = CGRect(x: 0, y: top, width: containerSize.width, height: bottom - top)
            let fitted = fitRect(in: box, aspectRatio: aspectRatio)
            guard fitted.height < box.height - 0.5 else { return fitted }
            return CGRect(x: fitted.minX, y: box.maxY - fitted.height, width: fitted.width, height: fitted.height)
        }
        let avail = availableRect(containerSize: containerSize, safeAreaTop: safeAreaTop)
        let fitted = fitRect(in: avail, aspectRatio: aspectRatio)
        // Owner re-adapt (pose 5, open-tall): a height-bound video —
        // its own fitted width narrower than `avail`'s, "a 9:19.5
        // phone video, or anything narrower than 9:16" — right-aligns
        // flush against the rail column's own leading edge
        // (`avail.maxX`, the same edge `availableRect`'s own trailing
        // branch already excludes the column to) instead of centring,
        // so the leftover gap lands on the left alone. A 9:16 video's
        // own fitted width already equals `avail.width` (bound by
        // WIDTH there, not height, with nothing left over to shift),
        // so this is a no-op for it — "a 9:16 video already spans
        // 0…535, so it doesn't move."
        //
        // Owner re-adapt (pose 5, follow-up): a WIDTH-bound (wide)
        // video — "touch the left bezel and the right side should be
        // closer to the rail" — gets its OWN, wider box instead:
        // `avail.maxX` (535 today) is the rail COLUMN's own
        // STRUCTURAL edge, the full status-block width, not where the
        // rail's own real pixels start — the same distinction
        // `railVisualEdge`/`chromeColumnRect` already draw for the
        // chrome column. Re-FITting into `[0, railVisualEdge.x −
        // minChromeRailClearance]` instead of `avail` lands the
        // video's own right edge at the rail's real glyph/label edge
        // minus the same 8pt floor the chrome column already respects
        // — never touching the rail's own icons or labels, by the
        // same measured boundary, not a second guess at it. `max`
        // against `avail.maxX` is a floor: this box is never NARROWER
        // than the old one, only ever wider.
        //
        // A height-bound (narrow) video deliberately does NOT also
        // read this tighter edge: it spans this stage's own FULL
        // height, including the very top row where the status
        // block/ring actually sits (`avail.maxX` already excludes
        // that block's own full width for exactly this reason) — the
        // wider, rail-only edge is a safe bound for the far SHORTER
        // width-bound box (vertically centred well clear of that top
        // row), not for one that reaches the top of the screen.
        if pose == .openTall {
            // Owner re-adapt (Live Activity pass): `avail` above comes
            // from `railColumn`'s own LIVE occlusion width — exactly
            // as wide as whatever is currently grown, pill included.
            // Fine for centring the rail/chrome column on the ring
            // (unaffected here — "rail x stays," the owner's own
            // words), wrong for the STAGE: a grown pill used to shrink
            // `avail` enough that a plain 9:16 video's own fitted width
            // stopped reading as narrower than `avail`'s, flipping it
            // out of the height-bound branch just below and into the
            // wide-video branch after it — moving and narrowing a
            // video the pill was never meant to affect at all. `avail`
            // is rebuilt here with the column width capped at
            // `openTallNormalOcclusionWidth` — this pose's own normal,
            // un-grown ring width — so the stage holds the exact
            // position and size it already had before any pill grew,
            // however wide `occlusion` reports itself this frame.
            let cappedColumnWidth = max(Rail.hit, min(occlusion?.width ?? 0, Self.openTallNormalOcclusionWidth))
            // Mirrored-layout round: the capped column sits on the
            // LEADING side instead, so the rebuilt `stageAvail` excludes
            // it from the left, not the right — `avail.minX` is already
            // 0 in that case (`availableRect`'s own leading branch moved
            // the exclusion into `x`/`width` instead), so this reads
            // `avail.maxX` (the window's own true right edge) as the
            // far bound rather than re-deriving it from `avail.minX`.
            let stageAvail = isMirrored
                ? CGRect(x: cappedColumnWidth, y: avail.minY,
                         width: max(0, avail.maxX - cappedColumnWidth), height: avail.height)
                : CGRect(x: avail.minX, y: avail.minY,
                         width: max(0, containerSize.width - cappedColumnWidth - avail.minX),
                         height: avail.height)
            let stageFitted = fitRect(in: stageAvail, aspectRatio: aspectRatio)
            // Owner re-adapt: "the video moved back over to the left" —
            // a height-bound (tall) video used to right-align against
            // `stageAvail.maxX`, the rail COLUMN's own structural edge
            // (the full status-block width), not where the rail's own
            // real pixels start. Both branches now share ONE right
            // edge — `railVisualEdge.x − minChromeRailClearance`, the
            // SAME edge the width-bound case already used — so a tall
            // video sits flush against the rail too, leftover gap on
            // the LEFT. Reads `railVisualEdge`, never `stageAvail`, for
            // exactly the same reason `cappedColumnWidth` above does
            // not read live occlusion width either: `railVisualEdge`
            // is pinned to `occlusion.maxX` (the display's own trailing
            // edge, which a GROWING pill does not move) minus a static
            // label half-width, so it cannot drift when a Live Activity
            // grows the status block, unlike `stageAvail.maxX` itself.
            // The owner's own accepted trade-off: a tall video's top
            // row now reaches up far enough that its own top-right
            // corner sits under the status cluster — system status
            // draws over video, same as everywhere else in this file.
            // Mirrored-layout round: the rail's own near edge is now its
            // LEADING visual edge (`railVisualEdge`'s own `.leading`
            // case, already generic) pushed OUTWARD by the same
            // clearance, and the video aligns flush against THAT edge
            // instead — "pose 5 tall video LEFT-aligned to the rail."
            let visualNearEdge = railVisualEdge(containerSize: containerSize, safeAreaTop: safeAreaTop)
                .map { isMirrored ? $0.x + Self.minChromeRailClearance : $0.x - Self.minChromeRailClearance }
            if stageFitted.width < stageAvail.width {
                if isMirrored {
                    let leftEdge = visualNearEdge ?? stageAvail.minX
                    let x = min(leftEdge, stageAvail.maxX - stageFitted.width)
                    return CGRect(x: x, y: stageFitted.minY, width: stageFitted.width, height: stageFitted.height)
                }
                let rightEdge = visualNearEdge ?? stageAvail.maxX
                return CGRect(x: max(stageAvail.minX, rightEdge - stageFitted.width), y: stageFitted.minY, width: stageFitted.width, height: stageFitted.height)
            }
            if let nearEdge = visualNearEdge {
                let widerBox = isMirrored
                    ? CGRect(x: min(stageAvail.minX, nearEdge), y: stageAvail.minY,
                             width: containerSize.width - min(stageAvail.minX, nearEdge), height: stageAvail.height)
                    : CGRect(x: 0, y: stageAvail.minY, width: max(stageAvail.maxX, nearEdge), height: stageAvail.height)
                return fitRect(in: widerBox, aspectRatio: aspectRatio)
            }
            return stageFitted
        }
        return fitted
    }

    /// The largest `aspectRatio` box that fits inside `box`, centred
    /// there — the one FIT formula every stage-rect case in this file
    /// shares, pulled out once `stageRect` grew pose-specific boxes of
    /// its own to fit (build 3) rather than only ever `availableRect`'s.
    private func fitRect(in box: CGRect, aspectRatio: CGFloat) -> CGRect {
        guard box.width > 0, box.height > 0 else { return box }
        let height = min(box.height, box.width / aspectRatio)
        let width = height * aspectRatio
        return CGRect(
            x: box.minX + (box.width - width) / 2,
            y: box.minY + (box.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// Pose 3's wide-video stage box. Originally "FIT video aspect in
    /// `[16, W − bar − 80 − 16] × [0, H − captionBand]`, centred" — the
    /// wireframe's own words for excluding BOTH the rail/bar column
    /// and the chrome column's own OLD 80pt line, `pagePad` clear on
    /// each side.
    ///
    /// Owner re-adapt: "touch the left bezel," the same ask pose 5's
    /// own wide video already got — `x` is now `0`, not `pagePad`, and
    /// the right edge is `chromeColumnRect`'s own real VISUAL leading
    /// edge minus `minChromeRailClearance`, not the OLD fixed
    /// `chromeColumnStageExclusion` line (owner's own measurement: a
    /// 16pt left margin plus ~50pt of empty space before the group's
    /// own real edge, at `x 820`, that this read past). Mirrors pose
    /// 5's own `stageRect` fix exactly: read the group's real pixels,
    /// not the wider structural column it sits inside. `chromeColumnRect`
    /// covers BOTH edges `railColumn` can report (`.trailing`, pose
    /// 3/4/4W's own always-measured case; `.leading`, never measured —
    /// see that function's own comment), so no separate edge switch is
    /// needed here any more either. Height/caption-band rule
    /// unchanged — `fitRect` still centres vertically in
    /// `[0, H − captionBand]`.
    ///
    /// Pose 3's TALL-video case (the default `aspectRatio`, handled by
    /// `stageRect`'s own fallthrough to `availableRect`) needs none of
    /// this: `availableRect` already excludes only the bar column, and
    /// `fitRect`'s height-first binding on that wider box already
    /// reduces to "FIT 9:16, full height" — the chrome column and
    /// caption band never come into it, because a tall video's own
    /// FIT box is already narrower than the leftover before either
    /// would ever bind. Confirmed algebraically: at this window's own
    /// proportions, `avail.width / (9/16)` is always well over
    /// `avail.height`, so height is always the binding side there.
    private func openWideWideVideoRect(containerSize: CGSize, safeAreaTop: CGFloat, aspectRatio: CGFloat) -> CGRect {
        fitRect(in: openWideWideVideoBox(containerSize: containerSize, safeAreaTop: safeAreaTop), aspectRatio: aspectRatio)
    }

    /// `openWideWideVideoRect`'s own box, BEFORE `fitRect` narrows it
    /// to the video's own real aspect — pulled out so `debugStageArea`
    /// can draw this SAME box as its own red area for a wide video in
    /// this pose, instead of the wider, un-tightened `availableRect`
    /// fallback every other pose still uses (owner: "tighten the debug
    /// red area in pose 3 to the real stage box").
    ///
    /// Mirrored-layout round: "touch the left bezel" is really "touch
    /// the bezel on the FAR side from the rail/chrome group" — when
    /// mirrored, that is the TRAILING bezel instead, with the near
    /// edge now read off `chromeColumnRect`'s own `maxX` (the group's
    /// own leading-side edge, once `railColumn` puts it there) rather
    /// than its `minX`.
    private func openWideWideVideoBox(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect {
        let column = railColumn(containerSize: containerSize, safeAreaTop: safeAreaTop)
        let barWidth = column?.width ?? 0
        let excluded = barWidth + chromeColumnStageExclusion(containerSize: containerSize, safeAreaTop: safeAreaTop)
        let height = max(0, containerSize.height - Self.captionBand)
        if isMirrored {
            // Defensive fallback only — same reasoning as the
            // trailing-case comment below, mirrored.
            let fallbackLeftEdge = min(containerSize.width, excluded + Self.pagePad)
            let leftEdge = chromeColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop)
                .map { $0.maxX + Self.minChromeRailClearance } ?? fallbackLeftEdge
            return CGRect(x: leftEdge, y: 0, width: max(0, containerSize.width - leftEdge), height: height)
        }
        // Defensive fallback only — `chromeColumnRect` is non-nil
        // whenever `railColumn` is, and pose 3 always has one; this
        // reduces to the OLD fixed-line edge if that ever changes.
        let fallbackRightEdge = max(0, containerSize.width - excluded - Self.pagePad)
        let rightEdge = chromeColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop)
            .map { $0.minX - Self.minChromeRailClearance } ?? fallbackRightEdge
        return CGRect(x: 0, y: 0, width: max(0, rightEdge), height: height)
    }

    /// Pose 4/4W's stage PAGE — the page the rail/chrome is NOT beside
    /// — plain, pre-video-aspect box: `[0, division.minX] × [0, H]`
    /// unmirrored (the left page), `[division.maxX, W] × [0, H]`
    /// mirrored (the right page). The fold's own real position
    /// (`division`) never moves; only which page the bar sits beside
    /// does, so this is the one place that decides which page is "the
    /// stage" — `bookWideVideoRect` and `rightPage` each read this
    /// same choice, from the same principle, rather than deciding it
    /// twice.
    private func bookStagePageBox(division: CGRect, containerSize: CGSize) -> CGRect {
        if isMirrored {
            return CGRect(x: division.maxX, y: 0, width: max(0, containerSize.width - division.maxX), height: containerSize.height)
        }
        return CGRect(x: 0, y: 0, width: max(0, division.minX), height: containerSize.height)
    }

    /// Pose 4W's stage box. Originally "width `division.minX − 32`, x
    /// = 16, centred on H" — `pagePad` clear on each side of the left
    /// page's own span.
    ///
    /// Owner re-adapt: the same "touch the left bezel" idea pose 3 and
    /// 5 both already got, applied within this page's own bounds —
    /// "0 → fold minX": `x` is `0`, `width` is `division.minX` itself,
    /// no `pagePad` margin on either side any more. Still a WIDTH-first
    /// box, not a FIT-into-box one like every other case in this file:
    /// the stage page's own width is fixed first, then the height
    /// follows from `aspectRatio` alone, centred vertically in the
    /// full window height. This differs from `fitRect` deliberately —
    /// a FIT box here could bind on height first for a near-square
    /// page width, which would narrow the video below the page's own
    /// full width.
    ///
    /// Mirrored-layout round: reads `bookStagePageBox`'s own choice of
    /// page instead of assuming the left one — "touch the bezel" now
    /// means the TRAILING bezel, `x` starting at the stage page's own
    /// `minX` (`division.maxX` when mirrored), not always `0`.
    private func bookWideVideoRect(division: CGRect, containerSize: CGSize, aspectRatio: CGFloat) -> CGRect {
        let page = bookStagePageBox(division: division, containerSize: containerSize)
        let width = page.width
        let height = width / aspectRatio
        return CGRect(x: page.minX, y: (containerSize.height - height) / 2, width: width, height: height)
    }

    // MARK: - Pose-table constants (build 3)
    //
    // Every number below is "measured/wireframe, no API" — read off
    // `DUO_VIDEO_WIREFRAMES.png`/`DUO_POSES.md`, not any SDK property.
    // There is no reserved-region kind, margin, or trait for a chrome
    // column, a caption band, a page margin, or a chin's own size;
    // Apple's hinge/division/occlusion API (this file's header comment)
    // says nothing about any of them. These are plain design constants,
    // the same category `Rail.hit`/`Rail.spacing` already are —
    // unlike the ring's own position, which `railColumn`'s open branch
    // now reads from `.occlusion` instead of a fixed number (F6, §5 of
    // the audit).

    /// Height reserved at a wide video's own bottom edge for its
    /// caption, pose 3's wide-video case only (`openWideWideVideoRect`).
    static let captionBand: CGFloat = 100
    /// A page margin, used wherever the wireframe leaves a plain 16pt
    /// clearance rather than reusing an existing gap constant — pose
    /// 3's wide-video box, pose 4W's box, and (elsewhere) the caption
    /// and right-page placements build 4 and later add.
    static let pagePad: CGFloat = 16
    /// Pose 5's chin: the gap above its own top edge, clear of the
    /// rail's last button — build 7.
    static let chinColumnGap: CGFloat = 40
    /// Pose 5's chin: its own size once expanded in its column —
    /// build 7.
    static let columnChinSize: CGFloat = 56
    /// Pose 5's real network ring centre, measured inward from
    /// `occlusion.maxX` — `occlusion` there covers the time text AND
    /// the ring together, so its own trailing edge, not its `midX`,
    /// is the stable anchor. See `ringCenteredColumnX`'s own doc for
    /// the measurement this came from.
    static let openTallRingInsetFromTrailingEdge: CGFloat = 47.7

    /// Pose 5's own normal, un-grown ring+time `occlusion` width —
    /// `stageRect`'s own `.openTall` branch caps the column width it
    /// reads at this, so a Live Activity's pill (which reports through
    /// the SAME `occlusion` field, with no way to tell "ring" from
    /// "grown pill" apart) cannot shrink the STAGE's own available
    /// width, only the real ring/time's own normal footprint can.
    ///
    /// Confirmed this session (`-cloudfull-log-rotation`'s own `occ-`
    /// field, this pose's own 669×951 Duo sim window, LA Demo app):
    /// `134` with no activity, `226` with one running — the owner's
    /// own bug report ("stage 29,0 534×951, was 0,0 534×951") was a
    /// plain 9:16 video flipping from this file's own height-bound
    /// branch into the wide-video branch purely because the UNCAPPED
    /// column width had grown, not because the video itself changed.
    /// Flagged like every other "measured, no API" constant in this
    /// file (see `openTallRingInsetFromTrailingEdge`'s own comment,
    /// just above) — a different window size or a larger Dynamic Type
    /// setting could measure a different normal width; this has not
    /// been checked against either.
    static let openTallNormalOcclusionWidth: CGFloat = 134

    /// `current(...)`'s own FB24906205 fallback — see that function's
    /// own comment. The TRAILING case's own measured bar width, read
    /// off every bar-on pose this file has ever actually measured
    /// (1V/3/4/4W); stands in for a LEADING bar's own safe-area inset
    /// only on the frames that bug drops it to `0`. Flagged like every
    /// other "measured, no API" constant in this file — unconfirmed
    /// against a real leading-bar reading, since none exists yet to
    /// measure.
    static let fallbackBarWidth: CGFloat = 84

    // MARK: - Rail column (step 3; extended by steps 4, 5, and the pose fixes)
    //
    // The action rail (Keep, Share, Album, Shrink, Delete) moves off
    // the stage and into its own column whenever one exists. The
    // column itself comes from one of two sources, and every function
    // below reads only `railColumn(containerSize:safeAreaTop:)` — never
    // `barEdge`/`barWidth` directly — so the closed-bar case (step 3)
    // and the open, computed case (step 5) share this one definition
    // end to end (`availableRect`, the stage, the rail, the chin).

    /// Re-adapted (`design/duo/duo_audit_apple_checklist.md` §5/F6):
    /// replaces the old `ringInset`/`openColumnWidth` pair — a fixed
    /// 50pt/100pt read off one Duo-sim screenshot, which drifts off the
    /// real ring in a Mirroring window, another display, or a larger
    /// Dynamic Type size (F6's own finding). The open (bar-off)
    /// column's own width is now derived live, in `railColumn` below:
    /// from the active `.occlusion` region's own `midX` when one is on
    /// the trailing half (the ring/status cluster's real measured
    /// position, the same field `statusBlock` already reads for pose
    /// 5), or from `Rail.hit` (the button's own hit target, a design
    /// constant, not a device size) plus this margin when there is
    /// none to read.
    ///
    /// Also the fallback column width `railColumn`'s open branch uses
    /// when there is no `.occlusion` to read — `Rail.hit` plus this
    /// margin on each side.
    static let minStageMargin: CGFloat = 16

    /// Pose 1V's own status-cluster lower bound — owner ask: "can the
    /// rail be higher? Shift Delete through Keep up as a whole,"
    /// answered by centring the rail in the column's own full height,
    /// clamped so its own top edge never rises above this + 16pt (see
    /// `railVerticalExtent`'s own `isClosedBar` branch).
    ///
    /// Reads the active `.occlusion` region directly when this frame
    /// reports one, filtered to frames genuinely inside this window
    /// (`windowBounds.contains`, the same cross-display staleness
    /// guard `DuoLayout.current` already applies to `division` — only
    /// one display is ever active in pose 1V, so no `minX`-based side
    /// check like `statusBlock`'s own is needed here). Falls back to
    /// `safeAreaTop` alone, no added constant, when there is none to
    /// read: a documented, deliberately conservative choice — the one
    /// real, API-reported value this frame has for "how much the
    /// system reserves at this display's own top edge" — rather than
    /// an invented pixel number.
    ///
    /// Unverified against real hardware: an EARLIER version of this
    /// rail's own anchor (since replaced, then replaced again here)
    /// was top-anchored from exactly this pair of signals
    /// (`.occlusion`/`safeAreaTop`), and on a real closed Duo screen it
    /// undershot the system's own time + connectivity ring — there is
    /// no SDK API for that cluster's own extent — so the rail's first
    /// button (Keep) rendered partly under it. This change carries the
    /// same risk if the signal undershoots again; the owner's own ask
    /// to confirm this via `-cloudfull-log-rotation`'s `occ-`/`hSC`/
    /// `vSC` fields on a REAL closed Duo screen, not just the
    /// simulator, is exactly the right check before trusting this.
    private func closedStatusBottom(containerSize: CGSize, safeAreaTop: CGFloat) -> CGFloat {
        guard let occlusion, CGRect(origin: .zero, size: containerSize).contains(occlusion) else {
            return safeAreaTop
        }
        return occlusion.maxY
    }

    /// A Live Activity's own pill grows the Dynamic Island and pushes
    /// the system's time + connectivity ring down with it — but no
    /// public API reports the growth (owner probe: reservedRegions,
    /// safe area, traits, layout regions, and a layout callback were
    /// all checked and found unchanged while the pill is up, so
    /// `occlusion` itself never grows to report it either). The one
    /// thing this frame CAN still read, pill or no pill, is
    /// `occlusion.minY` — the status cluster's own top edge, which the
    /// pill grows DOWN from, not up. This adds a flat, hand-measured
    /// margin on top of that live top edge: `Self
    /// .liveActivityStatusGrowth`, the owner's own screenshot-measured
    /// worst case with the demo activity running (grown pill height,
    /// plus the time text and ring that still sit below it).
    ///
    /// Used only by `railVerticalExtent`'s own bottom-up branch, only
    /// to COMPRESS the rail's own pitch so Keep's own top never reaches
    /// above this line — never to move the rail, the chin, or anything
    /// else. Same stale-frame guard as `closedStatusBottom` above.
    private func closedStatusWorstCaseBottom(containerSize: CGSize, safeAreaTop: CGFloat) -> CGFloat {
        guard let occlusion, CGRect(origin: .zero, size: containerSize).contains(occlusion) else {
            return safeAreaTop + Self.liveActivityStatusGrowth
        }
        return occlusion.minY + Self.liveActivityStatusGrowth
    }

    /// The grown pill, plus the time text and ring that still sit
    /// below it, measured as the span BEYOND `occlusion.minY` — not an
    /// absolute y — so the same margin travels to whatever
    /// `occlusion.minY` a given frame/pose actually reads, rather than
    /// freezing one sample as a fixed line on one screen size.
    ///
    /// Checked twice this session, on the Duo sim, pose 1V, closed
    /// display (`--display=1`), LA Demo's own timer activity: the
    /// FIRST check (Cloudfull relaunched straight back to the front
    /// right after starting the activity) saw no push at all —
    /// `occlusion`'s rendered time+ring sat at the identical pixel
    /// position with the pill on or off. The owner's own live check
    /// explains why: the pill only shows while the app that owns it
    /// is NOT the one in front, so relaunching Cloudfull immediately
    /// suppressed it every time. The owner's own SECOND check (pill
    /// actually showing) measured `occlusion.minY` at 29pt and the
    /// grown stack's own bottom at ≈235pt — this constant is that
    /// gap, 206pt, so `closedStatusWorstCaseBottom` reproduces 235
    /// from a live `occlusion.minY` of 29 and travels correctly to
    /// whatever `occlusion.minY` a different pose/window reads.
    /// Flagged like every other "measured, no API" constant in this
    /// file (see `openTallRingInsetFromTrailingEdge`'s own comment)
    /// all the same — one sample, one window size.
    static let liveActivityStatusGrowth: CGFloat = 206

    /// Where the rail column sits, and how wide it is, this frame — or
    /// `nil` when no column applies.
    ///
    /// Closed (`isClosedBar`): the column IS the system vertical bar —
    /// same edge, same width as `barEdge`/`barWidth`. The rail moves
    /// into furniture the system already reserved; nothing new is
    /// carved out of the stage. Unconditional: there is no gate here,
    /// because the bar is real system furniture, already there.
    ///
    /// Open, pose 5 (`openTall`, the only bar-off pose with a rail —
    /// `.laptop` and `.tent` return `nil` here; see each pose's own
    /// panel/view): there is no system column to reuse, so one is
    /// computed instead, on the trailing edge, sized so its own CENTRE
    /// lands on the active `.occlusion` region's own `midX` (F6: "the
    /// safe-area inset already read in `DuoLayout.current`" for the
    /// bar case; the occlusion's own real position for the open case)
    /// — never a fixed, screenshot-measured width. With no occlusion
    /// to read, the column falls back to `Rail.hit + minStageMargin ×
    /// 2`, a size built from the rail button's own design constant,
    /// not a device number.
    ///
    /// Re-adapted again (owner review, pose 5: "rail sits too low,"
    /// tabs and chrome missing or overlapping): an earlier version of
    /// this branch gated the computed column on a margin check — "is
    /// the natural leftover big enough to carve out the column AND
    /// still leave the stage `minStageMargin` on each side" — before
    /// returning it. At pose 5's own measured window (669×951) and
    /// `.occlusion` (134×82 at the trailing edge, `DUO_POSES.md`'s own
    /// numbers), that leftover is 134.0625pt and the computed column
    /// is 134pt: there is no slack left over for a 32pt margin on top
    /// of it, so the gate always failed — silently falling the rail
    /// back to the pre-Duo bottom-trailing overlay (the "too low" the
    /// owner saw) and leaving `chromeColumnRect`/`zigzagCenters` (both
    /// built from this same column) empty too. The approved wireframe
    /// (`DUO_POSES.md`'s own pose-5 row: "Column x = ring x") already
    /// settles that a column belongs here; the margin gate was testing
    /// for a problem pose 5's own real proportions do not have — the
    /// window is always tall enough that `stageRect`'s FIT box is
    /// height-bound regardless of this column, so removing the column
    /// never actually reduces the stage's own margins below their
    /// natural (already ample) amount. This branch now trusts the
    /// occlusion signal the same unconditional way the closed branch
    /// above trusts the bar — "reuse that path" rather than adding a
    /// parallel gate pose 5 is the only one of the two bar-off cases
    /// that even reaches.
    /// Mirrored-layout round: the RETURNED edge now reads `isMirrored`,
    /// not `barEdge` alone, in both branches. Bar-on: while there IS a
    /// real bar, `barEdge` and `isMirrored` already agree by
    /// construction (`current(...)`'s own `isMirrored` formula never
    /// overrides a real bar's own side) — EXCEPT under
    /// `-cloudfull-force-mirror`, which forces `isMirrored` true to
    /// test a leading rail against the sim's own real, still-trailing
    /// bar (a deliberate DEBUG approximation: the column READS as
    /// leading, at the real trailing bar's own measured width, with no
    /// real leading-side furniture to actually anchor to on the sim —
    /// fine for checking the REST of this file's own geometry, not a
    /// claim that this matches a real leading-bar reading). Open (pose
    /// 5): no bar to defer to at all, so `isMirrored` (the owner's own
    /// `leftHandedControls` setting, this pose's only source for it —
    /// see that property's own comment) decides outright.
    func railColumn(containerSize: CGSize, safeAreaTop: CGFloat) -> (edge: HorizontalEdge, width: CGFloat)? {
        let edge: HorizontalEdge = isMirrored ? .leading : .trailing
        if let barEdge, barWidth > 0 {
            return (edge, barWidth)
        }
        guard pose == .openTall else { return nil }
        if let occlusion, occlusion.minX > containerSize.width / 2 {
            // A column centred on `occlusion.midX`, so its own centre
            // lands exactly on the ring's real position regardless of
            // how wide the window is — the same goal `openColumnWidth`
            // used to reach with a fixed, sim-measured number.
            return (edge, max(Rail.hit, (containerSize.width - occlusion.midX) * 2))
        }
        return (edge, Rail.hit + Self.minStageMargin * 2)
    }

    /// The rail column's own rectangle this frame, full height — the
    /// complement of `availableRect(containerSize:safeAreaTop:)`'s
    /// WIDTH only, deliberately not its top-inset height too, since
    /// this rectangle is the column's own hit area and background, not
    /// the stage's — or `nil` when `railColumn(containerSize:safeAreaTop:)`
    /// found none.
    ///
    /// `FeedPageContent.actionRailColumn` renders inside this instead
    /// of over the stage.
    func railColumnRect(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect? {
        guard let column = railColumn(containerSize: containerSize, safeAreaTop: safeAreaTop) else { return nil }
        switch column.edge {
        case .leading:
            return CGRect(x: 0, y: 0, width: column.width, height: containerSize.height)
        case .trailing:
            return CGRect(x: containerSize.width - column.width, y: 0,
                          width: column.width, height: containerSize.height)
        }
    }

    /// The rail/chin column's own horizontal CENTRE this frame, for
    /// positioning content inside it — `nil` when no column applies.
    ///
    /// Owner correction (pose pass, 1V): a screenshot crop showed the
    /// system's own time + connectivity ring sitting measurably LEFT
    /// of `railColumnRect`'s own `midX` — the bar's own safe-area
    /// width is not perfectly centred on the ring it reserves room
    /// for. Confirmed on the sim (`-cloudfull-log-rotation`, pose 1V,
    /// 466×678 window): `occlusion` reads `399,29,37,37` (`midX`
    /// 417.5pt) while the bar rect's own `midX` is 424pt — a 6.5pt
    /// gap, the same direction and the same rough size the owner's
    /// own crop showed. So this reads the active `.occlusion`
    /// region's own `midX` directly instead of the column rect's.
    /// Falls back to the column rect's own `midX` when there is no
    /// occlusion to read, or it reads well outside the column's own
    /// bounds (a stale/cross-display frame) — never an invented
    /// offset.
    ///
    /// Owner re-adapt (Opus wireframe compare, pose 5): this used to
    /// trust `railColumn`'s own open branch to have already centred
    /// its computed column on `occlusion.midX` by construction, and
    /// return the bar-off case's `columnRect.midX` unchecked. That
    /// construction holds only while `railColumn`'s own `max(Rail
    /// .hit, …)` clamp does not bind; once the ring sits close enough
    /// to the trailing edge that the raw computed width would fall
    /// under `Rail.hit`, the clamp takes over and the column's own
    /// centre stops tracking `occlusion.midX` at all — "rail x ≈ 8pt
    /// left of the ring's own centre x" on the sim, the wireframe's
    /// own "rail x = ring x" broken by exactly that clamp. Bar-off
    /// now takes the same direct, tolerance-checked `occlusion` read
    /// bar-on already did, rather than trusting construction.
    ///
    /// Owner re-adapt (Opus round-3 compare, pose 5): `occlusion.midX`
    /// alone was still ~11pt LEFT of the ring's own real centre there
    /// — confirmed still wrong after the fix just above. Unlike 1V,
    /// where `occlusion` reads as exactly the ring's own small square
    /// (`399,29,37,37`, `midX` already the ring's own centre), pose
    /// 5's own status region covers BOTH the time text and the ring
    /// together — the owner's own guess, since there is no Apple API
    /// that reports the ring's own extent apart from the whole region
    /// it shares with that text — so `occlusion.midX` there is the
    /// midpoint between the two, not the ring's own centre, which
    /// sits further toward the region's own trailing edge.
    /// `openTallRingOffset` was that gap, first measured directly from
    /// the owner's own screenshot at 11pt — superseded below.
    ///
    /// Owner re-adapt (DEBUG guide capture `guides_p5_r2.png`, pose
    /// 5): the `+11` guess above still sat the guide line ~8pt LEFT
    /// of the ring's real centre — a visual check at normal zoom
    /// called it exact, but a pixel-level crop of the ring's own
    /// white arc did not. Measured straight from that capture:
    /// `occlusion` reads `535,0,134×951` (`maxX` 669pt); the ring's
    /// own arc spans 1803–1925px of a 3×, 2007pt-wide capture →
    /// centre 621.3pt. So the ring's real centre sits
    /// `Self.openTallRingInsetFromTrailingEdge` (47.7pt) inside
    /// `occlusion`'s own trailing edge, not at its `midX` plus a
    /// small nudge. 1V is unchanged: its own `occlusion` already
    /// reads as the ring alone, with nothing to add.
    ///
    /// Owner re-adapt (ring-alignment bug, 3/4/4W): "rail x ≈ 909pt,
    /// ring's own real centre ≈ 903pt" — this `pose == .openTall` gate
    /// was the bug. 3/4/4W's own bar-on LANDSCAPE column reports
    /// `occlusion` as the SAME kind of wide, multi-element box pose
    /// 5's own region already is (confirmed this session,
    /// `-cloudfull-log-rotation`'s own `occ-` field, pose 4/book:
    /// `867,0,84,212`, 84pt wide — nothing like 1V's own tight
    /// 37×37 camera crop) — not the camera-hole-sized box this
    /// function used to assume every bar-on pose but 5 would have. So
    /// the midpoint-vs-trailing-inset choice below now reads
    /// `occlusion.width` itself, not `pose`: `909 (occlusion.midX)`
    /// vs `867+84−47.7 = 903.3pt` for that exact reading — within
    /// 0.3pt of the owner's own 903.0pt measurement, the SAME
    /// `openTallRingInsetFromTrailingEdge` this file already trusted
    /// for pose 5, now shared rather than duplicated. First tried
    /// reading TWO separate `.occlusion` regions (one tight, one
    /// wide) and picking the tight one, on the owner's own
    /// hypothesis that `reservedRegions` reports both at once on this
    /// pose — reverted: confirmed via the same log field that only
    /// ONE region is ever active here, so there was never a second,
    /// correct one to pick.
    static let wideOcclusionThreshold: CGFloat = 60

    /// Mirrored-layout round: a wide occlusion's own real ring centre
    /// was always measured inset from its TRAILING edge
    /// (`openTallRingInsetFromTrailingEdge`'s own comment) — unmeasured
    /// on a real leading-side reading, since none has existed to
    /// measure yet, but the construction that produced the trailing
    /// number (time text then ring, reading toward the display's own
    /// outer edge) mirrors exactly, so this reads the SAME inset from
    /// the LEADING edge instead whenever mirrored. Does not change the
    /// DEBUG `-cloudfull-force-mirror` case on 3/4/4W: the real
    /// occlusion there stays on the TRAILING half regardless (the
    /// camera does not move), well outside a now-LEADING `columnRect`'s
    /// own range check below, so this naturally falls through to the
    /// no-occlusion-detected answer (`columnRect.midX`) instead of
    /// guessing at an inset against the wrong occlusion.
    func ringCenteredColumnX(containerSize: CGSize, safeAreaTop: CGFloat) -> CGFloat? {
        guard let columnRect = railColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop) else { return nil }
        guard let occlusion, occlusion.midX >= columnRect.minX - 8, occlusion.midX <= columnRect.maxX + 8 else {
            return columnRect.midX
        }
        if occlusion.width >= Self.wideOcclusionThreshold {
            return isMirrored
                ? occlusion.minX + Self.openTallRingInsetFromTrailingEdge
                : occlusion.maxX - Self.openTallRingInsetFromTrailingEdge
        }
        return occlusion.midX
    }

    /// The rail's own top and bottom edge, in the page's own
    /// coordinate space (0 at the top), for whichever anchor this
    /// frame's column uses — or `nil` when no column applies.
    ///
    /// Both bar ON (closed, pose 1V/1H) and bar OFF (the open-tall
    /// pose) now centre the rail in the column's own full height —
    /// `(containerSize.height - Rail.columnHeight) / 2`. Bar OFF has
    /// read this way since an earlier top-anchored version put the
    /// rail right under the system's own time + connectivity ring; the
    /// owner's own review called that "too high," asking for the rail
    /// "centred vertically and accessible if I'm holding with one hand
    /// unfolded" instead.
    ///
    /// Bar ON picked up the same centring in a LATER review, replacing
    /// a bottom-anchored version this file's own history shows was
    /// itself a deliberate choice at the time ("leave pose 1's rail
    /// position as it is") — the owner later asked to "shift Delete
    /// through Keep up as a whole." Centring alone is not safe there,
    /// though: the ring sits ABOVE the bar column in this pose, with no
    /// SDK API for its own extent, so this clamps the centred top down
    /// to `closedStatusBottom(containerSize:safeAreaTop:) + 26`pt
    /// whenever straight centring would rise above it — seeing the
    /// clamp bind at all, on a real closed Duo screen, is the one
    /// thing to check (see that function's own comment on why this
    /// specific signal undershot once before).
    ///
    /// Owner re-adapt (pose pass, 1V, second round): "Keep is crowding
    /// the network ring" — the clamp's own gap was 16pt; raised by
    /// 10pt to 26pt, lowering the whole rail (Keep through Delete, and
    /// the chin below it where the chin's own anchor tracks the
    /// rail's bottom) clear of the ring.
    /// Owner re-adapt (Live Activity pass): bar-on (`isClosedBar`) no
    /// longer centres the rail in the column — it builds BOTTOM-UP
    /// from the closed chin instead. Why: a Live Activity's own pill
    /// grows the Dynamic Island and pushes the system's time +
    /// connectivity ring down with it (~85pt, owner's own measurement)
    /// with no public API reporting the growth — the old centred-then-
    /// clamped rule reads `occlusion` for that clamp, and `occlusion`
    /// itself never grows, so it could not see the pill coming; the
    /// owner's own screenshot with the demo activity running showed
    /// the ring sitting on Keep. Anchoring from the BOTTOM instead —
    /// Delete's own bottom edge `Self.railChinGap` above the chin's own
    /// top edge, same as always, pill or no pill — never depends on
    /// that signal at all, so there is nothing for it to miss.
    ///
    /// `Self.railChinGap` is the SAME pitch as between the rail's own
    /// five items (`Rail.spacing`) — "no new magic numbers beyond that
    /// gap" — not pose 5's own, already different, already named
    /// `chinColumnGap` (40pt, the bar-OFF case).
    ///
    /// Safety net: `closedStatusWorstCaseBottom` is this frame's own
    /// worst-case reading of where the grown status cluster's bottom
    /// edge could reach. If the bottom-up stack's own top (Keep) would
    /// rise ABOVE that line on this frame, this compresses the pitch
    /// between items — Delete's own bottom edge stays fixed at the
    /// chin — rather than let Keep overlap the ring. `Rail.itemHeight`
    /// (each button's own real size) is never compressed, only the air
    /// between them.
    func railVerticalExtent(containerSize: CGSize, safeAreaTop: CGFloat, safeAreaBottom: CGFloat) -> (top: CGFloat, bottom: CGFloat, spacing: CGFloat)? {
        guard railColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop) != nil else { return nil }
        let centeredTop = (containerSize.height - Rail.columnHeight) / 2
        guard isClosedBar else {
            return (centeredTop, centeredTop + Rail.columnHeight, Rail.spacing)
        }
        guard let chinCenter = railAlignedChinCenter(safeAreaTop: safeAreaTop, safeAreaBottom: safeAreaBottom, containerSize: containerSize) else {
            // Defensive only — every `isClosedBar` pose already has a
            // rail column, so `railAlignedChinCenter` always resolves
            // one here too. Falls back to the pre-Live-Activity rule.
            let minTop = closedStatusBottom(containerSize: containerSize, safeAreaTop: safeAreaTop) + 26
            let top = max(minTop, centeredTop)
            return (top, top + Rail.columnHeight, Rail.spacing)
        }
        let chinTop = chinCenter.y - Rail.hit / 2
        let bottom = chinTop - Self.railChinGap
        // Owner re-adapt (live check, pose 1V, pill running with
        // Cloudfull in front — the pill only shows while its OWN app
        // is NOT frontmost, which is why an earlier check of this same
        // code, done with Cloudfull in front, saw no push at all):
        // Keep's top touched the grown ring's own dots at a bare 0pt
        // gap. `Self.railKeepClearance` (24pt) is the floor required
        // ABOVE `closedStatusWorstCaseBottom`'s own worst-case line,
        // not just clear of it.
        let minTop = closedStatusWorstCaseBottom(containerSize: containerSize, safeAreaTop: safeAreaTop) + Self.railKeepClearance
        let naiveTop = bottom - Rail.columnHeight
        guard naiveTop < minTop else {
            return (naiveTop, bottom, Rail.spacing)
        }
        let compressed = Self.compressedRailLayout(bottom: bottom, minTop: minTop, gap: Self.railChinGap)
        guard compressed.pitch < Self.railMinPitch else {
            return (compressed.top, bottom, compressed.spacing)
        }
        // Still too tight at the normal gap (a short bar-on window —
        // 3/4/4W's own landscape column, the owner's own flag: "check
        // it fits there too"): closing the gap to the chin to
        // `railChinGapCompressed` buys a little more room before
        // falling back to the pitch this produces, whatever it is —
        // `Rail.itemHeight` itself is still never compressed.
        let tighterGap = Self.railChinGapCompressed
        let tighterBottom = chinTop - tighterGap
        let tighterCompressed = Self.compressedRailLayout(bottom: tighterBottom, minTop: minTop, gap: tighterGap)
        return (tighterCompressed.top, tighterBottom, tighterCompressed.spacing)
    }

    /// Shared by `railVerticalExtent`'s own two compression attempts
    /// (normal gap, then the tighter one) — `Rail.itemHeight` (each
    /// button's own real size) is never compressed, only the air
    /// between items, floored at 0 (overlapping items, the last-resort
    /// case neither attempt is expected to reach in practice).
    private static func compressedRailLayout(bottom: CGFloat, minTop: CGFloat, gap: CGFloat) -> (top: CGFloat, spacing: CGFloat, pitch: CGFloat) {
        let compressedHeight = max(Rail.itemHeight * 5, bottom - minTop)
        let compressedSpacing = max(0, (compressedHeight - Rail.itemHeight * 5) / 4)
        return (bottom - compressedHeight, compressedSpacing, Rail.itemHeight + compressedSpacing)
    }

    /// See `railVerticalExtent`'s own doc comment.
    static let railChinGap: CGFloat = Rail.spacing

    /// Owner re-adapt (live check, pose 1V): the floor `railVerticalExtent`
    /// requires between Keep's own top and `closedStatusWorstCaseBottom`'s
    /// own worst-case line — not merely "not overlapping," real air.
    static let railKeepClearance: CGFloat = 24

    /// Owner re-adapt (live check): the smallest pitch (item height +
    /// spacing) `railVerticalExtent`'s own compression is allowed to
    /// reach before it also closes `railChinGap` down to
    /// `railChinGapCompressed` for a little more room, rather than
    /// compressing the pitch further still.
    static let railMinPitch: CGFloat = 52

    /// Owner re-adapt (live check): `railChinGap`'s own fallback value
    /// once a bar-on window is short enough that the normal 20pt gap
    /// cannot leave `railMinPitch` between items even at Keep's own
    /// required clearance — a shorter landscape column (3/4/4W) is the
    /// owner's own flagged case to check this against.
    static let railChinGapCompressed: CGFloat = 12

    /// The actual bottom edge of the rail's last button (Delete) this
    /// frame, in the page's own coordinate space (0 at the top) —
    /// whichever anchor `railVerticalExtent` reports for this frame.
    ///
    /// No rail column (a regular iPhone, or an open Duo too narrow for
    /// one): the rail is the pre-Duo overlay, bottom-anchored against
    /// the video's own seam — see `FeedPageContent.actionRail`'s
    /// identical `bottomBand + Rail.seamClearance` padding, which this
    /// mirrors so the two can never disagree.
    ///
    /// `ChinNavigation` reads this (as `railBottom`) to keep its own
    /// top edge below the rail's, with a minimum gap, instead of
    /// relying on a fixed offset that only happens to clear it on
    /// whichever screen it was tuned against. Bar ON, this is a no-op
    /// in practice: both this and the chin's own fixed anchor derive
    /// from the same chin position, so they can never disagree by more
    /// than rounding. Bar OFF, the rail's bottom now sits well above
    /// the chin (it hangs from the stage's own top, not the page's
    /// own bottom), so the clamp stays a no-op there too — just no
    /// longer for the same algebraic reason.
    func railBottom(safeAreaTop: CGFloat, safeAreaBottom: CGFloat, containerSize: CGSize) -> CGFloat {
        if let extent = railVerticalExtent(containerSize: containerSize, safeAreaTop: safeAreaTop, safeAreaBottom: safeAreaBottom) {
            return extent.bottom
        }
        let bottomBand = StageGeometry.bottomBand(safeAreaTop: safeAreaTop, containerSize: containerSize)
        return containerSize.height - (bottomBand + Rail.seamClearance)
    }

    // MARK: - Chrome column + right page (build 3)
    //
    // Pose 3/4/4W put Mute, Filter, and Bin in their own column,
    // `chromeColumnWidth` wide, immediately leading of wherever
    // `railColumn` already put the rail/bar column — never computed
    // independently of it, so the two columns can never drift apart
    // or overlap. `FeedView.chromeColumn` is the one caller.

    /// Half of the rail's own real visual width this frame — the
    /// WIDER of the 40pt glyph circle (`Rail.hit`) and the rail's own
    /// widest label, actually measured against a `UIFont` built to
    /// match `Rail.labelFont`'s own point size/weight (10pt
    /// semibold), the same pattern `ChinTabItemContentView
    /// .intrinsicContentSize` already uses for its own words instead
    /// of guessing a text's width. "Delete"/"Shrink" print about 32pt
    /// wide at this size — under `Rail.hit` today, so the glyph
    /// circle is what actually bounds the rail's own pixels in
    /// English at the system's default text size.
    ///
    /// Owner re-adapt (round-4 review): the comment here used to claim
    /// a longer localized label or a larger Dynamic Type size was
    /// "still covered, not silently unmeasured" — not true. `labels`
    /// below is a hand-copied, ENGLISH-only snapshot of the rail's own
    /// five words (`likeButton`/`shareButton`/`albumButton`/
    /// `shrinkButton`/`deleteButton`'s own label text, not read from
    /// them), and `font` is a fixed 10pt `UIFont` literal — `UIFont`
    /// and `Rail.labelFont`'s own SwiftUI `Font` are different types
    /// with no shared constant between them, so this duplicates that
    /// `10` by hand rather than reading it. Neither tracks a real
    /// localization or a real Dynamic Type setting. This is accepted,
    /// same as any other "measured, no API" constant in this file —
    /// but accepted as a flagged gap, not as real coverage.
    private static let railVisualHalfWidth: CGFloat = {
        let font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        let labels = ["Keep", "Share", "Album", "Shrink", "Delete"]
        let widestLabel = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(Rail.hit, widestLabel) / 2
    }()

    /// The smallest gap the chrome column is ever allowed to close to
    /// the rail's own real pixels — the owner's own floor (pose pass,
    /// round 4: "move those 3 buttons closer to the rail … keeping
    /// 8pt clear"). Not `private` since the owner's own Bin-badge
    /// clamp (`FeedView.chromeColumn`) reads this too, so the two
    /// stay the one floor, not a second hand-copied `8`.
    static let minChromeRailClearance: CGFloat = 8

    /// The rail's own real visual edge this frame, closest to the
    /// chrome column — `ringCenteredColumnX` (the SAME x
    /// `actionRailColumn` actually renders the rail at, not a second
    /// guess at it) pulled in by `railVisualHalfWidth`. `nil` when no
    /// rail column applies.
    ///
    /// Owner re-adapt (round-4 review): no longer clamped to
    /// `railColumnRect`'s own edge. That clamp meant "the rail's
    /// real pixels can never be reported past the structural column's
    /// own bound" — true only while the rail sits inside that bound
    /// in the first place. A left-shifted rail (`ringCenteredColumnX`
    /// genuinely further leading than `railColumnRect.minX` — the
    /// kind of reading the pose-5 ring-x rounds this file has already
    /// seen) would have its real left extent silently UNDERSTATED by
    /// the clamp, so `chromeColumnRect` — which trusts this value to
    /// mean "how far left the rail's own pixels actually reach" —
    /// could place the buttons past that real, further-left edge and
    /// overlap it. The measured edge alone is always the honest
    /// answer; `chromeColumnRect`'s own `min(railRect.minX − Rail.hit
    /// / 2, …)` clamp (its own comment) already keeps the BUTTON'S
    /// own position from crossing the structural column — the
    /// non-overlap guarantee this clamp duplicated, less accurately.
    ///
    /// Not `private` since `FeedView.chromeColumn`'s own Bin-badge
    /// label clamp (owner re-adapt, BLOCKER: the badge's own widened
    /// capsule ran over the rail's Shrink icon) reads this too — the
    /// same real boundary the button's own position already answers
    /// to, not a second guess at it.
    func railVisualEdge(containerSize: CGSize, safeAreaTop: CGFloat) -> (edge: HorizontalEdge, x: CGFloat)? {
        guard let column = railColumn(containerSize: containerSize, safeAreaTop: safeAreaTop),
              railColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop) != nil,
              let centerX = ringCenteredColumnX(containerSize: containerSize, safeAreaTop: safeAreaTop)
        else { return nil }
        switch column.edge {
        case .trailing:
            return (.trailing, centerX - Self.railVisualHalfWidth)
        case .leading:
            return (.leading, centerX + Self.railVisualHalfWidth)
        }
    }

    /// This frame's chrome column, or `nil` when `railColumn` found no
    /// rail/bar column to sit beside (a regular iPhone, or any pose
    /// without one). Full height, like `railColumnRect` — this is a
    /// geometry source for `zigzagCenters`'s own `x` and the stage's
    /// own exclusion width (`chromeColumnWidth` below), not a
    /// rendered box; nothing draws its background.
    ///
    /// Owner re-adapt (pose pass, round 4): "for 3 move those 3
    /// buttons closer to the rail." The round-3 build centred the
    /// group in a fixed `chromeColumnWidth = 80` box, independent of
    /// the rail's own real position. The approved round-4 wireframe
    /// (`design/DUO_VIDEO_WIREFRAMES_gen.py`'s own `right_columns()`)
    /// instead sits the group close to the rail's own real pixels —
    /// "roughly half" the old box's own gap to them, the owner's own
    /// words — so this derives that position from two REAL signals,
    /// `railColumnRect`'s own leading edge and `railVisualEdge`'s own
    /// measured rail extent, rather than a second frozen pixel
    /// number. The round-3 box put the group's own centre at exactly
    /// `railColumnRect.minX − Rail.hit` — that box's own arithmetic
    /// (`80` wide, immediately leading of the rail column, the group
    /// centred inside it), not a new guess — so `oldGap` below is
    /// exactly the gap THAT box left to the rail's real pixels, read
    /// live instead of copied from one sim screenshot. The new gap
    /// (`newGap`) is floored at `minChromeRailClearance` so it can
    /// never cross the rail's own labels, and the column's own width
    /// is floored at `Rail.hit` so it is never narrower than the
    /// circles it holds. Verified against the wireframe at this window's own
    /// measured 951×669 (assuming the wireframe's own 84pt bar and no
    /// `.occlusion` override — `ringCenteredColumnX`'s own fallback,
    /// the one case this comment's own arithmetic can be checked by
    /// hand against): this lands at `x 847`, within 1pt of the
    /// generator's own `x 846`, from live geometry alone, not by
    /// copying the number (`design/duo/duo_build_spec.md`'s own
    /// build-3 row has the prior `x 827` this replaces).
    ///
    /// Owner re-adapt (round-4 review): at THIS verified size, `x 847`
    /// is the `min(railRect.minX − Rail.hit / 2, …)` clamp's own
    /// value, not the "half the gap" formula — the clamp is BINDING
    /// here, not merely the rare safety bound its own inline comment
    /// frames it as. So the half-gap term itself (`visual.x − newGap
    /// − Rail.hit / 2`) is larger than `railRect.minX − 20` at this
    /// size, and `min` picks the clamp instead.
    func chromeColumnRect(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect? {
        guard let railRect = railColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop),
              let visual = railVisualEdge(containerSize: containerSize, safeAreaTop: safeAreaTop)
        else { return nil }
        switch visual.edge {
        case .trailing:
            let oldCenterX = railRect.minX - Rail.hit
            let oldGap = visual.x - oldCenterX - Rail.hit / 2
            let newGap = max(Self.minChromeRailClearance, oldGap / 2)
            // The `min` is a hard safety bound, not part of "half the
            // gap": however wide a future bar/occlusion reading makes
            // `visual.x`, the button's own right edge can never cross
            // past `railRect.minX` into the rail's own structural
            // column.
            let centerX = min(railRect.minX - Rail.hit / 2, visual.x - newGap - Rail.hit / 2)
            let width = max(Rail.hit, (railRect.minX - centerX) * 2)
            return CGRect(x: railRect.minX - width, y: 0, width: width, height: containerSize.height)
        case .leading:
            // Not a configuration pose 3/4/4W has ever measured (the
            // bar is always trailing there, `rightPage`'s own
            // comment) — mirrored for the same reason
            // `availableRect`/`railColumn` handle both edges
            // generically.
            let oldCenterX = railRect.maxX + Rail.hit
            let oldGap = oldCenterX - Rail.hit / 2 - visual.x
            let newGap = max(Self.minChromeRailClearance, oldGap / 2)
            let centerX = max(railRect.maxX + Rail.hit / 2, visual.x + newGap + Rail.hit / 2)
            let width = max(Rail.hit, (centerX - railRect.maxX) * 2)
            return CGRect(x: railRect.maxX, y: 0, width: width, height: containerSize.height)
        }
    }

    /// This frame's chrome column width alone — `chromeColumnRect`'s
    /// own width. `0` when `chromeColumnRect` found nothing.
    ///
    /// Owner re-adapt (round-4 review, BLOCKER): `openWideWideVideoRect`
    /// and `rightPage` used to read THIS for their own stage/right-page
    /// exclusion too — correct through round 3, when the button box
    /// and the stage's own exclusion were the same fixed `80`, but
    /// wrong once round 4 shrank the button box's own rendered width
    /// to sit closer to the rail: the stage and the right page then
    /// widened into space the wireframe still reserves (the pose-3
    /// wide-video stage's own right edge 771 → 811, the book's own
    /// right page 827 → 787 with its tiles growing 84 → ~97-104pt, at
    /// this window's own measured size) — "move those 3 buttons
    /// closer to the rail," never "give the stage more room." Those
    /// two callers now read `chromeColumnStageExclusion` instead,
    /// which stays at the OLD fixed line regardless of where the
    /// buttons actually sit. This function itself is for the button
    /// box's own real width — `zigzagCenters`'s own `x`, and anything
    /// else that needs to know where the buttons themselves actually
    /// are.
    func chromeColumnWidth(containerSize: CGSize, safeAreaTop: CGFloat) -> CGFloat {
        chromeColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop)?.width ?? 0
    }

    /// The stage/right-page's own exclusion width for the chrome
    /// column — separate from `chromeColumnWidth` since round 4 (see
    /// that function's own comment for why reusing it widened both
    /// callers past what the wireframe asks for). `2 * Rail.hit` is
    /// the arithmetic the OLD fixed `chromeColumnWidth = 80` box
    /// always was: an 80pt box, immediately leading of the rail
    /// column, the group centred inside it — `railRect.minX − 2 *
    /// Rail.hit` is that box's own leading edge, the "old line" the
    /// stage and the right page still hold to. Written as `2 *
    /// Rail.hit`, not the bare literal `80`, so a future change to
    /// `Rail.hit` keeps this consistent with it. `0` under the same
    /// condition `chromeColumnWidth` is `0` — no chrome column this
    /// frame, nothing to exclude.
    func chromeColumnStageExclusion(containerSize: CGSize, safeAreaTop: CGFloat) -> CGFloat {
        guard chromeColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop) != nil else { return 0 }
        return 2 * Rail.hit
    }

    /// Three points, x = the chrome column's own centre, Filter
    /// centred on the rail's own vertical centre, Mute and Bin pulled
    /// in close to it — a tight group, not level with the rail's own
    /// (much wider) button gaps.
    ///
    /// Owner re-adapt (pose pass, poses 3/4): the previous version
    /// placed each button level with a gap between two of the rail's
    /// five buttons (`pitch = Rail.itemHeight + Rail.spacing`, 76pt) —
    /// "each button is level with a gap between two rail buttons"
    /// (`DUO_POSES.md`'s own original wording for the pose-3
    /// wireframe). The owner's own look at the sim asked for a tight
    /// group instead: Filter on the rail's own vertical centre
    /// (`railTop + Rail.columnHeight / 2`), Mute and Bin one `pitch`
    /// above/below it, `pitch = Rail.hit + 12` (52pt) — "about one
    /// button height + ~12pt," using `Rail.hit` as the one existing
    /// constant that already means "a round control's own size" in
    /// this file, not the taller labelled-rail-item unit `pitch` used
    /// before. `[]` when `chromeColumnRect`/`railVerticalExtent` found
    /// nothing to anchor against.
    func zigzagCenters(containerSize: CGSize, safeAreaTop: CGFloat, safeAreaBottom: CGFloat) -> [CGPoint] {
        guard let columnRect = chromeColumnRect(containerSize: containerSize, safeAreaTop: safeAreaTop),
              let extent = railVerticalExtent(containerSize: containerSize, safeAreaTop: safeAreaTop, safeAreaBottom: safeAreaBottom)
        else { return [] }
        let pitch = Rail.hit + 12
        // The rail's own vertical centre — `(extent.top + extent.bottom)
        // / 2` rather than `extent.top + Rail.columnHeight / 2` — so
        // this still lands on the rail's REAL centre if the bottom-up
        // anchor ever compresses the column shorter than
        // `Rail.columnHeight` (the Live Activity safety net).
        let filterY = (extent.top + extent.bottom) / 2
        return [filterY - pitch, filterY, filterY + pitch].map { y in
            CGPoint(x: columnRect.midX, y: y)
        }
    }

    /// The book pose's GRID page (pose 4/4W only; `nil` otherwise, or
    /// with no active division to anchor against) — the page the stage
    /// is NOT on (`stageRect`/`bookWideVideoRect`'s own
    /// `bookStagePageBox`), named `rightPage` from when that was always
    /// the physical right page; it is the LEFT page once mirrored
    /// swaps the stage to the right. Originally "`x ∈ [division.maxX,
    /// W − bar − 80]`, full height" — the fold's own trailing edge to
    /// the leading edge of whichever column (rail/bar, then chrome)
    /// sits on the window's own far side. Reads
    /// `chromeColumnStageExclusion`, not `chromeColumnWidth` — see
    /// that function's own comment (round-4 review, BLOCKER): the
    /// wireframe keeps this page at its OLD edge even though round 4
    /// moved the Mute/Filter/Bin buttons closer to the rail.
    /// `DuoRightPage` (build 12) mounts here, and reads this rect on
    /// every reload for its own grid/tile sizing — not unread, as an
    /// earlier version of this comment said.
    ///
    /// Mirrored-layout round: unmirrored, unchanged — the fold's own
    /// trailing edge to the rail/chrome's own leading edge, same as
    /// always. Mirrored, the grid is the LEFT page instead — the
    /// rail/chrome's own trailing edge (now on the window's own
    /// leading side) to the fold's own leading edge.
    func rightPage(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect? {
        guard pose == .book, let division else { return nil }
        let column = railColumn(containerSize: containerSize, safeAreaTop: safeAreaTop)
        let barWidth = column?.width ?? 0
        let chromeExclusion = chromeColumnStageExclusion(containerSize: containerSize, safeAreaTop: safeAreaTop)
        if isMirrored {
            let maxX = division.minX
            let minX = min(maxX, barWidth + chromeExclusion)
            return CGRect(x: minX, y: 0, width: maxX - minX, height: containerSize.height)
        }
        let minX = division.maxX
        let maxX = max(minX, containerSize.width - barWidth - chromeExclusion)
        return CGRect(x: minX, y: 0, width: maxX - minX, height: containerSize.height)
    }

    /// Pose 5's own top-chrome anchor (build 6): "the active
    /// `.occlusion` region whose `minX > W/2`" — the spike that
    /// measured this proved it is the time + connectivity ring block
    /// on pose 5. Pose 1V (`.closed`) reuses this same anchor now too
    /// (owner re-adapt, pose pass) — `pose5TopRow` generalizes to both
    /// poses unchanged; see that function's own comment. Re-adapted (`design/duo/duo_audit_apple_checklist.md`
    /// §5): the old fallback was a fixed, screenshot-measured 134×82
    /// box at the window's own top-trailing corner — a device size
    /// (F6's own category of finding, even though this particular
    /// constant post-dates F6's own list). With no `.occlusion` to read
    /// — absent, or sitting on the wrong half, a frame the owner's own
    /// sim readings already caught transiently reporting a stale
    /// cross-display rect; see `current(...)`'s own division filter for
    /// the equivalent fix on that field, since `occlusion` has no such
    /// filter yet, so this check doubles as one for this one caller —
    /// this now returns a zero-width rect pinned to the true trailing
    /// edge, `safeAreaTop` tall: `pose5TopRow`'s own `trailing =
    /// statusBlock.minX − 8` lands the row 8pt from the real trailing
    /// edge, and `statusBlock.midY` centres it in the real safe-area
    /// top inset instead of a guessed height.
    ///
    /// No separate log call here: this type stays a pure value with
    /// no side effects, by design (this file's own header comment);
    /// `PlayerPageView`'s `-cloudfull-log-rotation` probe already
    /// prints the raw `occlusion` field on every pose/hinge change,
    /// which already shows whether this fell back — `occ-none`, or an
    /// `occ-` rect whose own `x` sits left of half the printed `W`.
    ///
    /// Mirrored-layout round: both the half-check and the fallback's
    /// own edge flip with `isMirrored` — "the leading half," "the true
    /// leading edge," instead of trailing. The DEBUG
    /// `-cloudfull-force-mirror` case on 3/4/4W reads the same way
    /// `ringCenteredColumnX` does: the real occlusion there never
    /// leaves the trailing half, so the mirrored check correctly finds
    /// nothing on the (now-checked) leading half and falls back to the
    /// zero-width leading anchor instead of a wrong reading.
    func statusBlock(containerSize: CGSize, safeAreaTop: CGFloat) -> CGRect {
        if isMirrored {
            if let occlusion, occlusion.maxX < containerSize.width / 2 {
                return occlusion
            }
            return CGRect(x: 0, y: 0, width: 0, height: safeAreaTop)
        }
        if let occlusion, occlusion.minX > containerSize.width / 2 {
            return occlusion
        }
        return CGRect(x: containerSize.width, y: 0, width: 0, height: safeAreaTop)
    }

    // MARK: - Laptop bottom deck (build 8b, re-adapted R2, re-adapted R4)
    //
    // Pose 6 only: everything below the fold's bottom edge — the
    // scrubber, the caption, the Mute/Filter/Bin group, the
    // horizontal action rail and its chin, and Previous/Next — is one
    // shared panel (`design/duo/duo_build_spec.md` §2.6), anchored to
    // this frame's own `division`, never a fixed 669×951 window.
    //
    // Owner re-adapt: the first build scaled the wireframe's own
    // measured x positions (120/220/420/452, 70…470, 535, 600, ∓120)
    // by `containerSize.width / 669`. That is still a device-size
    // constant in the numerator's shadow — 669 only ever meant anything
    // because the laptop window happens to measure that wide — so the
    // owner's rule rules it out too, denominator or not. Every number
    // below instead comes from `laptopBottomRect`'s own live rect:
    // the deck's three row-groups (scrubber+caption+group, rail+chin,
    // Previous/Next) are `laptopBand`'s own equal thirds of its
    // height, and every x position is either the rect's own live
    // width or a fraction/gap of the rail-and-chin row's own even,
    // six-way split — never a ratio against a measured constant. Every
    // function below reads only `laptopBottomRect`/`laptopBand`, so the
    // whole deck moves together if either changes. "Shared" mirrors
    // the audit's own call (`design/duo/duo_audit_apple_checklist.md`
    // §2): the pieces that describe the CURRENT item (the rail, the
    // caption, the scrubber) still render once per page, inside
    // `FeedPageContent`/`PlayerPageView`, same as every other pose —
    // only the two pieces that are genuinely screen-global (the Mute/
    // Filter/Bin group, and Previous/Next, which pages the feed) mount
    // once in `FeedView.overlayControls`. See each call site's own
    // comment.
    //
    // Owner re-adapt (round 4): "put the filters in the top right of
    // the bottom section, across and aligned from the date and time."
    // The group no longer has its own row — it now shares band 0 with
    // the scrubber/caption, right-aligned to that band's own trailing
    // margin (the same `pagePad` inset `laptopScrubberRect`'s own
    // right edge already uses) and vertically centred on the
    // caption's own date line. That date line's real position is a
    // genuine on-screen fact a pure-geometry type like this one cannot
    // read for itself — `FeedView.laptopCaptionDateLineCenterY` reads
    // it live, the same `GeometryReader`/`PreferenceKey` technique
    // `duoRightGridBottomY` already uses (see that property's own
    // comment); `laptopControlGroupTrailingX` below hands back only the
    // X axis. The deck drops from four
    // bands to three: band 0 now carries the group too, so `laptopZigzagRow`
    // (its own now-empty row) is gone, and the rail/chin and
    // Previous/Next rows each shift up one band index.

    /// Pose 6's bottom-of-fold panel: "`CGRect(0, division.maxY, W, H
    /// − division.maxY − safeAreaBottom)`" (§2.6) — `nil` outside the
    /// laptop pose, or with no active division to anchor against.
    /// `safeAreaBottom` is the real home-indicator inset, the same
    /// "pass the real proxy value, never a constant" rule every other
    /// function in this file already follows for `safeAreaTop`.
    func laptopBottomRect(containerSize: CGSize, safeAreaBottom: CGFloat) -> CGRect? {
        guard pose == .laptop, let division else { return nil }
        return CGRect(x: 0, y: division.maxY, width: containerSize.width,
                      height: max(0, containerSize.height - division.maxY - safeAreaBottom))
    }

    /// The deck's three equal row-groups, in order: 0
    /// scrubber+caption+group, 1 the rail+chin, 2 Previous/Next —
    /// "Rows evenly spaced in that rect … divide the rect height into
    /// equal bands" (owner re-adapt), now three instead of four since
    /// the group (round 4) folded into band 0 rather than keeping its
    /// own row. Every laptop-deck function below reads its own band
    /// from here instead of a wireframe v-offset.
    private static let laptopBandCount: CGFloat = 3
    private static func laptopBand(_ bottom: CGRect, _ index: Int) -> CGRect {
        let height = bottom.height / laptopBandCount
        return CGRect(x: bottom.minX, y: bottom.minY + CGFloat(index) * height, width: bottom.width, height: height)
    }

    /// The scrubber's own frame, in band 0's own upper portion.
    /// `PlayerPageView` positions its own `ScrubberView` here, with
    /// `bandHeight: 0` — it owns `holder.progress`; this file stays a
    /// pure value type with no playback state of its own.
    func laptopScrubberRect(containerSize: CGSize, safeAreaBottom: CGFloat) -> CGRect? {
        guard let bottom = laptopBottomRect(containerSize: containerSize, safeAreaBottom: safeAreaBottom) else { return nil }
        let band = Self.laptopBand(bottom, 0)
        return CGRect(x: band.minX + Self.pagePad, y: band.minY + band.height * 0.25 - 14,
                      width: max(0, band.width - Self.pagePad * 2), height: 28)
    }

    /// Band 0's own bottom edge — `FeedPageContent.duoLaptopCaption`'s
    /// own bottom-aligned text box ends here, under the scrubber,
    /// still inside the deck's first third (now shared with the
    /// Mute/Filter/Bin group — see `laptopControlGroupTrailingX`).
    func laptopCaptionBottomY(containerSize: CGSize, safeAreaBottom: CGFloat) -> CGFloat? {
        guard let bottom = laptopBottomRect(containerSize: containerSize, safeAreaBottom: safeAreaBottom) else { return nil }
        return Self.laptopBand(bottom, 0).maxY
    }

    /// The Mute/Filter/Bin group's own X-axis geometry, in band 0 —
    /// owner re-adapt (round 4): "put the filters in the top right of
    /// the bottom section, across and aligned from the date and
    /// time." `trailingX` is band 0's own trailing margin, the same
    /// `pagePad` inset `laptopScrubberRect`'s own right edge already
    /// uses, so the group's right edge lines up directly under the
    /// scrubber's own right end — `FeedView.laptopDeckControls` right-
    /// aligns the group's own `HStack` to it with a `.frame(width:
    /// trailingX, alignment: .trailing)`/`.position(x: trailingX / 2,
    /// y:)` pair (the same "zero-anchored box, aligned content"
    /// technique `duoLaptopCaption`'s own `rect` already uses), which
    /// is what actually shifts the group left on its own, with no
    /// gap math here, when `binBadgeText` widens it.
    ///
    /// The Y axis is NOT this function's job: vertically the group
    /// centres on the caption's own date line, a real on-screen fact
    /// (`FeedView.laptopCaptionDateLineCenterY`, measured the same
    /// `GeometryReader`/`PreferenceKey` way `duoRightGridBottomY`
    /// already is) this pure-geometry type cannot read for itself.
    ///
    /// Owner re-adapt (round-4 review, BLOCKER + follow-up): this used
    /// to also hand back a guessed `fallbackY` (`band.height * 0.62`)
    /// for the one frame before a real measurement landed. Guessing a
    /// Y a pure-geometry type has no way to actually know was the
    /// wrong fix for a one-frame problem — `FeedView.laptopDeckControls`
    /// now hides the group with `.opacity(0)` until
    /// `laptopCaptionDateLineCenterY` reports its first real value,
    /// instead of drawing at a guessed spot for one frame and then
    /// jumping.
    /// Mirrored-layout round: the group moves to band 0's own LEADING
    /// margin instead, same `pagePad` inset — the returned value is
    /// then an X coordinate near the window's LEFT edge, not the
    /// right, and the group grows rightward from it. The name stays
    /// `laptopControlGroupTrailingX` (the unmirrored case this file
    /// has always measured); `FeedView.laptopDeckControls`/
    /// `duoLaptopCaption` are the two callers that turn this one
    /// number into a box on whichever side `isMirrored` picks.
    func laptopControlGroupTrailingX(containerSize: CGSize, safeAreaBottom: CGFloat) -> CGFloat? {
        guard let bottom = laptopBottomRect(containerSize: containerSize, safeAreaBottom: safeAreaBottom) else { return nil }
        let band = Self.laptopBand(bottom, 0)
        return isMirrored ? band.minX + Self.pagePad : band.maxX - Self.pagePad
    }

    /// The horizontal action rail, centred in band 1: the same five
    /// buttons `actionRail`/`actionRailColumn` already draw everywhere
    /// else, this time in a row — 6 slots (Keep, Share, Album, Shrink,
    /// Delete, then the chin) evenly distributed across the deck's own
    /// live width, inset by `pagePad` on each side: "x positions …
    /// from even distribution of the 5 rail items + chin" (owner
    /// re-adapt). `hairlineX`/`hairlineY` mark the one gap this row
    /// still needs a divider for — between Delete and the chin —
    /// clamped by the caller to `Rail.itemHeight` tall, "a SHORT
    /// divider only as tall as the rail row," not the whole deck.
    /// `FeedPageContent` renders the five buttons and the hairline
    /// (per-page, like every other pose's rail); this file's own
    /// `railAlignedChinCenter` reads `chinCenter` to anchor
    /// `ChinNavigation`'s own collapsed switcher here, the same
    /// position-based path pose 5's rail column already uses.
    /// Mirrored-layout round: "chin bottom-leading … rail order
    /// reverses, builds from the chin downward" (the owner's own 1V-
    /// upside-down description, the same principle applied here) —
    /// the chin moves from slot 5 (trailing) to slot 0 (leading), and
    /// the five rail buttons shift into slots 1–5, keeping their own
    /// Keep→Delete order: the row still "builds away from the chin,"
    /// just from the other end.
    func laptopRailRow(containerSize: CGSize, safeAreaBottom: CGFloat) -> (centers: [CGPoint], hairlineX: CGFloat, hairlineY: CGFloat, chinCenter: CGPoint)? {
        guard let bottom = laptopBottomRect(containerSize: containerSize, safeAreaBottom: safeAreaBottom) else { return nil }
        let band = Self.laptopBand(bottom, 1)
        let y = band.midY
        let leading = band.minX + Self.pagePad
        let usable = max(0, band.width - Self.pagePad * 2)
        let slot = usable / 6
        let xs = (0..<6).map { leading + (CGFloat($0) + 0.5) * slot }
        if isMirrored {
            let centers = xs.suffix(5).map { CGPoint(x: $0, y: y) }
            let chinCenter = CGPoint(x: xs[0], y: y)
            return (centers: Array(centers), hairlineX: (xs[0] + xs[1]) / 2, hairlineY: y, chinCenter: chinCenter)
        }
        let centers = xs.prefix(5).map { CGPoint(x: $0, y: y) }
        let chinCenter = CGPoint(x: xs[5], y: y)
        return (centers: Array(centers), hairlineX: (xs[4] + xs[5]) / 2, hairlineY: y, chinCenter: chinCenter)
    }

    /// Previous/Next pill geometry, centred in band 2: two slots of
    /// the deck's own live width, each inset by `pagePad` from the
    /// deck's own edge and from each other, mirroring
    /// `laptopRailRow`'s own even-distribution approach rather than a
    /// fixed pill size. `FeedView.laptopDeckControls` mounts the two
    /// pills here; §3d's own `retreatToPreviousPage(from:)`/
    /// `advanceToNextPage(from:)` page the feed.
    func laptopPagerCenters(containerSize: CGSize, safeAreaBottom: CGFloat) -> (previous: CGPoint, next: CGPoint, width: CGFloat, height: CGFloat)? {
        guard let bottom = laptopBottomRect(containerSize: containerSize, safeAreaBottom: safeAreaBottom) else { return nil }
        let band = Self.laptopBand(bottom, 2)
        let y = band.midY
        let width = max(0, (band.width - Self.pagePad * 3) / 2)
        let height = min(60, max(44, band.height - 12))
        return (
            previous: CGPoint(x: band.minX + Self.pagePad + width / 2, y: y),
            next: CGPoint(x: band.maxX - Self.pagePad - width / 2, y: y),
            width: width,
            height: height
        )
    }

    // MARK: - Chin anchor (R5 chin pass; review follow-up: shared by every host)
    //
    // `ChinNavigation`'s own `railAlignedCenter`/`railAlignedTopClamp`
    // parameters used to be solved once, in `FeedView` alone — the only
    // host with a rail to align against. Review follow-up: `PhotoFeedView`
    // and `SettingsView` need the SAME point, or the chin jumps between
    // tabs on the Duo (owner report). Solving it three times, once per
    // host, is exactly the "parallel copies of the same formula drift
    // apart" risk this file's own header already warns every new branch
    // away from — the pose-5 ring-x rounds earlier in this file are a
    // real instance of that risk, not a hypothetical one. One function
    // here, read by all three hosts with their own live
    // `safeAreaTop`/`safeAreaBottom`/`containerSize`, is what keeps the
    // chin at one point.

    /// The owner's own measured 8pt the Home Screen's Search button sits
    /// inside the real bottom safe-area inset line, on the closed
    /// display — `railAlignedChinCenter`'s own `y` is built from this.
    static let chinBottomInset: CGFloat = 8

    /// This frame's rail-aligned chin centre, or `nil` on every pose —
    /// and every regular iPhone — that still uses `ChinNavigation`'s own
    /// plain bottom-trailing anchor instead.
    ///
    /// **Pose 6 (`.laptop`)**: `laptopRailRow`'s own `chinCenter` —
    /// "chin collapsed centre (600, v 236) via `railAlignedCenter`"
    /// (`design/duo/duo_build_spec.md` §2.6).
    ///
    /// **1V (`.closed`), pose 3 (`.openWide`), pose 4/4W (`.book`), and
    /// pose 5 (`.openTall`)** share one rule (owner, R5 chin pass: "the
    /// alignment of the tab switcher should be like it is on 1V right
    /// now … for 3, 5, 1, 4"). `x` is `ringCenteredColumnX` — the SAME x
    /// the rail items use (3/4's own bar column, when the bar is on; 5's
    /// own computed column; 1V's own bar column), never a second guess
    /// at it, so the chin can never drift from the rail/ring it sits
    /// beside. `y` is 1V's own original rule, applied to all four: the
    /// COLLAPSED chin's own bottom sits where the Home Screen's own
    /// Search button sits, `chinBottomInset` inside the real bottom
    /// safe-area inset line.
    ///
    /// Review follow-up: floored at `chinBottomInset` itself, not the
    /// plain `containerSize.height - safeAreaBottom + chinBottomInset`
    /// 1V/5 used alone — a pose whose own bottom inset is SMALLER than
    /// `chinBottomInset` (3/4/4W's own book/wide window, well under the
    /// closed display's 34pt) would otherwise compute a bottom PAST the
    /// window's own true edge: at a zero inset, the un-floored formula
    /// gives `H - 0 + 8`, 8pt off the bottom of the screen.
    /// `max(safeAreaBottom - chinBottomInset, chinBottomInset)` is never
    /// less than `chinBottomInset` itself, so the chin's own bottom edge
    /// stays at least that far inside the real bottom edge at any inset,
    /// including zero — "it never leaves the screen." This reduces to
    /// the old, un-floored formula exactly once `safeAreaBottom >= 2 *
    /// chinBottomInset` (16pt here), which every closed/open-tall
    /// reading this has been measured against so far already clears —
    /// so 1V and pose 5 are unaffected by this change.
    func railAlignedChinCenter(safeAreaTop: CGFloat, safeAreaBottom: CGFloat, containerSize: CGSize) -> CGPoint? {
        if pose == .laptop {
            return laptopRailRow(containerSize: containerSize, safeAreaBottom: safeAreaBottom)?.chinCenter
        }
        guard pose == .closed || pose == .openWide || pose == .book || pose == .openTall,
              let centerX = ringCenteredColumnX(containerSize: containerSize, safeAreaTop: safeAreaTop)
        else { return nil }
        let bottom = containerSize.height - max(safeAreaBottom - Self.chinBottomInset, Self.chinBottomInset)
        let centerY = bottom - Rail.hit / 2
        return CGPoint(x: centerX, y: centerY)
    }

    /// Pose 6 (`.laptop`) only: the fold's own `y` — `laptopBottomRect`'s
    /// own `minY` (`division.maxY`) — for `ChinNavigation
    /// .railAlignedTopClamp`, so the EXPANDED capsule's own top edge can
    /// never rise above the fold, however little clearance a short
    /// window leaves between it and `railAlignedChinCenter`'s own `y`.
    /// `nil` everywhere else — 1V and pose 5 have no fold to clamp
    /// against, and `ChinNavigation` only ever reads this where
    /// `railAlignedChinCenter` is also non-nil.
    func railAlignedTopClamp(containerSize: CGSize, safeAreaBottom: CGFloat) -> CGFloat? {
        guard pose == .laptop else { return nil }
        return laptopBottomRect(containerSize: containerSize, safeAreaBottom: safeAreaBottom)?.minY
    }
}

/// Reads `EnvironmentValues.toolbarVerticalEdge` and reports it through
/// `onChange`, instead of exposing it as an `@Environment` property on
/// the host view directly.
///
/// Swift refuses `@available` on a stored property, and
/// `toolbarVerticalEdge` only exists from iOS 27.1 — so a host view
/// whose own deployment target is lower (every view in this app) cannot
/// declare `@Environment(\.toolbarVerticalEdge)` as one of its own
/// properties. Confining the read to this small view, which is itself
/// `@available`-marked, sidesteps that: mount it only inside an
/// `if #available(iOS 27.1, *)` branch, and it is simply never
/// instantiated — hence never type-checked against the environment key
/// it reads — on an older OS.
///
/// Zero-size and non-interactive, the same shape every DEBUG probe
/// elsewhere in this app already uses for an invisible reader.
@available(iOS 27.1, *)
struct ToolbarVerticalEdgeReader: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    let onChange: (HorizontalEdge?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: edge, initial: true) { _, newValue in onChange(newValue) }
    }
}

/// The hinge's own equivalent of `ToolbarVerticalEdgeReader`: a
/// zero-size, non-interactive view whose only job is converting
/// `onHingeChange`'s SDK types into this file's plain, always-available
/// `DuoHingeStatus`/`Double` pair, and reporting them up to a host
/// view's own `@State`.
///
/// `onHingeChange(isEnabled:_:)` has no `initial:` parameter (confirmed
/// against `SwiftUICore.swiftinterface`), unlike `.onChange(of:initial:)`
/// above — so, unlike `toolbarVerticalEdge`, the first real value may
/// arrive late, after the view mounts, rather than on the first frame.
/// The classifier (`DuoLayout.classify`) only ever needs the hinge for
/// the tent pose, which requires a `.partial` hinge AND a landscape
/// device stance together — never true at launch — so a hinge reading
/// that is still `nil` for the first frame or two costs nothing there;
/// every other pose decides without it. Step 1's own build-list check
/// is exactly this: note on the sim whether `onHingeChange` fires at
/// mount at all.
@available(iOS 27.1, *)
struct HingeReader: View {
    let onChange: (DuoHingeStatus?, Double?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onHingeChange { _, new in
                onChange(new.hinge.map { Self.mirror($0.status) }, new.hinge?.angle.degrees)
            }
    }

    /// `DeviceHinge.Status` is a struct, not a Swift enum (three static
    /// members, `.closed`/`.partiallyOpen`/`.fullyOpen`) — so a `switch`
    /// over it cannot be exhaustive from the compiler's own point of
    /// view. This reads the two cases `DuoLayout.classify` actually
    /// distinguishes (`.closed`, `.full`) and folds anything else,
    /// including `.partiallyOpen`, into `.partial` — the correct
    /// default, since partial is the only status with more than one
    /// member in practice.
    private static func mirror(_ status: DeviceHinge.Status) -> DuoHingeStatus {
        if status == .closed { return .closed }
        if status == .fullyOpen { return .full }
        return .partial
    }
}

// MARK: - DEBUG alignment guides (`-cloudfull-duo-guides`)
//
// Owner, direct: "these lines are useful! can you add more so we can
// use them as conversation references?" This section is the shared
// plumbing every production view uses to report its own real rendered
// frame to `FeedView.duoGuidesOverlay`'s own collector — the same "a
// real view reports its own geometry up" pattern `DuoRightGridBottomKey`
// already uses for the right page's grid bottom, extended to every
// element a pose fix might ever need to talk about. A real frame, not
// a second derivation of the same layout math, is the whole point:
// the pose 5 ring-x round found a guide line that LOOKED right by eye
// but was wrong by 8pt, because it was still redrawing the computed
// number rather than measuring the real pixels. Marking the real view
// instead removes that whole class of drift.

/// True only behind `-cloudfull-duo-guides`, and only in a DEBUG
/// build — the one flag `FeedView`'s own guide overlay and every
/// `.duoGuideMark` call site across the app share, so there is a
/// single source of truth instead of each file re-deriving its own
/// bare launch-argument check. `false`, unconditionally, outside
/// DEBUG: this must never read `true` in a shipped build regardless
/// of what arguments a shipped binary happens to be launched with.
enum DuoGuides {
    #if DEBUG
    static let isOn = ProcessInfo.processInfo.arguments.contains("-cloudfull-duo-guides")
    #else
    static let isOn = false
    #endif
}

/// True only behind `-cloudfull-duo-guide-colours`, and only in a
/// DEBUG build — same reasoning as `DuoGuides` above, a separate flag
/// rather than folding into it. Owner: "turn OFF the red/blue colour
/// fill, keep all other guide lines" — `-cloudfull-duo-guides` alone
/// now goes back to lines/labels only, plain black background, the
/// same as before `DuoGuideColouredBackground` existed; this SECOND
/// flag is what that background itself gates on, on top of
/// `DuoGuides.isOn` (both must be on — this flag alone, without
/// `-cloudfull-duo-guides`, is never read; see
/// `FeedView.pagerBackground`'s own two-flag check). `false`,
/// unconditionally, outside DEBUG, same guarantee as `DuoGuides`.
enum DuoGuideColours {
    #if DEBUG
    static let isOn = ProcessInfo.processInfo.arguments.contains("-cloudfull-duo-guide-colours")
    #else
    static let isOn = false
    #endif
}

/// True only behind `-cloudfull-force-mirror`, and only in a DEBUG
/// build — same reasoning as `DuoGuides`/`DuoGuideColours` above.
/// Mirrored-layout round: forces `DuoLayout.isMirrored` on for every
/// frame, regardless of `toolbarVerticalEdge` or the owner's own
/// `leftHandedControls` setting — see `DuoLayout.current(...)`'s own
/// comment. Lets every pose's own mirrored geometry be checked on the
/// Duo sim directly, with no real leading-bar (Split View-left)
/// configuration to switch into. `false`, unconditionally, outside
/// DEBUG, same guarantee as the other two flags — this must never
/// silently mirror a shipped build's layout.
enum DuoForceMirror {
    #if DEBUG
    static let isOn = ProcessInfo.processInfo.arguments.contains("-cloudfull-force-mirror")
    #else
    static let isOn = false
    #endif
}

#if DEBUG
/// One labeled rect this DEBUG session wants outlined on screen —
/// `.duoGuideMark`'s own payload. `id` is the element's own name
/// ("stage", "rail.keep", "grid.date", …), shown in the overlay's own
/// label alongside the rect's live x, y, w, h.
struct DuoGuideMark: Equatable {
    let id: String
    let rect: CGRect
    let color: Color
}

/// Collects every `.duoGuideMark` reporting view's own frame this
/// frame. `FeedView` reads this through a single `.onPreferenceChange`
/// on its outer `ZStack`, the same way it already reads
/// `DuoRightGridBottomKey` — preferences bubble up through the whole
/// view tree on their own, so a mark set deep inside `PlayerPageView`
/// or `DuoRightPage` reaches that one collector with no manual
/// plumbing in between.
struct DuoGuideMarksKey: PreferenceKey {
    static var defaultValue: [DuoGuideMark] = []
    static func reduce(value: inout [DuoGuideMark], nextValue: () -> [DuoGuideMark]) {
        value.append(contentsOf: nextValue())
    }
}

/// `-cloudfull-duo-guides` only — see `DuoLayout.debugStageArea`'s own
/// comment for what red/blue mean and why. `FeedView.pagerBackground`
/// and `PlayerPageView`'s own per-page background both mount this
/// (replacing their own plain `Color.black`) so the SAME two colours
/// show at both layers, one shared definition rather than two that
/// could drift apart.
struct DuoGuideColouredBackground: View {
    let duoLayout: DuoLayout
    let safeAreaTop: CGFloat
    let containerSize: CGSize
    /// See `DuoLayout.debugStageArea`'s own `isWideVideo` doc —
    /// `FeedView.pagerBackground`'s own pager-level call leaves this at
    /// its default `false`; `PlayerPageView`'s own per-page call passes
    /// its real `useVideoAspect`.
    var isWideVideo: Bool = false

    var body: some View {
        ZStack {
            Color.blue.opacity(0.55)
            if let stageArea = duoLayout.debugStageArea(containerSize: containerSize, safeAreaTop: safeAreaTop, isWideVideo: isWideVideo) {
                Color.red.opacity(0.55)
                    .frame(width: stageArea.width, height: stageArea.height)
                    .position(x: stageArea.midX, y: stageArea.midY)
            }
            if let division = duoLayout.division {
                Color(white: 0.4)
                    .frame(width: division.width, height: division.height)
                    .position(x: division.midX, y: division.midY)
            }
        }
    }
}
#endif

extension View {
    /// Marks this view's own real rendered frame, in window/`.global`
    /// space — the same space `occlusion`/`division`/`railColumnRect`
    /// and `duoRightGridBottomY` already read in, confirmed identical
    /// for this app's one full-screen scene — for the DEBUG
    /// alignment-guide overlay.
    ///
    /// `active` lets a per-PAGE call site (a pager can keep more than
    /// one `PlayerPageView`/`FeedPageContent` mounted at once) report
    /// only while it is the centred page — pass `isActive`, the same
    /// guard every other per-page side effect in this app already
    /// uses — so an off-screen neighbour never draws a second, stale
    /// "stage" or "caption" box. Global, once-per-screen elements
    /// (the chin, the top row, the deck) need no such guard and
    /// default to `true`.
    ///
    /// A true no-op outside DEBUG, and a no-op at runtime whenever
    /// `DuoGuides.isOn`/`active` is false — safe to call at any
    /// production call site in either configuration.
    @ViewBuilder
    func duoGuideMark(_ name: String, color: Color, active: Bool = true) -> some View {
        #if DEBUG
        if DuoGuides.isOn && active {
            self.background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DuoGuideMarksKey.self,
                        value: [DuoGuideMark(id: name, rect: proxy.frame(in: .global), color: color)]
                    )
                }
            )
        } else {
            self
        }
        #else
        self
        #endif
    }
}
