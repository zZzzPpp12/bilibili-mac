import SwiftUI
import BiliMacCore

struct CommentsSection: View {
    @Bindable var model: CommentsModel
    @Bindable var actions: CommentActionsModel
    let aid: Int
    let accountID: Int?
    let login: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("评论\(model.loaded ? " · \(DisplayFormat.count(model.total))" : "")").font(.title3.bold())
                Spacer()
                Picker("评论排序", selection: Binding(get: { model.sort }, set: { value in Task { await model.changeSort(value) } })) {
                    ForEach(CommentSort.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 160).disabled(actions.busy || actions.refreshing)
                Button { Task { await actions.refresh(model) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass).accessibilityLabel("刷新评论").disabled(model.loading || actions.busy || actions.refreshing)
                Button(accountID == nil ? "登录后发表评论" : "写评论") {
                    if accountID == nil { login() } else { actions.present() }
                }.buttonStyle(.glass).disabled(accountID != nil && !actions.canAct)
            }
            Text("支持文字评论和回复 · 表情以文字显示").font(.caption).foregroundStyle(.secondary)
            CommentWriteStatus(model: actions)
            if let receipt = actions.receipt {
                VStack(alignment: .leading, spacing: 8) {
                    Label(receipt.commentID == nil ? "本次提交结果未确认" : "服务器已接收", systemImage: "paperplane")
                        .font(.callout.weight(.semibold))
                    if let name = receipt.replyTo { Text("回复 @\(name)").font(.caption).foregroundStyle(.secondary) }
                    Text(receipt.text).font(.callout).textSelection(.enabled)
                    if let id = receipt.commentID { Text("评论编号 \(id)").font(.caption).foregroundStyle(.secondary) }
                    if let url = actions.officialURL { Link("在哔哩哔哩查看", destination: url).font(.caption) }
                    Text("这是本次提交记录，不代表已公开显示；评论列表以服务端返回为准。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("收起提交记录") { actions.clearReceipt() }.font(.caption).buttonStyle(.plain)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.06), in: .rect(cornerRadius: 12))
            }
            if let error = model.error { InlineError(message: error) { Task { await model.retry() } } }
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(model.items.filter { !actions.deleted.contains($0.id) }) { comment in
                    VStack(alignment: .leading, spacing: 12) {
                        row(comment, root: comment.id)
                        if let thread = model.threads[comment.id] {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(thread.items.filter { !actions.deleted.contains($0.id) }) { row($0, root: comment.id, compact: true) }
                                if let error = thread.error { InlineError(message: error) { Task { await model.loadThread(comment) } } }
                                if thread.loading { ProgressView("正在加载回复…").controlSize(.small) }
                                else if thread.hasMore { Button(thread.page == 0 ? "重试加载回复" : "更多回复") { Task { await model.loadThread(comment) } }.font(.callout) }
                                else if thread.items.isEmpty { Text("暂无可见回复").font(.caption).foregroundStyle(.secondary) }
                            }.padding(16).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12)).padding(.leading, 16)
                        } else if comment.replyCount > 0 || !comment.children.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(comment.children.prefix(2).filter { !actions.deleted.contains($0.id) }) { row($0, root: comment.id, compact: true) }
                                Button("查看全部 \(comment.replyCount) 条回复") { Task { await model.loadThread(comment) } }.font(.callout)
                            }.padding(16).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12)).padding(.leading, 16)
                        }
                        Divider().opacity(0.5)
                    }
                }
            }
            HStack {
                Spacer()
                if model.loading { ProgressView("正在加载评论…").controlSize(.small) }
                else if model.hasMore { Button("加载更多评论") { Task { await model.load(more: true) } }.buttonStyle(.glass) }
                else if model.loaded { Text(model.items.isEmpty ? "还没有可见评论" : "已显示全部可见评论").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }.padding(.vertical, 8)
        }.padding(.top, 8)
            .task(id: "\(aid)-\(accountID ?? 0)") { await model.open(aid: aid) }
            .sheet(item: Binding(get: { actions.composer }, set: { if $0 == nil { actions.dismissComposer() } })) { target in
                CommentComposerView(model: actions, target: target)
            }
            .confirmationDialog("删除这条评论？", isPresented: Binding(get: { actions.deletion != nil }, set: { if !$0 { actions.cancelDelete() } }), presenting: actions.deletion) { proposal in
                Button("确认删除", role: .destructive) { actions.requestDelete(id: proposal.id) }
                Button("取消", role: .cancel) { actions.cancelDelete() }
            } message: { proposal in Text("删除后无法恢复。\n\(proposal.comment.message)") }
    }
    private func row(_ comment: Comment, root: Int, compact: Bool = false) -> some View {
        CommentBody(comment: actions.effective(comment), root: root, model: actions, login: login, compact: compact)
    }
}

