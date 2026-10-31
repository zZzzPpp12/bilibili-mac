import Foundation
import Observation
import Testing
import BiliMacCore
@testable import BiliMac

@MainActor private final class DiscoveryStub: SearchServing, DiscoveryServing, SearchSuggesting {
    var feed: ((DiscoverySource,ContentRegion,Int) async throws -> VideoSearchPage)?
    var videos: ((String,Int,VideoSearchOptions) async throws -> VideoSearchPage)?
    var suggest: ((String) async throws -> [String])?
    var requests: [Int] = []
    var suggestionCalls: [String] = []
    func discovery(source: DiscoverySource,region: ContentRegion,page: Int) async throws -> VideoSearchPage { requests.append(page); return try await feed?(source,region,page) ?? .init(items:[],total:0,hasMore:false) }
    func search(_ term: String,page: Int) async throws -> [Video] { [] }
    func searchVideos(_ term: String,page: Int,options: VideoSearchOptions) async throws -> VideoSearchPage { try await videos?(term,page,options) ?? .init(items:[],total:0,hasMore:false) }
    func searchUsers(_ term: String,page: Int) async throws -> UserSearchPage { .init(items:[.init(mid:10,name:"用户")],total:1,hasMore:false) }
    func suggestions(_ term: String) async throws -> [String] { suggestionCalls.append(term); return try await suggest?(term) ?? [] }
}
@MainActor private final class InvalidationFlag { var value = false }

