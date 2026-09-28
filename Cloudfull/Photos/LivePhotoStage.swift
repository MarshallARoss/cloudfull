//
//  LivePhotoStage.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import PhotosUI
import Photos
import AVFoundation
import UIKit
import os

/// The three states a Live post can be in. Also the suffix of the DEBUG
/// `photo_live_state_<playing|key|off>` probe, rendered by `PhotoFeedView`
/// for the current post only. Do not rename a case without updating that
/// probe.
enum LivePhotoPlaybackState: String, Sendable {
    case playing, key, off
}

/// The paired-movie fetch and playback state for one Live post, used to
/// drive the loading ring in `PhotoPostView`.
///
/// `.fetching`'s `progress` is nil until the first progress callback
/// arrives. After that, it is the paired-movie download fraction,
/// throttled to 2% steps by `LiveProgressThrottle`. The ring falls back
/// to the same indeterminate sweep it uses for an unknown still download.
enum LiveReadiness: Equatable, Sendable {
    case idle
    case fetching(progress: Double?)
    case ready
    case playing
}

/// The view this stage mounts: a `PHLivePhotoView` draws the key photo and
/// the Live badge, with a bare `AVPlayerLayer` hovering over it, transparent
/// at rest.
///
/// A second layer exists because `PHLivePhotoView` mutes its own playback
/// whenever the ringer switch is off, with no way to override it. An
/// `AVPlayer` has no such rule: it obeys the app's audio session category,
/// the same way the video rail plays through the ringer switch
/// (`PlayerHolder`, Cloudfull/Feed/PlayerPageView.swift). A Live-ON play
/// renders the Live Photo's paired movie through this layer instead of
/// asking `PHLivePhotoView` to play it.
///
/// `PHLivePhotoView` stays mounted rather than being dropped. It draws the
/// key photo at the exact frame and quality the feed already shows, and the
/// still image must always be visible.
final class LiveStageView: UIView {
    let livePhotoView = PHLivePhotoView()
    /// Above `livePhotoView`, with `opacity == 0` at rest. Non-zero only
    /// while the paired movie is on screen — see
    /// `LivePhotoStage.Coordinator.applyStagePresentation`.
    ///
    /// Built lazily, on the first play that needs it (`ensurePlayerLayer`),
    /// not at mount. `AVPlayerLayer()` is an AVFoundation object, and
    /// `PhotoPostView.photoArea` mounts a stage for the current post, its
    /// neighbors, and anything in the center band, so most mounted rows
    /// never play. A row that never plays never touches AVFoundation.
    private(set) var playerLayer: AVPlayerLayer?
    /// The last size `layoutSubviews` applied. A scrolling `LazyVStack` lays
    /// out its rows every frame at the same size, so a compare-and-return
    /// handles every pass after the first.
    private var lastLaidOutSize: CGSize?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // Live playback scales both layers up by `bloomScale`. Clip to
        // bounds so the scaled image does not cover the header and the
        // actions row.
        clipsToBounds = true
        livePhotoView.contentMode = .scaleAspectFit
        livePhotoView.backgroundColor = .clear
        // Must match `Coordinator.isMuted`'s initial value. The
        // coordinator writes `isMuted` only when the flag changes (see
        // `Coordinator.update`). If the view started unmuted, it would
        // stay unmuted, and a Live-OFF post would play sound.
        livePhotoView.isMuted = true
        addSubview(livePhotoView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Builds the movie layer on demand. See `playerLayer`. Main thread
    /// only, since it joins a layer tree, and at most once per row.
    func ensurePlayerLayer() -> AVPlayerLayer {
        if let playerLayer { return playerLayer }
        let created = AVPlayerLayer()
        // `.resizeAspect` matches `PHLivePhotoView`'s `.scaleAspectFit`, so
        // the movie lands on the same pixels the still occupied. The
        // cross-fade is a fade only, never a nudge or a resize.
        created.videoGravity = .resizeAspect
        created.opacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        created.bounds = CGRect(origin: .zero, size: bounds.size)
        created.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        layer.addSublayer(created)
        playerLayer = created
        return created
    }

    /// Uses `bounds` and `center`/`position`, never `frame`. Setting `frame`
    /// on a view or layer with a non-identity transform is undefined, and
    /// both layers carry one during the bloom.
    override func layoutSubviews() {
        super.layoutSubviews()
        // `layoutSubviews` runs on every layout pass of a moving
        // `LazyVStack`. A row's size changes only on rotation or a delete
        // collapse, so the assignments below are per-frame waste unless the
        // size actually changed.
        let size = bounds.size
        guard size != lastLaidOutSize else { return }
        lastLaidOutSize = size
        // Disables implicit animation on the bounds change: a row resizing
        // under a scroll must not drag either layer along behind it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        livePhotoView.bounds = CGRect(origin: .zero, size: size)
        livePhotoView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        if let playerLayer {
            playerLayer.bounds = CGRect(origin: .zero, size: size)
            playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
    }
}

/// A `PHLivePhotoView` (PhotosUI) for the key photo, with an `AVPlayer` over
/// the top for the motion. Plays once when `playNonce` changes, then
/// returns to the key photo. It never loops. A single tap replays once.
///
/// `isMuted` doubles as the Live on/off flag end to end. Live ON means
/// unmuted; Live OFF means muted. The idle state this view reports after a
/// play finishes, or after loading with no play requested, is `.key` when
/// `isMuted == false` and `.off` when `isMuted == true`. The caller never
/// passes Live-on/off as a separate flag.
///
/// `isMuted` also picks the playback engine. Live ON (`isMuted == false`)
/// plays the paired movie through `AVPlayer`, so sound plays even with the
/// ringer switch off. Live OFF (`isMuted == true`) uses
/// `PHLivePhotoView.startPlayback(with: .full)`: there is no audio to
/// preserve, the motion is already correct, and a muted play must stay
/// instant, with no resource write ahead of it.
struct LivePhotoStage: UIViewRepresentable {
    let assetID: String
    let targetSize: CGSize
    let isMuted: Bool
    /// Bumped to request one full playthrough. 0 means no play has happened
    /// yet: the initial mount never autoplays on its own. `PhotoPostView`
    /// bumps this once its band-dwell and Live-on conditions are met, and
    /// once per tap.
    let playNonce: Int
    /// "band" or "tap": which caller bumped `playNonce`, current at the
    /// instant it changed. Used for the deferred-play band check, the
    /// scroll-idle wait and band re-check in `startMoviePlayback` for
    /// "band", the `Usage.shared.livePlayed(byTap:)` count, and the
    /// `live_play_<reason>` log. See `pendingPlayReason`.
    let playReason: String
    /// Bumped when the post leaves the center band. Stops playback, drops
    /// a pending play, and cancels a paired-movie fetch. 0 means no stop
    /// has been requested.
    let stopNonce: Int
    /// True exactly when `PhotoPostView.isInCenterBand` is, current on
    /// every render. A deferred autoplay checks this when its fetch
    /// completes. The `stopNonce` change fires only once, when the post
    /// leaves. Tap-to-replay never gates on this. See `pendingPlayReason`'s
    /// own doc comment.
    let isInBand: Bool
    let onStateChange: (LivePhotoPlaybackState) -> Void
    /// Reports the paired-movie fetch and playback state, on the main
    /// actor. See `LiveReadiness`.
    let onReadinessChange: (LiveReadiness) -> Void

    func makeUIView(context: Context) -> LiveStageView {
        // Arms the paired-movie cache's memory-warning purge the first time
        // any Live post mounts. Runs once per process. See
        // `LivePairedMovieStore`.
        LivePairedMovieStore.armMemoryWarningPurge()
        let view = LiveStageView()
        view.livePhotoView.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: LiveStageView, context: Context) {
        context.coordinator.update(
            view: uiView,
            assetID: assetID,
            targetSize: targetSize,
            playNonce: playNonce,
            playReason: playReason,
            stopNonce: stopNonce,
            isMuted: isMuted,
            isInBand: isInBand,
            onStateChange: onStateChange,
            onReadinessChange: onReadinessChange
        )
    }

    static func dismantleUIView(_ uiView: LiveStageView, coordinator: Coordinator) {
        coordinator.teardown()
        // Releases the decoded `PHLivePhoto` the instant the row leaves the
        // `LazyVStack`. Without this, a row scrolled out of the near window
        // (see `PhotoPostView.isNear`) would keep its object alive for as
        // long as SwiftUI kept the now-hidden `PHLivePhotoView` around. The
        // movie layer is detached for the same reason: an `AVPlayerLayer`
        // still pointing at a player holds a decode pipeline open.
        uiView.livePhotoView.livePhoto = nil
        // A row that never played has no movie layer, so this returns
        // with no AVFoundation work. A row that played must clear the
        // layer's player on the main thread.
        guard let playerLayer = uiView.playerLayer else { return }
        wdMark("liveDrop")
        playerLayer.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        private var currentAssetID: String?
        private var lastHandledNonce = 0
        private var lastHandledStopNonce = 0
        private var isMuted = true
        private var isPlaying = false
        /// Current at the instant of the most recent `update(...)` call: the
        /// freshness check a deferred play needs. See `pendingPlay`.
        private var isInBand = false
        private var loadTask: Task<Void, Never>?
        /// Weak so the coordinator does not keep the view alive.
        /// `LivePlaybackArbiter` calls back outside `update`, which is the
        /// only place `view` is passed in.
        private weak var currentView: LiveStageView?
        /// True while a `PHLivePhoto` fetch for `currentAssetID` is actually
        /// in flight. `loadTask` stays non-nil forever once any fetch has
        /// started, so this is the real "is one running right now" signal
        /// `update(...)` needs below.
        private var isLoading = false
        /// Remembers a play request (`playNonce` bump) that arrives before
        /// the `PHLivePhoto` has finished loading. The in-flight fetch's own
        /// completion (`startLoad`) checks this flag and plays the instant
        /// the photo lands, instead of starting a second, competing fetch.
        ///
        /// `stopNonce` clears this the moment the post leaves the center
        /// band. As a second guard against the fetch landing in the same
        /// instant the post leaves, `startLoad`'s completion re-checks
        /// `isInBand` fresh for a "band"-reasoned pending play before
        /// honoring it. A "tap"-reasoned pending play is never gated on band
        /// membership: replaying a Live photo by tapping it works whether
        /// Live is on or off, and off-band, so it must not be dropped just
        /// because the post is not centered.
        private var pendingPlay = false
        /// "band" or "tap", captured from `playReason` at the moment
        /// `pendingPlay` is set. The deferred completion needs to know which
        /// check to hold the eventual play to. See `pendingPlay`.
        private var pendingPlayReason = "band"
        private var onStateChange: ((LivePhotoPlaybackState) -> Void)?
        /// Set alongside `onStateChange` in `update(...)`.
        private var onReadinessChange: ((LiveReadiness) -> Void)?

        // MARK: - Paired-movie playback state

        /// Created lazily, on this coordinator's first Live-ON play, and
        /// reused by every later play of the same row. Most mounted rows
        /// never play at all, so an `AVPlayer` per row is unneeded cost.
        private var moviePlayer: AVPlayer?
        /// True once `moviePlayer` has been handed to the stage's
        /// `AVPlayerLayer`. That assignment happens on the main thread, once
        /// per player, and is never touched again mid-life: re-assigning
        /// even the identical player makes the layer tear its video renderer
        /// down and rebuild it.
        private var didAttachPlayerToLayer = false
        /// The item currently attached to `moviePlayer`, and the identity
        /// token every deferred work-queue block checks before it touches
        /// the player. Each play builds a fresh item and tears its own item
        /// down, so `moviePlayer.currentItem === item` answers "is the thing
        /// I was scheduled for still the thing playing".
        ///
        /// Without that check, a fade-out's delayed
        /// `replaceCurrentItem(with: nil)`, armed when a post leaves the
        /// band, can land after a tap replay the user started in the
        /// meantime. It would kill the audio and leave an opaque, blank
        /// movie layer over the still, with `isPlaying` stuck true and no
        /// end notification possible.
        private var movieItem: AVPlayerItem?
        private var movieEndObserver: NSObjectProtocol?
        private var movieFailObserver: NSObjectProtocol?
        private var movieStatusObservation: NSKeyValueObservation?
        /// Armed at fade-in, disarmed at end. A Live Photo's paired movie
        /// runs a couple of seconds. Anything still "playing" after ten
        /// seconds is an item that failed with no notification. The row
        /// must not announce `.playing` forever.
        private var movieWatchdogTask: Task<Void, Never>?
        /// True from `play()` until the movie actually starts, is abandoned,
        /// or falls back. The paired-video write can take seconds on an
        /// iCloud asset, and during that window this row plays nothing. See
        /// `play()` for why the arbiter claim and the `.playing`
        /// announcement wait for `beginMovieFadeIn`.
        private var wantsMoviePlay = false
        /// Monotonic. Bumped by every new play request. Every async hop
        /// carries the value it started with and gives up if it no longer
        /// matches, so a slow fetch for one play can never drive a later
        /// one.
        private var playEpoch = 0
        /// The asset this row currently holds a `LivePairedMovieStore` pin
        /// for, if any. Tracked separately from `currentAssetID` because a
        /// recycled row changes `currentAssetID` before it tears the old
        /// movie down. Releasing "the current asset's" pin there would
        /// release the wrong one and leak the old asset's file forever.
        private var pinnedMovieAssetID: String?
        /// The asset whose paired movie reached `.ready` in this row. Once a
        /// movie has played, ending the play must report `.ready` (cached,
        /// playable again) rather than `.idle`, which means "not fetched
        /// yet" and puts the ring back on screen. Cleared when the row shows
        /// a different asset or is torn down.
        private var readyMovieAssetID: String?
        /// The in-flight "fetch the paired movie, activate the session,
        /// attach and play" pipeline, including the `setActive` await.
        /// Cancelled by every path that can end playback before it
        /// resolves.
        private var moviePlayTask: Task<Void, Never>?
        /// True from the instant the movie layer starts fading in until the
        /// instant it starts fading back out. Distinguishes "this row is
        /// playing through `AVPlayer`" from "this row is playing muted
        /// through `PHLivePhotoView`", which need different stop paths.
        private var isMoviePlaying = false
        /// Watches `AVPlayerLayer.isReadyForDisplay` so the cross-fade only
        /// starts once the layer actually has a video frame to cross-fade
        /// to. Without it, the fade runs against an empty layer and the
        /// movie appears as a hard cut the instant its first frame lands.
        private var readyObservation: NSKeyValueObservation?
        /// Backstop for `readyObservation`. See `waitForFirstFrame`.
        private var readyFallbackTask: Task<Void, Never>?
        /// Never assigned. The `setActive` await actually runs inside
        /// `moviePlayTask`, and cancelling `moviePlayTask` abandons it.
        /// Every stop path also cancels this field, which is a harmless
        /// no-op.
        private var audioActivationTask: Task<Void, Never>?

        /// The cross-fade duration, each way, matching Apple's own Live
        /// playback transition.
        private static let fadeDuration: CFTimeInterval = 0.35
        /// The bloom scale. Apple's Live playback scales the frame up
        /// about 3% during motion. Without the scale, the change looks
        /// like a cut to a video. 3% is the largest value that never shows
        /// as a crop on a post whose edges carry detail.
        private static let bloomScale: CGFloat = 1.03

        func update(
            view: LiveStageView,
            assetID: String,
            targetSize: CGSize,
            playNonce: Int,
            playReason: String,
            stopNonce: Int,
            isMuted: Bool,
            isInBand: Bool,
            onStateChange: @escaping (LivePhotoPlaybackState) -> Void,
            onReadinessChange: @escaping (LiveReadiness) -> Void
        ) {
            self.onStateChange = onStateChange
            self.onReadinessChange = onReadinessChange
            self.currentView = view
            self.isInBand = isInBand
            let mutedChanged = isMuted != self.isMuted
            self.isMuted = isMuted
            // `PHLivePhotoView.isMuted` is a PhotosUI setter that reaches
            // that view's own AVFoundation plumbing. Writing it only when
            // the flag changes avoids touching AVFoundation on every body
            // pass of the photo feed, for every mounted Live row.
            if mutedChanged { view.livePhotoView.isMuted = isMuted }

            // Most calls change nothing. Return early when the asset, both
            // nonces, and the mute flag are unchanged.
            let assetChanged = assetID != currentAssetID
            let stopRequested = stopNonce != lastHandledStopNonce && stopNonce > 0
            let playRequested = playNonce != lastHandledNonce && playNonce > 0
            guard assetChanged || stopRequested || playRequested || mutedChanged else { return }
            // Do not move this mark above the guard. `MainThreadWatchdog.mark`
            // keeps only the last three labels, and a mark on every body
            // pass hides the others. Past the guard, this fires only on a
            // real event.
            wdMark("liveUpdate")

            if assetChanged {
                readyMovieAssetID = nil
                // A new asset under this view: a recycled row, or the
                // post's own asset changed under it. Reset everything and
                // load the still key photo only. Never carry a stale nonce
                // from a previous asset into a play or stop here.
                let previousAssetID = currentAssetID
                currentAssetID = assetID
                lastHandledNonce = playNonce
                lastHandledStopNonce = stopNonce
                isPlaying = false
                // The recycled row's movie must go before the new asset's
                // still is even requested, or the previous post's video sits
                // visible over the new post's key photo.
                detachMovie(view: view, animated: false)
                dropPendingPlay(reason: "recycled", assetID: previousAssetID)
                isLoading = false
                view.livePhotoView.livePhoto = nil
                if let previousAssetID { LivePlaybackArbiter.shared.release(assetID: previousAssetID) }
                // Starts the fetch the instant this stage mounts, which is
                // the instant a post enters the center band, even when it
                // is not near the current post. A post with no
                // `LivePhotoStage` mounted has no coordinator to receive the
                // band-dwell's `playNonce` bump, so starting here keeps that
                // play from being lost.
                startLoad(view: view, assetID: assetID, targetSize: targetSize, playOnceReady: false, playReason: playReason)
                return
            }

            // A stop always wins over a same-update play request: the post
            // already left the center band, so this never falls through to
            // the `playNonce` handling below.
            if stopNonce != lastHandledStopNonce, stopNonce > 0 {
                lastHandledStopNonce = stopNonce
                dropPendingPlay(reason: "left_band", assetID: assetID)
                #if DEBUG
                Self.logLive("live_stop_\(assetID)")
                #endif
                // Cancel these even when `isPlaying` is false. A Live-ON
                // play is not playing while its paired-video write runs,
                // and on iCloud that write can take seconds.
                audioActivationTask?.cancel()
                cancelPendingMoviePlay()
                if isPlaying {
                    if isMoviePlaying {
                        detachMovie(view: view, animated: true)
                    } else {
                        view.livePhotoView.stopPlayback()
                    }
                    isPlaying = false
                    onStateChange(isMuted ? .off : .key)
                    LivePlaybackArbiter.shared.release(assetID: assetID)
                }
                return
            }

            if playNonce != lastHandledNonce, playNonce > 0 {
                lastHandledNonce = playNonce
                if let livePhoto = view.livePhotoView.livePhoto {
                    #if DEBUG
                    Self.logLive("live_play_\(playReason)_\(assetID)")
                    #endif
                    play(view: view, livePhoto: livePhoto, assetID: assetID, reason: playReason)
                } else if isLoading {
                    // The fetch already running will play this the moment
                    // it lands. See `pendingPlay`'s own doc comment.
                    pendingPlay = true
                    pendingPlayReason = playReason
                    #if DEBUG
                    Self.logLive("live_missed_notloaded_\(assetID)")
                    #endif
                } else {
                    // No fetch has run for this asset. The mount's own
                    // `startLoad` above normally covers this; this
                    // defensive fallback starts one now and plays once it
                    // lands.
                    startLoad(view: view, assetID: assetID, targetSize: targetSize, playOnceReady: true, playReason: playReason)
                }
                return
            }

            // Live toggled OFF mid-play, on the paired-movie engine. Live
            // OFF means the key photo, still, not the clip finishing
            // quietly. Toggling OFF must stop the clip immediately, the
            // same revert-to-key path a band exit (`stopNonce`, above)
            // already uses.
            if mutedChanged, isMuted, isMoviePlaying {
                audioActivationTask?.cancel()
                cancelPendingMoviePlay()
                detachMovie(view: view, animated: true)
                isPlaying = false
                onStateChange(.off)
                LivePlaybackArbiter.shared.release(assetID: assetID)
                return
            }

            // Live toggled OFF while a play was still fetching the paired
            // movie or activating the audio session. Playback never reached
            // `isMoviePlaying`, so nothing is on screen to stop, but the
            // in-flight fetch must still be abandoned so it cannot start
            // playing after the toggle already announced this post as OFF.
            if mutedChanged, isMuted, wantsMoviePlay {
                audioActivationTask?.cancel()
                cancelPendingMoviePlay()
            }

            // Live toggled mid-rest, not mid-play: re-announce the idle
            // state under the new mute flag without a re-fetch or a replay.
            if mutedChanged, !isPlaying, view.livePhotoView.livePhoto != nil {
                onStateChange(isMuted ? .off : .key)
            }
        }

        /// The one fetch path, for both "load the key photo only" (mount,
        /// `playOnceReady == false`) and "load then play" (a nonce arrived
        /// with no fetch running yet, `playOnceReady == true`). A fetch
        /// already in flight when a nonce arrives never comes back through
        /// here. See `pendingPlay` above. This always starts a fresh
        /// PhotoKit request, so calling it twice for the same asset would
        /// restart, and delay, a download already under way.
        private func startLoad(view: LiveStageView, assetID: String, targetSize: CGSize, playOnceReady: Bool, playReason: String) {
            loadTask?.cancel()
            isLoading = true
            if playOnceReady {
                pendingPlay = true
                pendingPlayReason = playReason
            }
            // Read on the main actor, before the async fetch.
            let allowNetwork = !PhotoLibraryService.shared.isNetworkExpensiveOrConstrained
            let startedAt = Date()
            #if DEBUG
            Self.logLive("live_request_start_\(assetID)")
            #endif
            loadTask = Task { [weak self, weak view] in
                let photo = await LivePhotoLoader.request(assetID: assetID, targetSize: targetSize, allowNetwork: allowNetwork)
                guard let self, !Task.isCancelled, let view, self.currentAssetID == assetID else { return }
                self.isLoading = false
                view.livePhotoView.livePhoto = photo
                #if DEBUG
                let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                Self.logLive("live_request_done_\(ms)_\(assetID)")
                #endif
                // A pending play fires only when the photo loaded and, for
                // a "band" play, the post is still in the band. A band
                // play that is out of band logs a band drop, whether or
                // not the photo loaded.
                if self.pendingPlay {
                    let bandOK = self.pendingPlayReason != "band" || self.isInBand
                    let reason = self.pendingPlayReason
                    self.pendingPlay = false
                    if let photo, bandOK {
                        #if DEBUG
                        Self.logLive("live_play_ready_\(assetID)")
                        #endif
                        self.play(view: view, livePhoto: photo, assetID: assetID, reason: reason)
                        return
                    } else if !bandOK {
                        #if DEBUG
                        Self.logLive("live_pending_dropped_not_in_band_\(assetID)")
                        #endif
                    }
                }
                self.onStateChange?(self.isMuted ? .off : .key)
            }
        }

        /// A Live Photo plays its audio through the ringer switch, the same
        /// as video. `CloudfullApp` (`configureAudioSessionCategory`) sets
        /// the session's category once at launch (`.playback`, which
        /// ignores the silent switch); activation is deliberately deferred
        /// to the moment something is actually about to play with sound,
        /// the same split `PlayerHolder.setActive`
        /// (Cloudfull/Feed/PlayerPageView.swift) draws for video.
        /// `setActive` runs off the main thread, on this file's own serial
        /// queue.
        ///
        /// A Live-OFF play claims `LivePlaybackArbiter` at once. A
        /// Live-ON play claims it in `beginMovieFadeIn`. Claiming
        /// synchronously stops whatever other post was mid-playback: at
        /// most one Live Photo plays anywhere in the app at a time.
        ///
        /// `PHLivePhotoView` mutes its own playback whenever the ringer
        /// switch is off, regardless of the audio session's own state, and
        /// no audio-session arrangement changes that. So a Live-ON play
        /// never asks `PHLivePhotoView` to play: it hands the paired movie
        /// to an `AVPlayer` (`startMoviePlayback`), which obeys only the
        /// app's session category. A Live-OFF play keeps the
        /// `PHLivePhotoView` path exactly: there is no sound to preserve,
        /// and no resource write ahead of a muted play that must stay
        /// instant.
        ///
        /// The arbiter claim and the `.playing` announcement do not happen
        /// here for the movie engine. Claiming synchronously stops whatever
        /// other Live post is mid-playback. On an iCloud asset the
        /// paired-video write that follows can take seconds. Claiming here
        /// would stop a post that was still playing, just to show a
        /// motionless still. Both wait until `beginMovieFadeIn`,
        /// the instant the movie is actually about to be on screen.
        /// `wantsMoviePlay` carries the intent across that window so every
        /// stop path can still cancel it.
        private func play(view: LiveStageView, livePhoto: PHLivePhoto, assetID: String, reason: String) {
            // "band" means autoplay on entering the center band; "tap" means
            // the user asked for it directly.
            Task { @MainActor in Usage.shared.livePlayed(byTap: reason == "tap") }
            wdMark("livePlay")
            audioActivationTask?.cancel()
            cancelPendingMoviePlay()
            playEpoch &+= 1
            guard !isMuted else {
                claimPlayback(assetID: assetID)
                #if DEBUG
                Self.logAudioSession(engine: "livephotoview", active: false, muted: true, assetID: assetID)
                #endif
                view.livePhotoView.startPlayback(with: .full)
                return
            }
            wantsMoviePlay = true
            // From the instant a Live-ON play is requested until the movie
            // actually starts, `PhotoPostView` has nothing else on screen
            // telling the user this post is still working towards playing.
            // The ring shows that the post is fetching its movie.
            //
            // A replay, whether a tap or the band autoplay firing again
            // after the post re-enters the center band, must not announce
            // `.fetching` for a movie already on disk. That would raise
            // the ring for a play that has nothing left to fetch. A cached
            // movie is `.ready` here and the ring never rises; only a real
            // fetch reports `.fetching`. `readyMovieAssetID` covers a
            // replay on this row; `LivePairedMovieCache` covers a recycled
            // row, which has forgotten its own state.
            if readyMovieAssetID == assetID || LivePairedMovieCache.shared.isReady(assetID) {
                onReadinessChange?(.ready)
            } else {
                onReadinessChange?(.fetching(progress: nil))
            }
            startMoviePlayback(view: view, assetID: assetID, epoch: playEpoch, reason: reason)
        }

        /// The moment this row really does own playback: take the arbiter,
        /// which stops whoever held it, and announce it.
        private func claimPlayback(assetID: String) {
            LivePlaybackArbiter.shared.claim(assetID: assetID) { [weak self] in
                self?.forceStopForArbiter()
            }
            isPlaying = true
            onStateChange?(.playing)
            // Covers both the paired-movie engine's real play and its
            // no-paired-video fallback (`startMoviePlayback`'s `guard let
            // url else` branch). Both are reached only from the `!isMuted`
            // half of `play()`, so this never announces for a Live-OFF
            // (muted) play, which `PhotoPostView` never consults anyway.
            if !isMuted { onReadinessChange?(.playing) }
        }

        /// Abandons any play that has been requested but has not reached the
        /// screen yet. Safe to call unconditionally.
        ///
        /// Every path that ends a movie-engine play calls this: a stop, a
        /// toggle-off mid-fetch, a new play superseding an old one, an
        /// arbiter loss, a natural end, a failure, a recycled row,
        /// teardown. It is also the one place `LiveReadiness` falls back
        /// to `.idle`. A call here when nothing was pending or playing
        /// still re-announces `.idle`, a harmless no-op for
        /// `PhotoPostView`'s own `@State`.
        private func cancelPendingMoviePlay() {
            wantsMoviePlay = false
            moviePlayTask?.cancel()
            moviePlayTask = nil
            releaseMoviePin()
            // A movie that already reached `.ready` for this asset stays
            // ready when its play ends; only a never-fetched asset is idle.
            // `LivePairedMovieCache` covers a recycled row, whose
            // `readyMovieAssetID` is nil. Without it, the row would
            // announce `.idle` one update ahead of its own `.ready`. That
            // single `.idle` frame is enough to put the ring back on
            // screen for a cached movie.
            if let currentAssetID,
               readyMovieAssetID == currentAssetID || LivePairedMovieCache.shared.isReady(currentAssetID) {
                onReadinessChange?(.ready)
            } else {
                onReadinessChange?(.idle)
            }
        }

        /// Tells the store this row is finished with its cached file, so the
        /// file may be evicted or purged like any other. Safe to call
        /// unconditionally.
        private func releaseMoviePin() {
            guard let assetID = pinnedMovieAssetID else { return }
            pinnedMovieAssetID = nil
            Task { await LivePairedMovieStore.shared.unpin(assetID: assetID) }
        }

        /// Live ON only. Four hops, in this order:
        ///
        /// 1. the paired movie file (`LivePairedMovieStore`), a PhotoKit
        ///    resource write, cached per asset so only the first play of a
        ///    given post pays for it;
        /// 2. `AVAudioSession.setActive(true)`, an IPC to mediaserverd that
        ///    can block for hundreds of milliseconds;
        /// 3. build and attach the `AVPlayerItem`, then seek to exactly 0;
        /// 4. set the rate, then fade the layer in when it has a first
        ///    frame.
        ///
        /// Steps 1-3 run off the main thread because each can be slow.
        /// Every hop re-checks that this row still wants to play. A band
        /// autoplay whose post scrolled away mid-fetch must stop here, the
        /// same way `pendingPlay` stops in `startLoad`.
        private func startMoviePlayback(view: LiveStageView, assetID: String, epoch: Int, reason: String) {
            // Main-actor read, before the async work, the same rule
            // `startLoad` follows for the `PHLivePhoto` fetch.
            let allowNetwork = !PhotoLibraryService.shared.isNetworkExpensiveOrConstrained
            moviePlayTask = Task { [weak self, weak view] in
                // No engine work while the finger is moving, the same rule
                // the video rail follows. The paired-video write is a
                // `PHAssetResourceManager` read that competes with the
                // still fetches drawing the feed. A band autoplay waits for
                // the scroll to settle; a tap never does, since the user is
                // looking at a post they just touched.
                var allowNetwork = allowNetwork
                if reason == "band" {
                    await ScrollPhaseGate.shared.waitUntilIdle()
                    guard let self, !Task.isCancelled,
                          self.currentAssetID == assetID, self.playEpoch == epoch,
                          self.wantsMoviePlay, self.isInBand else {
                        #if DEBUG
                        Self.logLive("live_paired_gated_out_\(assetID)")
                        #endif
                        // This play is over. Every other abandon path in
                        // this method clears the intent; so does this one.
                        self?.wantsMoviePlay = false
                        return
                    }
                    // Re-reads the Wi-Fi guard after the wait. The value
                    // sampled before it is as old as the whole scroll, and a
                    // user who dropped to cellular or Low Data Mode during
                    // that scroll must not pull a paired video from iCloud
                    // on a stale `true`. This body runs on the main actor,
                    // so the re-read is as cheap as the first one.
                    allowNetwork = !PhotoLibraryService.shared.isNetworkExpensiveOrConstrained
                }
                // Logged past the gate, not at the call, so a flick that
                // only passes a post is not counted as a fetch. The
                // duration below is the write only, with no gate wait
                // folded in.
                #if DEBUG
                let startedAt = Date()
                Self.logLive("live_paired_fetch_start_\(assetID)")
                #endif
                // The paired-movie download's own fraction drives the
                // corner ring's arc instead of an endless sweep. PhotoKit
                // calls the progress handler on its own queue; hop to main
                // and publish only visible steps (2% or more) so the ring
                // never redraws per byte. Guarded on the same epoch and
                // asset as the fetch.
                let progressBox = LiveProgressThrottle()
                let url = await LivePairedMovieStore.shared.movieURL(assetID: assetID, allowNetwork: allowNetwork) { [weak self] fraction in
                    guard progressBox.shouldPublish(fraction) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.currentAssetID == assetID, self.playEpoch == epoch, self.wantsMoviePlay else { return }
                        self.onReadinessChange?(.fetching(progress: fraction))
                    }
                }
                guard let self, let view, !Task.isCancelled,
                      self.currentAssetID == assetID, self.playEpoch == epoch, self.wantsMoviePlay else {
                    await LivePairedMovieStore.shared.unpin(assetID: assetID)
                    return
                }
                if url != nil { self.pinnedMovieAssetID = assetID }
                #if DEBUG
                let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                Self.logLive(url == nil ? "live_paired_fetch_fail_\(assetID)" : "live_paired_fetch_done_\(ms)_\(assetID)")
                #endif
                guard let url else {
                    self.releaseMoviePin()
                    // No paired video for this asset, or the write failed:
                    // fall back to `PHLivePhotoView` playback so the motion
                    // still shows. Silent with the ringer off, but still
                    // better than a post that does nothing when tapped.
                    self.wantsMoviePlay = false
                    self.claimPlayback(assetID: assetID)
                    #if DEBUG
                    Self.logAudioSession(engine: "livephotoview_fallback", active: false, muted: false, assetID: assetID)
                    #endif
                    view.livePhotoView.startPlayback(with: .full)
                    return
                }
                let active = await Self.activateAudioSession()
                guard !Task.isCancelled, self.currentAssetID == assetID,
                      self.playEpoch == epoch, self.wantsMoviePlay else {
                    self.releaseMoviePin()
                    return
                }
                self.attachAndPlay(url: url, view: view, assetID: assetID, sessionActive: active, epoch: epoch)
            }
        }

        /// Hops 3 and 4 of `startMoviePlayback`. The `AVPlayer` and
        /// `AVPlayerItem` are built, attached, and seeked on
        /// `movieWorkQueue`. Only layer work (create the layer, set
        /// `player`, read `isReadyForDisplay`) and observer registration
        /// run on main.
        private func attachAndPlay(url: URL, view: LiveStageView, assetID: String, sessionActive: Bool, epoch: Int) {
            removeMovieObservers()
            let muted = isMuted
            let existingPlayer = moviePlayer
            Self.movieWorkQueue.async { [weak self, weak view] in
                // `AVPlayer()` is itself an AVFoundation call. AVFoundation's
                // internal serial work can hold a main-thread caller for
                // hundreds of milliseconds, so this is built here, on this
                // file's own serial queue, and only handed to the main
                // thread afterward.
                let player = existingPlayer ?? Self.makeMoviePlayer()
                let item = AVPlayerItem(url: url)
                // A local file has nothing to run ahead of, matching the
                // buffering policy `PlayerHolder` gives its active page.
                item.preferredForwardBufferDuration = 0
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view,
                          self.currentAssetID == assetID, self.playEpoch == epoch,
                          self.wantsMoviePlay else { return }
                    wdMark("liveItem")
                    self.moviePlayer = player
                    self.movieItem = item
                    self.movieEndObserver = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime,
                        object: item,
                        queue: .main
                    ) { [weak self] _ in
                        // `queue: .main` above guarantees this closure runs
                        // on the main queue, the same assumption
                        // `PlayerHolder.configure` makes.
                        MainActor.assumeIsolated {
                            self?.movieDidReachEnd(assetID: assetID, epoch: epoch)
                        }
                    }
                    // Watches for an item that fails outright. A failed item
                    // still calls the seek completion below, so without this
                    // the row would fade in, announce `.playing`, and then
                    // wait for an end notification that never arrives. This
                    // is reachable in practice: the file can be missing or
                    // unreadable.
                    self.movieFailObserver = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemFailedToPlayToEndTime,
                        object: item,
                        queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.movieDidFail(assetID: assetID, epoch: epoch, reason: "failed_to_end")
                        }
                    }
                    self.movieStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                        guard item.status == .failed else { return }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self?.movieDidFail(assetID: assetID, epoch: epoch, reason: "item_failed")
                            }
                        }
                    }
                    wdMark("liveLayer")
                    // The one AVFoundation call allowed, and required, on
                    // the main thread: a layer's player must be set there.
                    // Set once per player and never touched again mid-life.
                    // Re-assigning even the same player runs the layer's
                    // full detach-and-reattach of the video renderer.
                    let movieLayer = view.ensurePlayerLayer()
                    if !self.didAttachPlayerToLayer {
                        self.didAttachPlayerToLayer = true
                        movieLayer.player = player
                    }
                    // `isReadyForDisplay` belongs to the layer, which
                    // outlives every item, so on a replay or a recycled row
                    // it can still read `true` from the previous item.
                    // Captured here, before the new item attaches, so
                    // `waitForFirstFrame` knows not to trust the current
                    // value and waits for a real change instead.
                    let staleReady = movieLayer.isReadyForDisplay
                    Self.movieWorkQueue.async { [weak self, weak view] in
                        player.isMuted = muted
                        player.replaceCurrentItem(with: item)
                        // Exact zero, with no tolerance: the frame the
                        // cross-fade reveals must be the movie's first
                        // frame. The completion is also this path's
                        // readiness signal, since a seek does not report
                        // finished until the item can actually serve that
                        // time.
                        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                            Task { @MainActor [weak self, weak view] in
                                guard let self, let view,
                                      self.currentAssetID == assetID, self.playEpoch == epoch,
                                      self.wantsMoviePlay else { return }
                                #if DEBUG
                                if !finished { Self.logLive("live_avplay_seek_unfinished_\(assetID)") }
                                #endif
                                // The layer exists by now, built on the hop
                                // that scheduled this seek, so this is a
                                // stored-property read, not a build. It also
                                // keeps a `CALayer` out of the cross-queue
                                // capture list.
                                self.beginMovieFadeIn(
                                    view: view,
                                    player: player,
                                    layer: view.ensurePlayerLayer(),
                                    assetID: assetID,
                                    sessionActive: sessionActive,
                                    epoch: epoch,
                                    staleReady: staleReady
                                )
                            }
                        }
                    }
                }
            }
        }

        /// Hop 4: start the rate, then cross-fade the movie layer up over the
        /// still once the layer has a real frame on it.
        ///
        /// Rate first, fade second, and the order matters. The fade must
        /// dissolve the still into a visible movie frame. A fade on an
        /// empty layer shows nothing, then cuts to the movie when the
        /// first frame arrives. The few milliseconds of audio that start
        /// under a still frame are inaudible; a visible cut is not.
        private func beginMovieFadeIn(
            view: LiveStageView,
            player: AVPlayer,
            layer: AVPlayerLayer,
            assetID: String,
            sessionActive: Bool,
            epoch: Int,
            staleReady: Bool
        ) {
            wantsMoviePlay = false
            isMoviePlaying = true
            // The seek completed, so the item can play from time zero.
            // Report `.ready` before `claimPlayback` reports `.playing`.
            readyMovieAssetID = assetID
            onReadinessChange?(.ready)
            // This row owns playback now, not back in `play()`, while the
            // paired video was still being written. See `play()`.
            claimPlayback(assetID: assetID)
            #if DEBUG
            Self.logLive("live_avplay_start_\(assetID)")
            Self.logAudioSession(engine: "avplayer", active: sessionActive, muted: isMuted, assetID: assetID)
            #endif
            Self.movieWorkQueue.async { player.rate = 1 }
            armMovieWatchdog(assetID: assetID, epoch: epoch)
            waitForFirstFrame(view: view, layer: layer, assetID: assetID, epoch: epoch, staleReady: staleReady)
        }

        /// Fades the movie layer in the instant `isReadyForDisplay` flips
        /// true, or after 400 ms regardless. A fade that never starts
        /// because a layer never reported ready would leave the post frozen
        /// on its key photo with audio playing behind it, which is worse
        /// than a late cut. `staleReady` means the layer was already
        /// reporting ready before this item was attached, so its current
        /// value says nothing about this item, and only an observed change
        /// counts.
        private func waitForFirstFrame(view: LiveStageView, layer: AVPlayerLayer, assetID: String, epoch: Int, staleReady: Bool) {
            readyObservation?.invalidate()
            readyFallbackTask?.cancel()
            if !staleReady, layer.isReadyForDisplay {
                applyStagePresentation(view, showMovie: true, animated: true)
                return
            }
            readyObservation = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self, weak view] layer, _ in
                guard layer.isReadyForDisplay else { return }
                // KVO can land on any thread: hop to main before touching
                // this main-actor coordinator, the same shape
                // `PlayerHolder`'s own `\.rate` observation uses.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let view else { return }
                        self.finishFadeIn(view: view, assetID: assetID, epoch: epoch)
                    }
                }
            }
            readyFallbackTask = Task { [weak self, weak view] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, let self, let view else { return }
                #if DEBUG
                Self.logLive("live_avplay_fade_fallback_\(assetID)")
                #endif
                self.finishFadeIn(view: view, assetID: assetID, epoch: epoch)
            }
        }

        private func finishFadeIn(view: LiveStageView, assetID: String, epoch: Int) {
            guard isMoviePlaying, currentAssetID == assetID, playEpoch == epoch else { return }
            readyObservation?.invalidate()
            readyObservation = nil
            readyFallbackTask?.cancel()
            readyFallbackTask = nil
            applyStagePresentation(view, showMovie: true, animated: true)
        }

        /// The end notification is the only thing that returns this row to
        /// `.key`, and an item can fail in ways that never post one. Ten
        /// seconds is much longer than any paired movie, so this fires only
        /// when the item hangs. The row then reverts instead of announcing
        /// `.playing` for the rest of the session.
        private func armMovieWatchdog(assetID: String, epoch: Int) {
            movieWatchdogTask?.cancel()
            movieWatchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.movieDidFail(assetID: assetID, epoch: epoch, reason: "watchdog")
            }
        }

        /// The paired movie could not play. Reverts to the key photo exactly
        /// as a natural end would, so the user sees a post that did not
        /// move rather than a post stuck claiming it is playing.
        private func movieDidFail(assetID: String, epoch: Int, reason: String) {
            guard currentAssetID == assetID, playEpoch == epoch,
                  isMoviePlaying || wantsMoviePlay else { return }
            #if DEBUG
            Self.logLive("live_avplay_fail_\(reason)_\(assetID)")
            #endif
            detachMovie(view: currentView, animated: isMoviePlaying)
            isPlaying = false
            onStateChange?(isMuted ? .off : .key)
            LivePlaybackArbiter.shared.release(assetID: assetID)
        }

        /// The paired movie played to its end: fades back to the still and
        /// drops the item. Every play builds a fresh `AVPlayerItem`, so
        /// there is nothing here worth keeping for a replay.
        private func movieDidReachEnd(assetID: String, epoch: Int) {
            guard isMoviePlaying, currentAssetID == assetID, playEpoch == epoch else { return }
            #if DEBUG
            Self.logLive("live_avplay_end_\(assetID)")
            #endif
            isPlaying = false
            detachMovie(view: currentView, animated: true)
            onStateChange?(isMuted ? .off : .key)
            LivePlaybackArbiter.shared.release(assetID: assetID)
        }

        /// Every "this row must stop showing its movie now" path: natural
        /// end, band leave, arbiter loss, failure, Live toggled OFF, a
        /// recycled row, teardown. `animated` is false for a recycled row
        /// and for teardown, where a fade would show stale motion over the
        /// content already in place.
        private func detachMovie(view: LiveStageView?, animated: Bool) {
            cancelPendingMoviePlay()
            movieWatchdogTask?.cancel()
            movieWatchdogTask = nil
            readyObservation?.invalidate()
            readyObservation = nil
            readyFallbackTask?.cancel()
            readyFallbackTask = nil
            removeMovieObservers()
            guard isMoviePlaying || movieItem != nil else { return }
            // Below the guard: a recycled row calls this on every recycle
            // and almost always returns above, which would otherwise flood
            // the watchdog's mark trail. See `update`'s own note.
            wdMark("liveStop")
            isMoviePlaying = false
            if let view { applyStagePresentation(view, showMovie: false, animated: animated) }
            guard let moviePlayer, let item = movieItem else { movieItem = nil; return }
            movieItem = nil
            Self.movieWorkQueue.async { [moviePlayer] in
                if moviePlayer.currentItem === item { moviePlayer.pause() }
            }
            // Detaching runs off-main, the same reason `PlayerHolder.release`
            // does: a decoded item's teardown is synchronous and not free.
            // It is held back until the fade has finished, because
            // detaching the item blanks the layer, and a layer that goes
            // black halfway through its own fade-out is a flicker, not a
            // fade.
            //
            // The `=== item` check matters: without it, a fade-out armed
            // when a post left the band could land after a tap replay the
            // user started meanwhile, detaching the new item instead. That
            // would kill the audio, leave the layer blank but fully opaque
            // over the still, leave `isPlaying` stuck true, and make an end
            // notification impossible.
            let delay = animated ? Self.fadeDuration + 0.05 : 0
            Self.movieWorkQueue.asyncAfter(deadline: .now() + delay) { [moviePlayer] in
                guard moviePlayer.currentItem === item else { return }
                moviePlayer.replaceCurrentItem(with: nil)
            }
        }

        /// The whole transition, both directions, in one call: the movie
        /// layer dissolves in or out while both layers bloom to
        /// `bloomScale` or settle back to 1.
        ///
        /// Both layers scale together, by the same amount, at the same
        /// time. That is what makes it a dissolve and not a
        /// dissolve-plus-drift: at every instant of the cross-fade the
        /// still underneath and the movie on top are the same size, so the
        /// only thing changing is which one is visible. The bloom holds for
        /// the length of the clip and releases on the way out, matching
        /// Apple's own Live playback: the frame grows slightly larger
        /// while the clip plays, then returns to its rest size.
        private func applyStagePresentation(_ view: LiveStageView, showMovie: Bool, animated: Bool) {
            let scale = showMovie ? Self.bloomScale : 1
            // No movie layer means this row never played: there is nothing
            // to dissolve, and the still is already the only thing on
            // screen.
            if let playerLayer = view.playerLayer {
                animate(playerLayer, opacity: showMovie ? 1 : 0, scale: scale, animated: animated)
            }
            animate(view.livePhotoView.layer, opacity: nil, scale: scale, animated: animated)
        }

        /// Explicit `CABasicAnimation`s, not implicit ones under a
        /// `CATransaction` duration. `AVPlayerLayer` is a standalone
        /// sublayer here, not a view's backing layer, and leaving its
        /// cross-fade to the implicit-animation machinery would make the
        /// timing depend on whichever transaction happens to be open on the
        /// caller's run-loop turn. `presentation()` supplies both
        /// from-values, so interrupting a transition halfway, such as a tap
        /// replay landing during a fade-out, picks up from what is actually
        /// on screen rather than snapping first.
        private func animate(_ layer: CALayer, opacity: Float?, scale: CGFloat, animated: Bool) {
            let presentation = layer.presentation()
            let fromOpacity = presentation?.opacity ?? layer.opacity
            let currentTransform = presentation?.transform ?? layer.transform
            let fromScale = CATransform3DGetAffineTransform(currentTransform).a
            layer.removeAnimation(forKey: Self.fadeAnimationKey)
            layer.removeAnimation(forKey: Self.bloomAnimationKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let opacity { layer.opacity = opacity }
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
            CATransaction.commit()
            guard animated else { return }
            let timing = CAMediaTimingFunction(name: .easeInEaseOut)
            if let opacity, fromOpacity != opacity {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = fromOpacity
                fade.toValue = opacity
                fade.duration = Self.fadeDuration
                fade.timingFunction = timing
                layer.add(fade, forKey: Self.fadeAnimationKey)
            }
            if fromScale != scale {
                let bloom = CABasicAnimation(keyPath: "transform.scale")
                bloom.fromValue = fromScale
                bloom.toValue = scale
                bloom.duration = Self.fadeDuration
                bloom.timingFunction = timing
                layer.add(bloom, forKey: Self.bloomAnimationKey)
            }
        }

        private static let fadeAnimationKey = "cloudfull.live.movieFade"
        private static let bloomAnimationKey = "cloudfull.live.movieBloom"

        /// Not main-actor isolated, so `attachAndPlay` can call it on
        /// `movieWorkQueue`. Built on this row's first Live-ON play, never
        /// before. See `moviePlayer`.
        private nonisolated static func makeMoviePlayer() -> AVPlayer {
            let player = AVPlayer()
            // The one property worth setting eagerly: without it the player
            // holds the display awake for a 2-second clip.
            player.preventsDisplaySleepDuringVideoPlayback = false
            // Set once, here, rather than on every play: the movie must stop
            // on its last frame so the fade-out dissolves from that frame.
            player.actionAtItemEnd = .pause
            return player
        }

        private func removeMovieObservers() {
            movieEndObserver.map(NotificationCenter.default.removeObserver)
            movieEndObserver = nil
            movieFailObserver.map(NotificationCenter.default.removeObserver)
            movieFailObserver = nil
            movieStatusObservation?.invalidate()
            movieStatusObservation = nil
        }

        /// Off-main, on this file's own serial queue. See `play()`'s doc
        /// comment. Returns whether `setActive(true)` actually succeeded,
        /// for the `live_audio_session_..._active_<bool>` diagnostic below.
        /// On a throw, returns false and logs the error in DEBUG builds.
        /// Playback still continues.
        private static func activateAudioSession() async -> Bool {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                audioWorkQueue.async {
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        continuation.resume(returning: true)
                    } catch {
                        #if DEBUG
                        Self.audioLog.error("Live Photo setActive failed: \(error.localizedDescription, privacy: .public)")
                        logLive("live_audio_session_setActive_error_\(error.localizedDescription)")
                        #endif
                        continuation.resume(returning: false)
                    }
                }
            }
        }

        #if DEBUG
        /// A diagnostic logged right before playback starts on either
        /// engine:
        /// `live_audio_session_<engine>_<category>_<mode>_active_<bool>_muted_<bool>_<assetID>`.
        /// Shows, for a Live post that did or did not have sound, exactly
        /// what the session and the player thought at the instant playback
        /// started, and which engine served it. `engine` is `avplayer` for
        /// the paired-movie path, `livephotoview` for a Live-OFF (muted)
        /// play, and `livephotoview_fallback` when the paired movie could
        /// not be had.
        ///
        /// Do not read `AVAudioSession` state on the main thread. This
        /// checks the gate first, then reads the session on
        /// `audioWorkQueue`.
        private static func logAudioSession(engine: String, active: Bool, muted: Bool, assetID: String) {
            guard DiagnosticsGate.isOn("-cloudfull-log-live") else { return }
            audioWorkQueue.async {
                let session = AVAudioSession.sharedInstance()
                logLive("live_audio_session_\(engine)_\(session.category.rawValue)_\(session.mode.rawValue)_active_\(active)_muted_\(muted)_\(assetID)")
            }
        }
        #endif

        func livePhotoView(_ photoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            // Only the Live-OFF (and fallback) engine reaches here. The
            // `AVPlayer` path ends through `movieDidReachEnd`.
            guard !isMoviePlaying else { return }
            isPlaying = false
            onStateChange?(isMuted ? .off : .key)
            if let currentAssetID { LivePlaybackArbiter.shared.release(assetID: currentAssetID) }
        }

        /// `LivePlaybackArbiter`'s callback when a different post claims
        /// exclusive playback. Reverts this one to idle exactly like a
        /// normal `stopNonce` would, but without touching `pendingPlay`:
        /// this post was never asked to leave the band, a different post
        /// simply started playing while this one already was.
        private func forceStopForArbiter() {
            audioActivationTask?.cancel()
            // Unconditional, for the same reason the `stopNonce` branch
            // cancels unconditionally: the expensive window is the one
            // where this row is not playing yet but is still downloading
            // towards a play it has now lost.
            cancelPendingMoviePlay()
            guard isPlaying else { return }
            if isMoviePlaying {
                detachMovie(view: currentView, animated: true)
            } else {
                currentView?.livePhotoView.stopPlayback()
            }
            isPlaying = false
            onStateChange?(isMuted ? .off : .key)
        }

        /// Clears `pendingPlay` and logs `live_pending_dropped_<reason>`,
        /// but only when there actually was one to drop. Safe to call
        /// unconditionally from every "this post no longer wants a
        /// deferred play" call site without logging a stream of no-op
        /// clears for posts that were never waiting on one.
        private func dropPendingPlay(reason: String, assetID: String?) {
            guard pendingPlay else { return }
            pendingPlay = false
            #if DEBUG
            if let assetID { Self.logLive("live_pending_dropped_\(reason)_\(assetID)") }
            #endif
        }

        func teardown() {
            loadTask?.cancel()
            audioActivationTask?.cancel()
            readyObservation?.invalidate()
            readyObservation = nil
            readyFallbackTask?.cancel()
            movieWatchdogTask?.cancel()
            detachMovie(view: currentView, animated: false)
            releaseMoviePin()
            moviePlayer = nil
            didAttachPlayerToLayer = false
            dropPendingPlay(reason: "unmounted", assetID: currentAssetID)
            if isPlaying, let currentAssetID {
                LivePlaybackArbiter.shared.release(assetID: currentAssetID)
            }
        }

        /// Serial queue for `AVAudioSession` activation and reads, like
        /// `PlayerHolder.playerWorkQueue` (Cloudfull/Feed/PlayerPageView.swift).
        /// Kept separate since `PlayerHolder` is private to its own file.
        private static let audioWorkQueue = DispatchQueue(label: "com.cloudfull.photo-audio-work", qos: .utility)
        /// Every `AVPlayer`/`AVPlayerItem` mutation this file makes,
        /// serialized and off-main: the Photos-module equivalent of
        /// `PlayerHolder.playerWorkQueue`. `.userInitiated`, not `.utility`,
        /// since everything on this queue is in the critical path of a play
        /// the user is watching for.
        private static let movieWorkQueue = DispatchQueue(label: "com.cloudfull.photo-movie-work", qos: .userInitiated)
        #if DEBUG
        private static let audioLog = Logger(subsystem: "com.cloudfull.app", category: "PhotoAudio")

        /// A diagnostic (`-cloudfull-log-live`): one line per fetch
        /// start/finish, per play, per missed-then-deferred request, and
        /// per stop, so a device log shows, for a Live post that did or did
        /// not play, exactly which of those happened and when. Same gate
        /// style as `PlaceLookup.logLookup`/`PhotoPostView.logRowUpdated`
        /// (`-cloudfull-log-place`).
        private static func logLive(_ message: String) {
            guard DiagnosticsGate.isOn("-cloudfull-log-live") else { return }
            DiagnosticsLog.shared.log("LivePhoto", message)
        }
        #endif
    }
}

