import SwiftUI
import Observation
import BiliMacCore

@Observable @MainActor final class ThumbnailModel {
    private(set) var image: CoverImage?
    private(set) var failure: CoverImageError?
    private(set) var loading = false
    private var generation = UUID()
    private let loader: any CoverImageServing

    init(loader: any CoverImageServing = CoverImageLoader.shared) { self.loader = loader }

    func load(_ source: String) async {
        let generation = UUID(); self.generation = generation
        image = nil; failure = nil; loading = true
        defer { if self.generation == generation { loading = false } }
        do {
            let result = try await loader.image(for: source)
            guard self.generation == generation, !Task.isCancelled else { return }
            image = result
        } catch {
            guard self.generation == generation, !Task.isCancelled else { return }
            failure = error as? CoverImageError ?? .network((error as? URLError)?.code ?? .unknown)
        }
    }
}

struct Thumbnail: View {
    let url: String
    var color: Color = .indigo
    var symbol = "play.rectangle"
    var playLabel = "播放视频"
    var open: (() -> Void)?
    @State private var model = ThumbnailModel()
    @State private var attempt = 0
    @State private var hovered = false

    init(url: String, color: Color = .indigo, symbol: String = "play.rectangle",
         playLabel: String = "播放视频", open: (() -> Void)? = nil,
         loader: any CoverImageServing = CoverImageLoader.shared) {
        self.url = url; self.color = color; self.symbol = symbol
        self.playLabel = playLabel; self.open = open
        _model = State(initialValue: ThumbnailModel(loader: loader))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let open {
                    Button(action: open) { picture(size: geometry.size) }
                        .buttonStyle(.plain).accessibilityLabel(playLabel)
                } else { picture(size: geometry.size) }
                // Sibling of the play button: retry never opens the video.
                if let failure = model.failure {
                    VStack(spacing: 7) {
                        Label(failure.canRetry ? "封面加载失败" : "暂无封面", systemImage: "photo.badge.exclamationmark")
                            .font(.callout.weight(.medium))
                        Text(failure.message).font(.caption)
                        if failure.canRetry {
                            Button("重试封面") { attempt += 1 }
                                .buttonStyle(.bordered).controlSize(.small)
                                .accessibilityLabel("重试封面，\(playLabel)")
                        }
                    }.foregroundStyle(.white).padding(12)
                        .background(.black.opacity(0.65), in: .rect(cornerRadius: 10)).padding(14)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .onHover { hovered = $0 }
        .task(id: "\(url)\n\(attempt)") { await model.load(url) }
    }

    private func picture(size: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: [color.opacity(0.8), color.opacity(0.35), .black.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image = model.image {
                Image(decorative: image.image, scale: 1).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
                if hovered, open != nil {
                    Image(systemName: "play.circle.fill").font(.system(size: 40)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.3))
                }
            } else if model.failure == nil {
                Image(systemName: symbol).font(.system(size: 51, weight: .ultraLight)).foregroundStyle(.white.opacity(0.25))
                ProgressView("正在加载封面…").font(.caption).tint(.white).foregroundStyle(.white)
            }
        }.frame(width: size.width, height: size.height).contentShape(.rect)
    }
}
