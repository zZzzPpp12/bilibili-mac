import Foundation
import Testing
import BiliMacCore
@testable import BiliMac

@MainActor private final class InteractionStub: VideoInteractionServing {
    var state = VideoInteractionState(liked: false, coins: 0, favorited: false, balance: 10, coinLimit: 2, ownerID: 99)
    var read: (() async throws -> VideoInteractionState)?
    var like: (() async throws -> Void)?
    var coin: (() async throws -> CoinReceipt)?
    var tripleResult: (() async throws -> TripleReceipt)?
    var reads = 0
    var likes: [Bool] = []
    var coins: [(Int, Bool)] = []
    var triples = 0
    func interactionState(mid: Int, aid: Int) async throws -> VideoInteractionState {
        reads += 1; if let read { return try await read() }; return state
    }
    func setVideoLike(mid: Int, aid: Int, bvid: String, liked: Bool) async throws {
        likes.append(liked); if let like { try await like() }
    }
    func addCoins(mid: Int, aid: Int, bvid: String, amount: Int, alsoLike: Bool) async throws -> CoinReceipt {
        coins.append((amount, alsoLike)); if let coin { return try await coin() }; return CoinReceipt(liked: alsoLike)
    }
    func triple(mid: Int, aid: Int, bvid: String) async throws -> TripleReceipt {
        triples += 1; if let tripleResult { return try await tripleResult() }
        return TripleReceipt(liked: true, coined: true, favorited: true, coins: 2)
    }
    func model(mid: Int? = 10, favoritesChanged: @escaping (Int) -> Void = { _ in }) -> VideoActionsModel {
        VideoActionsModel(api: self, mid: mid, aid: 20, bvid: "BV1xx411c7mD", favoritesChanged: favoritesChanged)
    }
}

