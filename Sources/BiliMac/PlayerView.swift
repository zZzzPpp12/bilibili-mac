import SwiftUI
import AVKit
import BiliMacCore

struct PlayerPage: View {
    @Bindable var store: AppStore
    @AppStorage("danmakuEnabled", store: AppSettings.defaults) private var enabled = true
    @AppStorage("danmakuOpacity", store: AppSettings.defaults) private var opacity = 0.8
    @State private var presentation = ScrollPlaybackPresentation()
    private let videoAnchor = "inline-video"
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ZStack {
                        if presentation.inlineVisible {
                            playbackSurface(mini: false)
                        } else {
                            Color.black.overlay {
                                Label(presentation.dismissed ? "视频已暂停并收起" : "视频已移至右下角小窗", systemImage: "pip")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }.aspectRatio(16/9, contentMode: .fit).frame(maxHeight: 580).background(.black).clipShape(.rect(cornerRadius: 18))
                        .id(videoAnchor)
                        .onScrollVisibilityChange(threshold: 0.2) { presentation.setInlineVisible($0) }
                    HStack(spacing: 18) {
                        if let manifest = store.player.manifest {
                            Picker("画质", selection: Binding(get: { store.player.quality }, set: { store.player.change(client:store.client,quality:$0) })) {
                                ForEach(manifest.qualities, id: \.self) { value in Text(manifest.qualityNames[value] ?? "画质 \(value)").tag(value) }
                            }.frame(width: 175)
                        }
                        Picker("倍速", selection: Binding(get:{ store.player.rate }, set:{ store.player.setRate($0) })) {
                            ForEach([Float(0.75),1,1.25,1.5,2], id: \.self) { Text("\(Double($0).formatted())×").tag($0) }
                        }.frame(width: 125)
                        Toggle("弹幕", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
                        Spacer()
                        Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.glass).accessibilityLabel("切换窗口全屏")
                        Button { store.leavePlayer() } label: { Label("小窗播放",systemImage:"pip") }.buttonStyle(.glass)
                    }
                    if let detail = store.player.detail {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(detail.video.title).font(.system(size: 23, weight: .bold)).textSelection(.enabled)
                            HStack(spacing: 18) {
                                if let mid = detail.video.authorID {
                                    Button { store.openProfile(mid) } label: { Label(detail.video.author, systemImage: "person.crop.circle") }
                                        .buttonStyle(.plain).accessibilityLabel("查看 UP 主 \(detail.video.author) 的主页")
                                } else { Label(detail.video.author, systemImage: "person.crop.circle") }
                                Label("\(DisplayFormat.count(detail.video.views)) 次播放", systemImage: "play.rectangle"); Text(detail.video.bvid)
                            }.font(.callout).foregroundStyle(.secondary)
                        }
                        VideoInteractionsView(store: store, model: store.interactions.model(for: detail.video))
                            .id("\(detail.video.bvid)-\(store.account?.id ?? 0)")
                        VideoLibraryActions(store: store, video: detail.video).id(detail.video.bvid)
                        if detail.pages.count > 1 {
                            VStack(alignment:.leading, spacing:12) {
                                Text("视频分 P").font(.headline)
                                LazyVGrid(columns:[GridItem(.adaptive(minimum:190))],spacing:10) {
                                    ForEach(Array(detail.pages.enumerated()),id:\.element.id) { index, page in
                                        Button { store.player.change(client:store.client,cid:page.id) } label: {
                                            Text("P\(index+1) · \(page.title)").lineLimit(1).frame(maxWidth:.infinity,alignment:.leading).padding(12).background(store.player.cid == page.id ? accent.opacity(0.12) : Color.primary.opacity(0.04),in:.rect(cornerRadius:10))
                                        }.buttonStyle(.plain).foregroundStyle(store.player.cid == page.id ? accent : .primary)
                                    }
                                }
                            }
                        }
                        if let error = store.player.danmakuError { Label(error,systemImage:"text.bubble").font(.caption).foregroundStyle(.secondary) }
                        if !detail.description.isEmpty { Text(detail.description).font(.callout).foregroundStyle(.secondary).lineSpacing(6).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(20).background(.quaternary.opacity(0.3),in:.rect(cornerRadius:14)) }
                        if !store.isDemo, detail.video.aid > 0 {
                            CommentsSection(model: store.comments, actions: store.commentActions.model(for: detail.video), aid: detail.video.aid, accountID: store.account?.id, openUser: store.openProfile) { store.showLogin = true }
                                .id("\(detail.video.bvid)-\(store.account?.id ?? 0)")
                        }
                    }
                }.padding(30)
            }
            .overlay(alignment: .bottomTrailing) {
                if presentation.floating && store.player.isOpen {
                    floatingPlayer {
                        withAnimation(.easeInOut(duration: 0.2)) { scroll.scrollTo(videoAnchor, anchor: .top) }
                    }.padding(20)
                }
            }
            .onChange(of: store.player.requestedBVID) { _, _ in
                presentation.reset()
                scroll.scrollTo(videoAnchor, anchor: .top)
            }
        }
    }
    private func playbackSurface(mini: Bool) -> some View {
        ZStack {
            NativePlayer(controller: store.player, items: !mini && enabled ? store.player.danmaku : [], opacity: mini ? 0 : opacity)
            if store.player.loading {
                VStack(spacing: 10) { ProgressView().tint(.white); Text("正在准备播放…").font(.callout) }
                    .foregroundStyle(.white).padding(18).background(.black.opacity(0.7), in: .rect(cornerRadius: 12))
            }
            if let error = store.player.error {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash").font(.title2)
                    Text(error).multilineTextAlignment(.center).font(mini ? .caption : .callout).lineLimit(mini ? 3 : nil)
                    if !store.isDemo { Button("重新播放") { if let bvid = store.player.requestedBVID { store.open(bvid) } }.buttonStyle(.glass) }
                }.foregroundStyle(.white).padding(18).frame(maxWidth: 470).background(.black.opacity(0.8), in: .rect(cornerRadius: 12))
            }
        }
    }
    private func floatingPlayer(returnToVideo: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("边看边聊").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.player.pause(); presentation.dismiss()
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("暂停并收起小窗").accessibilityLabel("暂停并收起自动小窗")
            }
            playbackSurface(mini: true).aspectRatio(16/9, contentMode: .fit)
                .background(.black).clipShape(.rect(cornerRadius: 10))
            Text(store.player.detail?.video.title ?? "正在加载…").font(.callout.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button { store.player.toggle() } label: { Image(systemName: store.player.intendedPlaying ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(store.player.intendedPlaying ? "暂停小窗视频" : "播放小窗视频")
                    .disabled(store.player.error != nil)
                Spacer()
                Button("回到视频", action: returnToVideo)
            }.buttonStyle(.glass)
        }.padding(12).frame(width: 320).glassEffect(.regular, in: .rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.24), radius: 16, y: 5)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("automatic-mini-player")
    }
}

