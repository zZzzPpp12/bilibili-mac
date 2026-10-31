import Foundation
import Testing
@testable import BiliMacCore

@Suite struct DiscoveryAPITests {
    private let spi: [String: Any] = ["code":0,"data":["b_3":"official-fixture-id"]]
    private let nav: [String: Any] = ["code":0,"data":["isLogin":false,"wbi_img":["img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c49.png","sub_url":"https://i0.hdslb.com/bfs/wbi/3caff0ff746eab6f01bf08b70ac45.png"]]]
    private let row: [String: Any] = ["bvid":"BV1xx411c7mD","title":"中文教程","author":"测试 UP","duration":"12:00","pubdate":1_700_000_000,"typeid":"188"]
    @Test func advancedSearchUsesSignedServerFiltersAndServerPagination() async throws {
        let scenario = APIScenario([spi,nav,["code":0,"data":["result":[row,row],"numResults":30,"numPages":2]],
                                    ["code":0,"data":["result":[],"numResults":30,"numPages":2]]])
        var options = VideoSearchOptions(); options.order = .favorites; options.region = .technology
        options.duration = .medium; options.published = .week; options.copyright = .original
        let result = try await scenario.client.searchVideos(" 中文 A&B ",page:1,options:options)
        #expect(result.items.count == 1); #expect(result.total == 30); #expect(result.hasMore)
        #expect(try await !scenario.client.searchVideos("中文",page:2,options:options).hasMore)
        let requests = scenario.finish(); let values = query(requests[2])
        #expect(values["keyword"] == "中文 A&B"); #expect(values["order"] == "stow"); #expect(values["duration"] == "2")
        #expect(values["tids"] == "188"); #expect(values["copyright"] == "1"); #expect(values["w_rid"]?.count == 32)
        #expect(Int(values["pubtime_end_s"]!)! - Int(values["pubtime_begin_s"]!)! == 7 * 86400)
        #expect(query(requests[3])["page"] == "2"); #expect(requests.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func malformedSearchMetadataIsNotAnEmptySuccess() async throws {
        let scenario = APIScenario([spi,nav,["code":0,"data":["result":[]]],
                                    ["code":0,"data":["result":NSNull(),"numResults":0,"numPages":0]]])
        await #expect(throws:(any Error).self) { try await scenario.client.searchVideos("测试",page:1,options:.init()) }
        let empty = try await scenario.client.searchVideos("测试",page:1,options:.init())
        #expect(empty.items.isEmpty); #expect(!empty.hasMore); #expect(scenario.finish().count == 4)
    }
    @Test func suggestionsUseTheirOfficialHostAndNeverCarryAccountCookies() async throws {
        let scenario = APIScenario([["code":0,"result":["tag":[["value":"SwiftUI"],["value":"swiftui"],["value":"Swift 教程"],["value":""]]]]])
        await scenario.login()
        #expect(try await scenario.client.suggestions(" Swift ") == ["SwiftUI","Swift 教程"])
        let request = try #require(scenario.finish().first)
        #expect(request.url?.host == "s.search.bilibili.com"); #expect(query(request)["term"] == "Swift")
        #expect(request.value(forHTTPHeaderField:"Cookie") == nil); #expect(request.httpMethod == "GET")
    }
    @Test func suggestionsDoNotHideMalformedResponses() async {
        let scenario = APIScenario([["code":0,"result":[:]]])
        await #expect(throws:(any Error).self) { try await scenario.client.suggestions("测试") }
        #expect(scenario.finish().count == 1)
    }
    @Test func regionalRankingIsOneRealSnapshotWithoutInventedPagination() async throws {
        let scenario = APIScenario([["code":0,"data":["list":[row,row]]]])
        let result = try await scenario.client.discovery(source:.regions,region:.technology,page:1)
        #expect(result.items.count == 1); #expect(!result.hasMore)
        #expect(result.items[0].categoryID == 188); #expect(result.items[0].publishedAt?.timeIntervalSince1970 == 1_700_000_000)
        await #expect(throws:(any Error).self) { try await scenario.client.discovery(source:.regions,region:.technology,page:2) }
        let requests = scenario.finish(); #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/x/web-interface/ranking/v2"); #expect(query(requests[0])["rid"] == "188")
    }
    @Test func invalidInputsNeverReachTheNetwork() async {
        let scenario = APIScenario([])
        await #expect(throws:(any Error).self) { try await scenario.client.suggestions(String(repeating:"中",count:101)) }
        await #expect(throws:(any Error).self) { try await scenario.client.searchVideos(" ",page:1,options:.init()) }
        await #expect(throws:(any Error).self) { try await scenario.client.discovery(source:.popular,region:.all,page:0) }
        #expect(scenario.finish().isEmpty)
    }
    @Test func newMetadataRemainsCompatibleWithOldHistory() throws {
        let old = Data("{\"bvid\":\"BV1xx411c7mD\",\"aid\":1,\"title\":\"旧\",\"cover\":\"\",\"author\":\"UP\",\"duration\":60,\"views\":10}".utf8)
        let video = try JSONDecoder().decode(Video.self,from:old)
        #expect(video.publishedAt == nil); #expect(video.categoryID == nil)
        #expect(try JSONDecoder().decode(Video.self,from:JSONEncoder().encode(video)) == video)
    }
}

