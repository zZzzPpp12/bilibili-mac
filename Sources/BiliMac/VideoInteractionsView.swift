import SwiftUI
import BiliMacCore

struct VideoInteractionsView: View {
    @Bindable var store: AppStore
    @Bindable var model: VideoActionsModel
    private var guest: Bool { store.account == nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    if guest { store.showLogin = true } else { Task { await model.toggleLike() } }
                } label: { Label(model.state?.liked == true ? "已点赞" : "点赞", systemImage: model.state?.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup") }
                    .buttonStyle(.glass).disabled(!guest && !model.canAct)
                Button {
                    if guest { store.showLogin = true } else { model.present(.coins) }
                } label: { Label(model.state.map { $0.coins > 0 ? "已投 \($0.coins) 枚" : "投币" } ?? "投币", systemImage: "circle.circle") }
                    .buttonStyle(.glass).disabled(!guest && (!model.canAct || model.coinReason != nil))
                    .help(model.coinReason ?? "选择硬币数量并确认投币")
                Button {
                    if guest { store.showLogin = true } else { model.present(.triple) }
                } label: { Label(model.state?.isTriple == true ? "已三连" : "三连…", systemImage: "hands.clap") }
                    .buttonStyle(.glass).disabled(!guest && (!model.canAct || model.tripleReason != nil))
                    .help(model.tripleReason ?? "确认点赞、投币和收藏到默认收藏夹")
                if model.loading || model.busy { ProgressView().controlSize(.small); Text(model.busy ? "正在同步…" : "读取状态…").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if !guest {
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).accessibilityLabel("刷新互动状态").disabled(model.busy || model.loading)
                }
            }.disabled(store.isDemo)
            if let state = model.state, !guest {
                Text("硬币余额 \(state.balance.formatted()) · \(state.coinLimit == 1 ? "转载" : "原创")视频最多投 \(state.coinLimit) 枚 · \(state.favorited ? "已收藏" : "未收藏")\(model.needsRefresh ? " · 状态待核对" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = model.coinReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                else if let reason = model.tripleReason, !state.isTriple { Text(reason).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = model.error, !guest {
                InlineError(message: error) { Task { await model.refresh() } }
                if let url = officialURL { Link("在哔哩哔哩查看视频／处理官方验证", destination: url).font(.caption) }
            }
            if let notice = model.notice, !guest { Text(notice).font(.callout).foregroundStyle(model.needsRefresh ? .secondary : accent) }
        }
        .task { if !store.isDemo { await model.ensureLoaded() } }
        .sheet(item: Binding(get: { model.confirmation }, set: { if $0 == nil { model.cancelConfirmation() } })) { proposal in
            SpendConfirmationView(model: model, proposal: proposal)
        }
    }
    private var officialURL: URL? {
        guard VideoInput.bvid(model.bvid) == model.bvid else { return nil }
        return URL(string: "https://www.bilibili.com/video/" + model.bvid + "/")
    }
}

private struct SpendConfirmationView: View {
    @Bindable var model: VideoActionsModel
    let proposal: VideoActionsModel.Confirmation
    @State private var amount = 1
    @State private var alsoLike = false
    private var coins: Bool { proposal.kind == .coins }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(coins ? "确认投币" : "确认三连", systemImage: coins ? "circle.circle" : "hands.clap").font(.title2.bold())
            LabeledContent("硬币余额", value: proposal.before.balance.formatted())
            LabeledContent("本视频已投", value: "\(proposal.before.coins) / \(proposal.before.coinLimit) 枚")
            if coins {
                Picker("本次投币", selection: $amount) {
                    ForEach([1, 2].filter { $0 <= proposal.before.available }, id: \.self) { Text("\($0) 枚").tag($0) }
                }.pickerStyle(.segmented)
                Toggle("同时点赞", isOn: $alsoLike).toggleStyle(.checkbox).disabled(proposal.before.liked)
                Text("本次将消耗 \(amount) 枚硬币。投币后无法撤回。")
            } else {
                Text("点赞、投币，并收藏到默认收藏夹。")
                Text(proposal.before.remaining == 0 ? "本视频已投满，本次无需新增投币。" : "本次最多消耗 \(proposal.before.remaining) 枚硬币，实际数量以服务器回执为准。投币后无法撤回。")
                Text("部分操作可能已完成；应用会分别显示结果，不会自动补发。 ").font(.caption).foregroundStyle(.secondary)
            }
            if model.busy { ProgressView("正在核对并提交，请稍候…").controlSize(.small) }
            if let error = model.error { InlineError(message: error) }
            HStack {
                Button("取消") { model.cancelConfirmation() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(coins ? "确认投 \(amount) 枚" : "确认三连") {
                    Task { await model.confirm(id: proposal.id, amount: amount, alsoLike: alsoLike) }
                }.buttonStyle(.borderedProminent)
            }.disabled(model.busy)
        }.padding(28).frame(width: 460).interactiveDismissDisabled(model.busy)
    }
}
