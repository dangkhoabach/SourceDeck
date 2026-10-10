import SwiftUI

/// Grey blocks shaped like the content on its way: rows of a list, lines of
/// a diff, the details of a card. For content being read; an operation the
/// user started (fetch, commit, clone) keeps its spinner.
///
/// The blocks come in after a short wait, so a read that finishes quickly
/// (a status takes ~25 ms) never flashes them, and shimmer once for the
/// whole group, unless Reduce Motion is on.
struct SkeletonBlock: View {
    /// nil fills the width offered.
    var width: CGFloat?
    var height: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: min(4, height / 2))
            .fill(.quaternary)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    /// Widths that vary from row to row, the same every time.
    static func fraction(_ index: Int) -> CGFloat {
        [0.82, 0.58, 0.9, 0.67, 0.74, 0.5, 0.86, 0.62][index % 8]
    }
}

extension View {
    /// Marks a group of `SkeletonBlock`s as loading content.
    func skeleton() -> some View {
        modifier(SkeletonGroup())
    }
}

private struct SkeletonGroup: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var phase: CGFloat = 0

    /// Long enough for a quick read to finish first.
    static let delay = Duration.milliseconds(150)

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 0.5)
                            .offset(x: -width * 0.5 + phase * width * 1.5)
                    }
                    .mask(content)
                    .onAppear {
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
                    }
                }
            }
            .opacity(shown ? 1 : 0)
            .task {
                try? await Task.sleep(for: Self.delay)
                withAnimation(.easeIn(duration: 0.2)) { shown = true }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Loading"))
    }
}

/// Rows of a list: an icon, a line of text, and a shorter second line when
/// asked for. Shaped like a file row, a commit row or a branch row.
struct SkeletonRows: View {
    var count = 8
    var icon: CGFloat = 14
    var secondLine = false
    /// Takes all the height offered, as the list it stands for; false
    /// inside a list or a form, where it is one row among others.
    var fills = true

    var body: some View {
        VStack(alignment: .leading, spacing: secondLine ? 14 : 11) {
            ForEach(0..<count, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    SkeletonBlock(width: icon, height: secondLine ? 16 : icon)
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { proxy in
                            SkeletonBlock(width: proxy.size.width * SkeletonBlock.fraction(index), height: 11)
                        }
                        .frame(height: 11)
                        if secondLine {
                            SkeletonBlock(width: 140, height: 8)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, fills ? 14 : 0)
        .padding(.vertical, fills ? 10 : 4)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .skeleton()
    }
}

/// Lines of a diff or a file: a narrow gutter and code of varying length.
struct SkeletonCode: View {
    var lines = 18
    var gutter: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<lines, id: \.self) { index in
                HStack(spacing: 12) {
                    SkeletonBlock(width: gutter, height: 9)
                    GeometryReader { proxy in
                        SkeletonBlock(width: proxy.size.width * SkeletonBlock.fraction(index * 3 + 1) * 0.8, height: 9)
                    }
                    .frame(height: 9)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .skeleton()
    }
}
