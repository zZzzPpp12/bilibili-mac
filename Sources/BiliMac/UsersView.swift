import SwiftUI
import BiliMacCore

private struct AvatarLoader: CoverImageServing {
    func image(for source: String) async throws -> CoverImage { try await CoverImageLoader.shared.avatar(for: source) }
}
struct AvatarView: View {
    let url: String
    var size: CGFloat = 64
    @State private var model = ThumbnailModel(loader: AvatarLoader())
    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            if let image = model.image {
                Image(decorative: image.image, scale: 1).resizable().scaledToFill().frame(width: size, height: size).clipped()
            } else { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary.opacity(0.5)) }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
            .task(id: url) { await model.load(url) }
    }
}

struct SearchPage: View {
    @Bindable var model: SearchModel
    let openVideo: (String) -> Void
    let openUser: (Int) -> Void
    let accountID: Int?
    let login: () -> Void
    private var result: SearchModel.Results { model.current }
    private var officialURL: URL? {
        var parts = URLComponents(string: "https://search.bilibili.com/\(model.kind == .users ? "upuser" : "video")")!
        parts.queryItems = [.init(name: "keyword", value: model.term)]
        return parts.url
    }
    var body: some View {
        let key = "\(model.term)-\(model.kind.rawValue)"
        RetainedScrollView(offset: Binding(get: { model.scrollOffset }, set: { if key == "\(model.term)-\(model.kind.rawValue)" { model.scrollOffset = $0 } })) {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("搜索结果").font(.system(size: 31, weight: .bold))
                        Text("关于「\(model.term)」\(result.total.map { " · \(DisplayFormat.count($0)) \(model.kind == .users ? "位用户" : "条视频")" } ?? "")").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.load() } label: { Label("刷新", systemImage: "arrow.clockwise") }.buttonStyle(.glass).disabled(result.loading)
                }
                Picker("搜索分类", selection: Binding(get: { model.kind }, set: { model.select($0) })) {
                    ForEach(SearchKind.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 220)
                if model.kind == .videos { SearchFiltersView(model: model) }
                if let error = result.error {
                    InlineError(message: error) { model.retry() }
                    if let officialURL { Link("在哔哩哔哩查看／处理验证", destination: officialURL).font(.callout) }
                    if accountID == nil { Button("扫码登录") { login() }.buttonStyle(.glass) }
                }
                if model.kind == .videos {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 22)], spacing: 28) {
                        ForEach(Array(result.videos.enumerated()), id: \.element.id) { index, video in
                            VideoCard(video: video, index: index, authorAction: video.authorID.map { mid in { openUser(mid) } }) { openVideo(video.bvid) }.id(video.id)
                        }
                    }
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(result.users) { user in
                            Button { openUser(user.mid) } label: { UserResultRow(user: user) }.buttonStyle(.plain)
                                .accessibilityLabel("查看用户 \(user.name) 的主页，UID \(user.mid)").id("user-\(user.mid)")
                        }
                    }
                }
                if result.loading { ProgressView("正在搜索\(model.kind.rawValue)…").frame(maxWidth: .infinity) }
                else if result.loaded && (model.kind == .videos ? result.videos.isEmpty : result.users.isEmpty) && result.error == nil {
                    ContentUnavailableView("没有找到相关\(model.kind.rawValue)", systemImage: model.kind == .users ? "person.crop.circle.badge.questionmark" : "magnifyingglass", description: Text("试试其他关键词，或切换搜索分类。"))
                } else if result.hasMore { Button("加载更多\(model.kind.rawValue)") { model.load(more: true) }.buttonStyle(.glass).frame(maxWidth: .infinity).disabled(result.loading) }
                else if result.loaded && result.error == nil { Text(result.limited ? "已保留 600 条结果，请缩小筛选范围继续查找" : "已显示全部结果").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }.padding(30)
        }.id(result.revision).id(key).id(model.kind == .videos ? model.options : .init())
    }
}

