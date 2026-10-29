import Foundation
import Testing
import BiliMacCore
@testable import BiliMac

@MainActor private final class CommentWriteStub: CommentWriting {
    struct Post: Equatable { let text: String; let root: Int; let parent: Int }
    var posts: [Post] = []
    var likes: [Bool] = []
    var deletions: [Int] = []
    var postResult: (() async throws -> CommentSubmission)?
    var likeResult: (() async throws -> Void)?
    var deleteResult: (() async throws -> Void)?
    func addComment(mid: Int, aid: Int, bvid: String, message: String, root: Int, parent: Int) async throws -> CommentSubmission {
        posts.append(.init(text: message, root: root, parent: parent))
        if let postResult { return try await postResult() }; return .init(id: 100)
    }
    func likeComment(mid: Int, aid: Int, bvid: String, id: Int, liked: Bool) async throws {
        likes.append(liked); if let likeResult { try await likeResult() }
    }
    func deleteComment(mid: Int, aid: Int, bvid: String, comment: BiliMacCore.Comment) async throws {
        deletions.append(comment.id); if let deleteResult { try await deleteResult() }
    }
    func model(mid: Int? = 10) -> CommentActionsModel { .init(api: self, mid: mid, aid: 20, bvid: "BV1xx411c7mD") }
}
@MainActor private final class CommentReadStub: CommentServing {
    var error: (any Error)?
    var reads = 0
    var items: [BiliMacCore.Comment] = []
    func comments(aid: Int, sort: CommentSort, offset: String?) async throws -> CommentPage {
        reads += 1; if let error { throw error }; return .init(items: items, total: items.count, next: nil)
    }
    func commentThread(aid: Int, root: Int, page: Int) async throws -> CommentThreadPage { .init(items: [], hasMore: false) }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct CommentActionsModelTests {
    private let own = Comment(id: 1, name: "自己", message: "原评论", likes: 5, mid: 10, liked: false)
    private let child = Comment(id: 3, name: "用户", message: "楼中楼", mid: 99, root: 1, liked: false)
    private func compose(_ model: CommentActionsModel, text: String = "测试正文") throws -> UUID {
        model.present(); model.draft = text; return try #require(model.composer?.id)
    }
    @Test func guestCannotComposeLikeDeleteOrSend() async {
        let api = CommentWriteStub(); let model = api.model(mid: nil)
        model.present(); model.present(reply: own, root: 1); model.proposeDelete(own)
        model.draft = "游客"; await model.send(id: UUID()); await model.like(own); await model.confirmDelete(id: UUID())
        #expect(model.composer == nil); #expect(model.deletion == nil)
        #expect(api.posts.isEmpty); #expect(api.likes.isEmpty); #expect(api.deletions.isEmpty)
    }
    @Test func cancelledComposerKeepsSeparateRootAndReplyDraftsAndRejectsOldSend() async throws {
        let api = CommentWriteStub(); let model = api.model()
        let old = try compose(model, text: "根评论草稿")
        model.dismissComposer(); model.present(reply: child, root: 1); model.draft = "回复草稿"
        let reply = try #require(model.composer)
        #expect(reply.root == 1); #expect(reply.parent == 3)
        await model.send(id: old); #expect(api.posts.isEmpty)
        model.dismissComposer(); model.present(); #expect(model.draft == "根评论草稿")
        model.dismissComposer(); model.present(reply: child, root: 1); #expect(model.draft == "回复草稿")
        await model.send(id: try #require(model.composer?.id))
        #expect(api.posts == [.init(text: "回复草稿", root: 1, parent: 3)])
        #expect(model.receipt?.replyTo == "用户"); #expect(model.receipt?.commentID == 100)
        model.present(reply: child, root: 1); #expect(model.draft.isEmpty)
        model.dismissComposer(); model.present(); #expect(model.draft == "根评论草稿")
    }
    @Test func invalidDraftsNeverSendAndKnownBoundaryIsAllowed() async throws {
        let api = CommentWriteStub(); let model = api.model(); let id = try compose(model)
        for value in [" \n", String(repeating: "好", count: 1001), String(repeating: "😺", count: 501)] {
            model.draft = value; #expect(!model.canSend); await model.send(id: id)
        }
        #expect(api.posts.isEmpty)
        model.draft = String(repeating: "好", count: 1000); #expect(model.canSend)
        await model.send(id: id); #expect(api.posts.count == 1)
    }
    @Test func doubleSendWaitsForReceiptAndCannotDismissOrChangeTargetWhileBusy() async throws {
        let api = CommentWriteStub(); let model = api.model(); let id = try compose(model, text: " 正文 ")
        var waiting: CheckedContinuation<CommentSubmission, any Error>?
        api.postResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let request = Task { await model.send(id: id) }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let completion = try #require(waiting)
        #expect(model.busy); #expect(model.receipt == nil); #expect(model.draft == " 正文 ")
        model.dismissComposer(); model.present(reply: child, root: 1)
        #expect(model.composer?.id == id)
        await model.send(id: id); #expect(api.posts.count == 1)
        completion.resume(returning: .init(id: 777)); await request.value
        #expect(model.receipt?.commentID == 777); #expect(model.receipt?.text == "正文")
        #expect(model.composer == nil); #expect(!model.busy)
    }
    @Test func acceptedReceiptDoesNotInsertIntoBrowserOrInflateCount() async throws {
        let api = CommentWriteStub(); let read = CommentReadStub(); read.items = [own]
        let browser = CommentsModel(api: read); await browser.open(aid: 20)
        let model = api.model(); let id = try compose(model)
        await model.send(id: id)
        #expect(model.receipt?.commentID == 100)
        #expect(browser.items.map(\.id) == [1]); #expect(browser.total == 1); #expect(read.reads == 1)
        await model.refresh(browser)
        #expect(read.reads == 2); #expect(api.posts.count == 1); #expect(browser.total == 1)
    }
    @Test func explicitRejectionAndVerificationRetainDraftWithoutClaimingSubmission() async throws {
        let api = CommentWriteStub(); let model = api.model()
        await model.send(id: try compose(model)); #expect(model.receipt != nil)
        let id = try compose(model); #expect(model.notice == nil)
        for code in [12002, -352, -101] {
            api.postResult = { throw ClientError.server(code, "服务端拒绝") }
            await model.send(id: id)
            #expect(model.draft == "测试正文"); #expect(model.composer?.id == id)
            #expect(model.receipt == nil); #expect(!model.needsReview); #expect(model.error != nil)
        }
        #expect(api.posts.count == 4)
    }
    @Test func uncertainSubmissionStaysLockedAcrossRefreshUntilExplicitUserReview() async throws {
        let api = CommentWriteStub(); let model = api.model(); let id = try compose(model)
        api.postResult = { throw ClientError.writeUncertain }; await model.send(id: id)
        #expect(model.needsReview); #expect(model.receipt?.commentID == nil); #expect(model.receipt?.text == "测试正文")
        await model.send(id: id); await model.like(own); model.proposeDelete(own)
        #expect(api.posts.count == 1); #expect(api.likes.isEmpty); #expect(api.deletions.isEmpty)
        let read = CommentReadStub(); let browser = CommentsModel(api: read); await browser.open(aid: 20)
        await model.refresh(browser); #expect(model.needsReview); #expect(api.posts.count == 1)
        model.dismissComposer(); model.present(); #expect(model.composer == nil)
        model.acknowledgeReview(); #expect(!model.needsReview); #expect(api.posts.count == 1)
        model.present(); #expect(model.draft == "测试正文"); #expect(model.canSend)
    }
    @Test func missingReceiptIDIsUncertainAndNewerDraftIsNeverClearedByOldReceipt() async throws {
        let api = CommentWriteStub(); let model = api.model(); let id = try compose(model)
        api.postResult = { .init(id: 0) }; await model.send(id: id)
        #expect(model.needsReview); #expect(model.draft == "测试正文")
        model.acknowledgeReview()
        var waiting: CheckedContinuation<CommentSubmission, any Error>?
        api.postResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let request = Task { await model.send(id: id) }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let completion = try #require(waiting); model.draft = "更新的草稿"
        completion.resume(returning: .init(id: 101)); await request.value
        model.present(); #expect(model.draft == "更新的草稿")
    }
    @Test func likeChangesOnlyAfterAcknowledgementAndRepeatedClickSendsOnce() async throws {
        let api = CommentWriteStub(); let model = api.model()
        var waiting: CheckedContinuation<Void, any Error>?
        api.likeResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let request = Task { await model.like(own) }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let completion = try #require(waiting)
        await model.like(own); #expect(api.likes == [true]); #expect(model.effective(own).likes == 5)
        completion.resume(); await request.value
        #expect(model.effective(own).liked == true); #expect(model.effective(own).likes == 6)
        api.likeResult = nil; await model.like(own)
        #expect(api.likes == [true, false]); #expect(model.effective(own).likes == 5)
    }
    @Test func unknownLikeStateAndUnknownWriteDoNotInventReaction() async {
        let api = CommentWriteStub(); let model = api.model()
        await model.like(.init(id: 1, name: "用户", message: "状态缺失")); #expect(api.likes.isEmpty)
        api.likeResult = { throw ClientError.writeUncertain }
        await model.like(own); #expect(model.needsReview); #expect(model.effective(own).liked == false)
        await model.like(own); #expect(api.likes == [true])
    }
    @Test func deletionRequiresOwnCommentAndCurrentUncancelledConfirmation() async throws {
        let api = CommentWriteStub(); let model = api.model()
        model.proposeDelete(child); #expect(model.deletion == nil)
        model.proposeDelete(own); let old = try #require(model.deletion?.id)
        model.cancelDelete(); await model.confirmDelete(id: old); #expect(api.deletions.isEmpty)
        model.proposeDelete(own); await model.confirmDelete(id: old); #expect(api.deletions.isEmpty)
        await model.confirmDelete(id: try #require(model.deletion?.id))
        #expect(api.deletions == [1]); #expect(model.deleted.contains(1))
        model.proposeDelete(own); #expect(model.deletion == nil)
    }
    @Test func delayedDeleteCannotRepeatOrRestoreStateAfterLogout() async throws {
        let api = CommentWriteStub(); let model = api.model()
        var waiting: CheckedContinuation<Void, any Error>?
        api.deleteResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        model.proposeDelete(own); let id = try #require(model.deletion?.id)
        let request = Task { await model.confirmDelete(id: id) }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let completion = try #require(waiting)
        await model.confirmDelete(id: id); #expect(api.deletions == [1]); #expect(model.deleted.isEmpty)
        model.invalidate(); completion.resume(); await request.value
        #expect(model.deleted.isEmpty); #expect(!model.canAct); #expect(model.notice == nil)
    }
    @Test func confirmationDismissalCannotCancelAnExplicitlyAcceptedDeletion() async throws {
        let api = CommentWriteStub(); let model = api.model()
        var waiting: CheckedContinuation<Void, any Error>?
        api.deleteResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        model.proposeDelete(own); let id = try #require(model.deletion?.id)
        model.requestDelete(id: id); model.cancelDelete(); model.requestDelete(id: id)
        #expect(model.busy); #expect(model.deletion == nil)
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let completion = try #require(waiting); #expect(api.deletions == [1])
        completion.resume()
        for _ in 0..<1_000 { if !model.busy { break }; await Task.yield() }
        #expect(!model.busy); #expect(model.deleted.contains(1)); #expect(model.deletion == nil)
    }
    @Test func failedRefreshPreservesReactionAndPendingOutcomeSuccessfulReadDoesNotResend() async throws {
        let api = CommentWriteStub(); let model = api.model(); await model.like(own)
        let read = CommentReadStub(); read.items = [own]; let browser = CommentsModel(api: read); await browser.open(aid: 20)
        read.error = URLError(.timedOut); await model.refresh(browser)
        #expect(model.effective(own).liked == true); #expect(model.effective(own).likes == 6)
        read.error = nil; await model.refresh(browser)
        #expect(model.effective(browser.items[0]).liked == false); #expect(api.likes == [true])
    }
    @Test func navigationRetainsEachVideoDraftAndUnknownOutcomeAccountSwitchDropsEverything() async throws {
        let api = CommentWriteStub(); let store = CommentActionsStore(api: api); store.setAccount(10)
        let a = Video(bvid: "BV1xx411c7mD", aid: 20, title: "A", author: "UP", duration: 20)
        let b = Video(bvid: "BV1xx411c7mE", aid: 21, title: "B", author: "UP", duration: 20)
        let first = store.model(for: a); let id = try compose(first, text: "A 的草稿")
        api.postResult = { throw ClientError.writeUncertain }; await first.send(id: id)
        let second = store.model(for: b); _ = try compose(second, text: "B 的草稿")
        #expect(store.model(for: a) === first); #expect(first.needsReview); #expect(second.draft == "B 的草稿")
        store.setAccount(99); let changed = store.model(for: a)
        #expect(changed !== first); #expect(changed.mid == 99); #expect(changed.draft.isEmpty)
        #expect(!first.canAct); #expect(first.receipt == nil); #expect(first.draft.isEmpty)
    }
    @Test func oldSubmissionCannotReappearAfterAccountSwitch() async throws {
        let api = CommentWriteStub(); let model = api.model(); let id = try compose(model)
        var waiting: CheckedContinuation<CommentSubmission, any Error>?
        api.postResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let request = Task { await model.send(id: id) }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let completion = try #require(waiting); model.invalidate()
        completion.resume(returning: .init(id: 999)); await request.value
        #expect(model.receipt == nil); #expect(model.notice == nil); #expect(model.draft.isEmpty); #expect(!model.busy)
    }
}
