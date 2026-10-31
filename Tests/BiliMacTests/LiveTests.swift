import Testing
import Foundation
import AVFoundation
import BiliMacMedia
@testable import BiliMacCore

@Suite struct LiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIMAC_LIVE_TEST"] == "1"))
    func publicSearchSuggestionsAndRegionalRanking() async throws {
        let client = BilibiliClient()
        let suggestions = try await client.suggestions("swift")
        #expect(!suggestions.isEmpty)
        for region in [ContentRegion.technology,.music] {
            let ranking = try await client.discovery(source:.regions,region:region,page:1)
            #expect(!ranking.items.isEmpty); #expect(!ranking.hasMore)
        }
        print("LIVE: official suggestions and two regional rankings checked without credentials or writes")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIMAC_LIVE_SEARCH"] == "1"))
    func publicAdvancedSearch() async throws {
        let client = BilibiliClient(); var options = VideoSearchOptions(); options.order = .views; options.duration = .short
        let result = try await client.searchVideos("猫咪",page:1,options:options)
        #expect(!result.items.isEmpty); #expect(result.total != nil)
        print("LIVE: signed advanced video search checked without credentials or writes")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIMAC_LIVE_TEST"] == "1"))
    func publicUserProfileAndAvatar() async throws {
        let client = BilibiliClient()
        let profile = try await client.userProfile(mid: 946974)
        #expect(profile.user.mid == 946974); #expect(!profile.user.name.isEmpty)
        let avatar = try await CoverImageLoader.shared.avatar(for: profile.user.avatar)
        #expect(avatar.image.width > 0)
        print("LIVE: real public UP profile and avatar checked; no account or follow writes; user search/uploads not asserted")
    }
    // Opt in separately: space/search requests can demand official verification
    // even while public profile, cover and playback endpoints remain available.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIMAC_LIVE_USERS"] == "1"))
    func publicUserUploadsPagination() async throws {
        let client = BilibiliClient()
        let page = try await client.userVideos(mid: 946974, page: 1)
        #expect(!page.items.isEmpty); #expect(page.total >= page.items.count)
        #expect(page.items.allSatisfy { $0.authorID == 946974 && $0.duration >= 0 })
        if page.hasMore {
            let next = try await client.userVideos(mid: 946974, page: 2)
            #expect(!next.items.isEmpty)
            #expect(Set(next.items.map(\.bvid)).subtracting(page.items.map(\.bvid)).count > 0)
        }
        print("LIVE: two real public UP upload pages checked; no account or follow writes; user search not asserted")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIMAC_LIVE_TEST"] == "1"))
    func publicFeedCoversDecode() async throws {
        let client = BilibiliClient()
        for recommended in [false, true] {
            let feed = try await client.feed(recommended: recommended, page: 1)
            #expect(!feed.isEmpty)
            for video in feed.prefix(3) {
                let image = try await CoverImageLoader.shared.image(for: video.cover)
                #expect(image.image.width > 0); #expect(image.image.height > 0)
            }
        }
        print("LIVE: six real popular/recommended covers downloaded and decoded with the production loader; no credentials or writes")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIMAC_LIVE_TEST"] == "1"))
    func publicCommentsAndThread() async throws {
        let client = BilibiliClient()
        let feed = try await client.feed(recommended: false, page: 1)
        let video = try #require(feed.first)
        let page = try await client.comments(aid: video.aid, sort: .hot, offset: nil)
        #expect(page.total >= 0)
        if let root = page.items.first(where: { $0.replyCount > 0 }) {
            _ = try await client.commentThread(aid: video.aid, root: root.id, page: 1)
        }
        if let offset = page.next { _ = try await client.comments(aid: video.aid, sort: .hot, offset: offset) }
        _ = try await client.comments(aid: video.aid, sort: .latest, offset: nil)
        print("LIVE: public comment sorting, cursor and thread reads checked; no credentials or writes")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIMAC_LIVE_TEST"] == "1"))
    func publicEndpointsAndQR() async throws {
        let client = BilibiliClient()
        let feed = try await client.feed(recommended:false,page:1)
        let video = try #require(feed.first)
        let detail = try await client.detail(video.bvid)
        #expect(!detail.pages.isEmpty)
        let qr = try await client.qrCode()
        #expect(!qr.key.isEmpty)
        let preparation = try await client.request("/x/frontend/finger/spi").data
        #expect((preparation["b_3"] as? String)?.isEmpty == false)
        print("LIVE: public feed, signed detail, QR and official interaction identifier checked; no account loaded or writes")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIMAC_LIVE_PLAYBACK"] == "1")) @MainActor
    func publicVideoActuallyPlays() async throws {
        let client = BilibiliClient()
        let bvid: String
        if let sample = ProcessInfo.processInfo.environment["BILIMAC_LIVE_BVID"] {
            bvid = try #require(VideoInput.bvid(sample))
        } else {
            let feed = try await client.feed(recommended:false,page:1)
            bvid = try #require(feed.first).bvid
        }
        let detail = try await client.detail(bvid)
        let manifest = try await client.manifest(bvid:bvid,cid:detail.pages[0].id)
        let representation = try #require(manifest.videos.filter { $0.codec.hasPrefix("avc1") }.last)
        let asset = try await NativePlaybackBridge().prepare(video:representation,audio:manifest.audio,headers:BilibiliClient.mediaHeaders)
        defer { asset.stop() }
        let player = AVPlayer(url:asset.url); player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with:nil) }
        player.play()
        for _ in 0..<120 {
            if player.currentTime().seconds > 0.5 || player.currentItem?.status == .failed { break }
            try await Task.sleep(for:.milliseconds(250))
        }
        #expect(player.currentTime().seconds > 0.5)
        #expect((player.currentItem?.presentationSize.width ?? 0) > 0)
        print("LIVE: BiliMacMedia independent bridge media clock and decoded picture verified; no legacy bridge or credentials used")
    }
}
