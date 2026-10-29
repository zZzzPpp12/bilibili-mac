import Foundation
import Testing
import BiliMacCore
@testable import BiliMac

@MainActor private final class CommunityStub: LibraryServing, CommentServing {
    var folders: [FavoriteFolder] = [.init(id: 1, title: "默认", containsVideo: true), .init(id: 2, title: "学习")]
    var folderResult: (() async throws -> [FavoriteFolder])?
    var favoriteResult: ((Int, Int) async throws -> SavedPage)?
    var laterResult: (() async throws -> [SavedVideo])?
    var commentResult: ((CommentSort, String?) async throws -> CommentPage)?
    var threadResult: ((Int, Int) async throws -> CommentThreadPage)?
    var writeError: (any Error)?
    var favoriteWriteResult: (() async throws -> Void)?
    var laterWriteResult: (() async throws -> Void)?
    var favoriteWrites: [FavoriteChanges] = []
    var laterWrites: [Bool] = []
    var created = 0
    func favoriteFolders(mid: Int, aid: Int?) async throws -> [FavoriteFolder] { if let folderResult { return try await folderResult() }; return folders }
    func favorites(mid: Int, folder: Int, page: Int) async throws -> SavedPage {
        if let favoriteResult { return try await favoriteResult(folder, page) }; return .init(items: [], hasMore: false)
    }
    func watchLater(mid: Int) async throws -> [SavedVideo] { if let laterResult { return try await laterResult() }; return [] }
    func changeFavorites(mid: Int, aid: Int, changes: FavoriteChanges) async throws {
        favoriteWrites.append(changes); if let favoriteWriteResult { try await favoriteWriteResult() }; if let writeError { throw writeError }
    }
    func createFolder(mid: Int, title: String, isPrivate: Bool) async throws -> FavoriteFolder {
        created += 1; if let writeError { throw writeError }; return .init(id: 3, title: title, isPrivate: isPrivate)
    }
    func setWatchLater(mid: Int, aid: Int, saved: Bool) async throws {
        laterWrites.append(saved); if let laterWriteResult { try await laterWriteResult() }; if let writeError { throw writeError }
    }
    func comments(aid: Int, sort: CommentSort, offset: String?) async throws -> CommentPage {
        if let commentResult { return try await commentResult(sort, offset) }; return .init(items: [], total: 0, next: nil)
    }
    func commentThread(aid: Int, root: Int, page: Int) async throws -> CommentThreadPage {
        if let threadResult { return try await threadResult(root, page) }; return .init(items: [], hasMore: false)
    }
}

@Suite @MainActor struct CommunityModelTests {
    private let first = Comment(id: 1, name: "作者", message: "第一条", replyCount: 2)
    private let second = Comment(id: 2, name: "用户", message: "第二条")
    private let resource = SavedVideo(id: 170001, title: "视频", video: nil)

