import SwiftUI
import BiliMacCore

struct CommentsSection: View {
    @Bindable var model: CommentsModel
    let aid: Int
    let accountID: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("评论\(model.loaded ? " · \(DisplayFormat.count(model.total))" : "")").font(.title3.bold())
                Spacer()
                Picker("评论排序", selection: Binding(get: { model.sort }, set: { value in Task { await model.changeSort(value) } })) {
                    ForEach(CommentSort.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 160)
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass).accessibilityLabel("刷新评论").disabled(model.loading)
            }
            Text("只读浏览 · 表情以文字显示").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { InlineError(message: error) { Task { await model.retry() } } }
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(model.items) { comment in
                    VStack(alignment: .leading, spacing: 12) {
                        CommentBody(comment: comment)
                        if let thread = model.threads[comment.id] {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(thread.items) { CommentBody(comment: $0, compact: true) }
                                if let error = thread.error { InlineError(message: error) { Task { await model.loadThread(comment) } } }
                                if thread.loading { ProgressView("正在加载回复…").controlSize(.small) }
                                else if thread.hasMore { Button(thread.page == 0 ? "重试加载回复" : "更多回复") { Task { await model.loadThread(comment) } }.font(.callout) }
                                else if thread.items.isEmpty { Text("暂无可见回复").font(.caption).foregroundStyle(.secondary) }
                            }.padding(16).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12)).padding(.leading, 16)
                        } else if comment.replyCount > 0 || !comment.children.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(comment.children.prefix(2)) { CommentBody(comment: $0, compact: true) }
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
    }
}

private struct CommentBody: View {
    let comment: Comment
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(accent.opacity(0.65))
                Text(comment.name).fontWeight(.semibold)
                Spacer()
                if comment.likes > 0 { Label(DisplayFormat.count(comment.likes), systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary) }
            }.font(compact ? .caption : .callout)
            Text(comment.message).font(compact ? .callout : .body).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if comment.date.timeIntervalSince1970 > 0 { Text(comment.date, format: .dateTime.year().month().day().hour().minute()) }
                if !comment.location.isEmpty { Text(comment.location) }
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}
