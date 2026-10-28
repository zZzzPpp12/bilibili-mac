import SwiftUI
import AVKit
import BiliMacCore

struct PlayerPage: View {
    @Bindable var store: AppStore
    @AppStorage("danmakuEnabled", store: AppSettings.defaults) private var enabled = true
    @AppStorage("danmakuOpacity", store: AppSettings.defaults) private var opacity = 0.8
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ZStack {
                    NativePlayer(controller: store.player, items: enabled ? store.player.danmaku : [], opacity: opacity)
                    if store.player.loading {
                        VStack(spacing: 12) { ProgressView().tint(.white); Text("正在准备播放…").font(.callout).foregroundStyle(.white) }.padding(22).background(.black.opacity(0.65), in: .rect(cornerRadius: 16))
                    }
                    if let error = store.player.error {
                        VStack(spacing: 14) {
                            Image(systemName: "play.slash").font(.title)
                            Text(error).multilineTextAlignment(.center).font(.callout)
                            if !store.isDemo { Button("重新播放") { if let bvid = store.player.requestedBVID { store.open(bvid) } }.buttonStyle(.glass) }
                        }.foregroundStyle(.white).padding(26).frame(maxWidth: 470).background(.black.opacity(0.8), in: .rect(cornerRadius: 16))
                    }
                }.aspectRatio(16/9, contentMode: .fit).frame(maxHeight: 580).background(.black).clipShape(.rect(cornerRadius: 18))
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
                        HStack(spacing: 18) { Label(detail.video.author, systemImage:"person.crop.circle"); Label("\(DisplayFormat.count(detail.video.views)) 次播放", systemImage:"play.rectangle"); Text(detail.video.bvid) }.font(.callout).foregroundStyle(.secondary)
                    }
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
                }
            }.padding(30)
        }
    }
}

struct MiniPlayer: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(spacing: 10) {
            HStack { Text("继续观看").font(.caption).foregroundStyle(.secondary); Spacer(); Button { store.closePlayer() } label: { Image(systemName:"xmark") }.buttonStyle(.plain).accessibilityLabel("关闭播放器") }
            NativePlayer(controller:store.player,items:[],opacity:0,mini:true).frame(height:160).clipShape(.rect(cornerRadius:10))
            Text(store.player.detail?.video.title ?? "正在加载…").font(.callout.weight(.semibold)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
            HStack {
                Button { store.player.toggle() } label: { Image(systemName:store.player.playing ? "pause.fill" : "play.fill") }.accessibilityLabel("播放或暂停")
                Spacer()
                Button("返回播放页") { store.showPlayer = true }
            }.buttonStyle(.glass)
        }.padding(12).frame(width:290).glassEffect(.regular,in:.rect(cornerRadius:20))
    }
}

final class PlayerSurface: AVPlayerView {
    weak var controller: PlayerController?
    let overlay = DanmakuSurface()
    override init(frame: NSRect) {
        super.init(frame:frame); controlsStyle = .inline; videoGravity = .resizeAspect; allowsPictureInPicturePlayback = true
        overlay.wantsLayer = true; overlay.layer?.backgroundColor = NSColor.clear.cgColor
        contentOverlayView?.addSubview(overlay)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); overlay.frame = contentOverlayView?.bounds ?? bounds }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event:NSEvent) { window?.makeFirstResponder(self); super.mouseDown(with:event) }
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
struct NativePlayer: NSViewRepresentable {
    let controller: PlayerController
    let items: [Danmaku]
    let opacity: Double
    var mini = false
    func makeNSView(context:Context) -> PlayerSurface {
        let view = PlayerSurface(); view.controller = controller; view.player = controller.player
        view.controlsStyle = mini ? .none : .inline
        return view
    }
    func updateNSView(_ view:PlayerSurface,context:Context) {
        if view.player !== controller.player { view.player = controller.player }
        view.overlay.update(player:controller.player, items:items, opacity:opacity)
    }
    static func dismantleNSView(_ view:PlayerSurface,coordinator:()) { view.overlay.stop(); view.player = nil }
}
