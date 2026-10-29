import SwiftUI
import BiliMacCore

struct PlayerViewport: Equatable {
    var visibleRect: CGRect = .zero
    var containerSize: CGSize = .zero
}

enum FloatingPlayerMetrics {
    static let width: CGFloat = 320
    static let padding: CGFloat = 12
    static let videoSize = CGSize(width: width - padding * 2, height: (width - padding * 2) * 9 / 16)
    static let height: CGFloat = padding * 2 + 16 + 10 + videoSize.height + 10 + 20 + 10 + 28
    static func frame(in viewport: PlayerViewport) -> CGRect {
        CGRect(x: max(0, viewport.visibleRect.maxX - width - 20),
               y: max(viewport.visibleRect.minY, viewport.visibleRect.maxY - height - 20),
               width: width, height: height)
    }
    static func video(in frame: CGRect) -> CGRect {
        CGRect(origin: CGPoint(x: frame.minX + padding, y: frame.minY + padding + 16 + 10), size: videoSize)
    }
}

/// Only the presentation layer observes scroll geometry. The comments tree
/// does not need to rebuild for every pixel of scrolling.
@MainActor @Observable final class PlayerPresentationLayout {
    private(set) var viewport = PlayerViewport()
    private(set) var inlineFrame: CGRect = .zero
    private(set) var presentation = ScrollPlaybackPresentation()
    var floating: Bool { presentation.floating }
    var chromeFrame: CGRect { FloatingPlayerMetrics.frame(in: viewport) }
    var videoFrame: CGRect { floating ? FloatingPlayerMetrics.video(in: chromeFrame) : inlineFrame }
    var showsVideo: Bool {
        inlineFrame.width > 0 && viewport.containerSize.height > 0 && (presentation.inlineVisible || floating)
    }
    func setInlineFrame(_ value: CGRect) {
        guard inlineFrame != value else { return }
        inlineFrame = value; updateVisibility()
    }
    func setViewport(_ value: PlayerViewport) {
        guard viewport != value else { return }
        viewport = value; updateVisibility()
    }
    private func updateVisibility() {
        guard inlineFrame.width > 0, inlineFrame.height > 0, viewport.visibleRect.height > 0 else { return }
        let intersection = inlineFrame.intersection(viewport.visibleRect)
        let fraction = intersection.isNull ? 0 : intersection.width * intersection.height / (inlineFrame.width * inlineFrame.height)
        presentation.updateVisibleFraction(fraction)
    }
    func dismiss() { presentation.dismiss() }
    func reset() { presentation.reset() }
}

struct InlinePlaybackPlaceholder: View {
    let layout: PlayerPresentationLayout
    var body: some View {
        Color.black.overlay {
            if !layout.presentation.inlineVisible {
                Label(layout.presentation.dismissed ? "视频已暂停并收起" : "视频已移至右下角小窗", systemImage: "pip")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One NativePlayer at one structural position for the entire details page.
/// Its frame changes; it never moves to another superview/window on scroll.
struct PlayerPresentationLayer: View {
    @Bindable var store: AppStore
    let layout: PlayerPresentationLayout
    var danmakuEnabled: Bool
    var danmakuOpacity: Double
    var returnToVideo: () -> Void
    var body: some View {
        let video = layout.videoFrame
        ZStack(alignment: .topLeading) {
            if layout.floating && store.player.isOpen {
                floatingControls
                    .offset(x: layout.chromeFrame.minX, y: layout.chromeFrame.minY)
            }
            playbackSurface
                .frame(width: max(1, video.width), height: max(1, video.height))
                .background(.black)
                .clipShape(.rect(cornerRadius: layout.floating ? 10 : 18))
                .offset(x: video.minX, y: video.minY)
                .opacity(layout.showsVideo ? 1 : 0)
                .allowsHitTesting(layout.showsVideo)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transaction { $0.animation = nil }
    }
    private var playbackSurface: some View {
        ZStack {
            NativePlayer(controller: store.player, items: danmakuEnabled ? store.player.danmaku : [], opacity: danmakuOpacity,
                         showsDanmaku: danmakuEnabled && layout.presentation.inlineVisible, danmakuCanvasSize: layout.inlineFrame.size)
            if store.player.loading {
                VStack(spacing: 10) { ProgressView().tint(.white); Text("正在准备播放…").font(.callout) }
                    .foregroundStyle(.white).padding(18).background(.black.opacity(0.7), in: .rect(cornerRadius: 12))
            }
            if let error = store.player.error {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash").font(.title2)
                    Text(error).multilineTextAlignment(.center).font(layout.floating ? .caption : .callout).lineLimit(layout.floating ? 3 : nil)
                    if !store.isDemo {
                        Button("重新播放") { if let bvid = store.player.requestedBVID { store.open(bvid) } }.buttonStyle(.glass)
                    }
                }.foregroundStyle(.white).padding(18).frame(maxWidth: 470).background(.black.opacity(0.8), in: .rect(cornerRadius: 12))
            }
        }
    }
    private var floatingControls: some View {
        VStack(spacing: 10) {
            HStack {
                Text("边看边聊").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.player.pause(); layout.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("暂停并收起小窗").accessibilityLabel("暂停并收起自动小窗")
            }.frame(height: 16)
            Color.clear.frame(width: FloatingPlayerMetrics.videoSize.width, height: FloatingPlayerMetrics.videoSize.height)
            Text(store.player.detail?.video.title ?? "正在加载…")
                .font(.callout.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).frame(height: 20)
            HStack {
                Button { store.player.toggle() } label: { Image(systemName: store.player.intendedPlaying ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(store.player.intendedPlaying ? "暂停小窗视频" : "播放小窗视频")
                    .disabled(store.player.error != nil)
                Spacer()
                Button("回到视频", action: returnToVideo)
            }.buttonStyle(.glass).frame(height: 28)
        }.padding(FloatingPlayerMetrics.padding).frame(width: FloatingPlayerMetrics.width, height: FloatingPlayerMetrics.height)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.24), radius: 16, y: 5)
            .accessibilityElement(children: .contain).accessibilityIdentifier("automatic-mini-player")
    }
}