@Suite struct ContentRankingTests {
    private let now = Date(timeIntervalSince1970:1_800_000_000)
    private func video(_ id: String,_ title: String,author: String = "UP",views: Int = 0,days: Double = 0) -> Video {
        .init(bvid:id,title:title,author:author,duration:600,views:views,publishedAt:now.addingTimeInterval(-days*86400))
    }
    @Test func relevanceBeatsUnrelatedPopularityAndNormalizesChineseAndLatin() {
        let unrelated = video("a","游戏实况",views:10_000_000), exact = video("b","SwiftUI 入门教程",views:10)
        #expect(ContentRanking.search([unrelated,exact],term:"ＳＷＩＦＴＵＩ",now:now).first?.id == "b")
        #expect(ContentRanking.search([unrelated,video("c","中文编程教程")],term:"编程教程",now:now).first?.id == "c")
        #expect(TextMatching.normalize(" Ｓｗｉｆｔ　 UI ") == "swift ui")
        #expect(TextMatching.tokens("SwiftUI入门") == ["swiftui","入门"])
    }
    @Test func diversityReducesAdjacentDuplicateAuthorsWithoutRemovingVideos() {
        let rows = [video("a","旅行风景",author:"同一 UP"),video("b","旅行风景",author:"同一 UP"),video("c","旅行风景",author:"另一 UP")]
        let ranked = ContentRanking.discovery(rows,order:.balanced,now:now)
        #expect(ranked.map(\.id) == ["a","c","b"])
        #expect(Set(ranked.map(\.id)) == Set(rows.map(\.id)))
        #expect(ContentRanking.discovery(rows,order:.official) == rows)
    }
    @Test func sortingIsStableAndUnknownDatesAreNotInvented() {
        let old = video("a","旧视频",days:60), recent = video("b","新视频",days:1)
        #expect(ContentRanking.discovery([old,recent],order:.latest).map(\.id) == ["b","a"])
        #expect(ContentRanking.discovery([old,recent],order:.views).map(\.id) == ["a","b"])
        #expect(!PublicationWindow.week.matches(nil,now:now))
        #expect(!PublicationWindow.week.matches(now.addingTimeInterval(10),now:now))
        #expect(VideoDuration.medium.matches(600)); #expect(!VideoDuration.short.matches(600)); #expect(!VideoDuration.short.matches(0))
    }
    @Test func historyOnlyChangesRankingWhenSupplied() {
        let a = video("a","编程开发",author:"A"), b = video("b","美食烹饪",author:"B")
        let history = [WatchRecord(video:video("c","美食烹饪",author:"B"),cid:1,position:5)]
        #expect(ContentRanking.discovery([a,b],order:.balanced,now:now).first?.id == "a")
        #expect(ContentRanking.discovery([a,b],order:.balanced,history:history,now:now).first?.id == "b")
    }
}