    @Test func favoritesOnlyWriteTheSelectionDeltaOnSave() async {
        let api = CommunityStub()
        let editor = FavoriteEditorModel(api: api, mid: 10, aid: 20)
        await editor.load(); editor.selected = [2]
        #expect(api.favoriteWrites.isEmpty)
        #expect(await editor.save())
        #expect(api.favoriteWrites == [FavoriteChanges(original: [1], selected: [2])])
        #expect(await editor.save())
        #expect(api.favoriteWrites.count == 1)
    }
    @Test func creatingFolderIsImmediateButAddingVideoStillRequiresSave() async {
        let api = CommunityStub()
        let model = FavoriteEditorModel(api: api, mid: 10, aid: 20)
        await model.load(); #expect(await model.create(title: "新建", isPrivate: true))
        #expect(api.created == 1); #expect(api.favoriteWrites.isEmpty)
        #expect(model.selected == [1, 3]); #expect(model.original == [1]); #expect(model.folders.last?.isPrivate == true)
        model.invalidate(); #expect(!(await model.save())); #expect(api.favoriteWrites.isEmpty)
    }
    @Test func ambiguousFavoriteWriteRequiresSuccessfulReadBeforeAnotherWrite() async {
        let api = CommunityStub()
        let editor = FavoriteEditorModel(api: api, mid: 10, aid: 20)
        await editor.load(); editor.selected = [2]; api.writeError = ClientError.writeUncertain
        #expect(!(await editor.save())); #expect(editor.needsRefresh)
        #expect(!(await editor.save())); #expect(!(await editor.create(title: "不要重复", isPrivate: false)))
        #expect(api.favoriteWrites.count == 1); #expect(api.created == 0)
        api.folderResult = { throw URLError(.timedOut) }; await editor.load(); #expect(editor.needsRefresh)
        api.folderResult = nil; api.folders = [.init(id: 2, title: "学习", containsVideo: true)]
        await editor.load(); #expect(!editor.needsRefresh); #expect(editor.selected == [2])
    }
    @Test func staleFolderAndAccountResultsCannotReplaceCurrentLibrary() async throws {
        let api = CommunityStub()
        let library = LibraryModel(api: api); library.setAccount(10); await library.loadFolders()
        var waiting: CheckedContinuation<SavedPage, any Error>?
        api.favoriteResult = { _, _ in try await withCheckedThrowingContinuation { waiting = $0 } }
        let old = Task { await library.loadFavorites() }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let continuation = try #require(waiting)
        library.selectFolder(2)
        api.favoriteResult = { folder, _ in .init(items: [.init(id: folder, title: "新结果", video: nil)], hasMore: false) }
        await library.loadFavorites()
        continuation.resume(returning: .init(items: [resource], hasMore: true)); await old.value
        #expect(library.items.map(\.id) == [2]); #expect(!library.loading)
        library.setAccount(nil); #expect(library.items.isEmpty); #expect(library.folders.isEmpty)
    }
    @Test func favoritesUseServerHasMoreAndKeepPageAfterFailure() async {
        let api = CommunityStub()
        let model = LibraryModel(api: api); model.setAccount(10); await model.loadFolders()
        var pages: [Int] = []
        api.favoriteResult = { _, page in pages.append(page); return .init(items: [resource], hasMore: true) }
        await model.loadFavorites(); #expect(model.hasMore)
        await model.loadFavorites(more: true); #expect(model.error != nil); #expect(model.items.count == 1)
        api.favoriteResult = { _, page in pages.append(page); return .init(items: [], hasMore: false) }
        await model.loadFavorites(more: true)
        #expect(pages == [1, 2, 2]); #expect(!model.hasMore); #expect(model.items.count == 1)
        api.favoriteResult = { _, _ in throw URLError(.timedOut) }
        await model.loadFavorites(); #expect(model.items.count == 1)
    }
    @Test func laterWriteUncertaintyAndAccountSwitchAreScoped() async throws {
        let api = CommunityStub()
        let library = LibraryModel(api: api); library.setAccount(10); await library.loadLater()
        api.writeError = ClientError.writeUncertain
        await library.setLater(resource, saved: true); #expect(library.laterNeedsRefresh)
        await library.setLater(resource, saved: true); #expect(api.laterWrites == [true])
        api.laterResult = { throw URLError(.timedOut) }; await library.loadLater(); #expect(library.laterNeedsRefresh)
        api.laterResult = nil; await library.loadLater(); #expect(!library.laterNeedsRefresh)
        api.writeError = nil; await library.setLater(resource, saved: true); #expect(library.later.map(\.id) == [resource.id])
        await library.setLater(resource, saved: false); #expect(library.later.isEmpty)
        var waiting: CheckedContinuation<[SavedVideo], any Error>?
        api.laterResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let old = Task { await library.loadLater() }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let continuation = try #require(waiting); library.setAccount(99)
        continuation.resume(returning: [resource]); await old.value
        #expect(library.later.isEmpty); #expect(!library.laterLoaded); #expect(!library.laterLoading)
    }
    @Test func commentOpaqueCursorCanRepeatWithNewContentAndRefreshFailureKeepsBody() async {
        let api = CommunityStub()
        let comments = CommentsModel(api: api)
        var offsets: [String?] = []
        api.commentResult = { _, offset in
            offsets.append(offset)
            return .init(items: offset == nil ? [first] : [first, second], total: 3, next: "opaque")
        }
        await comments.open(aid: 20); await comments.load(more: true)
        #expect(comments.items.map(\.id) == [1, 2]); #expect(comments.hasMore)
        await comments.load(more: true); #expect(comments.error != nil)
        #expect(offsets == [nil, "opaque", "opaque"])
        api.commentResult = { _, _ in throw URLError(.timedOut) }
        await comments.load(); #expect(comments.items.map(\.id) == [1, 2]); #expect(comments.hasMore)
        api.commentResult = { _, offset in #expect(offset == "opaque"); return .init(items: [], total: 2, next: nil) }
        await comments.load(more: true); #expect(!comments.hasMore); #expect(comments.items.count == 2)
    }
    @Test func sortAndVideoChangesDiscardLateComments() async throws {
        let api = CommunityStub()
        let comments = CommentsModel(api: api)
        var waiting: CheckedContinuation<CommentPage, any Error>?
        api.commentResult = { _, _ in try await withCheckedThrowingContinuation { waiting = $0 } }
        let old = Task { await comments.open(aid: 20) }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let continuation = try #require(waiting)
        api.commentResult = { order, _ in #expect(order == .latest); return .init(items: [second], total: 1, next: nil) }
        await comments.changeSort(.latest)
        continuation.resume(returning: .init(items: [first], total: 1, next: "old")); await old.value
        #expect(comments.items.map(\.id) == [2]); #expect(!comments.hasMore)
        comments.reset(aid: 99); #expect(comments.items.isEmpty); #expect(comments.threads.isEmpty)
    }
    @Test func threadPagesRetryIndependentlyAndRemainValidDuringMainPagination() async throws {
        let api = CommunityStub()
        let model = CommentsModel(api: api)
        api.commentResult = { _, _ in .init(items: [first], total: 2, next: "next") }
        await model.open(aid: 20)
        var waiting: CheckedContinuation<CommentThreadPage, any Error>?
        api.threadResult = { _, _ in try await withCheckedThrowingContinuation { waiting = $0 } }
        let pending = Task { await model.loadThread(first) }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let continuation = try #require(waiting)
        api.commentResult = { _, _ in .init(items: [second], total: 2, next: nil) }
        await model.load(more: true)
        continuation.resume(returning: .init(items: [second], hasMore: true)); await pending.value
        #expect(model.threads[1]?.items.map(\.id) == [2]); #expect(model.threads[1]?.loading == false)
        var pages: [Int] = []
        api.threadResult = { _, page in pages.append(page); throw URLError(.timedOut) }
        await model.loadThread(first); #expect(model.threads[1]?.items.count == 1)
        api.threadResult = { _, page in pages.append(page); return .init(items: [], hasMore: false) }
        await model.loadThread(first); #expect(pages == [2, 2]); #expect(model.threads[1]?.hasMore == false)
        await model.load(); #expect(model.threads.isEmpty)
    }
    @Test func doubleSaveCannotDuplicateWritesAndDismissedEditorIgnoresLateResult() async throws {
        let api = CommunityStub()
        let editor = FavoriteEditorModel(api: api, mid: 10, aid: 20)
        await editor.load(); editor.selected = [2]
        var waiting: CheckedContinuation<Void, any Error>?
        api.favoriteWriteResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let old = Task { await editor.save() }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let continuation = try #require(waiting)
        #expect(editor.busy); #expect(!(await editor.save())); #expect(api.favoriteWrites.count == 1)
        editor.invalidate(); continuation.resume(); #expect(!(await old.value)); #expect(!editor.ready)
    }
    @Test func laterDoubleClickAndLogoutCannotChangeTheNewAccount() async throws {
        let api = CommunityStub()
        let library = LibraryModel(api: api); library.setAccount(10); await library.loadLater()
        var waiting: CheckedContinuation<Void, any Error>?
        api.laterWriteResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let old = Task { await library.setLater(resource, saved: true) }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let continuation = try #require(waiting)
        await library.setLater(resource, saved: true); #expect(api.laterWrites.count == 1)
        library.setAccount(99); continuation.resume(); await old.value
        #expect(library.later.isEmpty); #expect(library.notice == nil); #expect(!library.writingLater)
    }
    @Test func retryRefreshUsesFirstPageInsteadOfTheNextCursor() async {
        let api = CommunityStub()
        let comments = CommentsModel(api: api)
        api.commentResult = { _, _ in .init(items: [first], total: 2, next: "next") }
        await comments.open(aid: 20)
        api.commentResult = { _, _ in throw URLError(.timedOut) }; await comments.load()
        api.commentResult = { _, offset in #expect(offset == nil); return .init(items: [second], total: 1, next: nil) }
        await comments.retry(); #expect(comments.items.map(\.id) == [2])
    }
}
