import Foundation
import Observation
import BiliMacCore

@MainActor @Observable final class LibraryModel {
    let api: any LibraryServing
    private(set) var mid: Int?
    private var identity = UUID()
    private var folderIdentity = UUID()
    private var itemsIdentity = UUID()
    private var laterIdentity = UUID()
    private(set) var folders: [FavoriteFolder] = []
    private(set) var foldersLoaded = false
    private(set) var foldersLoading = false
    private(set) var selectedFolder: Int?
    private(set) var items: [SavedVideo] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var hasMore = false
    private var page = 0
    var error: String?
    private var failedMore = false
    var foldersError: String?
    private(set) var later: [SavedVideo] = []
    private(set) var laterLoaded = false
    private(set) var laterLoading = false
    var laterError: String?
    private(set) var writingLater = false
    private(set) var laterNeedsRefresh = false
    var notice: String?
    init(api: any LibraryServing) { self.api = api }
    func setAccount(_ mid: Int?) {
        identity = UUID(); folderIdentity = UUID(); itemsIdentity = UUID(); laterIdentity = UUID(); self.mid = mid
        folders = []; foldersLoaded = false; foldersLoading = false; selectedFolder = nil
        items = []; loading = false; loaded = false; hasMore = false; page = 0; error = nil; failedMore = false; foldersError = nil
        later = []; laterLoaded = false; laterLoading = false; laterError = nil
        writingLater = false; laterNeedsRefresh = false; notice = nil
    }
    func loadFolders() async {
        guard let mid else { return }
        folderIdentity = UUID(); let token = folderIdentity, session = identity
        foldersLoading = true; foldersError = nil
        defer { if token == folderIdentity && session == identity { foldersLoading = false } }
        do {
            let result = try await api.favoriteFolders(mid: mid, aid: nil)
            guard session == identity, token == folderIdentity, !Task.isCancelled else { return }
            folders = result; foldersLoaded = true
            if !result.contains(where: { $0.id == selectedFolder }) { selectFolder(result.first?.id) }
        } catch {
            if session == identity, token == folderIdentity, !Task.isCancelled { foldersError = error.localizedDescription }
        }
    }
    func selectFolder(_ folder: Int?) {
        guard selectedFolder != folder else { return }
        itemsIdentity = UUID(); selectedFolder = folder; items = []; loaded = false; loading = false; page = 0; hasMore = false; error = nil; failedMore = false
    }
    func loadFavorites(more: Bool = false) async {
        guard let mid, let folder = selectedFolder, !more || (!loading && hasMore) else { return }
        itemsIdentity = UUID(); let token = itemsIdentity, session = identity
        let next = more ? page + 1 : 1
        loading = true; error = nil
        defer { if token == itemsIdentity && session == identity { loading = false } }
        do {
            let result = try await api.favorites(mid: mid, folder: folder, page: next)
            guard session == identity, token == itemsIdentity, !Task.isCancelled else { return }
            let combined = SavedVideo.unique((more ? items : []) + result.items)
            if more && result.hasMore && combined.count == items.count { throw ClientError.paginationStalled }
            items = combined; hasMore = result.hasMore; page = next; loaded = true
        } catch {
            if session == identity, token == itemsIdentity, !Task.isCancelled { self.error = error.localizedDescription; failedMore = more }
        }
    }
    func retryFavorites() async { await loadFavorites(more: failedMore) }
    func loadLater() async {
        guard let mid, !writingLater else { return }
        laterIdentity = UUID(); let token = laterIdentity, session = identity
        laterLoading = true; laterError = nil
        defer { if token == laterIdentity && session == identity { laterLoading = false } }
        do {
            let result = try await api.watchLater(mid: mid)
            guard session == identity, token == laterIdentity, !Task.isCancelled else { return }
            later = result; laterLoaded = true; laterNeedsRefresh = false
        } catch {
            if session == identity, token == laterIdentity, !Task.isCancelled { laterError = error.localizedDescription }
        }
    }
    func setLater(_ video: SavedVideo, saved: Bool) async {
        guard let mid, laterLoaded, !laterLoading, !writingLater, !laterNeedsRefresh else { return }
        let session = identity
        writingLater = true; laterError = nil; notice = nil
        defer { if session == identity { writingLater = false } }
        do {
            try await api.setWatchLater(mid: mid, aid: video.id, saved: saved)
            guard session == identity else { return }
            later.removeAll { $0.id == video.id }
            if saved { later.insert(video, at: 0) }
            notice = saved ? "已加入稍后再看" : "已移出稍后再看"
        } catch {
            guard session == identity else { return }
            laterError = error.localizedDescription
            if case ClientError.writeUncertain = error { laterNeedsRefresh = true }
        }
    }
}

@MainActor @Observable final class FavoriteEditorModel {
    let api: any LibraryServing
    let mid: Int
    let aid: Int
    private var identity = UUID()
    private(set) var folders: [FavoriteFolder] = []
    private(set) var original: Set<Int> = []
    var selected: Set<Int> = []
    private(set) var ready = false
    private(set) var busy = false
    private(set) var needsRefresh = false
    var error: String?
    var notice: String?
    var changes: FavoriteChanges { FavoriteChanges(original: original, selected: selected) }
    init(api: any LibraryServing, mid: Int, aid: Int) { self.api = api; self.mid = mid; self.aid = aid }
    func load() async {
        guard !busy else { return }
        let token = identity; busy = true; error = nil
        defer { if token == identity { busy = false } }
        do {
            let result = try await api.favoriteFolders(mid: mid, aid: aid)
            guard token == identity, !Task.isCancelled else { return }
            folders = result; original = Set(result.filter(\.containsVideo).map(\.id)); selected = original
            ready = true; needsRefresh = false; notice = nil
        } catch { if token == identity { self.error = error.localizedDescription } }
    }
    func invalidate() { identity = UUID(); busy = false; ready = false }
    func save() async -> Bool {
        guard ready, !busy, !needsRefresh else { return false }
        if changes.isEmpty { return true }
        let token = identity, delta = changes; busy = true; error = nil
        defer { if token == identity { busy = false } }
        do {
            try await api.changeFavorites(mid: mid, aid: aid, changes: delta)
            guard token == identity else { return false }
            original = selected; return true
        } catch {
            if token == identity {
                self.error = error.localizedDescription
                if case ClientError.writeUncertain = error { needsRefresh = true }
            }
            return false
        }
    }
    func create(title: String, isPrivate: Bool) async -> Bool {
        guard ready, !busy, !needsRefresh else { return false }
        let token = identity; busy = true; error = nil
        defer { if token == identity { busy = false } }
        do {
            let folder = try await api.createFolder(mid: mid, title: title, isPrivate: isPrivate)
            guard token == identity else { return false }
            folders.append(folder); selected.insert(folder.id)
            notice = "收藏夹已创建。点击保存后，视频才会加入新收藏夹。"; return true
        } catch {
            if token == identity {
                self.error = error.localizedDescription
                if case ClientError.writeUncertain = error { needsRefresh = true }
            }
            return false
        }
    }
}
