import AppKit
import SwiftUI
import AVFoundation
import Testing
@testable import BiliMacCore
import BiliMacMedia
@testable import BiliMac

@Suite(.serialized) @MainActor struct PlayerTransitionTests {
    @Test func scrollingKeepsTheVideoAttachedAndTheMediaClockAdvancing() async throws {
        let fixture = try MediaFixtures()
        let asset = try await NativePlaybackBridge(reader:fixture.reader).prepare(video:fixture.video,audio:fixture.audio)
        defer { asset.stop() }
        let scenario = APIScenario([])
        let store = AppStore(client:scenario.client); store.player.onProgress = nil
        let item = AVPlayerItem(url:asset.url)
        store.player.player.replaceCurrentItem(with:item); store.player.player.isMuted = true
        store.player.detail = VideoDetail(video:Video(bvid:"BV1xx411c7mD",title:"合成媒体切换回归",author:"测试素材",duration:8),description:"",pages:[])
        store.player.danmaku = (0..<120).map { Danmaku(id:"line-\($0)",time:Double($0)/8,mode:1,size:18,color:0xffffff,text:"合成弹幕 \($0)") }
        let layout = PlayerPresentationLayout()
        let size = CGSize(width:1000,height:700)
        layout.setInlineFrame(CGRect(x:30,y:30,width:940,height:528.75))
        layout.setViewport(.init(visibleRect:CGRect(origin:.zero,size:size),containerSize:size))
        let hosting = NSHostingView(rootView:PlayerPresentationLayer(store:store,layout:layout,danmakuEnabled:true,danmakuOpacity:0.8,returnToVideo:{}))
        hosting.frame = CGRect(x:0,y:0,width:1000,height:3000)
        let scroll = NSScrollView(frame:CGRect(origin:.zero,size:size))
        scroll.documentView = hosting
        let window = NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "BiliMac 合成素材回归（不连接账号）"; window.isReleasedWhenClosed = false
        window.contentView = scroll; window.orderFront(nil)
        defer { store.player.stop(); window.contentView = nil; window.close(); _ = scenario.finish() }
        store.player.player.play()
        for _ in 0..<100 {
            if store.player.player.currentTime().seconds > 0.3 { break }
            try await Task.sleep(for:.milliseconds(30))
        }
        let surface = store.player.surface
        let parent = try #require(surface.superview)
        try #require(surface.window === window)
        try #require(store.player.player.currentTime().seconds > 0.3)
        let before = surface.windowChangeCount
        let plans = surface.overlay.planBuildCount
        try #require(plans > 0)
        let clock = store.player.player.currentTime().seconds
        for _ in 0..<10 {
            for offset in [CGFloat(650),0] {
                layout.setViewport(.init(visibleRect:CGRect(x:0,y:offset,width:1000,height:700),containerSize:size))
                scroll.contentView.scroll(to:CGPoint(x:0,y:offset)); scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for:.milliseconds(60))
                #expect(surface.superview === parent)
                #expect(surface.window === window)
                #expect(store.player.player.currentItem === item)
                #expect(surface.windowChangeCount == before)
                #expect(abs(surface.bounds.width-layout.videoFrame.width) <= 1)
                #expect(surface.visibleRect.width > 100 && surface.visibleRect.height > 60)
            }
        }
        #expect(store.player.player.currentTime().seconds > clock + 0.7)
        #expect(item.status == .readyToPlay)
        #expect(item.presentationSize.width == 160)
        #expect(surface.overlay.planBuildCount == plans)
        print("TRANSITION: 20 geometry changes, additional window attachments = \(surface.windowChangeCount-before), additional danmaku layouts = \(surface.overlay.planBuildCount-plans); same view/item, media clock advanced")
    }
}
