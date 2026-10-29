import SwiftUI
import BiliMacCore

let accent = Color(red: 0.93, green: 0.30, blue: 0.48)
struct RootView: View {
    @Bindable var store: AppStore
    @AppStorage("appearance", store: AppSettings.defaults) private var appearance = "system"
    @FocusState private var searching: Bool
    @State private var clearHistory = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 214)
            VStack(spacing: 0) {
                toolbar
                Divider().opacity(0.5)
                ZStack(alignment: .bottomTrailing) {
                    Group { if store.showPlayer { PlayerPage(store: store) } else { library } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !store.showPlayer && store.player.isOpen { MiniPlayer(store: store).padding(24) }
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }.tint(accent).frame(minWidth: 1000, minHeight: 680)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .sheet(isPresented: $store.showLogin) { LoginView(store: store) }
            .task { await store.start() }
            .onChange(of: store.searchFocus) { searching = true }
            .onChange(of: store.showPlayer) { if store.showPlayer { searching = false } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.player.saveProgress() }
            .confirmationDialog("清空本机观看记录？", isPresented: $clearHistory) { Button("清空记录", role: .destructive) { store.clearHistory() } }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill").font(.system(size: 27)).foregroundStyle(accent)
                Text("BiliMac").font(.system(size: 23, weight: .bold, design: .rounded))
            }.padding(.top, 48).padding(.bottom, 8)
            Text("你的桌面放映室").font(.caption).foregroundStyle(.secondary).padding(.bottom, 38)
            Text("探索").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).padding(.leading, 12).padding(.bottom, 12)
            ForEach(Destination.allCases) { destination in
                Button { store.select(destination) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: destination.icon).font(.system(size: 16)).frame(width: 21)
                        Text(destination.rawValue).font(.system(size: 14, weight: store.destination == destination && store.activeSearch.isEmpty ? .semibold : .regular))
                        Spacer()
                        if destination == .history && !store.history.isEmpty { Text("\(store.history.count)").font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 12).frame(height: 45).contentShape(.rect)
                        .foregroundStyle(store.destination == destination && store.activeSearch.isEmpty ? accent : .primary)
                        .background(store.destination == destination && store.activeSearch.isEmpty ? accent.opacity(0.11) : .clear, in: .rect(cornerRadius: 12))
                }.buttonStyle(.plain).padding(.bottom, 6)
            }
            Spacer()
            if store.isDemo { Label("演示数据", systemImage: "testtube.2").font(.caption).foregroundStyle(.orange).padding(.bottom, 20) }
            VStack(alignment: .leading, spacing: 12) {
                SettingsLink { Label("设置", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                Text("为好奇心，留一扇窗。").font(.caption2).foregroundStyle(.tertiary)
            }.padding(12).padding(.bottom, 20)
        }.padding(.horizontal, 20).background(.ultraThinMaterial)
    }
    private var toolbar: some View {
        HStack(spacing: 16) {
            if store.showPlayer { Button { store.leavePlayer() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).accessibilityLabel("返回列表") }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索视频，或粘贴 BV 号 / 视频链接", text: $store.query).textFieldStyle(.plain).focused($searching).onSubmit { store.search() }
                if !store.query.isEmpty { Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("清空搜索") }
                Text("⌘ F").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 13).frame(height: 38).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 11)).frame(maxWidth: 540)
            Spacer(minLength: 10)
            if let account = store.account {
                Menu { Button("检查登录状态") { Task { await store.checkAccount() } }; Button("退出登录", role: .destructive) { Task { await store.logout() } } } label: { Label(account.name, systemImage: "person.crop.circle.fill") }.menuStyle(.borderlessButton).fixedSize()
            } else {
                Button { store.showLogin = true } label: { Label("扫码登录", systemImage: "person.crop.circle") }.buttonStyle(.glass)
            }
        }.padding(.horizontal, 30).frame(height: 76)
    }
    @ViewBuilder private var library: some View {
        if store.activeSearch.isEmpty && [.favorites, .later].contains(store.destination) {
            SavedLibraryView(store: store)
        } else { discovery }
    }
    private var discovery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.title).font(.system(size: 31, weight: .bold))
                        Text(store.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.destination == .history && store.activeSearch.isEmpty {
                        Button { clearHistory = true } label: { Label("清空", systemImage: "trash") }.disabled(store.history.isEmpty).buttonStyle(.glass)
                    } else {
                        Button { store.reload() } label: { Label("换一批", systemImage: "arrow.clockwise") }.buttonStyle(.glass).disabled(store.loading)
                    }
                }
                if let message = store.accountMessage { Label(message, systemImage: "person.crop.circle.badge.exclamationmark").font(.callout).foregroundStyle(.secondary) }
                if let error = store.error {
                    HStack { Label(error, systemImage: "wifi.exclamationmark"); Spacer(); Button("重试") { store.reload() } }.font(.callout).padding(16).background(accent.opacity(0.08), in: .rect(cornerRadius: 14))
                }
                if store.destination == .history && store.activeSearch.isEmpty { historyGrid }
                else { videoGrid }
            }.padding(30)
        }.background(alignment: .topTrailing) {
            Circle().fill(accent.opacity(0.035)).frame(width: 480, height: 480).blur(radius: 100).offset(x:160,y:-200).allowsHitTesting(false)
        }
    }
    @ViewBuilder private var videoGrid: some View {
        if store.videos.isEmpty && !store.loading && store.error == nil {
            ContentUnavailableView(store.activeSearch.isEmpty ? "还没有内容" : "没有找到相关视频", systemImage: "play.rectangle.on.rectangle", description: Text("试试其他关键词，或稍后刷新。")).frame(maxWidth: .infinity, minHeight: 350)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 22)], alignment: .leading, spacing: 28) {
            ForEach(Array(store.videos.enumerated()), id: \.element.id) { index, video in
                VideoCard(video: video, index: index) { store.open(video.bvid) }
            }
        }
        HStack {
            Spacer()
            if store.loading { ProgressView().controlSize(.small); Text("正在发现好内容…").font(.caption).foregroundStyle(.secondary) }
            else if store.hasMore && !store.videos.isEmpty { Button("加载更多") { store.loadMore() }.buttonStyle(.glass) }
            else if !store.videos.isEmpty { Text("慢慢看，好内容不赶时间").font(.caption).foregroundStyle(.tertiary) }
            Spacer()
        }.padding(.vertical, 16)
    }
    @ViewBuilder private var historyGrid: some View {
        if store.history.isEmpty {
            ContentUnavailableView("故事从这里开始", systemImage: "clock.arrow.circlepath", description: Text("看过的视频会留在这里，方便下次继续。")).frame(maxWidth: .infinity, minHeight: 350)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 22)], spacing: 28) {
                ForEach(Array(store.history.enumerated()), id: \.element.id) { index, record in
                    VStack(alignment: .leading, spacing: 7) {
                        VideoCard(video: record.video, index: index) { store.open(record.id) }
                        Text("上次看到 \(DisplayFormat.time(record.position))").font(.caption).foregroundStyle(accent)
                    }
                }
            }
        }
    }
}

