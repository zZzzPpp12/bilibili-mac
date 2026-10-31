import Foundation
import Observation
import BiliMacCore

struct SearchHistoryEntry: Codable, Equatable, Identifiable {
    var id: String { TextMatching.normalize(term) }
    var term: String
    var count: Int
    var date: Date
}
@MainActor @Observable final class SearchAssistanceModel {
    struct Suggestion: Identifiable {
        var id: String { TextMatching.normalize(text) }
        let text: String
        let local: Bool
    }
    private let api: any SearchSuggesting
    private let defaults: UserDefaults?
    private var scope = "guest"
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let delay: Duration
    private(set) var history: [SearchHistoryEntry] = []
    private(set) var suggestions: [Suggestion] = []
    private(set) var input = ""
    private(set) var presented = false
    private(set) var loading = false
    private(set) var error: String?
    private(set) var selected: Int?
    init(api: any SearchSuggesting, defaults: UserDefaults? = nil, delay: Duration = .milliseconds(300)) {
        self.api = api; self.defaults = defaults; self.delay = delay
        readHistory()
    }
    private var storageKey: String { "searchHistory.v1.\(scope)" }
    func setAccount(_ mid: Int?) {
        dismiss(); suggestions = []; input = ""; error = nil
        scope = mid.map(String.init) ?? "guest"; readHistory()
    }
    private func readHistory() {
        history = defaults?.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([SearchHistoryEntry].self, from: $0) } ?? []
        history = Array(history.filter { !$0.term.isEmpty && $0.term.utf16.count <= 100 && $0.count > 0 }.prefix(30))
    }
    private func persist() { if let data = try? JSONEncoder().encode(history) { defaults?.set(data, forKey: storageKey) } }
    func record(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 100, VideoInput.bvid(text) == nil, UserInput.mid(text) == nil else { return }
        let id = TextMatching.normalize(text), previous = history.first { $0.id == id }
        history.removeAll { $0.id == id }
        history.insert(.init(term: text, count: min(1000, (previous?.count ?? 0) + 1), date: Date()), at: 0)
        history = Array(history.prefix(30)); persist()
    }
    func remove(_ id: String) { history.removeAll { $0.id == id }; persist(); update(input) }
    func clear() { history = []; persist(); update(input) }
    func dismiss() { task?.cancel(); generation = UUID(); presented = false; loading = false; selected = nil }
    func move(_ delta: Int) {
        guard presented, !suggestions.isEmpty else { return }
        selected = min(suggestions.count - 1, max(0, (selected ?? (delta > 0 ? -1 : suggestions.count)) + delta))
    }
    var selectedText: String? { selected.flatMap { suggestions.indices.contains($0) ? suggestions[$0].text : nil } }
    func update(_ text: String) {
        dismiss(); input = text; error = nil
        let query = TextMatching.normalize(text)
        guard text.utf16.count <= 100 else { presented = true; suggestions = []; error = "搜索词最多 100 个字符"; return }
        guard VideoInput.bvid(text) == nil, UserInput.mid(text) == nil else { suggestions = []; return }
        presented = true
        let now = Date()
        let local = history.filter { query.isEmpty || $0.id.contains(query) }.sorted { a, b in
            func score(_ entry: SearchHistoryEntry) -> Double {
                (entry.id.hasPrefix(query) ? 2 : 0) + log1p(Double(entry.count)) + exp(-max(0, now.timeIntervalSince(entry.date)) / (14 * 86400))
            }
            let x = score(a), y = score(b); return x == y ? a.date > b.date : x > y
        }
        suggestions = Array(local.prefix(8)).map { .init(text: $0.term, local: true) }
        guard !query.isEmpty else { return }
        guard defaults?.object(forKey: "searchSuggestionsEnabled") as? Bool != false else { return }
        loading = true; let token = generation
        task = Task {
            do {
                try await Task.sleep(for: delay)
                let remote = try await api.suggestions(text.trimmingCharacters(in: .whitespacesAndNewlines))
                guard token == generation, !Task.isCancelled else { return }
                var seen = Set(suggestions.map(\.id))
                suggestions += remote.filter { seen.insert(TextMatching.normalize($0)).inserted }.prefix(max(0, 10 - suggestions.count)).map { .init(text: $0, local: false) }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                self.error = "联想暂不可用，仍可直接回车搜索"
            }
            if token == generation { loading = false }
        }
    }
    func settled() async { await task?.value }
}
struct DemoSuggestService: SearchSuggesting { func suggestions(_ term: String) async throws -> [String] { [] } }
