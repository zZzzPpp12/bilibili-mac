import SwiftUI
import BiliMacCore

struct DiscoveryPage: View {
    @Bindable var model: DiscoveryModel
    let title: String
    let subtitle: String
    let accountMessage: String?
    let openVideo: (String) -> Void
    let openUser: (Int) -> Void
    var body: some View {
        let key = model.key
        RetainedScrollView(offset: Binding(get: { model.scrollOffset }, set: { if model.key == key { model.scrollOffset = $0 } })) {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.system(size: 31, weight: .bold))
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.load() } label: { Label("刷新", systemImage: "arrow.clockwise") }.buttonStyle(.glass).disabled(model.current.loading)
                }
                if model.key.source == .regions {
                    Picker("发现分区", selection: Binding(get: { model.key.region }, set: { model.select(.regions, region: $0) })) {
                        ForEach(ContentRegion.allCases) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 280, alignment: .leading)
                    Text("来源：B 站分区榜单，一次读取当前榜单；不代表该分区全部投稿。").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    Picker("发现排序", selection: Binding(get: { model.order }, set: model.setOrder)) {
                        ForEach(DiscoveryOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("视频时长", selection: Binding(get: { model.duration }, set: model.setDuration)) {
                        ForEach(VideoDuration.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("发布时间", selection: Binding(get: { model.published }, set: model.setPublication)) {
                        ForEach(PublicationWindow.allCases) { Text($0.title).tag($0) }
                    }
                }
                if model.order == .balanced {
                    Toggle("结合本机观看兴趣", isOn: Binding(get: { model.useHistory }, set: model.setUseHistory)).toggleStyle(.switch).font(.callout)
                    Text("多样发现综合原始顺序、热度与时效，并减少相邻同作者和相似标题；兴趣加权仅在本机计算。").font(.caption).foregroundStyle(.secondary)
                }
                Text("排序与筛选作用于已加载的 \(model.current.videos.count) 条视频，当前显示 \(model.displayed.count) 条。缺少发布时间的视频不进入时间筛选。").font(.caption).foregroundStyle(.secondary)
                if let accountMessage { Label(accountMessage, systemImage: "person.crop.circle.badge.exclamationmark").font(.callout).foregroundStyle(.secondary) }
                if let error = model.current.error {
                    InlineError(message: error) { model.retry() }
                    Link("在哔哩哔哩查看／处理验证", destination: URL(string: "https://www.bilibili.com/")!).font(.callout)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 22)], spacing: 28) {
                    ForEach(Array(model.displayed.enumerated()), id: \.element.id) { index, video in
                        VideoCard(video: video, index: index, authorAction: video.authorID.map { mid in { openUser(mid) } }) { openVideo(video.bvid) }.id(video.id)
                    }
                }
                if model.current.loading || (!model.current.loaded && model.current.error == nil) { ProgressView("正在发现好内容…").frame(maxWidth: .infinity) }
                else if model.displayed.isEmpty && model.current.error == nil {
                    ContentUnavailableView("当前条件下暂无视频", systemImage: "line.3.horizontal.decrease", description: Text(model.current.hasMore ? "可以调整筛选，或继续加载下一页。" : "可以调整筛选，或刷新内容。"))
                }
                if !model.current.loading && model.current.hasMore {
                    Button("加载更多") { model.load(more: true) }.buttonStyle(.glass).frame(maxWidth: .infinity)
                } else if model.current.loaded && !model.current.loading {
                    Text(model.key.source == .regions ? "已显示当前榜单" : "本批内容已加载完成（最多保留 600 条）").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }.padding(30)
        }.id(model.current.revision).id(key)
    }
}

struct SearchSuggestionsView: View {
    @Bindable var model: SearchAssistanceModel
    let choose: (String) -> Void
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "本机搜索历史" : "搜索建议").font(.headline)
                Spacer()
                if !model.history.isEmpty { Button("清空历史") { confirmClear = true }.font(.caption).buttonStyle(.plain) }
            }.padding(.horizontal, 12).padding(.top, 8)
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, item in
                HStack {
                    Button { choose(item.text) } label: {
                        HStack {
                            Image(systemName: item.local ? "clock.arrow.circlepath" : "magnifyingglass")
                            Text(item.text).lineLimit(1)
                            Spacer()
                            Text(item.local ? "历史" : "B 站联想").font(.caption).foregroundStyle(.secondary)
                        }.contentShape(.rect)
                    }.buttonStyle(.plain)
                    if item.local {
                        Button { model.remove(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("删除搜索历史 \(item.text)")
                    }
                }.padding(10).background(model.selected == index ? accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
            }
            if model.loading { ProgressView("正在获取联想…").controlSize(.small).padding(10) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.secondary).padding(10) }
            if model.suggestions.isEmpty && !model.loading && model.error == nil { Text("输入关键词搜索视频或用户").font(.callout).foregroundStyle(.secondary).padding(10) }
            Text("↑↓ 选择 · 回车搜索 · Esc 收起").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
        }.padding(8).frame(width: 520).background(.regularMaterial, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
            .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
            .confirmationDialog("清空当前账号在本机的搜索历史？", isPresented: $confirmClear) { Button("清空历史", role: .destructive) { model.clear() } }
    }
}

struct SearchFiltersView: View {
    @Bindable var model: SearchModel
    private func binding<Value>(_ path: WritableKeyPath<VideoSearchOptions, Value>) -> Binding<Value> {
        Binding(get: { model.options[keyPath: path] }, set: { value in var options = model.options; options[keyPath: path] = value; model.setOptions(options) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                Picker("视频排序", selection: binding(\.order)) { ForEach(VideoSearchOrder.allCases) { Text($0.rawValue).tag($0) } }
                Picker("视频分区", selection: binding(\.region)) { ForEach(ContentRegion.allCases) { Text($0.title).tag($0) } }
                Picker("视频时长", selection: binding(\.duration)) { ForEach(VideoDuration.allCases) { Text($0.title).tag($0) } }
            }
            HStack(spacing: 18) {
                Picker("发布时间", selection: binding(\.published)) { ForEach(PublicationWindow.allCases) { Text($0.title).tag($0) } }
                Picker("投稿来源", selection: binding(\.copyright)) { ForEach(VideoCopyright.allCases) { Text($0.title).tag($0) } }
                Button("重置筛选") { model.setOptions(.init()) }.buttonStyle(.glass)
            }
            if model.options.order == .smart {
                Text("智能相关仅重排已加载结果：结合关键词匹配、原始顺序、时效和热度，并减少相邻同作者与相似标题。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
