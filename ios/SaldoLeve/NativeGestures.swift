import SwiftUI

struct NativeEdgeSwipe: View {
    let open: () -> Void
    var body: some View {
        Color.clear.frame(width: 22).contentShape(Rectangle()).gesture(
            DragGesture(minimumDistance: 18).onEnded { value in
                if value.translation.width > 45 && value.translation.width > abs(value.translation.height) * 1.4 {
                    UISelectionFeedbackGenerator().selectionChanged(); open()
                }
            }
        ).accessibilityHidden(true)
    }
}
struct NativeDrawerSwipeClose: ViewModifier {
    let close: () -> Void
    func body(content: Content) -> some View {
        content.simultaneousGesture(DragGesture(minimumDistance: 22).onEnded { value in
            if value.translation.width < -45 && abs(value.translation.width) > abs(value.translation.height) * 1.4 { close() }
        })
    }
}