/// Records the one post that plays Live motion now.
/// `Coordinator.claimPlayback` claims it. A claim stops the previous
/// holder, so two Live Photos never play at the same time.
@MainActor
private final class LivePlaybackArbiter {
    static let shared = LivePlaybackArbiter()

    private var current: (assetID: String, stop: () -> Void)?

    private init() {}

    /// Makes `assetID` the holder. If a different asset held the claim,
    /// calls that holder's `stop` first. `stop` must synchronously return
    /// this post to its idle key/off state. Does nothing extra when
    /// `assetID` already holds the claim.
    func claim(assetID: String, stop: @escaping () -> Void) {
        if let current, current.assetID != assetID {
            current.stop()
        }
        current = (assetID, stop)
    }

    /// Does nothing unless `assetID` holds the claim. A post that lost
    /// its claim must not clear the new holder's claim.
    func release(assetID: String) {
        if current?.assetID == assetID {
            current = nil
        }
    }
}

/// The paired movie inside a Live Photo, streamed out to a temp file once
/// per asset and cached, up to 20 entries, least-recently-used evicted
/// first.
///
/// A file exists because an `AVPlayerItem` needs something it can seek in,
/// and `PHAssetResourceManager` is the only way to get a Live Photo's
/// paired video out of the library. The write is the expensive part of a
/// first play, and the part that can go to iCloud, so it runs once and is
/// cached.
///
/// Uses `requestData`, not `writeData`: `writeData` returns nothing to
/// cancel with, so a feed of iCloud Live posts scrolled past at speed would
/// leave one unstoppable download per post running against the still
/// fetches that draw the feed. `requestData` hands back a
/// `PHAssetResourceDataRequestID`, so a play abandoned mid-download really
/// does stop downloading.
///
/// Bounds, in the order they apply:
///
/// * two writes in flight at once (see `maxConcurrentWrites`);
/// * 20 cached entries, least-recently-used evicted first. A Live Photo's
///   paired movie is one to three seconds at capture resolution, so 20 of
///   them is tens of megabytes of temp storage, not hundreds;
/// * every asset handed out and not yet unpinned is pinned and never
///   evicted, because an `AVPlayerItem` may be reading that file;
/// * a memory warning drops everything unpinned and deletes those files
///   (`armMemoryWarningPurge`);
/// * every entry lives under one directory that is swept clean the first
///   time this store is touched in a process, so a crash or a kill
///   mid-scroll cannot leak the previous run's movies forever.
private actor LivePairedMovieStore {
    static let shared = LivePairedMovieStore()

    private struct Pending {
        let task: Task<URL?, Never>
        let allowedNetwork: Bool
        /// How many `movieURL` callers are still waiting on `task`. When it
        /// reaches zero, the write is cancelled outright. See `callerLeft`.
        var waiters: Int
    }

    private var urls: [String: URL] = [:]
    /// Least-recently-used first, most-recent last.
    private var order: [String] = []
    /// One write per asset even if three plays race for it.
    private var inFlight: [String: Pending] = [:]
    /// The assets whose files a player is reading right now. Never evicted,
    /// never purged. A set, not one id. The arbiter allows only one Live
    /// post to be playing, but several rows can be between "got the file"
    /// and "attached it". A single slot would let a later row steal the
    /// pin out from under a player that was still reading.
    private var pinned: Set<String> = []
    /// Bumped by `purgeAll`. A write that was already running when a purge
    /// happened must not quietly repopulate the cache afterward.
    private var generation = 0
    private var didSweep = false

    private var activeWrites = 0
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    private static let capacity = 20
    /// These writes are PhotoKit reads that contend with the still fetches
    /// drawing the feed. Only one post plays at a time
    /// (`LivePlaybackArbiter`), so more concurrent writes add load and no
    /// benefit.
    private static let maxConcurrentWrites = 2

    private static let directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cloudfull-live-paired", isDirectory: true)

    /// Hands back a local file URL for `assetID`'s paired video, writing it
    /// out on first use, and pins it so nothing deletes the file while the
    /// caller's `AVPlayerItem` is reading it. Every caller must `unpin` when
    /// done: `LivePhotoStage.Coordinator.detachMovie` does, as do the
    /// abandon paths in `startMoviePlayback`.
    ///
    /// Returns `nil` when the asset has no paired video at all (not
    /// actually a Live Photo), or when the write failed. The caller falls
    /// back to `PHLivePhotoView` in that case.
    func movieURL(assetID: String, allowNetwork: Bool, progress: (@Sendable (Double) -> Void)? = nil) async -> URL? {
        sweepOnce()
        if let url = urls[assetID], FileManager.default.fileExists(atPath: url.path) {
            touch(assetID)
            pinned.insert(assetID)
            return url
        }
        // Coalesces onto a write already running for this asset, but only
        // if it was allowed at least as much network as this caller. A
        // first play on cellular creates a `nil`-returning task; a second
        // play after the user reached Wi-Fi must not inherit that answer.
        if var pending = inFlight[assetID], pending.allowedNetwork || !allowNetwork {
            pending.waiters += 1
            inFlight[assetID] = pending
            let url = await awaitWrite(pending.task, assetID: assetID)
            if url != nil {
                touch(assetID)
                pinned.insert(assetID)
            }
            return url
        }
        let startGeneration = generation
        let task = Task<URL?, Never> { [allowNetwork] in
            await Self.shared.acquireWriteSlot()
            defer { Task { await Self.shared.releaseWriteSlot() } }
            return await Self.write(assetID: assetID, allowNetwork: allowNetwork, progress: progress)
        }
        inFlight[assetID] = Pending(task: task, allowedNetwork: allowNetwork, waiters: 1)
        let url = await awaitWrite(task, assetID: assetID)
        // Identity-checked: a cancelled caller may already have cleared
        // this entry, and a later caller started a fresh write under the
        // same key.
        if inFlight[assetID]?.task == task { inFlight[assetID] = nil }
        guard let url else { return nil }
        guard generation == startGeneration else {
            // A purge ran while this was downloading. The caller no longer
            // has a cache to put it in, and leaving the file behind would
            // defeat the purge.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        urls[assetID] = url
        touch(assetID)
        pinned.insert(assetID)
        evictIfNeeded()
        publishCacheMirror()
        return url
    }

    /// Hands the current cached set to `LivePairedMovieCache` so the ring
    /// rule and `play` can ask "is this one already on disk?" without
    /// awaiting this actor. Called from every path that adds or removes an
    /// entry, never per byte and never per frame.
    private func publishCacheMirror() {
        let ids = Set(urls.keys)
        Task { LivePairedMovieCache.shared.replace(with: ids) }
    }

    /// The caller's `AVPlayerItem` is finished with this asset's file, so it
    /// may now be evicted or purged like any other entry.
    func unpin(assetID: String) {
        pinned.remove(assetID)
    }

    /// When a caller is cancelled, the download stops too. `nonisolated`
    /// because the `onCancel` body must not need this actor's executor to
    /// run.
    private nonisolated func awaitWrite(_ task: Task<URL?, Never>, assetID: String) async -> URL? {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.callerLeft(assetID: assetID) }
        }
    }

    /// One waiter gave up. The last one to give up cancels the write, which
    /// cancels the `PHAssetResourceManager` request under it.
    private func callerLeft(assetID: String) {
        guard var pending = inFlight[assetID] else { return }
        pending.waiters -= 1
        guard pending.waiters <= 0 else {
            inFlight[assetID] = pending
            return
        }
        inFlight[assetID] = nil
        pending.task.cancel()
    }

    private func acquireWriteSlot() async {
        if activeWrites < Self.maxConcurrentWrites {
            activeWrites += 1
            return
        }
        // The resumed waiter does not increment: `releaseWriteSlot` hands
        // its own slot straight over. Incrementing here would re-open the
        // slot for a whole actor turn, long enough for a fresh caller to
        // walk in on the fast path above and exceed the cap. The cap must
        // be real.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeWaiters.append(continuation)
        }
    }

    private func releaseWriteSlot() {
        guard !writeWaiters.isEmpty else {
            activeWrites -= 1
            return
        }
        // Slot handed over, not released: `activeWrites` stays where it is.
        writeWaiters.removeFirst().resume()
    }

    private func touch(_ assetID: String) {
        order.removeAll { $0 == assetID }
        order.append(assetID)
    }

    private func evictIfNeeded() {
        var evicted = false
        while order.count > Self.capacity {
            guard let victim = order.first(where: { !pinned.contains($0) }) else { break }
            order.removeAll { $0 == victim }
            if let url = urls.removeValue(forKey: victim) {
                try? FileManager.default.removeItem(at: url)
                evicted = true
            }
        }
        // An evicted asset must also leave `LivePairedMovieCache`, or the
        // ring rule keeps reading "already cached" for a file that is gone,
        // and the post's next fetch runs with no ring at all.
        if evicted { publishCacheMirror() }
    }

    /// Deletes every cached movie except pinned movies, and forgets them.
    /// Called on a memory warning. See `armMemoryWarningPurge`.
    func purgeAll() {
        generation &+= 1
        for (assetID, url) in urls where !pinned.contains(assetID) {
            try? FileManager.default.removeItem(at: url)
            urls[assetID] = nil
        }
        order.removeAll { !pinned.contains($0) }
        publishCacheMirror()
    }

    /// Deletes anything a previous run of the app left behind, once per
    /// process. Cheap: one directory, empty on a clean launch.
    private func sweepOnce() {
        guard !didSweep else { return }
        didSweep = true
        let fm = FileManager.default
        if let stale = try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) {
            for url in stale { try? fm.removeItem(at: url) }
        }
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    }

    /// Arms the memory-warning purge exactly once per process. Called from
    /// `LivePhotoStage.makeUIView`, so it costs nothing in a run that never
    /// shows a Live post.
    @MainActor
    static func armMemoryWarningPurge() {
        guard !hasArmedMemoryWarningPurge else { return }
        hasArmedMemoryWarningPurge = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await LivePairedMovieStore.shared.purgeAll() }
        }
    }

    @MainActor
    private static var hasArmedMemoryWarningPurge = false

    /// The PhotoKit calls here are a `nonisolated static` body reached only
    /// through this actor, so they never run on the caller's main executor.
    /// `withTaskCancellationHandler` plus `cancelDataRequest` mirrors
    /// `LivePhotoLoader.fetch`'s own shape: when a caller is cancelled,
    /// the download stops too.
    private nonisolated static func write(assetID: String, allowNetwork: Bool, progress: (@Sendable (Double) -> Void)? = nil) async -> URL? {
        guard let asset = PhotoLibraryService.fetchAsset(assetID) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        // `.fullSizePairedVideo` is the rendered paired video an edited
        // Live Photo carries; `.pairedVideo` is the original. Prefers the
        // rendered one when it exists, so a trimmed or filtered Live Photo
        // plays the motion the user actually kept.
        guard let resource = resources.first(where: { $0.type == .fullSizePairedVideo })
                ?? resources.first(where: { $0.type == .pairedVideo }) else { return nil }

        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // A PhotoKit local identifier looks like `<uuid>/L0/001`. The
        // slashes would otherwise be read as path components.
        let safeName = assetID.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent("\(safeName).mov")
        // A half-written file from a cancelled earlier attempt is worse
        // than no file at all.
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else { return nil }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? fm.removeItem(at: url)
            return nil
        }

        let options = PHAssetResourceRequestOptions()
        // The motion clip is content the user is looking at, so it may come
        // from iCloud, but only under the existing Wi-Fi guard the
        // Settings row surfaces.
        options.isNetworkAccessAllowed = allowNetwork
        if let progress {
            options.progressHandler = { fraction in progress(fraction) }
        }

        let requestBox = LiveDataRequestIDBox()
        let result: URL? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                let guardBox = LiveResumeGuard()
                let requestID = PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: options
                ) { chunk in
                    // Delivered serially, in order, on PhotoKit's own queue.
                    handle.write(chunk)
                } completionHandler: { error in
                    guard guardBox.markResumed() else { return }
                    try? handle.close()
                    if error != nil {
                        try? FileManager.default.removeItem(at: url)
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: url)
                    }
                }
                requestBox.id = requestID
            }
        } onCancel: {
            let requestID = requestBox.id
            if requestID != PHInvalidAssetResourceDataRequestID {
                PHAssetResourceManager.default().cancelDataRequest(requestID)
            }
        }
        if Task.isCancelled, result != nil {
            try? fm.removeItem(at: url)
            return nil
        }
        #if DEBUG
        // A verification aid: the seeded simulator library's paired video
        // resolves in milliseconds, too fast to capture the corner ring
        // staying up through `LiveReadiness.fetching`. See
        // `CloudfullApp.slowLiveArgument`'s own doc comment. This only
        // delays an already-running write; it never starts one that would
        // not otherwise happen.
        //
        // Discard the file if the task was cancelled during the delay.
        // `try? await Task.sleep` ignores cancellation, so without this
        // check `movieURL` caches a file for a cancelled caller. This can
        // happen when a band autoplay starts this write and a tap replay
        // supersedes it before the delay ends.
        if let delay = slowLiveDelay {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled {
                try? fm.removeItem(at: url)
                return nil
            }
        }
        #endif
        return result
    }

    #if DEBUG
    /// Seconds to delay the write above by, from
    /// `-cloudfull-slow-live <seconds>` (`CloudfullApp.slowLiveArgument`).
    /// `nonisolated static let`, read once at first touch, the same pattern
    /// as `PhotoImagePipeline.slowPhotoDelay`.
    nonisolated static let slowLiveDelay: TimeInterval? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: CloudfullApp.slowLiveArgument),
              arguments.index(after: flag) < arguments.endIndex,
              let seconds = TimeInterval(arguments[arguments.index(after: flag)]),
              seconds > 0 else { return nil }
        return seconds
    }()
    #endif
}