struct VideoCard: View {
    let video: Video
    let index: Int
    let action: () -> Void
    private let colors: [Color] = [.teal,.indigo,.orange,.purple,.blue,.pink,.green,.brown]
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                Thumbnail(url: video.cover, color: colors[index % colors.count],
                          symbol: ["mountain.2.fill","laptopcomputer","tram.fill","headphones","sparkles","fork.knife","camera.fill","desktopcomputer","water.waves"][index % 9],
                          playLabel: "播放 \(video.title)，\(video.author)", open: action)
                Text(DisplayFormat.time(Double(video.duration))).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white).padding(.horizontal,7).padding(.vertical,4)
                    .background(.black.opacity(0.65), in: .rect(cornerRadius:5)).padding(9).allowsHitTesting(false)
            }.aspectRatio(16/9, contentMode: .fit).clipShape(.rect(cornerRadius: 13))
            Button(action: action) {
                VStack(alignment: .leading, spacing: 11) {
                    Text(video.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(2).frame(height: 38, alignment: .topLeading).multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.rectangle").font(.system(size: 10))
                        Text(video.author).lineLimit(1)
                        Spacer(minLength: 6)
                        Image(systemName: "play").font(.system(size: 9))
                        Text(DisplayFormat.count(video.views)).lineLimit(1)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.contentShape(.rect)
            }.buttonStyle(.plain).accessibilityLabel("播放 \(video.title)，\(video.author)")
        }
    }
}
