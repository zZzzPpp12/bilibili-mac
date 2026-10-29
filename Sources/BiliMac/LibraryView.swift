import SwiftUI
import BiliMacCore

struct InlineError: View {
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle")
            Text(message).textSelection(.enabled)
            Spacer()
            if let retry { Button("重试", action: retry) }
        }.font(.callout).padding(14).background(accent.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}

struct SavedLibraryView: View {
    @Bindable var store: AppStore
    @State private var removing: SavedVideo?
    private var model: LibraryModel { store.library }
    private var favorites: Bool { store.destination == .favorites }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.destination.rawValue).font(.system(size: 31, weight: .bold))
                        Text(store.destination.subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.account != nil {
                        Button { Task { await refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                            .buttonStyle(.glass).disabled(model.loading || model.foldersLoading || model.laterLoading || model.writingLater)
                    }
                }
                if store.account == nil || store.isDemo {
                    ContentUnavailableView {
                        Label("登录后查看\(store.destination.rawValue)", systemImage: store.destination.icon)
                    } description: { Text("内容与当前哔哩哔哩账号同步。") } actions: {
                        if !store.isDemo { Button("扫码登录") { store.showLogin = true }.buttonStyle(.borderedProminent) }
                    }.frame(maxWidth: .infinity, minHeight: 350)
                } else if favorites { favoriteContent }
                else { laterContent }
            }.padding(30)
        }
        .task(id: "\(store.destination.id)-\(store.account?.id ?? 0)") {
            guard store.account != nil, !store.isDemo else { return }
            if favorites { if !model.foldersLoaded { await model.loadFolders() } }
            else if !model.laterLoaded { await model.loadLater() }
        }
        .task(id: "\(favorites)-\(model.selectedFolder ?? 0)-\(store.account?.id ?? 0)") {
            if favorites, store.account != nil, !model.loaded { await model.loadFavorites() }
        }
        .confirmationDialog("从稍后再看移出这个视频？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
            Button("移出稍后再看", role: .destructive) { Task { await model.setLater(item, saved: false) } }
        } message: { Text($0.title) }
    }
    @ViewBuilder private var favoriteContent: some View {
        if let error = model.foldersError { InlineError(message: error) { Task { await model.loadFolders() } } }
        if model.foldersLoading { ProgressView("正在加载收藏夹…") }
        if !model.folders.isEmpty {
            Picker("收藏夹", selection: Binding(get: { model.selectedFolder ?? 0 }, set: { model.selectFolder($0) })) {
                ForEach(model.folders) { folder in
                    Text("\(folder.title) · \(folder.count)\(folder.isPrivate ? " · 私密" : "")").tag(folder.id)
                }
            }.frame(maxWidth: 460, alignment: .leading)
        } else if model.foldersLoaded {
            ContentUnavailableView("还没有收藏夹", systemImage: "star", description: Text("打开视频后，点击“收藏到…”即可创建收藏夹。"))
        }
        if let error = model.error { InlineError(message: error) { Task { await model.retryFavorites() } } }
        savedGrid(model.items, removable: false)
        if model.loading { ProgressView("正在加载收藏内容…").frame(maxWidth: .infinity) }
        else if model.hasMore { Button("加载更多收藏") { Task { await model.loadFavorites(more: true) } }.frame(maxWidth: .infinity) }
        else if model.loaded && model.items.isEmpty { ContentUnavailableView("这个收藏夹还没有视频", systemImage: "star") }
    }
    @ViewBuilder private var laterContent: some View {
        if let error = model.laterError { InlineError(message: error) { Task { await model.loadLater() } } }
        if model.laterNeedsRefresh { Text("请先刷新核对线上结果，再继续增删。 ").font(.caption).foregroundStyle(.secondary) }
        if let notice = model.notice { Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary) }
        savedGrid(model.later, removable: true)
        if model.laterLoading { ProgressView("正在加载稍后再看…").frame(maxWidth: .infinity) }
        else if model.laterLoaded && model.later.isEmpty { ContentUnavailableView("把好内容留给稍后", systemImage: "clock", description: Text("在播放页点击“加入稍后再看”，视频就会出现在这里。")) }
    }
    private func savedGrid(_ rows: [SavedVideo], removable: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 22)], spacing: 28) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 10) {
                    if let video = item.video { VideoCard(video: video, index: index, authorAction: video.authorID.map { mid in { store.openProfile(mid) } }) { store.open(video.bvid) } }
                    else {
                        VStack(alignment: .leading, spacing: 10) {
                            Thumbnail(url: item.cover, color: .gray, symbol: "play.slash").aspectRatio(16/9, contentMode: .fit).clipShape(.rect(cornerRadius: 13))
                            Text(item.title).font(.callout.weight(.semibold)).lineLimit(2)
                            Text("视频已失效或暂不可播放").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if removable {
                        Button { removing = item } label: { Label("移出稍后再看", systemImage: "minus.circle") }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(model.writingLater || model.laterLoading || model.laterNeedsRefresh)
                    }
                }
            }
        }
    }
    private func refresh() async {
        if favorites { await model.loadFolders(); await model.loadFavorites() }
        else { await model.loadLater() }
    }
}