struct MiniPlayer: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(spacing: 10) {
            HStack { Text("继续观看").font(.caption).foregroundStyle(.secondary); Spacer(); Button { store.closePlayer() } label: { Image(systemName:"xmark") }.buttonStyle(.plain).accessibilityLabel("关闭播放器") }
            NativePlayer(controller:store.player,items:[],opacity:0).frame(height:160).clipShape(.rect(cornerRadius:10))
            Text(store.player.detail?.video.title ?? "正在加载…").font(.callout.weight(.semibold)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
            HStack {
                Button { store.player.toggle() } label: { Image(systemName:store.player.playing ? "pause.fill" : "play.fill") }.accessibilityLabel("播放或暂停")
                Spacer()
                Button("返回播放页") { store.showPlayer = true }
            }.buttonStyle(.glass)
        }.padding(12).frame(width:290).glassEffect(.regular,in:.rect(cornerRadius:20))
    }
}

final class PlayerSurface: AVPlayerView, NSGestureRecognizerDelegate {
    weak var controller: PlayerController?
    fileprivate var presentationOwner: UUID?
    let overlay = DanmakuSurface()
    private var wheelMonitor: Any?
    override init(frame: NSRect) {
        super.init(frame:frame); controlsStyle = .inline; videoGravity = .resizeAspect; allowsPictureInPicturePlayback = true
        overlay.wantsLayer = true; overlay.layer?.backgroundColor = NSColor.clear.cgColor
        contentOverlayView?.addSubview(overlay)
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleFromVideo))
        click.delegate = self; click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); overlay.frame = contentOverlayView?.bounds ?? bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stopInputMonitoring()
        guard window != nil else { return }
        // AVKit's child views consume wheel events before AVPlayerView's own
        // responder method. Route only picture events, in this window, before
        // those children can turn a comments-page scroll into a media seek.
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.visibleRect.contains(point), self.isPicture(at: point),
                  let recipient = self.enclosingScrollView ?? self.nextResponder else { return event }
            recipient.scrollWheel(with: event)
            return nil
        }
    }
    func stopInputMonitoring() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor); self.wheelMonitor = nil }
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event:NSEvent) { window?.makeFirstResponder(self); super.mouseDown(with:event) }
    override func scrollWheel(with event: NSEvent) {
        // AVPlayerView otherwise consumes a wheel over the picture as scrubbing.
        // Keep the enclosing comments page scrollable without seeking the video.
        nextResponder?.scrollWheel(with: event)
    }
    @objc private func toggleFromVideo(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended, controller?.error == nil else { return }
        window?.makeFirstResponder(self); controller?.toggle()
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 1 else { return false }
        return isPicture(at: convert(event.locationInWindow, from: nil))
    }
    private func isPicture(at point: NSPoint) -> Bool {
        // Let the system own its controls, menus, timeline and drag gestures.
        // Reserve its lower control strip even when those controls are hidden.
        guard bounds.contains(point), controlsStyle == .none || (isFlipped ? point.y < bounds.height - 76 : point.y > 76) else { return false }
        var hit = hitTest(convert(point, to: superview))
        while let view = hit, view !== self {
            if view is NSControl { return false }
            hit = view.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
    isolated deinit { if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) } }
    override func keyDown(with event:NSEvent) {
        guard event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { super.keyDown(with:event); return }
        switch event.keyCode {
        case 49: controller?.toggle()
        case 123: if let controller { controller.seek(controller.position-5) }
        case 124: if let controller { controller.seek(controller.position+5) }
        default: super.keyDown(with:event)
        }
    }
}