private struct UserResultRow: View {
    let user: BiliUser
    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            AvatarView(url: user.avatar)
            VStack(alignment: .leading, spacing: 8) {
                Text(user.name).font(.headline).foregroundStyle(.primary)
                if let verification = user.verification { Label(verification, systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(accent).lineLimit(1) }
                if !user.signature.isEmpty { Text(user.signature).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 18) {
                    Text("UID \(String(user.mid))")
                    if let fans = user.fans { Text("\(DisplayFormat.count(fans)) 粉丝") }
                    if let videos = user.videos { Text("\(DisplayFormat.count(videos)) 投稿") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 14)).contentShape(.rect)
    }
}

struct UserProfilePage: View {
    @Bindable var model: UserProfileModel
    let openVideo: (String) -> Void
    let openUser: (Int) -> Void
    let login: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("用户主页").font(.system(size: 31, weight: .bold))
                    Spacer()
                    Link("官方主页", destination: model.officialURL).font(.callout)
                    Button { Task { await model.refreshProfile() } } label: { Label("刷新资料", systemImage: "arrow.clockwise") }
                        .buttonStyle(.glass).disabled(model.profileLoading || model.followBusy)
                }
                if let error = model.profileError { InlineError(message: error) { Task { await model.refreshProfile() } } }
                if let profile = model.profile { header(profile) }
                else if model.profileLoading { ProgressView("正在加载用户资料…").frame(maxWidth: .infinity, minHeight: 120) }
                if let error = model.followError { InlineError(message: error) }
                if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Text("视频投稿\(model.total.map { " · \(DisplayFormat.count($0))" } ?? "")").font(.title2.bold())
                    Spacer()
                    Picker("投稿排序", selection: Binding(get: { model.order }, set: { order in Task { await model.changeOrder(order) } })) {
                        ForEach(UserVideoOrder.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 220)
                    Button { Task { await model.loadVideos() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.glass).accessibilityLabel("刷新用户投稿").disabled(model.videosLoading)
                }
                if let error = model.videosError {
                    InlineError(message: error) { Task { await model.retryVideos() } }
                    Link("在官方主页查看投稿／处理验证", destination: model.officialURL).font(.callout)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 22)], spacing: 28) {
                    ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                        VideoCard(video: video, index: index, authorAction: video.authorID.map { mid in { openUser(mid) } }) { openVideo(video.bvid) }
                    }
                }
                if model.videosLoading { ProgressView("正在加载投稿…").frame(maxWidth: .infinity) }
                else if model.videosLoaded && model.videos.isEmpty && model.videosError == nil {
                    ContentUnavailableView("暂无可见视频投稿", systemImage: "play.rectangle", description: Text("以该用户当前公开可见的投稿为准。"))
                } else if model.hasMore { Button("加载更多投稿") { Task { await model.loadVideos(more: true) } }.buttonStyle(.glass).frame(maxWidth: .infinity) }
            }.padding(30)
        }.task { await model.ensureLoaded() }
    }
    private func header(_ profile: UserProfile) -> some View {
        HStack(alignment: .top, spacing: 22) {
            AvatarView(url: profile.user.avatar, size: 88)
            VStack(alignment: .leading, spacing: 12) {
                Text(profile.user.name).font(.system(size: 25, weight: .bold)).textSelection(.enabled)
                Text("UID \(String(profile.user.mid))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let verification = profile.user.verification { Label(verification, systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(accent) }
                if !profile.user.signature.isEmpty { Text(profile.user.signature).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack(spacing: 24) {
                    Text("\(profile.user.fans.map(DisplayFormat.count) ?? "—") 粉丝")
                    Text("\(profile.followingCount.map(DisplayFormat.count) ?? "—") 关注")
                    Text("\(profile.user.videos.map(DisplayFormat.count) ?? "—") 投稿")
                }.font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if model.isSelf { Text("我的主页").font(.callout).foregroundStyle(.secondary) }
            else {
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        if model.account == nil { login() } else { Task { await model.toggleFollow() } }
                    } label: {
                        Label(model.followBusy ? "正在同步…" : profile.followed == true ? "取消关注" : "关注", systemImage: profile.followed == true ? "person.badge.minus" : "person.badge.plus")
                    }.buttonStyle(.glass).disabled(model.account != nil && !model.canFollow)
                    if model.account != nil && (profile.followed == nil || model.needsRefresh) { Text("请刷新资料核对关注状态").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 16))
    }
}