struct VideoLibraryActions: View {
    @Bindable var store: AppStore
    let video: Video
    @State private var editingFavorites = false
    private var model: LibraryModel { store.library }
    private var saved: Bool { model.later.contains { $0.id == video.aid } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    if store.account == nil { store.showLogin = true } else { editingFavorites = true }
                } label: { Label("收藏到…", systemImage: "star") }.buttonStyle(.glass)
                    .disabled(store.interactions.model(for: video).busy)
                Button {
                    if store.account == nil { store.showLogin = true }
                    else { Task { await model.setLater(SavedVideo(id: video.aid, title: video.title, cover: video.cover, video: video), saved: !saved) } }
                } label: {
                    Label(model.writingLater ? "正在同步…" : saved ? "已加入稍后再看" : "加入稍后再看", systemImage: saved ? "clock.badge.checkmark" : "clock.badge.plus")
                }.buttonStyle(.glass)
                    .disabled(store.account != nil && (!model.laterLoaded || model.laterLoading || model.writingLater || model.laterNeedsRefresh))
                if model.laterLoading { ProgressView().controlSize(.small) }
                Spacer()
            }.disabled(store.isDemo || video.aid <= 0)
            if let error = model.laterError, store.account != nil { InlineError(message: error) { Task { await model.loadLater() } } }
            if let notice = model.notice, store.account != nil { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: store.account?.id) { if store.account != nil, !store.isDemo, !model.laterLoaded { await model.loadLater() } }
        .onChange(of: store.account?.id) { editingFavorites = false }
        .sheet(isPresented: $editingFavorites) {
            if let account = store.account {
                FavoriteEditorView(api: store.client, mid: account.id, aid: video.aid) {
                    Task {
                        await model.loadFolders()
                        if model.loaded { await model.loadFavorites() }
                        await store.interactions.favoritesSaved(aid: video.aid)
                    }
                }.id("\(account.id)-\(video.aid)")
            }
        }
    }
}

struct FavoriteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: FavoriteEditorModel
    @State private var title = ""
    @State private var isPrivate = false
    let saved: () -> Void
    init(api: any LibraryServing, mid: Int, aid: Int, saved: @escaping () -> Void) {
        _model = State(initialValue: FavoriteEditorModel(api: api, mid: mid, aid: aid)); self.saved = saved
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("收藏到…").font(.title2.bold())
            Text("选择一个或多个收藏夹，点击保存后统一同步增删。 ").font(.callout).foregroundStyle(.secondary)
            if let error = model.error { InlineError(message: error) }
            if model.needsRefresh || !model.ready && !model.busy {
                Button("刷新线上状态（重置当前勾选）") { Task { await model.load() } }.disabled(model.busy)
            }
            if model.busy { ProgressView("正在同步…").controlSize(.small) }
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(model.folders) { folder in
                        Toggle(isOn: Binding(get: { model.selected.contains(folder.id) }, set: { if $0 { model.selected.insert(folder.id) } else { model.selected.remove(folder.id) } })) {
                            HStack { Text(folder.title); Spacer(); Text("\(folder.count) 个视频\(folder.isPrivate ? " · 私密" : "")").foregroundStyle(.secondary).font(.caption) }
                        }.toggleStyle(.checkbox)
                    }
                    if model.ready && model.folders.isEmpty { Text("还没有收藏夹，可以在下面创建。 ").foregroundStyle(.secondary) }
                }.padding(4)
            }.frame(minHeight: 100, maxHeight: 240).disabled(model.busy || model.needsRefresh)
            Divider()
            Text("新建收藏夹").font(.headline)
            HStack {
                TextField("名称（1–20 字）", text: $title)
                Toggle("私密", isOn: $isPrivate).toggleStyle(.checkbox)
                Button("创建") { Task { if await model.create(title: title, isPrivate: isPrivate) { title = "" } } }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 20)
            }.disabled(!model.ready || model.busy || model.needsRefresh)
            Text("创建会立即同步到账号；取消本窗口不会删除已创建的收藏夹。 ").font(.caption).foregroundStyle(.secondary)
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(accent) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                Text("新增 \(model.changes.added.count) · 移除 \(model.changes.removed.count)").font(.caption).foregroundStyle(.secondary)
                Button("保存") { Task { if await model.save() { saved(); dismiss() } } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!model.ready || model.busy || model.needsRefresh)
            }
        }.padding(26).frame(width: 510).interactiveDismissDisabled(model.busy)
            .task { await model.load() }.onDisappear { model.invalidate() }
    }
}
