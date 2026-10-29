import AVKit
import Observation
import BiliMacMedia
import BiliMacCore

@MainActor @Observable final class PlayerController {
    let player = AVPlayer()
    @ObservationIgnored lazy var surface: PlayerSurface = {
        let view = PlayerSurface()
        view.controller = self; view.player = player
        return view
    }()
    var detail: VideoDetail?
    var requestedBVID: String?
    var manifest: BiliMacCore.PlaybackManifest?
    var cid = 0
    var quality = 0
    var loading = false
    var error: String?
    var position = 0.0
    var duration = 0.0
    var playing = false
    var buffering = false
    var danmaku: [Danmaku] = []
    var danmakuError: String?
    var rate: Float = 1
    var onProgress: ((Video, Int, Double) -> Void)?
    private var session: PreparedStream?
    private let bridge: any PlaybackPreparing
    init(bridge: any PlaybackPreparing = NativePlaybackBridge()) {
        self.bridge = bridge
        configurePlayer()
    }
    private var task: Task<Void, Never>?
    private var danmakuTask: Task<Void, Never>?
    private var generation = UUID()
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var controlObserver: NSKeyValueObservation?
    private var lastSaved = -5.0
    private var pending: (position: Double, playing: Bool)?
    private var positions: [String: Double] = [:]
    var isOpen: Bool { detail != nil || loading }
    var intendedPlaying: Bool { pending?.playing ?? playing }
    private func configurePlayer() {
        player.preventsDisplaySleepDuringVideoPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.pending == nil, time.seconds.isFinite else { return }
                self.position = max(0,time.seconds)
                let length = self.player.currentItem?.duration.seconds ?? 0
                if length.isFinite, length > 0 { self.duration = length }
                if abs(self.position - self.lastSaved) >= 5 { self.lastSaved = self.position; self.saveProgress() }
            }
        }
        controlObserver = player.observe(\.timeControlStatus, options: [.initial,.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }; self.playing = self.player.rate > 0
                self.buffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
    }
    func open(_ bvid: String, client: BilibiliClient, record: WatchRecord?, playing: Bool? = nil) {
        stop(); let identity = generation; loading = true; requestedBVID = bvid
        pending = (record?.position ?? 0, playing ?? AppSettings.defaults.bool(forKey: "autoPlay"))
        positions = record?.positions ?? [:]
        task = Task {
            do {
                let detail = try await client.detail(bvid)
                guard identity == generation, !Task.isCancelled else { return }
                self.detail = detail
                let page = detail.pages.first { $0.id == record?.cid } ?? detail.pages[0]
                cid = page.id
                let position = WatchRecord.resumePosition(record?.position ?? 0, duration: Double(page.duration))
                try await prepare(client: client, quality: nil, position: position, playing: pending?.playing ?? false, identity: identity)
            } catch { fail(error, identity: identity) }
        }
    }
    private func prepare(client: BilibiliClient, quality requested: Int?, position: Double, playing: Bool, identity: UUID) async throws {
        guard let detail else { return }
        pending = (position, playing); self.position = position; loading = true; error = nil
        let manifest = try await client.manifest(bvid: detail.video.bvid, cid: cid)
        try Task.checkCancellation(); guard identity == generation else { return }
        self.manifest = manifest
        let preference = requested ?? AppSettings.defaults.integer(forKey: "quality")
        let selected = manifest.qualities.contains(preference) ? preference : manifest.qualities.first!
        guard let video = manifest.videos.first(where: { $0.id == selected && $0.codec.hasPrefix("avc1") }) ?? manifest.videos.first(where: { $0.id == selected }) else { throw ClientError.noPlayableMedia }
        let asset = try await bridge.prepare(video: video, audio: manifest.audio, headers: BilibiliClient.mediaHeaders, start: position > 0 ? position : nil)
        guard identity == generation, !Task.isCancelled else { asset.stop(); return }
        session?.stop(); session = asset; self.quality = selected
        AppSettings.defaults.set(selected, forKey: "quality")
        let item = AVPlayerItem(url: asset.url); item.preferredForwardBufferDuration = 10
        player.replaceCurrentItem(with: item)
        statusObserver = item.observe(\.status, options: [.initial,.new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, identity == self.generation, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    // EXT-X-START alone does not establish the media position
                    // for an item prepared while paused. Keep pending intent
                    // until the system has completed the explicit seek.
                    if let target = self.pending?.position, target > 0 {
                        let located = await withCheckedContinuation { continuation in
                            self.player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
                        }
                        guard identity == self.generation, self.player.currentItem === item else { return }
                        guard located else { self.fail(ClientError.server(0, "播放位置恢复失败，请重试。"), identity: identity); return }
                    }
                    let intent = self.pending?.playing ?? playing
                    let actual = self.player.currentTime().seconds
                    if actual.isFinite { self.position = max(0, actual) }
                    self.pending = nil; self.loading = false
                    self.rate = Float(AppSettings.defaults.double(forKey: "playbackRate"))
                    if intent { self.player.playImmediately(atRate: self.rate) }
                case .failed: self.fail(item.error ?? ClientError.noPlayableMedia, identity: identity)
                default: break
                }
            }
        }
        startDanmaku(client: client, identity: identity)
        // A finite deadline also covers a ready item that never obtains playable media.
        try await Task.sleep(for: .seconds(30))
        guard identity == generation else { return }
        // Native controls can pause immediately after ready. A paused item is
        // user intent, whereas waiting with no media progress is a stalled start.
        if loading || (player.timeControlStatus == .waitingToPlayAtSpecifiedRate && player.currentTime().seconds <= position + 0.01) {
            fail(ClientError.server(0,"媒体未能开始播放，请重试或切换画质"), identity: identity)
        }
    }
    func change(client: BilibiliClient, cid newCID: Int? = nil, quality: Int? = nil) {
        guard detail != nil else { return }
        let resume = pending ?? (position: position, playing: playing)
        saveProgress(); task?.cancel(); danmakuTask?.cancel(); generation = UUID()
        let identity = generation
        statusObserver = nil; player.pause(); player.replaceCurrentItem(with: nil); session?.stop(); session = nil; danmaku = []
        var targetPosition = resume.position
        if let newCID {
            cid = newCID; duration = 0
            targetPosition = AppSettings.defaults.bool(forKey: "rememberPosition") ? WatchRecord.resumePosition(positions[String(newCID)] ?? 0, duration: Double(detail?.pages.first { $0.id == newCID }?.duration ?? 0)) : 0
        }
        task = Task {
            do { try await prepare(client: client, quality: quality, position: targetPosition, playing: resume.playing, identity: identity) }
            catch { fail(error, identity: identity) }
        }
    }
    private func startDanmaku(client: BilibiliClient, identity: UUID) {
        danmakuTask?.cancel(); let currentCID = cid
        danmakuTask = Task {
            var segments: [Int: [Danmaku]] = [:]
            while !Task.isCancelled, identity == generation {
                let current = max(1, Int(position / 360) + 1)
                for index in current...current+1 where segments[index] == nil {
                    do {
                        let items = try await client.danmaku(cid: currentCID, segment: index)
                        guard identity == generation, !Task.isCancelled else { return }
                        segments[index] = items; danmakuError = nil
                    } catch { if !Task.isCancelled { danmakuError = "弹幕暂未加载，可继续观看" } }
                }
                segments = segments.filter { abs($0.key - current) <= 1 }
                var seen = Set<String>()
                danmaku = segments.values.flatMap { $0 }.filter { seen.insert($0.id).inserted }.sorted { $0.time < $1.time }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    func toggle() {
        if pending != nil { pending?.playing.toggle(); return }
        if player.rate > 0 { player.pause(); saveProgress() }
        else { if duration > 0, position >= duration - 0.25 { seek(0) }; player.playImmediately(atRate: rate) }
    }
    func pause() {
        if pending != nil { pending?.playing = false }
        player.pause(); playing = false; saveProgress()
    }
    func seek(_ seconds: Double) { guard seconds.isFinite else { return }; player.seek(to: CMTime(seconds: min(max(0,seconds), max(0,duration)), preferredTimescale: 600)) }
    func setRate(_ value: Float) { rate = value; AppSettings.defaults.set(Double(value), forKey: "playbackRate"); if player.rate > 0 { player.rate = value } }
    func saveProgress() { if pending == nil, let video = detail?.video, cid > 0 { positions[String(cid)] = position; onProgress?(video,cid,position) } }
    func stop() {
        saveProgress(); generation = UUID(); task?.cancel(); danmakuTask?.cancel(); task = nil; danmakuTask = nil
        statusObserver = nil; player.pause(); player.replaceCurrentItem(with: nil); session?.stop(); session = nil
        detail = nil; requestedBVID = nil; manifest = nil; danmaku = []; danmakuError = nil; pending = nil; loading = false; error = nil; positions = [:]
        position = 0; duration = 0; cid = 0; playing = false; buffering = false; lastSaved = -5
    }
    private func fail(_ failure: Error, identity: UUID) {
        guard identity == generation, !(failure is CancellationError), !Task.isCancelled else { return }
        loading = false; error = session?.lastFailure ?? failure.localizedDescription; pending = nil
        danmakuTask?.cancel(); danmakuTask = nil
        player.pause(); player.replaceCurrentItem(with: nil); session?.stop(); session = nil
    }
    func showDemo(_ video: Video) { stop(); detail = VideoDetail(video: video, description: "这是明确标记的离线界面演示，不会发起账号或媒体请求。正常启动即可连接 B 站。", pages: [VideoPage(id:1,title:"演示内容",duration:video.duration)]); cid = 1; duration = Double(video.duration); error = "演示模式不加载线上媒体" }
    isolated deinit { task?.cancel(); danmakuTask?.cancel(); if let timeObserver { player.removeTimeObserver(timeObserver) }; player.pause(); session?.stop() }
}