/// Limits concurrent `PHLivePhoto` fetches to 3: the current post and its
/// two neighbors. A fourth request waits for a slot instead of firing a
/// fourth PhotoKit decode at once. `PhotoPostView` only mounts a
/// `LivePhotoStage` for a Live post actually near the viewport, so in
/// practice this rarely queues.
private actor LivePhotoLoader {
    static let shared = LivePhotoLoader()

    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static func request(assetID: String, targetSize: CGSize, allowNetwork: Bool) async -> PHLivePhoto? {
        await shared.acquireSlot()
        defer { Task { await shared.releaseSlot() } }
        return await Self.fetch(assetID: assetID, targetSize: targetSize, allowNetwork: allowNetwork)
    }

    private func acquireSlot() async {
        if activeCount < 3 {
            activeCount += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        activeCount += 1
    }

    private func releaseSlot() {
        activeCount -= 1
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    /// A `nonisolated static` body, so the PhotoKit request runs off the
    /// caller's executor. Uses the same cancellable-continuation pattern
    /// as `PhotoLibraryService.requestPlayerItem`.
    private nonisolated static func fetch(assetID: String, targetSize: CGSize, allowNetwork: Bool) async -> PHLivePhoto? {
        guard let asset = PhotoLibraryService.fetchAsset(assetID) else { return nil }

        let options = PHLivePhotoRequestOptions()
        // A Live Photo's motion clip is content the user is looking at, not
        // incidental metadata, so this may download from iCloud, gated by
        // the existing Wi-Fi-only guard the Settings row surfaces. The flag
        // itself is read on the main actor by `Coordinator.startLoad`,
        // above the async fetch this `nonisolated` body runs in.
        options.isNetworkAccessAllowed = allowNetwork
        // `.highQualityFormat`, not `.opportunistic`: a single delivery, so
        // the continuation below resumes exactly once with no degraded
        // intermediate to guard against.
        options.deliveryMode = .highQualityFormat

        let clampedSize = CGSize(
            width: max(targetSize.width, 1),
            height: max(targetSize.height, 1)
        )
        let requestBox = LiveRequestIDBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PHLivePhoto?, Never>) in
                let hasResumed = LiveResumeGuard()
                let requestID = PHImageManager.default().requestLivePhoto(
                    for: asset,
                    targetSize: clampedSize,
                    contentMode: .aspectFit,
                    options: options
                ) { livePhoto, _ in
                    guard hasResumed.markResumed() else { return }
                    continuation.resume(returning: livePhoto)
                }
                requestBox.id = requestID
            }
        } onCancel: {
            let requestID = requestBox.id
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
    }
}

