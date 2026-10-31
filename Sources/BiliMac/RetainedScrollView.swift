import SwiftUI

/// Offset writes do not invalidate the observable list and its video cards.
@MainActor final class ScrollMemory { var offset: CGFloat = 0 }

/// Persist a point rather than a lazy-grid item ID. Grid size estimation and
/// header visibility can otherwise move the first row while restoring an ID.
struct RetainedScrollView<Content: View>: View {
    @Binding private var offset: CGFloat
    @State private var position: ScrollPosition
    @State private var target: CGFloat
    @State private var restored = false
    private let content: Content
    init(offset: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        _offset = offset
        let value = offset.wrappedValue.isFinite ? max(0, offset.wrappedValue) : 0
        _position = State(initialValue: ScrollPosition(y: value))
        _target = State(initialValue: value)
        self.content = content()
    }
    var body: some View {
        ScrollView { content }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.y) } action: { _, value in
                if !restored {
                    guard abs(value - target) < 1 else { return }
                    restored = true
                }
                if abs(offset - value) > 0.5 { offset = value }
            }
            .onScrollPhaseChange { _, phase in if phase == .interacting { restored = true } }
    }
}
