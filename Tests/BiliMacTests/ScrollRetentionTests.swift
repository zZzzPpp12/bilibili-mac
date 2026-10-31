import AppKit
import SwiftUI
import Testing
@testable import BiliMac

@Suite(.serialized) @MainActor struct ScrollRetentionTests {
    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
    @Test func cachedGridRestoresItsPixelOffsetAfterThePageIsRecreated() async throws {
        var saved: CGFloat = 0
        func page() -> NSView {
            let view = NSHostingView(rootView: RetainedScrollView(offset: Binding(get: { saved }, set: { saved = $0 })) {
                VStack(spacing: 20) {
                    Text("合成网格位置回归").frame(height:150)
                    LazyVGrid(columns:[GridItem(.fixed(250)),GridItem(.fixed(250))],spacing:20) {
                        ForEach(0..<60) { i in Text("合成视频 \(i)").frame(width:250,height:100).background(.gray) }
                    }
                }.padding(20)
            })
            view.frame = CGRect(x:0,y:0,width:600,height:500)
            return view
        }
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:600,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "BiliMac 合成网格回归（不连接账号）"; window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let first = page(); window.contentView = first; window.orderFront(nil)
        try await Task.sleep(for:.milliseconds(150))
        let scroll = try #require(scrollView(in:first))
        scroll.contentView.scroll(to:CGPoint(x:0,y:1180)); scroll.reflectScrolledClipView(scroll.contentView)
        for _ in 0..<50 { if abs(saved-1180) < 1 { break }; try await Task.sleep(for:.milliseconds(20)) }
        #expect(abs(saved-1180) < 1)
        let before = saved
        window.contentView = nil
        let second = page(); window.contentView = second
        for _ in 0..<50 {
            if let current = scrollView(in:second), abs(current.contentView.bounds.minY-before) < 1 { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        let restored = try #require(scrollView(in:second))
        #expect(abs(restored.contentView.bounds.minY-before) < 1)
        #expect(abs(saved-before) < 1)
    }
}
