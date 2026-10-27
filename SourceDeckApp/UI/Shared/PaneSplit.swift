import AppKit
import SwiftUI

/// Two panes side by side, or one above the other, with a divider to drag,
/// in place of `HSplitView` and `VSplitView`. It always fits the space it
/// is given: the sized pane gives way down to its minimum, so it never asks
/// for more than the two minimums, and both panes fill the other direction.
///
/// An `HSplitView` kept its leading pane wide instead, so with the sidebar
/// and the git output open on a 13-inch screen the window's content ran
/// past its edges. A `VSplitView` (an `NSSplitView`) on macOS 26 left its
/// panes at an earlier width inside a wider column: Working Copy showed the
/// file list and the composer short of the divider, with a blank strip.
struct PaneSplit<First: View, Second: View>: View {
    /// Which pane keeps the size the user dragged it to; the other takes
    /// what is left.
    enum Pane { case first, second }

    private let axis: Axis
    private let sizedPane: Pane
    private let size: ClosedRange<CGFloat>
    private let otherMinSize: CGFloat
    private let first: First
    private let second: Second
    /// What the user asked for; shown smaller while there's no room for it.
    @State private var length: CGFloat
    @State private var drag: CGFloat = 0

    init(_ axis: Axis = .horizontal, sizedPane: Pane = .first, size: ClosedRange<CGFloat>, idealSize: CGFloat,
         otherMinSize: CGFloat, @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.axis = axis
        self.sizedPane = sizedPane
        self.size = size
        self.otherMinSize = otherMinSize
        self.first = first()
        self.second = second()
        _length = State(initialValue: idealSize)
    }

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let sized = clamped(length + (sizedPane == .first ? drag : -drag), in: total)
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                pane(first, sized: sizedPane == .first ? sized : nil)
                Divider()
                    .overlay { handle(total: total) }
                    .zIndex(1)
                pane(second, sized: sizedPane == .second ? sized : nil)
            }
        }
        .frame(minWidth: axis == .horizontal ? size.lowerBound + 1 + otherMinSize : nil,
               minHeight: axis == .vertical ? size.lowerBound + 1 + otherMinSize : nil)
    }

    /// The sized pane at its length, the other filling the rest; both fill
    /// the cross direction.
    private func pane(_ content: some View, sized: CGFloat?) -> some View {
        content.frame(width: axis == .horizontal ? sized : nil, height: axis == .vertical ? sized : nil)
            .frame(maxWidth: axis == .vertical || sized == nil ? .infinity : nil,
                   maxHeight: axis == .horizontal || sized == nil ? .infinity : nil)
    }

    private func clamped(_ value: CGFloat, in total: CGFloat) -> CGFloat {
        let upper = min(size.upperBound, total - 1 - otherMinSize)
        return max(size.lowerBound, min(value, upper))
    }

    /// Wider than the line, so it's easy to grab, as a split view's divider is.
    private func handle(total: CGFloat) -> some View {
        Color.clear
            .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                inside ? (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() : NSCursor.pop()
            }
            // Global, as the divider moves under the pointer while dragged.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag = axis == .horizontal ? $0.translation.width : $0.translation.height }
                .onEnded { value in
                    let moved = axis == .horizontal ? value.translation.width : value.translation.height
                    length = clamped(length + (sizedPane == .first ? moved : -moved), in: total)
                    drag = 0
                })
            .accessibilityElement()
            .accessibilityLabel(Text("Resize"))
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 20 : -20
                length = clamped(clamped(length, in: total) + step, in: total)
            }
    }
}