/// Holds a `PHImageManager` request id so `onCancel` can read it after
/// this file's `withCheckedContinuation` closure has already returned.
private final class LiveRequestIDBox: @unchecked Sendable {
    var id = PHInvalidImageRequestID
}

/// The `PHAssetResourceManager` equivalent of `LiveRequestIDBox`: a
/// different id type (`PHAssetResourceDataRequestID`) with the same
/// cancellation shape.
private final class LiveDataRequestIDBox: @unchecked Sendable {
    var id = PHInvalidAssetResourceDataRequestID
}

/// Makes sure a continuation resumes exactly once.
private final class LiveResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return false }
        hasResumed = true
        return true
    }
}

/// A read-only mirror of the assets `LivePairedMovieStore` already holds
/// a written paired-movie file for. The store is an actor, so asking it
/// costs an `await`. `PhotoPostView`'s ring rule, `Coordinator.play`, and
/// `Coordinator.cancelPendingMoviePlay` all need a synchronous answer
/// instead, or the ring flashes for however many frames that hop takes.
/// The store republishes the whole set on every change it makes, so this
/// mirror can be one actor hop out of date.
///
/// The asymmetry is deliberate and is why a mirror is safe here: a stale
/// miss costs one extra ring frame on a first-ever fetch, while a stale hit
/// would hide a ring that ought to be up. Republishing on eviction and
/// purge, not only on insert, keeps hits from going stale.
final class LivePairedMovieCache: @unchecked Sendable {
    static let shared = LivePairedMovieCache()

    private let lock = NSLock()
    private var ready: Set<String> = []

    /// True when this asset's paired movie is already a file on disk, so a
    /// play of it needs no fetch and must never raise the ring.
    func isReady(_ assetID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ready.contains(assetID)
    }

    func replace(with assetIDs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        ready = assetIDs
    }
}

/// Publishes a download fraction only when it moved by at least 2%, or
/// reached 1.0, so the ring animates in visible steps instead of once per
/// delivered chunk. PhotoKit calls the progress handler off the main
/// thread; this box is the only shared state it touches.
private final class LiveProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = -1
    func shouldPublish(_ fraction: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fraction >= 1 || fraction - last >= 0.02 else { return false }
        last = fraction
        return true
    }
}
