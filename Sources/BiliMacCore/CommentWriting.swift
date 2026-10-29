import Foundation

public struct CommentSubmission: Sendable {
    public let id: Int
    /// A submission receipt is not evidence that a comment is publicly visible.
    public init(id: Int) { self.id = id }
}

public enum CommentText {
    public static let limit = 1000
    public static func normalized(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= limit else { throw ClientError.invalidCommentText }
        return text
    }
}

public protocol CommentWriting: Sendable {
    func addComment(mid: Int, aid: Int, bvid: String, message: String, root: Int, parent: Int) async throws -> CommentSubmission
    func likeComment(mid: Int, aid: Int, bvid: String, id: Int, liked: Bool) async throws
    func deleteComment(mid: Int, aid: Int, bvid: String, comment: Comment) async throws
}

extension BilibiliClient: CommentWriting {
    private func prepareCommentWrite(mid: Int, aid: Int, bvid: String) async throws {
        guard aid > 0, VideoInput.bvid(bvid) == bvid else { throw ClientError.invalidInput }
        try await prepareInteraction(mid: mid)
    }
    public func addComment(mid: Int, aid: Int, bvid: String, message: String, root: Int = 0, parent: Int = 0) async throws -> CommentSubmission {
        let message = try CommentText.normalized(message)
        guard (root == 0 && parent == 0) || (root > 0 && parent > 0) else { throw ClientError.invalidInput }
        let scope = authenticationID
        try await prepareCommentWrite(mid: mid, aid: aid, bvid: bvid)
        guard scope == authenticationID else { throw CancellationError() }
        var values = ["oid": "\(aid)", "type": "1", "message": message, "plat": "1"]
        if root > 0 { values["root"] = "\(root)"; values["parent"] = "\(parent)" }
        let result = try await postAuthenticated("/x/v2/reply/add", values: values, mid: mid, bvid: bvid)
        let nested = (result["reply"] as? [String: Any]).map { integer($0["rpid"]) } ?? 0
        let id = integer(result["rpid"]) > 0 ? integer(result["rpid"]) : nested
        guard id > 0, nested == 0 || nested == id else { throw ClientError.writeUncertain }
        return CommentSubmission(id: id)
    }
    public func likeComment(mid: Int, aid: Int, bvid: String, id: Int, liked: Bool) async throws {
        guard id > 0 else { throw ClientError.invalidInput }
        let scope = authenticationID
        try await prepareCommentWrite(mid: mid, aid: aid, bvid: bvid)
        guard scope == authenticationID else { throw CancellationError() }
        _ = try await postAuthenticated("/x/v2/reply/action", values: ["oid": "\(aid)", "type": "1", "rpid": "\(id)", "action": liked ? "1" : "0"], mid: mid, bvid: bvid)
    }
    public func deleteComment(mid: Int, aid: Int, bvid: String, comment: Comment) async throws {
        guard comment.id > 0, comment.mid == mid else { throw ClientError.invalidInput }
        let scope = authenticationID
        try await prepareCommentWrite(mid: mid, aid: aid, bvid: bvid)
        guard scope == authenticationID else { throw CancellationError() }
        _ = try await postAuthenticated("/x/v2/reply/del", values: ["oid": "\(aid)", "type": "1", "rpid": "\(comment.id)"], mid: mid, bvid: bvid)
    }
}