@Suite @MainActor struct VideoActionsModelTests {
    @Test func guestCannotReadPrivateStateOrSubmitAnyInteraction() async {
        let api = InteractionStub(); let model = api.model(mid: nil)
        await model.ensureLoaded(); await model.toggleLike(); model.present(.coins); model.present(.triple)
        #expect(model.confirmation == nil); #expect(!model.canAct)
        #expect(api.reads == 0); #expect(api.likes.isEmpty); #expect(api.coins.isEmpty); #expect(api.triples == 0)
    }
    @Test func likeWaitsForReceiptAndDoubleClickSendsOnce() async throws {
        let api = InteractionStub(); let model = api.model(); await model.ensureLoaded()
        var waiting: CheckedContinuation<Void, any Error>?
        api.like = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let pending = Task { await model.toggleLike() }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let continuation = try #require(waiting)
        #expect(model.state?.liked == false); await model.toggleLike(); #expect(api.likes == [true])
        continuation.resume(); await pending.value
        #expect(model.state?.liked == true); #expect(!model.busy)
        api.like = nil; await model.toggleLike(); #expect(api.likes == [true, false]); #expect(model.state?.liked == false)
    }
    @Test func draftCancellationAndStaleConfirmationCannotSpend() async throws {
        let api = InteractionStub(); let model = api.model(); await model.ensureLoaded()
        model.present(.coins); let old = try #require(model.confirmation)
        #expect(api.coins.isEmpty); await model.toggleLike(); #expect(api.likes.isEmpty)
        model.cancelConfirmation(); await model.confirm(id: old.id, amount: 2)
        #expect(api.coins.isEmpty)
        model.present(.coins); let new = try #require(model.confirmation)
        await model.confirm(id: old.id, amount: 2); #expect(api.coins.isEmpty)
        await model.confirm(id: new.id, amount: 2, alsoLike: true)
        #expect(api.coins.count == 1); #expect(api.coins.first?.0 == 2); #expect(api.coins.first?.1 == true)
        #expect(model.state?.coins == 2); #expect(model.state?.balance == 8); #expect(model.state?.liked == true)
    }
    @Test func coinControlsRespectRepostsOwnVideosBalancesAndRemainingLimit() async throws {
        let api = InteractionStub(); let model = api.model()
        api.state = .init(liked: false, coins: 0, favorited: false, balance: 10, coinLimit: 1, ownerID: 99)
        await model.refresh(); model.present(.coins); let proposal = try #require(model.confirmation)
        await model.confirm(id: proposal.id, amount: 2); #expect(api.coins.isEmpty)
        await model.confirm(id: proposal.id, amount: 1); #expect(model.state?.coins == 1)
        #expect(model.coinReason != nil); model.present(.coins); #expect(model.confirmation == nil)
        api.state = .init(liked: false, coins: 1, favorited: false, balance: 0.5, coinLimit: 2, ownerID: 99)
        await model.refresh(); #expect(model.coinReason == "硬币余额不足"); #expect(model.tripleReason != nil)
        api.state = .init(liked: false, coins: 0, favorited: false, balance: 10, coinLimit: 2, ownerID: 10)
        await model.refresh(); model.present(.coins); model.present(.triple)
        #expect(model.confirmation == nil); #expect(model.isOwnVideo)
    }
    @Test func changedPreflightSnapshotRequiresAnotherExplicitConfirmation() async throws {
        let api = InteractionStub(); let model = api.model(); await model.refresh()
        model.present(.coins); let old = try #require(model.confirmation)
        api.state.coins = 1; api.state.balance = 9
        await model.confirm(id: old.id, amount: 2)
        #expect(api.coins.isEmpty); #expect(model.confirmation == nil); #expect(model.state?.coins == 1)
        #expect(model.notice?.contains("重新确认") == true)
        model.present(.coins); let new = try #require(model.confirmation)
        await model.confirm(id: old.id); #expect(api.coins.isEmpty)
        await model.confirm(id: new.id); #expect(api.coins.count == 1); #expect(model.state?.coins == 2)
    }
    @Test func failedPreflightDoesNotSendWriteAndRequiresReadRecovery() async throws {
        let api = InteractionStub(); let model = api.model(); await model.refresh()
        model.present(.triple); let proposal = try #require(model.confirmation)
        api.read = { throw URLError(.timedOut) }
        await model.confirm(id: proposal.id)
        #expect(api.triples == 0); #expect(model.needsRefresh); #expect(model.notice?.contains("没有提交") == true)
        api.read = nil; await model.refresh(); #expect(model.canAct)
    }
    @Test func uncertainCoinOutcomeCannotBeRetriedUntilSuccessfulRead() async throws {
        let api = InteractionStub(); let model = api.model(); await model.refresh()
        model.present(.coins); let proposal = try #require(model.confirmation)
        api.coin = { throw ClientError.writeUncertain }
        await model.confirm(id: proposal.id, amount: 2)
        #expect(model.needsRefresh); #expect(model.state?.coins == 0)
        await model.toggleLike(); model.present(.triple); await model.confirm(id: proposal.id, amount: 2)
        #expect(api.coins.count == 1); #expect(api.likes.isEmpty); #expect(api.triples == 0)
        api.read = { throw URLError(.timedOut) }; await model.refresh(); #expect(model.needsRefresh)
        api.read = nil; api.state.coins = 2; api.state.balance = 8; await model.refresh()
        #expect(!model.needsRefresh); #expect(model.state?.coins == 2)
        model.present(.coins); #expect(model.confirmation == nil); #expect(api.coins.count == 1)
    }
    @Test func coinSuccessKeepsExistingLikeAndDoesNotInventAnAttachedLike() async throws {
        let api = InteractionStub(); let model = api.model()
        api.coin = { CoinReceipt(liked: false) }; await model.refresh()
        model.present(.coins); let proposal = try #require(model.confirmation)
        await model.confirm(id: proposal.id, alsoLike: true)
        #expect(model.state?.coins == 1); #expect(model.state?.liked == false)
        #expect(model.notice?.contains("附加点赞未成功") == true)
        api.state.liked = true; api.state.coins = 1; api.state.balance = 9; await model.refresh()
        model.present(.coins); let next = try #require(model.confirmation)
        await model.confirm(id: next.id)
        #expect(model.state?.liked == true); #expect(model.state?.balance == 8)
    }
    @Test func partialTripleKeepsConfirmedPartsWithoutRetryingOrClaimingCompletion() async throws {
        let api = InteractionStub(); var favorites = 0
        let model = api.model { _ in favorites += 1 }; await model.refresh()
        api.tripleResult = { TripleReceipt(liked: true, coined: false, favorited: true, coins: 2) }
        model.present(.triple); let proposal = try #require(model.confirmation)
        await model.confirm(id: proposal.id)
        #expect(model.state?.liked == true); #expect(model.state?.favorited == true); #expect(model.state?.coins == 0)
        #expect(model.state?.balance == 10); #expect(model.state?.isTriple == false); #expect(model.needsRefresh)
        #expect(favorites == 1); model.present(.triple); #expect(model.confirmation == nil); #expect(api.triples == 1)
    }
    @Test func tripleCompletionAndAlreadyCoinedReceiptsUseActualSpend() async throws {
        let api = InteractionStub(); let model = api.model(); await model.refresh()
        model.present(.triple); let proposal = try #require(model.confirmation)
        await model.confirm(id: proposal.id)
        #expect(model.state?.isTriple == true); #expect(model.state?.balance == 8); #expect(!model.needsRefresh)
        model.present(.triple); #expect(model.confirmation == nil); #expect(api.triples == 1)
        api.state.coins = 2; api.state.balance = 0; api.state.favorited = false; api.state.liked = false
        await model.refresh(); #expect(model.tripleReason == nil)
        api.tripleResult = { TripleReceipt(liked: true, coined: false, favorited: true, coins: 2) }
        model.present(.triple); let next = try #require(model.confirmation)
        await model.confirm(id: next.id)
        #expect(model.state?.isTriple == true); #expect(model.state?.balance == 0); #expect(model.state?.coins == 2)
    }
    @Test func impossibleTripleSpendIsUnknownInsteadOfOverwritingState() async throws {
        let api = InteractionStub(); let model = api.model(); api.state.coins = 1; await model.refresh()
        model.present(.triple); let proposal = try #require(model.confirmation)
        await model.confirm(id: proposal.id)
        #expect(model.needsRefresh); #expect(model.state?.coins == 1); #expect(model.state?.balance == 10)
    }
    @Test func revisitingVideoRetainsPendingOutcomeAndAccountSwitchInvalidatesIt() async throws {
        let api = InteractionStub(); let store = InteractionStore(api: api) { _ in }
        store.setAccount(10)
        let video = Video(bvid: "BV1xx411c7mD", aid: 20, title: "测试", author: "UP", duration: 60)
        let model = store.model(for: video); await model.refresh()
        api.like = { throw ClientError.writeUncertain }; await model.toggleLike()
        #expect(store.model(for: video) === model); #expect(store.model(for: video).needsRefresh)
        store.setAccount(nil); #expect(!model.canAct); #expect(model.state == nil)
        store.setAccount(99); #expect(store.model(for: video) !== model)
    }
    @Test func lateSpendCannotRestoreLoggedOutStateOrRefreshNewAccountFavorites() async throws {
        let api = InteractionStub(); var favorites = 0
        let model = api.model { _ in favorites += 1 }; await model.refresh()
        var waiting: CheckedContinuation<TripleReceipt, any Error>?
        api.tripleResult = { try await withCheckedThrowingContinuation { waiting = $0 } }
        model.present(.triple); let proposal = try #require(model.confirmation)
        let pending = Task { await model.confirm(id: proposal.id) }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let continuation = try #require(waiting)
        await model.confirm(id: proposal.id); #expect(api.triples == 1)
        model.invalidate(); continuation.resume(returning: .init(liked: true, coined: true, favorited: true, coins: 2)); await pending.value
        #expect(model.state == nil); #expect(model.notice == nil); #expect(favorites == 0); #expect(!model.busy)
    }
    @Test func refreshedSnapshotInvalidatesOpenDraftAndIgnoresEarlierRead() async throws {
        let api = InteractionStub(); let model = api.model(); await model.refresh()
        model.present(.coins); let proposal = try #require(model.confirmation)
        var waiting: CheckedContinuation<VideoInteractionState, any Error>?
        api.read = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let old = Task { await model.refresh() }
        for _ in 0..<1_000 { if waiting != nil { break }; await Task.yield() }
        let continuation = try #require(waiting)
        api.read = nil; api.state.coins = 2; await model.refresh()
        continuation.resume(returning: .init(liked: false, coins: 0, favorited: false, balance: 10, coinLimit: 2, ownerID: 99)); await old.value
        #expect(model.state?.coins == 2); #expect(model.confirmation == nil)
        await model.confirm(id: proposal.id); #expect(api.coins.isEmpty)
    }
}
