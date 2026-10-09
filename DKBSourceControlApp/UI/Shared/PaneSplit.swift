import AppKit
import SwiftUI

/// Two panes side by side with a divider to drag, in place of `HSplitView`.
/// It always fits the width it is given: the leading pane gives way down to
/// its minimum, so it never asks for more than the two minimums. An
/// `HSplitView` kept its leading pane wide instead, so with the sidebar and
/// the git output open on a 13-inch screen the window's content ran past
/// its edges and the git output was cut off.
struct PaneSplit<Leading: View, Trailing: View>: View {
    private let leadingWidth: ClosedRange<CGFloat>
    private let trailingMinWidth: CGFloat
    private let leading: Leading
    private let trailing: Trailing
    /// What the user asked for; shown narrower while there's no room for it.
    @State private var width: CGFloat
    @State private var drag: CGFloat = 0

    init(leadingWidth: ClosedRange<CGFloat>, idealLeadingWidth: CGFloat, trailingMinWidth: CGFloat,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leadingWidth = leadingWidth
        self.trailingMinWidth = trailingMinWidth
        self.leading = leading()
        self.trailing = trailing()
        _width = State(initialValue: idealLeadingWidth)
    }

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            HStack(spacing: 0) {
                leading.frame(width: clamped(width + drag, in: total))
                Divider()
                    .overlay { handle(total: total) }
                    .zIndex(1)
                trailing.frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: leadingWidth.lowerBound + 1 + trailingMinWidth)
    }

    private func clamped(_ value: CGFloat, in total: CGFloat) -> CGFloat {
        let upper = min(leadingWidth.upperBound, total - 1 - trailingMinWidth)
        return max(leadingWidth.lowerBound, min(value, upper))
    }

    /// Wider than the line, so it's easy to grab, as a split view's divider is.
    private func handle(total: CGFloat) -> some View {
        Color.clear
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            // Global, as the divider moves under the pointer while dragged.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag = $0.translation.width }
                .onEnded {
                    width = clamped(width + $0.translation.width, in: total)
                    drag = 0
                })
            .accessibilityElement()
            .accessibilityLabel(Text("Resize"))
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 20 : -20
                width = clamped(clamped(width, in: total) + step, in: total)
            }
    }
}
