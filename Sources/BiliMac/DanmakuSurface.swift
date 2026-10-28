import AppKit
import AVFoundation
import BiliMacCore

@MainActor final class DanmakuSurface: NSView {
    struct Placement { let item:Danmaku; let lane:Int; let width:Double; let lifetime:Double }
    private weak var player: AVPlayer?
    private var items: [Danmaku] = []
    private var plan: [Placement] = []
    private var text: [String:CATextLayer] = [:]
    private var frameLink: CADisplayLink?
    private var plannedSize = CGSize.zero
    private var plannedTime = -100.0
    private var alpha: Float = 0.8
    @MainActor private final class Target: NSObject {
        weak var view: DanmakuSurface?
        @objc func tick(_ link:CADisplayLink) { view?.tick() }
    }
    private let target = Target()
    override var isFlipped: Bool { true }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    func update(player:AVPlayer, items:[Danmaku], opacity:Double) {
        self.player = player; alpha = Float(opacity)
        if self.items != items { self.items = items; plannedTime = -100 }
        if frameLink == nil {
            target.view = self; let link = displayLink(target:target,selector:#selector(Target.tick(_:)))
            link.add(to:.main,forMode:.common); frameLink = link
        }
        tick()
    }
    private func prepare(_ time:Double) {
        plannedTime = time; plannedSize = bounds.size; plan = []
        let lanes = max(1,min(10,Int(bounds.height * 0.65 / 32)))
        var occupied = [[Placement]](repeating:[],count:lanes)
        for item in items where item.time >= time-9 && item.time <= time+35 {
            let width = Double((item.text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:CGFloat(item.size),weight:.medium)]).width + 8)
            let lifetime = [4,5].contains(item.mode) ? 4.0 : 8.0
            let choices = item.mode == 4 ? Array((0..<lanes).reversed()) : Array(0..<lanes)
            if let lane = choices.first(where: { lane in
                occupied[lane].removeAll { $0.item.time + $0.lifetime <= item.time }
                return occupied[lane].allSatisfy { previous in
                    guard ![4,5].contains(item.mode), ![4,5].contains(previous.item.mode), (item.mode == 6) == (previous.item.mode == 6) else { return false }
                    let elapsed = item.time - previous.item.time
                    let speed = (bounds.width + width) / lifetime, prior = (bounds.width + previous.width) / previous.lifetime
                    return prior * elapsed >= previous.width + 20 && (speed <= prior || speed * (previous.lifetime-elapsed) <= bounds.width-20)
                }
            }) {
                let placement = Placement(item:item,lane:lane,width:width,lifetime:lifetime)
                occupied[lane].append(placement); plan.append(placement)
            }
        }
    }
    private func tick() {
        guard let player, window != nil, !items.isEmpty, bounds.width > 0 else { frameLink?.isPaused = true; clear(); return }
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        if plannedSize != bounds.size || time < plannedTime || time > plannedTime + 20 { prepare(time) }
        let visible = Array(plan.filter { $0.item.time <= time && time < $0.item.time+$0.lifetime }.prefix(100))
        frameLink?.isPaused = player.timeControlStatus != .playing || visible.isEmpty
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let ids = Set(visible.map { $0.item.id })
        for key in Array(text.keys) where !ids.contains(key) { text.removeValue(forKey:key)?.removeFromSuperlayer() }
        for placement in visible {
            let item = placement.item
            let textLayer: CATextLayer
            if let old = text[item.id] { textLayer = old }
            else {
                textLayer = CATextLayer(); textLayer.string = item.text; textLayer.fontSize = CGFloat(item.size)
                textLayer.contentsScale = window?.backingScaleFactor ?? 2
                textLayer.foregroundColor = NSColor(red:CGFloat((item.color>>16)&255)/255,green:CGFloat((item.color>>8)&255)/255,blue:CGFloat(item.color&255)/255,alpha:1).cgColor
                textLayer.shadowColor = NSColor.black.cgColor; textLayer.shadowOpacity = 0.95; textLayer.shadowRadius = 1; textLayer.shadowOffset = CGSize(width:1,height:1)
                layer?.addSublayer(textLayer); text[item.id] = textLayer
            }
            let x = [4,5].contains(item.mode) ? (bounds.width-placement.width)/2 : DanmakuMotion.x(width:bounds.width,textWidth:placement.width,elapsed:time-item.time,reverse:item.mode == 6)
            let y = item.mode == 4 ? bounds.height - 70 - Double(placement.lane)*32 : 15 + Double(placement.lane)*32
            textLayer.frame = CGRect(x:x,y:y,width:placement.width,height:Double(item.size)+7); textLayer.opacity = alpha
        }
        CATransaction.commit()
    }
    private func clear() { text.values.forEach { $0.removeFromSuperlayer() }; text = [:] }
    func stop() { frameLink?.invalidate(); frameLink = nil; player = nil; items = []; clear() }
    isolated deinit { frameLink?.invalidate() }
}
