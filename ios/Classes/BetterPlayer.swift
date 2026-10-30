import Foundation
import Flutter
import AVFoundation
import AVKit
import UIKit

private var timeRangeContext = 0
private var statusContext = 0
private var playbackLikelyToKeepUpContext = 0
private var playbackBufferEmptyContext = 0
private var playbackBufferFullContext = 0
private var presentationSizeContext = 0

public class BetterPlayer: NSObject, FlutterPlatformView, FlutterStreamHandler, AVPictureInPictureControllerDelegate {
    public private(set) var player: AVPlayer
    public private(set) var loaderDelegate: BetterPlayerEzDrmAssetsLoaderDelegate?
    public var eventChannel: FlutterEventChannel?
    public var eventSink: FlutterEventSink?
    public var preferredTransform: CGAffineTransform = .identity
    public private(set) var disposed: Bool = false
    public private(set) var isPlaying: Bool = false
    public var isLooping: Bool = false
    public private(set) var isInitialized: Bool = false
    public private(set) var key: String? = nil
    public private(set) var failedCount: Int = 0

    public var playerLayerRef: AVPlayerLayer?
    public var pictureInPicture: Bool = false
    public var observersAdded: Bool = false
    public var stalledCount: Int = 0
    public var isStalledCheckStarted: Bool = false
    public var playerRate: Float = 1.0
    public var overriddenDuration: Int = 0
    public var lastAvPlayerTimeControlStatus: AVPlayer.TimeControlStatus? = nil
    public var preferredForwardBufferDuration: TimeInterval = 0
    // Minimum buffered duration required before playback is allowed to start.
    // Needed because automaticallyWaitsToMinimizeStalling is disabled above,
    // which otherwise lets AVPlayer start playing the instant it's ready,
    // with no regard for how little has actually been buffered.
    public var bufferForPlaybackDuration: TimeInterval = 0
    // Buffer ahead of the playhead required to resume after a stall — ExoPlayer's
    // bufferForPlaybackAfterRebufferMs. 0 keeps the old 10s fallback.
    public var bufferForPlaybackAfterRebufferDuration: TimeInterval = 0
    // Track cap kept on the player, like ExoPlayer's trackSelector which lives as
    // long as the player. AVPlayerItem holds it per item, so without this every
    // replaceCurrentItem starts uncapped (first-listed, often 1080p, rendition).
    private var maxResolution: CGSize = .zero
    // seekTo pauses (rate 0) while isPlaying stays true; the buffer and rate
    // observers must not restart playback before the seek completes.
    private var pendingSeeks = 0
    private var peakBitRate: Double = 0
    // Last variant reported to Dart as "qualityChanged"; KVO and access-log
    // notifications both re-fire for the same variant.
    private var lastQualitySize: CGSize = .zero
    private var lastQualityBitrate: Int = 0

    private var pipController: AVPictureInPictureController?
    private var restoreUIOnPipStop: ((Bool) -> Void)?

    // Starting playback while the app is leaving the foreground (no background
    // audio mode) can leave the rate change waiting forever on the media
    // server; AVFoundation's main-queue rate callback then blocks on it, the
    // screen goes black and the watchdog kills the app. So rate changes that
    // START playback are held until the app is active again, then replayed.
    private var appIsActive = true
    private var appStateObservers: [NSObjectProtocol] = []

    private var canStartPlayback: Bool { appIsActive || pictureInPicture }

    // Leak check (uncomment here, in init and in deinit): live instance count.
    // The pool keeps at most prev/current/next/hero, so n must stay <= 4.
    // private static var aliveCount = 0

