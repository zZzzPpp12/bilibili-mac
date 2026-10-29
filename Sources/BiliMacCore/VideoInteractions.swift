import Foundation

public struct VideoInteractionState: Equatable, Sendable {
    public var liked: Bool
    public var coins: Int
    public var favorited: Bool
    public var balance: Double
    public let coinLimit: Int
    public let ownerID: Int
    public init(liked: Bool, coins: Int, favorited: Bool, balance: Double, coinLimit: Int, ownerID: Int) {
        self.liked = liked; self.coins = coins; self.favorited = favorited; self.balance = balance; self.coinLimit = coinLimit; self.ownerID = ownerID
    }
    public var remaining: Int { max(0, coinLimit - coins) }
    public var available: Int { balance.isFinite ? max(0, min(remaining, Int(max(0, min(2, balance))))) : 0 }
    public var isTriple: Bool { liked && coins > 0 && favorited }
}
public struct CoinReceipt: Sendable {
    public let liked: Bool
    public init(liked: Bool) { self.liked = liked }
}
public struct TripleReceipt: Sendable {
    public let liked: Bool
    public let coined: Bool
    public let favorited: Bool
    public let coins: Int
    public init(liked: Bool, coined: Bool, favorited: Bool, coins: Int) { self.liked = liked; self.coined = coined; self.favorited = favorited; self.coins = coins }
}
public protocol VideoInteractionServing: Sendable {
    func interactionState(mid: Int, aid: Int) async throws -> VideoInteractionState
    func setVideoLike(mid: Int, aid: Int, bvid: String, liked: Bool) async throws
    func addCoins(mid: Int, aid: Int, bvid: String, amount: Int, alsoLike: Bool) async throws -> CoinReceipt
    func triple(mid: Int, aid: Int, bvid: String) async throws -> TripleReceipt
}

extension BilibiliClient: VideoInteractionServing {
    public func interactionState(mid: Int, aid: Int) async throws -> VideoInteractionState {
        try requireAccount(mid); guard aid > 0 else { throw ClientError.invalidInput }
        let scope = authenticationID
        let detail = try await request("/x/web-interface/view", query: ["aid":"\(aid)"]).data
        guard scope == authenticationID else { throw CancellationError() }
        let relation = try await request("/x/web-interface/archive/relation", query: ["aid":"\(aid)"]).data
        guard scope == authenticationID else { throw CancellationError() }
        let nav = try await request("/x/web-interface/nav").data
        guard scope == authenticationID else { throw CancellationError() }
        guard nav["isLogin"] as? Bool == true, integer(nav["mid"]) == mid else { throw ClientError.authenticationRequired }
        guard let liked = relation["like"] as? Bool, let coins = relation["coin"] as? Int, (0...2).contains(coins),
              let favorite = relation["favorite"] as? Bool, let balance = nav["money"] as? Double, balance.isFinite, balance >= 0,
              let copyright = detail["copyright"] as? Int, [1, 2].contains(copyright),
              let owner = detail["owner"] as? [String: Any], integer(owner["mid"]) > 0,
              integer(detail["aid"]) == aid else { throw ClientError.invalidResponse }
        return VideoInteractionState(liked: liked, coins: coins, favorited: favorite, balance: balance, coinLimit: copyright == 2 ? 1 : 2, ownerID: integer(owner["mid"]))
    }
    private func prepareVideoWrite(mid: Int, aid: Int, bvid: String) async throws {
        guard aid > 0, VideoInput.bvid(bvid) == bvid else { throw ClientError.invalidInput }
        try await prepareInteraction(mid: mid)
    }
    public func setVideoLike(mid: Int, aid: Int, bvid: String, liked: Bool) async throws {
        let scope = authenticationID
        try await prepareVideoWrite(mid: mid, aid: aid, bvid: bvid)
        guard scope == authenticationID else { throw CancellationError() }
        _ = try await postAuthenticated("/x/web-interface/archive/like", values: ["aid":"\(aid)", "like":liked ? "1" : "2"], mid: mid, bvid: bvid)
    }
    public func addCoins(mid: Int, aid: Int, bvid: String, amount: Int, alsoLike: Bool) async throws -> CoinReceipt {
        guard (1...2).contains(amount) else { throw ClientError.invalidCoinAmount }
        let scope = authenticationID
        try await prepareVideoWrite(mid: mid, aid: aid, bvid: bvid)
        guard scope == authenticationID else { throw CancellationError() }
        let data = try await postAuthenticated("/x/web-interface/coin/add", values: ["aid":"\(aid)", "multiply":"\(amount)", "select_like":alsoLike ? "1" : "0", "cross_domain":"true"], mid: mid, bvid: bvid)
        guard let liked = data["like"] as? Bool else { throw ClientError.writeUncertain }
        return CoinReceipt(liked: liked)
    }
    public func triple(mid: Int, aid: Int, bvid: String) async throws -> TripleReceipt {
        let scope = authenticationID
        try await prepareVideoWrite(mid: mid, aid: aid, bvid: bvid)
        guard scope == authenticationID else { throw CancellationError() }
        let data = try await postAuthenticated("/x/web-interface/archive/like/triple", values: ["aid":"\(aid)"], mid: mid, bvid: bvid)
        guard let liked = data["like"] as? Bool, let coin = data["coin"] as? Bool, let favorite = data["fav"] as? Bool,
              let count = data["multiply"] as? Int, (0...2).contains(count), !coin || count > 0 else { throw ClientError.writeUncertain }
        return TripleReceipt(liked: liked, coined: coin, favorited: favorite, coins: count)
    }
}