struct CommentWriteStatus: View {
    @Bindable var model: CommentActionsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.busy { ProgressView("正在提交，请稍候…").controlSize(.small) }
            if let error = model.error { InlineError(message: error) }
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if model.error != nil || model.needsReview {
                HStack {
                    if let url = model.officialURL { Link("在哔哩哔哩查看／处理验证", destination: url) }
                    if model.needsReview {
                        Button("我已在官方核对，继续操作") { model.acknowledgeReview() }
                            .disabled(model.busy)
                    }
                }.font(.caption)
            }
        }
    }
}

struct CommentComposerView: View {
    @Bindable var model: CommentActionsModel
    let target: CommentActionsModel.Composer
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(target.parent == 0 ? "发表评论" : "回复 @\(target.name)").font(.title2.bold())
            if target.parent != 0 { Text(target.preview).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
            TextEditor(text: $model.draft).font(.body).focused($focused)
                .frame(minHeight: 140, maxHeight: 220).padding(8)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
                .accessibilityLabel("评论内容").disabled(model.busy || model.mid == nil)
            HStack {
                Text("仅支持文字；收起会保留本视频的草稿。")
                Spacer()
                Text("\(model.characterCount) / \(CommentText.limit)")
                    .foregroundStyle(model.characterCount > CommentText.limit ? .red : .secondary)
            }.font(.caption).foregroundStyle(.secondary)
            CommentWriteStatus(model: model)
            Text("点击发送会提交到当前 B 站账号，公开显示以平台处理结果为准。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("收起（保留草稿）") { model.dismissComposer() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                Button(target.parent == 0 ? "发送评论" : "发送回复") { Task { await model.send(id: target.id) } }
                    .buttonStyle(.borderedProminent).disabled(!model.canSend)
            }
        }.padding(26).frame(width: 560).interactiveDismissDisabled(model.busy)
            .onAppear { focused = true }
    }
}

private struct CommentBody: View {
    let comment: Comment
    let root: Int
    @Bindable var model: CommentActionsModel
    let login: () -> Void
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(accent.opacity(0.65))
                Text(comment.name).fontWeight(.semibold)
                Spacer()
            }.font(compact ? .caption : .callout)
            Text(comment.message).font(compact ? .callout : .body).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                if comment.date.timeIntervalSince1970 > 0 { Text(comment.date, format: .dateTime.year().month().day().hour().minute()) }
                if !comment.location.isEmpty { Text(comment.location) }
                Button {
                    if model.mid == nil { login() } else { Task { await model.like(comment) } }
                } label: {
                    Label(comment.likes > 0 ? DisplayFormat.count(comment.likes) : "赞", systemImage: comment.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                }.buttonStyle(.plain).foregroundStyle(comment.liked == true ? accent : .secondary)
                    .accessibilityLabel(comment.liked == true ? "取消评论点赞" : "点赞评论")
                    .disabled(model.mid != nil && (!model.canAct || comment.liked == nil))
                    .help(comment.liked == nil && model.mid != nil ? "点赞状态暂不可用，请刷新评论" : "")
                Button("回复") { if model.mid == nil { login() } else { model.present(reply: comment, root: root) } }
                    .buttonStyle(.plain).disabled(model.mid != nil && !model.canAct)
                if model.mid == comment.mid && comment.mid > 0 {
                    Button("删除评论", role: .destructive) { model.proposeDelete(comment) }
                        .buttonStyle(.plain).disabled(!model.canAct)
                }
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}