    public override init() {
        self.player = AVPlayer()
        super.init()
        // BetterPlayer.aliveCount += 1
        // NSLog("[BPAlive] created n=%d", BetterPlayer.aliveCount)
        self.player.actionAtItemEnd = .none
        if #available(iOS 10.0, *) {
            self.player.automaticallyWaitsToMinimizeStalling = false
        }
        self.observersAdded = false
        self.isInitialized = false
        self.isPlaying = false
        self.disposed = false
        // Block observers: removeObservers()' removeObserver(self) leaves them be.
        let center = NotificationCenter.default
        appStateObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.appIsActive = false
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                // No auto-replay here: the Dart side's own lifecycle handler
                // (VideoPoolBloc._onAppForegrounded) already re-issues play
                // on resume. Replaying here too raced it after a long lock —
                // two near-simultaneous rate changes right as the media
                // server connection is cold reproduced the same deadlock
                // this guard exists to prevent (screen frozen, audio still
                // playing, force-kill required).
                self?.appIsActive = true
            },
        ]
    }

    deinit {
        appStateObservers.forEach { NotificationCenter.default.removeObserver($0) }
        // BetterPlayer.aliveCount -= 1
        // NSLog("[BPAlive] freed   n=%d", BetterPlayer.aliveCount)
    }

    public convenience init(frame: CGRect) {
        self.init()
    }

    public func view() -> UIView {
        let playerView = BetterPlayerView(frame: .zero)
        playerView.player = player
        return playerView
    }

    // MARK: - Observers
    private func addObservers(_ item: AVPlayerItem) {
        if !observersAdded {
            player.addObserver(self, forKeyPath: "rate", options: [], context: nil)
            item.addObserver(self, forKeyPath: "loadedTimeRanges", options: [], context: &timeRangeContext)
            item.addObserver(self, forKeyPath: "status", options: [], context: &statusContext)
            item.addObserver(self, forKeyPath: "presentationSize", options: [], context: &presentationSizeContext)
            item.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: [], context: &playbackLikelyToKeepUpContext)
            item.addObserver(self, forKeyPath: "playbackBufferEmpty", options: [], context: &playbackBufferEmptyContext)
            item.addObserver(self, forKeyPath: "playbackBufferFull", options: [], context: &playbackBufferFullContext)
            NotificationCenter.default.addObserver(self, selector: #selector(itemDidPlayToEndTime(_:)), name: .AVPlayerItemDidPlayToEndTime, object: item)
            // A new access-log entry is logged on every HLS variant switch, which
            // also covers same-resolution bitrate switches presentationSize misses.
            NotificationCenter.default.addObserver(self, selector: #selector(itemNewAccessLogEntry(_:)), name: .AVPlayerItemNewAccessLogEntry, object: item)
            observersAdded = true
        }
    }

    private func removeObservers() {
        if observersAdded {
            player.removeObserver(self, forKeyPath: "rate", context: nil)
            player.currentItem?.removeObserver(self, forKeyPath: "status", context: &statusContext)
            player.currentItem?.removeObserver(self, forKeyPath: "presentationSize", context: &presentationSizeContext)
            player.currentItem?.removeObserver(self, forKeyPath: "loadedTimeRanges", context: &timeRangeContext)
            player.currentItem?.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp", context: &playbackLikelyToKeepUpContext)
            player.currentItem?.removeObserver(self, forKeyPath: "playbackBufferEmpty", context: &playbackBufferEmptyContext)
            player.currentItem?.removeObserver(self, forKeyPath: "playbackBufferFull", context: &playbackBufferFullContext)
            NotificationCenter.default.removeObserver(self)
            observersAdded = false
        }
    }

    @objc private func itemNewAccessLogEntry(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.emitQualityIfChanged() }
    }

    // Reports the variant currently being played (ABR or capped) to Dart.
    private func emitQualityIfChanged() {
        guard let eventSink = eventSink, let item = player.currentItem else { return }
        let size = item.presentationSize
        guard size.width > 0, size.height > 0 else { return }
        let indicated = item.accessLog()?.events.last?.indicatedBitrate ?? 0
        let bitrate = indicated > 0 ? Int(indicated) : 0
        if size == lastQualitySize && bitrate == lastQualityBitrate { return }
        lastQualitySize = size
        lastQualityBitrate = bitrate
        eventSink(["event": "qualityChanged",
                   "width": NSNumber(value: Int(size.width)),
                   "height": NSNumber(value: Int(size.height)),
                   "bitrate": NSNumber(value: bitrate),
                   "key": key as Any])
    }

    @objc private func itemDidPlayToEndTime(_ notification: Notification) {
        if isLooping {
            if let p = notification.object as? AVPlayerItem {
                p.seek(to: .zero, completionHandler: nil)
            }
        } else {
            if let eventSink = eventSink {
                eventSink(["event": "completed", "key": key as Any])
                removeObservers()
            }
        }
    }

    private func radiansToDegrees(_ radians: CGFloat) -> CGFloat {
        var degrees = CGFloat(radians * 180.0 / .pi)
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    private func getVideoComposition(transform: CGAffineTransform, asset: AVAsset, videoTrack: AVAssetTrack) -> AVMutableVideoComposition {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRangeMake(start: .zero, duration: asset.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(preferredTransform, at: .zero)

        let videoComposition = AVMutableVideoComposition()
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        var width = videoTrack.naturalSize.width
        var height = videoTrack.naturalSize.height
        let rotationDegrees = Int(round(radiansToDegrees(atan2(preferredTransform.b, preferredTransform.a))))
        if rotationDegrees == 90 || rotationDegrees == 270 {
            width = videoTrack.naturalSize.height
            height = videoTrack.naturalSize.width
        }
        videoComposition.renderSize = CGSize(width: width, height: height)

        let nominalFrameRate = videoTrack.nominalFrameRate
        var fps: Int32 = 30
        if nominalFrameRate > 0 { fps = Int32(ceil(nominalFrameRate)) }
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: fps)
        return videoComposition
    }

    private func fixTransform(_ videoTrack: AVAssetTrack) -> CGAffineTransform {
        var transform = videoTrack.preferredTransform
        let rotationDegrees = Int(round(radiansToDegrees(atan2(transform.b, transform.a))))
        if rotationDegrees == 90 {
            transform.tx = videoTrack.naturalSize.height
            transform.ty = 0
        } else if rotationDegrees == 180 {
            transform.tx = videoTrack.naturalSize.width
            transform.ty = videoTrack.naturalSize.height
        } else if rotationDegrees == 270 {
            transform.tx = 0
            transform.ty = videoTrack.naturalSize.width
        }
        return transform
    }

    public func setDataSourceAsset(_ assetPath: String, key: String?, certificateUrl: String?, licenseUrl: String?, cacheKey: String?, cacheManager: CacheManager, overriddenDuration: Int) {
        if let path = Bundle.main.path(forResource: assetPath, ofType: nil) {
            let url = URL(fileURLWithPath: path)
            setDataSourceURL(url, key: key, certificateUrl: certificateUrl, licenseUrl: licenseUrl, headers: [:], useCache: false, cacheKey: cacheKey, cacheManager: cacheManager, overriddenDuration: overriddenDuration, videoExtension: nil)
        }
    }

    public func setDataSourceURL(_ url: URL, key: String?, certificateUrl: String?, licenseUrl: String?, headers: [AnyHashable: Any], useCache: Bool, cacheKey: String?, cacheManager: CacheManager, overriddenDuration: Int, videoExtension: String?) {
        self.overriddenDuration = 0
        var finalHeaders = headers
        if finalHeaders["dummy"] == nil {} // keep dictionary type stable

        let item: AVPlayerItem
        if useCache {
            let _cacheKey = cacheKey
            let _videoExt = videoExtension
            item = cacheManager.getCachingPlayerItemForNormalPlayback(url, cacheKey: _cacheKey, videoExtension: _videoExt, headers: finalHeaders as NSDictionary as! [NSObject: AnyObject]) ?? AVPlayerItem(url: url)
        } else {
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": finalHeaders])
            if let certificateUrl = certificateUrl, !certificateUrl.isEmpty {
                let certURL = URL(string: certificateUrl)
                let licURL = licenseUrl.flatMap { URL(string: $0) }
                if let certURL = certURL {
                    let delegate = BetterPlayerEzDrmAssetsLoaderDelegate(certURL, withLicenseURL: licURL)
                    self.loaderDelegate = delegate
                    let qos = DispatchQoS.QoSClass.default
                    let streamQueue = DispatchQueue(label: "streamQueue", qos: DispatchQoS(qosClass: qos, relativePriority: -1), attributes: [])
                    asset.resourceLoader.setDelegate(delegate, queue: streamQueue)
                }
            }
            item = AVPlayerItem(asset: asset)
        }
        if #available(iOS 10.0, *), overriddenDuration > 0 {
            self.overriddenDuration = overriddenDuration
        }
        setDataSourcePlayerItem(item, key: key)
    }

    private func setDataSourcePlayerItem(_ item: AVPlayerItem, key: String?) {
        self.key = key
        self.stalledCount = 0
        self.isStalledCheckStarted = false
        self.playerRate = 1
        // Mirrors the minBufferMs the Dart layer already sends for ExoPlayer
        // (Android) via BetterPlayerBufferingConfiguration, which this iOS
        // path previously never read. Gives AVPlayer an explicit buffer floor
        // to offset automaticallyWaitsToMinimizeStalling being disabled above.
        if #available(iOS 10.0, *), preferredForwardBufferDuration > 0 {
            item.preferredForwardBufferDuration = preferredForwardBufferDuration
        }
        applyTrackCap(item)
        pendingSeeks = 0
        lastQualitySize = .zero
        lastQualityBitrate = 0
        gateLog("new item cap=\(Int(maxResolution.width))x\(Int(maxResolution.height)) bitrate=\(Int(peakBitRate))")
        player.replaceCurrentItem(with: item)

        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            if asset.statusOfValue(forKey: "tracks", error: nil) == .loaded {
                let tracks = asset.tracks(withMediaType: .video)
                if let videoTrack = tracks.first {
                    videoTrack.loadValuesAsynchronously(forKeys: ["preferredTransform"]) { [weak self] in
                        guard let self = self, !self.disposed else { return }
                        if videoTrack.statusOfValue(forKey: "preferredTransform", error: nil) == .loaded {
                            self.preferredTransform = self.fixTransform(videoTrack)
                            let videoComposition = self.getVideoComposition(transform: self.preferredTransform, asset: asset, videoTrack: videoTrack)
                            item.videoComposition = videoComposition
                        }
                    }
                }
            }
        }
        addObservers(item)
    }

    private func handleStalled() {
        if isStalledCheckStarted { return }
        isStalledCheckStarted = true
        gateLog("stall detected pendingSeeks=\(pendingSeeks)")
        startStalledCheck()
    }

    private func startStalledCheck() {
        if let currentItem = player.currentItem {
            let resumeBuffer = bufferForPlaybackAfterRebufferDuration > 0 ? bufferForPlaybackAfterRebufferDuration : 10.0
            let ahead = bufferedAhead()
            // Keep counting while a seek is in flight but don't restart under it.
            // A seek on an item whose HLS connections died (long lock/background)
            // may never complete; the 60-try error below is what lets the app
            // reload the slot, so the check itself must never be skipped.
            if pendingSeeks == 0 && (currentItem.isPlaybackLikelyToKeepUp || ahead >= resumeBuffer) {
                gateLog(String(format: "stall -> resume ahead=%.1fs need=%.1fs", ahead, resumeBuffer))
                play()
            } else {
                stalledCount += 1
                gateLog(String(format: "stall check #%d ahead=%.1fs need=%.1fs likely=%@ pendingSeeks=%d",
                               stalledCount, ahead, resumeBuffer,
                               currentItem.isPlaybackLikelyToKeepUp ? "y" : "n", pendingSeeks))
                if stalledCount > 60 {
                    gateLog("stall -> VideoError playback stalled")
                    if let eventSink = eventSink {
                        let error = FlutterError(code: "VideoError", message: "Failed to load video: playback stalled", details: nil)
                        eventSink(error)
                    }
                    return
                }
                perform(#selector(startStalledCheckObjC), with: nil, afterDelay: 1)
            }
        }
    }

    @objc private func startStalledCheckObjC() { startStalledCheck() }

    private func hasEnoughStartupBuffer() -> Bool {
        guard bufferForPlaybackDuration > 0 else { return true }
        if player.currentItem?.isPlaybackLikelyToKeepUp == true { return true }
        return bufferedAhead() >= bufferForPlaybackDuration
    }

    // Seconds buffered ahead of the playhead, from the loaded range that contains
    // it (like ExoPlayer's buffered duration). loadedTimeRanges.first can be a
    // range behind the playhead after a forward seek or a resume.
    private func bufferedAhead() -> TimeInterval {
        guard let item = player.currentItem else { return 0 }
        let now = item.currentTime()
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            if CMTimeRangeContainsTime(range, time: now) {
                return CMTimeGetSeconds(CMTimeRangeGetEnd(range)) - CMTimeGetSeconds(now)
            }
        }
        return 0
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "rate" {
            if #available(iOS 10.0, *), let pipController = pipController, pipController.isPictureInPictureActive {
                if let last = lastAvPlayerTimeControlStatus, last == player.timeControlStatus {
                    return
                }
                if player.timeControlStatus == .paused {
                    lastAvPlayerTimeControlStatus = player.timeControlStatus
                    eventSink?(["event": "pause"])
                    return
                }
                if player.timeControlStatus == .playing {
                    lastAvPlayerTimeControlStatus = player.timeControlStatus
                    eventSink?(["event": "play"])
                }
            }

            if player.rate == 0 && CMTimeCompare(player.currentItem?.currentTime() ?? .zero, .zero) == 1 && (player.currentItem?.duration ?? .zero).isValid && CMTimeCompare(player.currentItem?.currentTime() ?? .zero, player.currentItem?.duration ?? .zero) == -1 && isPlaying {
                handleStalled()
            }
        }

        if context == &timeRangeContext {
            if let eventSink = eventSink, let item = object as? AVPlayerItem {
                var values: [[NSNumber]] = []
                for rangeValue in item.loadedTimeRanges {
                    let range = rangeValue.timeRangeValue
                    var start = NSNumber(value: BetterPlayerTimeUtils.cmTimeToMillis(range.start))
                    var end = NSNumber(value: BetterPlayerTimeUtils.cmTimeToMillis(range.start) + BetterPlayerTimeUtils.cmTimeToMillis(range.duration))
                    if let endTime = player.currentItem?.forwardPlaybackEndTime, !CMTIME_IS_INVALID(endTime) {
                        let endTimeMs = BetterPlayerTimeUtils.cmTimeToMillis(endTime)
                        if end.int64Value > endTimeMs { end = NSNumber(value: endTimeMs) }
                    }
                    values.append([start, end])
                }
                eventSink(["event": "bufferingUpdate", "values": values, "key": key as Any])
            }
            // Startup gate, ExoPlayer-style: start as soon as bufferForPlaybackDuration
            // is buffered instead of waiting for AVFoundation's (much more
            // conservative) isPlaybackLikelyToKeepUp. Stall recovery stays with
            // startStalledCheck, hence the isStalledCheckStarted guard.
            if isInitialized && isPlaying && player.rate == 0 && !isStalledCheckStarted && pendingSeeks == 0 && hasEnoughStartupBuffer() {
                gateLog(String(format: "start gate -> play ahead=%.1fs", bufferedAhead()))
                updatePlayingState()
            }
        } else if context == &presentationSizeContext {
            onReadyToPlay()
            emitQualityIfChanged()
        } else if context == &statusContext {
            if let item = object as? AVPlayerItem {
                switch item.status {
                case .failed:
                    NSLog("Failed to load video: \(String(describing: item.error?.localizedDescription))")
                    if let eventSink = eventSink {
                        let message = "Failed to load video: \(item.error?.localizedDescription ?? "unknown")"
                        let error = FlutterError(code: "VideoError", message: message, details: nil)
                        eventSink(error)
                    }
                case .unknown:
                    break
                case .readyToPlay:
                    onReadyToPlay()
                @unknown default:
                    break
                }
            }
        } else if context == &playbackLikelyToKeepUpContext {
            if player.currentItem?.isPlaybackLikelyToKeepUp == true {
                updatePlayingState()
                eventSink?(["event": "bufferingEnd", "key": key as Any])
            }
        } else if context == &playbackBufferEmptyContext {
            eventSink?(["event": "bufferingStart", "key": key as Any])
        } else if context == &playbackBufferFullContext {
            eventSink?(["event": "bufferingEnd", "key": key as Any])
        }
    }

    public func updatePlayingState() {
        guard isInitialized, key != nil else { return }
        if !observersAdded, let current = player.currentItem { addObservers(current) }
        if isPlaying {
            guard canStartPlayback else { return }
            // Each rate change is a sync XPC to mediaserverd; when it is slow the
            // main thread blocks reading rate state (app hangs, ALRIGHT-APP-11M).
            // One SetRate per play, none when already at the target rate.
            if player.rate != playerRate { player.playImmediately(atRate: playerRate) }
        } else if player.rate != 0 {
            // Warm slots land here on every readyToPlay/likelyToKeepUp while
            // already paused; skip the no-op SetRate.
            player.pause()
        }
    }

    public func onReadyToPlay() {
        guard let eventSink = eventSink, !isInitialized, key != nil else { return }
        guard player.currentItem != nil else { return }
        guard player.status == .readyToPlay else { return }

        let size = player.currentItem?.presentationSize ?? .zero
        var width = size.width
        var height = size.height

        let asset = player.currentItem!.asset
        let onlyAudio = asset.tracks(withMediaType: .video).count == 0
        if !onlyAudio && height == .zero && width == .zero {
            return
        }
        let isLive = CMTIME_IS_INDEFINITE(player.currentItem!.duration)
        if !isLive && duration() == 0 { return }

        if let track = player.currentItem?.tracks.first?.assetTrack {
            let naturalSize = track.naturalSize
            let prefTrans = track.preferredTransform
            let realSize = naturalSize.applying(prefTrans)
            width = abs(realSize.width) != 0 ? abs(realSize.width) : width
            height = abs(realSize.height) != 0 ? abs(realSize.height) : height
        }

        let durMs = BetterPlayerTimeUtils.cmTimeToMillis(player.currentItem!.asset.duration)
        if overriddenDuration > 0 && durMs > Int64(overriddenDuration) {
            player.currentItem?.forwardPlaybackEndTime = CMTimeMake(value: Int64(overriddenDuration/1000), timescale: 1)
        }

        isInitialized = true
        if hasEnoughStartupBuffer() {
            updatePlayingState()
        }
        // else: leave playback paused for now. The playbackLikelyToKeepUp KVO
        // observer below already calls updatePlayingState() as soon as
        // AVFoundation reports enough buffer to keep up, so this state isn't
        // stuck — it just waits instead of starting on an empty buffer.
        eventSink(["event": "initialized",
                   "duration": NSNumber(value: duration()),
                   "width": NSNumber(value: Float(width)),
                   "height": NSNumber(value: Float(height)),
                   "key": key as Any])
    }

    public func play() {
        stalledCount = 0
        isStalledCheckStarted = false
        isPlaying = true
        updatePlayingState()
    }

    public func pause() {
        isPlaying = false
        updatePlayingState()
    }

    public func position() -> Int64 {
        return BetterPlayerTimeUtils.cmTimeToMillis(player.currentTime())
    }

    public func absolutePosition() -> Int64 {
        let interval = player.currentItem?.currentDate()?.timeIntervalSince1970 ?? 0
        return BetterPlayerTimeUtils.timeIntervalToMillis(interval)
    }

    public func duration() -> Int64 {
        let time: CMTime
        if #available(iOS 13, *) {
            time = player.currentItem?.duration ?? .zero
        } else {
            time = player.currentItem?.asset.duration ?? .zero
        }
        if let endTime = player.currentItem?.forwardPlaybackEndTime, !CMTIME_IS_INVALID(endTime) {
            return BetterPlayerTimeUtils.cmTimeToMillis(endTime)
        }
        return BetterPlayerTimeUtils.cmTimeToMillis(time)
    }

    public func seekTo(_ location: Int) {
        let wasPlaying = isPlaying
        if wasPlaying { player.pause() }
        pendingSeeks += 1
        gateLog("seek start to=\(location)ms wasPlaying=\(wasPlaying) pendingSeeks=\(pendingSeeks)")
        // Called for every seek, also with finished=false when a newer seek supersedes it.
        player.seek(to: CMTimeMake(value: Int64(location), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self = self else { return }
            self.pendingSeeks = max(0, self.pendingSeeks - 1)
            self.gateLog("seek done finished=\(finished) pendingSeeks=\(self.pendingSeeks)")
            if wasPlaying && self.canStartPlayback { self.player.rate = self.playerRate }
        }
    }

    public func setVolume(_ volume: Double) {
        let v = max(0.0, min(1.0, volume))
        player.volume = Float(v)
    }

    public func setSpeed(_ speed: Double, result: FlutterResult) {
        if speed == 1.0 || speed == 0.0 {
            playerRate = 1
            result(nil)
        } else if speed < 0 || speed > 2.0 {
            result(FlutterError(code: "unsupported_speed", message: "Speed must be >= 0.0 and <= 2.0", details: nil))
        } else if (speed > 1.0 && (player.currentItem?.canPlayFastForward ?? false)) || (speed < 1.0 && (player.currentItem?.canPlaySlowForward ?? false)) {
            playerRate = Float(speed)
            result(nil)
        } else {
            if speed <= 1.0 {
                result(FlutterError(code: "unsupported_slow_forward", message: "This video cannot be played slow forward", details: nil))
            }
        }

        if isPlaying && canStartPlayback {
            if #available(iOS 16, *) {
                player.defaultRate = Float(speed)
            }
            player.rate = Float(speed)
        }
    }

    public func setTrackParameters(width: Int, height: Int, bitrate: Int) {
        // Same rules as Android's BetterPlayer.setTrackParameters.
        if width != 0 && height != 0 {
            maxResolution = CGSize(width: width, height: height)
        }
        if bitrate != 0 {
            peakBitRate = Double(bitrate)
        }
        if width == 0 && height == 0 && bitrate == 0 {
            maxResolution = .zero
            peakBitRate = 0
        }
        if let item = player.currentItem {
            applyTrackCap(item)
        }
    }

    private func gateLog(_ message: String) {
        // Both: stdout reaches `flutter run`, NSLog (os_log) survives a detached
        // run and shows up in Console / `log collect`.
        let line = "[BPGate] \(message) key=\(key ?? "-")"
        print(line)
        NSLog("%@", line)
    }

    private func applyTrackCap(_ item: AVPlayerItem) {
        item.preferredPeakBitRate = peakBitRate
        if #available(iOS 11.0, *) {
            item.preferredMaximumResolution = maxResolution
        }
    }

    public func setPictureInPicture(_ pictureInPicture: Bool) {
        self.pictureInPicture = pictureInPicture
        if #available(iOS 9.0, *) {
            if let pip = pipController, self.pictureInPicture && !pip.isPictureInPictureActive {
                DispatchQueue.main.async { pip.startPictureInPicture() }
            } else if let pip = pipController, !self.pictureInPicture && pip.isPictureInPictureActive {
                DispatchQueue.main.async { pip.stopPictureInPicture() }
            }
        }
    }

    public func setRestoreUserInterfaceForPIPStopCompletionHandler(_ restore: Bool) {
        restoreUIOnPipStop?(restore)
        restoreUIOnPipStop = nil
    }

    private func setupPipController() {
        if #available(iOS 9.0, *) {
            try? AVAudioSession.sharedInstance().setActive(true)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            if pipController == nil, let layer = playerLayerRef, AVPictureInPictureController.isPictureInPictureSupported() {
                pipController = AVPictureInPictureController(playerLayer: layer)
                pipController?.delegate = self
            }
        }
    }

    public func enablePictureInPicture(_ frame: CGRect) {
        disablePictureInPicture()
        usePlayerLayer(frame)
    }

    private func usePlayerLayer(_ frame: CGRect) {
        let layer = AVPlayerLayer(player: player)
        if #available(iOS 13.0, *) {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first,
               let rootVC = window.rootViewController {
                layer.frame = frame
                layer.needsDisplayOnBoundsChange = true
                rootVC.view.layer.addSublayer(layer)
                rootVC.view.layer.needsDisplayOnBoundsChange = true
                playerLayerRef = layer
                pipController = nil
                setupPipController()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.setPictureInPicture(true)
                }
            }
        } else {
            if let window = UIApplication.shared.keyWindow ?? UIApplication.shared.windows.first,
               let rootVC = window.rootViewController {
                layer.frame = frame
                layer.needsDisplayOnBoundsChange = true
                rootVC.view.layer.addSublayer(layer)
                rootVC.view.layer.needsDisplayOnBoundsChange = true
                playerLayerRef = layer
                pipController = nil
                setupPipController()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.setPictureInPicture(true)
                }
            }
        }
    }

    public func disablePictureInPicture() {
        setPictureInPicture(true)
        if let layer = playerLayerRef {
            layer.removeFromSuperlayer()
            playerLayerRef = nil
            eventSink?(["event": "pipStop"])
        }
    }

    // MARK: - AVPictureInPictureControllerDelegate
    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        disablePictureInPicture()
    }

    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        eventSink?(["event": "pipStart"])
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoreUIOnPipStop = completionHandler
        setRestoreUserInterfaceForPIPStopCompletionHandler(true)
    }

    // MARK: - Audio & Tracks
    public func setAudioTrack(name: String, index: Int) {
        guard let group = player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else { return }
        let options = group.options
        for audioTrackIndex in 0..<options.count {
            let option = options[audioTrackIndex]
            let metas = AVMetadataItem.metadataItems(from: option.commonMetadata, withKey: "title" as (NSCopying & NSObjectProtocol), keySpace: AVMetadataKeySpace(rawValue: "comn"))
            if let title = metas.first?.stringValue, title == name && audioTrackIndex == index {
                player.currentItem?.select(option, in: group)
            }
        }
    }

    public func setMixWithOthers(_ mixWithOthers: Bool) {
        if mixWithOthers {
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
        }
    }

    // MARK: - FlutterStreamHandler
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        onReadyToPlay()
        return nil
    }

    public func clear() {
        isInitialized = false
        isPlaying = false
        disposed = false
        failedCount = 0
        key = nil
        guard player.currentItem != nil else { return }
        removeObservers()
        player.currentItem?.asset.cancelLoading()
    }

    public func disposeSansEventChannel() {
        do {
            clear()
        }
    }

    public func dispose() {
        pause()
        disposeSansEventChannel()
        eventChannel?.setStreamHandler(nil)
        disablePictureInPicture()
        setPictureInPicture(false)
        disposed = true
    }
}
