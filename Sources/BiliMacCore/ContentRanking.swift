import Foundation

public enum TextMatching {
    public static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// Chinese bigrams plus Latin words: deterministic, no external model or service.
    public static func tokens(_ value: String) -> [String] {
        var result: [String] = [], word = "", chinese: [Character] = []
        func flushWord() { if !word.isEmpty { result.append(word); word = "" } }
        func flushChinese() {
            if chinese.count == 1 { result.append(String(chinese[0])) }
            else if chinese.count > 1 { result += (0..<chinese.count-1).map { String(chinese[$0...$0+1]) } }
            chinese = []
        }
        for char in normalize(value) {
            if char.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }) { flushWord(); chinese.append(char) }
            else if char.isLetter || char.isNumber { flushChinese(); word.append(char) }
            else { flushWord(); flushChinese() }
        }
        flushWord(); flushChinese(); return result
    }
}

public enum ContentRanking {
    public static func search(_ videos: [Video], term: String, now: Date = Date()) -> [Video] {
        let documents = videos.map { TextMatching.tokens($0.title + " " + $0.author) }
        let queries = Set(TextMatching.tokens(term))
        let average = max(1, Double(documents.reduce(0) { $0 + $1.count }) / Double(max(1, videos.count)))
        let frequencies = Dictionary(uniqueKeysWithValues: queries.map { token in (token, documents.filter { $0.contains(token) }.count) })
        let relevance: [Double] = documents.enumerated().map { index, tokens in
            var score = queries.reduce(0.0) { score, token in
                let tf = Double(tokens.filter { $0 == token }.count)
                let idf = log(1 + (Double(videos.count - (frequencies[token] ?? 0)) + 0.5) / (Double(frequencies[token] ?? 0) + 0.5))
                return score + idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * Double(tokens.count) / average))
            }
            let query = TextMatching.normalize(term)
            if TextMatching.normalize(videos[index].title).contains(query) { score += 2 }
            if TextMatching.normalize(videos[index].author) == query { score += 2 }
            return score
        }
        let maximum = max(1, relevance.max() ?? 1)
        return diversify(videos, scores: videos.indices.map {
            0.78 * relevance[$0] / maximum + 0.12 / (1 + Double($0) / 12)
                + 0.06 * freshness(videos[$0], now: now) + 0.04 * heat(videos[$0])
        })
    }
    public static func discovery(_ videos: [Video], order: DiscoveryOrder, history: [WatchRecord] = [], now: Date = Date()) -> [Video] {
        switch order {
        case .official: return videos
        case .latest: return stableSort(videos) { $0.publishedAt?.timeIntervalSince1970 ?? 0 }
        case .views: return stableSort(videos) { Double(max(0, $0.views)) }
        case .balanced:
            let recent = Array(history.prefix(50))
            let authors = Set(recent.compactMap { $0.video.authorID })
            let interests = Set(recent.flatMap { TextMatching.tokens($0.video.title) })
            let watched = Set(recent.map(\.id))
            let scores = videos.enumerated().map { index, video in
                let tokens = Set(TextMatching.tokens(video.title))
                let overlap = Double(tokens.intersection(interests).count) / Double(max(1, tokens.count))
                let affinity = min(1, overlap + (video.authorID.map { authors.contains($0) } == true ? 0.5 : 0))
                return 0.34 / (1 + Double(index) / 20) + 0.24 * freshness(video, now: now)
                    + 0.22 * heat(video) + 0.2 * affinity - (watched.contains(video.id) ? 0.25 : 0)
            }
            return diversify(videos, scores: scores)
        }
    }
    private static func heat(_ video: Video) -> Double { min(1, log1p(Double(max(0, video.views))) / log1p(10_000_000)) }
    private static func freshness(_ video: Video, now: Date) -> Double {
        guard let date = video.publishedAt, date <= now else { return 0 }
        return exp(-now.timeIntervalSince(date) / (30 * 86400))
    }
    private static func stableSort(_ videos: [Video], by score: (Video) -> Double) -> [Video] {
        videos.enumerated().sorted { a, b in let x = score(a.element), y = score(b.element); return x == y ? a.offset < b.offset : x > y }.map(\.element)
    }
    /// Greedy MMR-like author/title penalty; ties retain upstream order.
    private static func diversify(_ videos: [Video], scores: [Double]) -> [Video] {
        var remaining = Array(videos.indices), selected: [Int] = []
        let titles = videos.map { Set(TextMatching.tokens($0.title)) }
        while !remaining.isEmpty {
            if Task.isCancelled { return videos }
            func value(_ index: Int) -> Double {
                let penalty = selected.suffix(5).map { other -> Double in
                    let sameAuthor = videos[index].authorID != nil ? videos[index].authorID == videos[other].authorID : videos[index].author == videos[other].author
                    let union = titles[index].union(titles[other]).count
                    let similarity = Double(titles[index].intersection(titles[other]).count) / Double(max(1, union))
                    return (sameAuthor ? 0.14 : 0) + 0.08 * similarity
                }.max() ?? 0
                return scores[index] - penalty
            }
            var best = 0, bestScore = value(remaining[0])
            for position in remaining.indices.dropFirst() {
                let score = value(remaining[position])
                if score > bestScore { best = position; bestScore = score }
            }
            selected.append(remaining.remove(at: best))
        }
        return selected.map { videos[$0] }
    }
}
