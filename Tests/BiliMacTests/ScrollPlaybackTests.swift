import AppKit
import AVFoundation
import Testing
@testable import BiliMac

@Suite @MainActor struct ScrollPlaybackTests {
    @Test func videoVisibilityActivatesAndRestoresFloatingPresentation() {
        var presentation = ScrollPlaybackPresentation()
        #expect(!presentation.floating)
        presentation.setInlineVisible(false)
        #expect(presentation.floating)
        presentation.setInlineVisible(true)
        #expect(!presentation.floating)
    }
    @Test func dismissedWindowStaysDismissedWhileReadingAndRearmsAtVideo() {
        var presentation = ScrollPlaybackPresentation()
        presentation.setInlineVisible(false); presentation.dismiss()
        for _ in 0..<3 { presentation.setInlineVisible(false) }
        #expect(!presentation.floating)
        presentation.setInlineVisible(true); presentation.setInlineVisible(false)
        #expect(presentation.floating)
    }
    @Test func openingAnotherVideoResetsPriorDismissal() {
        var presentation = ScrollPlaybackPresentation()
        presentation.setInlineVisible(false); presentation.dismiss(); presentation.reset()
        #expect(presentation.inlineVisible); #expect(!presentation.dismissed)
        presentation.setInlineVisible(false); #expect(presentation.floating)
    }
    @Test func remountingKeepsOneSurfaceAndOldSlotCannotDetachItsNewOwner() {
        let controller = PlayerController()
        defer { controller.stop() }
        let surface = controller.surface
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/bili-presentation-fixture.mp4"))
        controller.player.replaceCurrentItem(with: item)
        let inline = PlayerContainer(surface: surface)
        #expect(inline.ownsSurface)
        let floating = PlayerContainer(surface: surface)
        inline.releaseSurface()
        #expect(!inline.ownsSurface); #expect(floating.ownsSurface)
        #expect(surface.superview === floating)
        #expect(surface.player === controller.player)
        #expect(controller.player.currentItem === item)
        floating.releaseSurface()
        #expect(surface.superview == nil)
        let restored = PlayerContainer(surface: surface)
        #expect(restored.ownsSurface); #expect(controller.surface === surface)
        #expect(controller.player.currentItem === item)
        restored.releaseSurface()
    }
    @Test func videoClickLeavesNativeControlsDoubleClicksAndRightClicksAlone() throws {
        let surface = PlayerSurface(frame:NSRect(x:0,y:0,width:640,height:360))
        let recognizer = try #require(surface.gestureRecognizers.first as? NSClickGestureRecognizer)
        func click(_ point:NSPoint, count:Int = 1, type:NSEvent.EventType = .leftMouseDown) throws -> Bool {
            let event = try #require(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,
                                                      windowNumber:0,context:nil,eventNumber:1,clickCount:count,pressure:1))
            return surface.gestureRecognizer(recognizer,shouldAttemptToRecognizeWith:event)
        }
        #expect(try click(NSPoint(x:120,y:200)))
        #expect(try !click(NSPoint(x:120,y:20)))
        #expect(try !click(NSPoint(x:120,y:200),count:2))
        #expect(try !click(NSPoint(x:120,y:200),type:.rightMouseDown))
        let button = NSButton(frame:NSRect(x:200,y:150,width:80,height:30))
        surface.addSubview(button)
        #expect(try !click(NSPoint(x:220,y:160)))
        surface.controlsStyle = .none
        #expect(try click(NSPoint(x:120,y:20)))
    }
}