@Suite @MainActor struct DiscoveryModelTests {
    private let video = Video(bvid:"BV1xx411c7mD",title:"教程",author:"UP",duration:600)
    private func until(_ predicate: () -> Bool) async { for _ in 0..<1000 { if predicate() { return }; await Task.yield() } }
    @Test func feedsCacheSeparatelyAndKeepTheirScrollOffsets() async {
        let api = DiscoveryStub(), model: DiscoveryModel
        api.feed = { [video] _,_,_ in .init(items:[video],total:1,hasMore:false) }
        model = DiscoveryModel(api:api); model.load(); await model.settled(); model.scrollOffset = 650
        model.select(.popular); await model.settled(); model.scrollOffset = 1200
        model.select(.recommended); await model.settled()
        #expect(model.scrollOffset == 650); #expect(api.requests == [1,1])
        model.reset(); #expect(model.displayed.isEmpty); #expect(model.scrollOffset == 0)
    }
    @Test func failedPaginationRetriesTheSamePageAndKeepsVisibleContent() async {
        let api = DiscoveryStub(); let model = DiscoveryModel(api:api)
        api.feed = { [video] _,_,page in if page == 1 { return .init(items:[video],total:nil,hasMore:true) }; throw URLError(.timedOut) }
        model.load(); await model.settled(); model.load(more:true); await model.settled()
        #expect(model.displayed == [video]); #expect(model.current.page == 1); #expect(model.current.error != nil)
        api.feed = { _,_,page in #expect(page == 2); return .init(items:[],total:nil,hasMore:false) }
        model.retry(); await model.settled(); #expect(model.current.page == 2); #expect(!model.current.hasMore)
    }
    @Test func scrollingDoesNotInvalidateTheCandidateListOrSearchResults() async {
        let api = DiscoveryStub(); let model = DiscoveryModel(api:api)
        api.feed = { [video] _,_,_ in .init(items:[video],total:1,hasMore:false) }
        model.load(); await model.settled()
        let invalidated = InvalidationFlag()
        withObservationTracking { _ = model.current.videos } onChange: { MainActor.assumeIsolated { invalidated.value = true } }
        for offset in 0..<100 { model.scrollOffset = CGFloat(offset) }
        #expect(!invalidated.value); #expect(model.scrollOffset == 99)
        let search = SearchModel(api:api); search.submit("教程"); await search.settled()
        withObservationTracking { _ = search.current.videos } onChange: { MainActor.assumeIsolated { invalidated.value = true } }
        search.scrollOffset = 100; #expect(!invalidated.value)
    }
    @Test func duplicatePaginationStopsAndCannotAdvanceTheCursor() async {
        let api = DiscoveryStub(); let model = DiscoveryModel(api:api)
        api.feed = { [video] _,_,_ in .init(items:[video],total:nil,hasMore:true) }
        model.load(); await model.settled(); model.load(more:true); await model.settled()
        #expect(model.current.page == 1); #expect(model.current.error != nil); #expect(model.displayed.count == 1)
    }
    @Test func lateRegionalResponseCannotOverwriteTheNewRegion() async {
        let api = DiscoveryStub(); let model = DiscoveryModel(api:api)
        var old: CheckedContinuation<VideoSearchPage,Error>?
        api.feed = { _,region,_ in
            if region == .technology { return try await withCheckedThrowingContinuation { old = $0 } }
            return .init(items:[],total:0,hasMore:false)
        }
        model.select(.regions,region:.technology); await until { old != nil }
        model.select(.regions,region:.music); await model.settled()
        old?.resume(returning:.init(items:[video],total:1,hasMore:false)); await Task.yield()
        #expect(model.key.region == .music); #expect(model.displayed.isEmpty)
    }
    @Test func localFiltersDoNotInventMissingDatesOrLoseTheNextPage() async {
        let api = DiscoveryStub(); let model = DiscoveryModel(api:api)
        api.feed = { [video] _,_,_ in .init(items:[video],total:nil,hasMore:true) }
        model.load(); await model.settled(); model.setPublication(.week)
        #expect(model.displayed.isEmpty); #expect(model.current.hasMore)
        model.setPublication(.any); model.setDuration(.short); #expect(model.displayed.isEmpty)
        model.setDuration(.medium); #expect(model.displayed == [video])
    }
    @Test func filterChangesDuringPaginationKeepTheNewScrollPosition() async {
        let api = DiscoveryStub(); let model = DiscoveryModel(api:api)
        var next: CheckedContinuation<VideoSearchPage,Error>?
        api.feed = { [video] _,_,page in
            if page == 1 { return .init(items:[video],total:nil,hasMore:true) }
            return try await withCheckedThrowingContinuation { next = $0 }
        }
        model.load(); await model.settled(); model.scrollOffset = 650
        model.load(more:true); await until { next != nil }
        model.setDuration(.medium); let revision = model.current.revision
        next?.resume(returning:.init(items:[],total:nil,hasMore:false)); await model.settled()
        #expect(model.scrollOffset == 0); #expect(model.current.revision == revision)
    }
    @Test func searchFilterChangesKeepUserResultsAndDiscardOldVideoResponses() async {
        let api = DiscoveryStub(); let model = SearchModel(api:api)
        var old: CheckedContinuation<VideoSearchPage,Error>?
        api.videos = { _,_,options in
            if options.order == .official { return try await withCheckedThrowingContinuation { old = $0 } }
            return .init(items:[],total:0,hasMore:false)
        }
        model.submit("教程"); await until { old != nil }
        var options = VideoSearchOptions(); options.order = .latest; model.setOptions(options); await model.settled()
        old?.resume(returning:.init(items:[video],total:1,hasMore:false)); await Task.yield()
        #expect(model.current.videos.isEmpty); #expect(model.options.order == .latest)
        model.select(.users); await model.settled(); model.scrollOffset = 480
        options.duration = .long; model.setOptions(options)
        #expect(model.current.users.count == 1); #expect(model.scrollOffset == 480)
    }
    @Test func accountResetRejectsOldSearchResponses() async {
        let api = DiscoveryStub(); let model = SearchModel(api:api)
        var old: CheckedContinuation<VideoSearchPage,Error>?
        api.videos = { _,_,_ in try await withCheckedThrowingContinuation { old = $0 } }
        model.submit("教程"); await until { old != nil }; let previous = old
        api.videos = { _,_,_ in .init(items:[],total:0,hasMore:false) }
        model.resetAccount(); await model.settled(); previous?.resume(returning:.init(items:[video],total:1,hasMore:false)); await Task.yield()
        #expect(model.current.videos.isEmpty)
    }
}

@Suite @MainActor struct SearchAssistanceTests {
    private func until(_ predicate: () -> Bool) async { for _ in 0..<1000 { if predicate() { return }; await Task.yield() } }
    @Test func historyIsNormalizedBoundedPersistentAndAccountScoped() {
        let name = "BiliMac-tests-\(UUID())"; let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let api = DiscoveryStub(); let model = SearchAssistanceModel(api:api,defaults:defaults)
        model.record(" Swift "); model.record("ＳＷＩＦＴ")
        #expect(model.history.count == 1); #expect(model.history[0].count == 2)
        for i in 0..<40 { model.record("关键词 \(i)") }; #expect(model.history.count == 30)
        let restored = SearchAssistanceModel(api:api,defaults:defaults); #expect(restored.history == model.history)
        model.setAccount(10); #expect(model.history.isEmpty); model.record("账号独立记录")
        model.setAccount(nil); #expect(model.history.count == 30)
        model.clear(); #expect(SearchAssistanceModel(api:api,defaults:defaults).history.isEmpty)
    }
    @Test func debounceOnlyRequestsLatestInputAndLinksDoNotReachSuggestions() async throws {
        let api = DiscoveryStub(); let model = SearchAssistanceModel(api:api,delay:.milliseconds(20))
        model.update("s"); model.update("sw"); model.update("swift"); await model.settled()
        #expect(api.suggestionCalls == ["swift"])
        model.update("https://www.bilibili.com/video/BV1xx411c7mD"); await model.settled(); #expect(!model.presented)
        #expect(api.suggestionCalls.count == 1)
    }
    @Test func lateSuggestionsAndAccountChangesCannotReopenThePopup() async {
        let api = DiscoveryStub(); let model = SearchAssistanceModel(api:api,delay:.zero)
        var old: CheckedContinuation<[String],Error>?
        api.suggest = { _ in try await withCheckedThrowingContinuation { old = $0 } }
        model.update("旧词"); await until { old != nil }; model.setAccount(20)
        old?.resume(returning:["旧建议"]); await Task.yield()
        #expect(!model.presented); #expect(model.suggestions.isEmpty)
    }
    @Test func failedSuggestionsKeepLocalMatchesAndKeyboardSelection() async {
        let api = DiscoveryStub(); let model = SearchAssistanceModel(api:api,delay:.zero)
        model.record("SwiftUI"); model.record("Swift 教程")
        api.suggest = { _ in throw URLError(.timedOut) }
        model.update("swift"); await model.settled()
        #expect(model.suggestions.count == 2); #expect(model.error != nil)
        model.move(1); #expect(model.selectedText != nil)
        model.remove(TextMatching.normalize("SwiftUI")); #expect(model.history.count == 1)
        model.dismiss(); #expect(!model.presented)
    }
    @Test func localAndRemoteSuggestionsAreDeduplicated() async {
        let api = DiscoveryStub(); let model = SearchAssistanceModel(api:api,delay:.zero)
        model.record("SwiftUI"); api.suggest = { _ in ["swiftui","Swift 教程"] }
        model.update("swift"); await model.settled()
        #expect(model.suggestions.map(\.text) == ["SwiftUI","Swift 教程"])
    }
    @Test func disablingOnlineSuggestionsStillProvidesLocalHistoryWithoutRequests() async {
        let name = "BiliMac-tests-\(UUID())"; let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        defaults.set(false,forKey:"searchSuggestionsEnabled")
        let api = DiscoveryStub(); let model = SearchAssistanceModel(api:api,defaults:defaults,delay:.zero)
        model.record("SwiftUI"); model.update("swift"); await model.settled()
        #expect(model.suggestions.map(\.text) == ["SwiftUI"]); #expect(api.suggestionCalls.isEmpty)
    }
}