/// A stable AVPlayerView moves between presentation slots. Recreating that
/// view while paused can leave the new video layer black until playback resumes.
final class PlayerContainer: NSView {
    private let owner = UUID()
    private weak var surface: PlayerSurface?
    var ownsSurface: Bool { surface?.presentationOwner == owner }
    init(surface: PlayerSurface) {
        self.surface = surface
        super.init(frame: surface.bounds)
        surface.presentationOwner = owner
        surface.removeFromSuperview()
        surface.frame = bounds; surface.autoresizingMask = [.width, .height]
        addSubview(surface)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func releaseSurface() {
        // SwiftUI may dismantle the old slot after mounting the new one.
        guard ownsSurface, let surface else { return }
        surface.presentationOwner = nil
        surface.stopInputMonitoring(); surface.overlay.stop(); surface.removeFromSuperview()
    }
}
struct NativePlayer: NSViewRepresentable {
    let controller: PlayerController
    let items: [Danmaku]
    let opacity: Double
    func makeNSView(context:Context) -> PlayerContainer {
        let surface = controller.surface
        // Keep AVKit's controls controller stable as the same view moves.
        // Rebuilding it with setControlsStyle during an active scroll caused
        // a nested KVO exception inside AVKit on macOS 26.
        return PlayerContainer(surface: surface)
    }
    func updateNSView(_ container: PlayerContainer,context:Context) {
        guard container.ownsSurface else { return }
        let surface = controller.surface
        surface.overlay.update(player:controller.player, items:items, opacity:opacity)
    }
    static func dismantleNSView(_ view: PlayerContainer,coordinator:()) { view.releaseSurface() }
}
