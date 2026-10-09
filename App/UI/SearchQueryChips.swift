import SwiftUI

/// Labels may truncate, but the accessible name and submitted value never do.
/// AppState owns the three defaults / most-recent-first history replacement.
struct SearchQueryChips: View {
    let suggestions: [SearchQuerySuggestion]
    let select: (String) -> Void

    var body: some View {
        SearchQueryChipRow {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { choose(suggestion) } label: {
                    Text(suggestion.label)
                        .font(.caption.weight(.medium))
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(IQStyle.line, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(IQStyle.text)
                .accessibilityLabel(suggestion.query)
                .accessibilityHint("填入完整查询并搜索")
                .accessibilityIdentifier("search-query-chip-\(index + 1)")
                .minimalSearchFrame(.chip(index))
            }
        }
        .minimalSearchFrame(.chips)
    }

    func choose(_ suggestion: SearchQuerySuggestion) { select(suggestion.query) }
}

/// Never switches to a flow/scroll layout, even at accessibility text sizes.
/// V5's proportional columns give the longer middle example more room, without
/// making the outside blocks jump in size as full history labels replace them.
private struct SearchQueryChipRow: Layout {
    private let spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { max(44, $0.sizeThatFits(.unspecified).width) }.reduce(0, +)
        return CGSize(width: proposal.width ?? ideal + spacing * CGFloat(max(0, subviews.count - 1)), height: 44)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let available = max(0, bounds.width - spacing * CGFloat(subviews.count - 1))
        let weights: [CGFloat] = subviews.count == 3 ? [0.85, 1.65, 1.10] : Array(repeating: 1, count: subviews.count)
        let total = weights.reduce(0, +)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = available * weights[index] / total
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: 44))
            x += width + spacing
        }
    }
}

/// Passive production geometry for native presentation tests; no AX traversal,
/// fake accessibility elements or cached frame used to route user interactions.
enum MinimalSearchPart: Hashable {
    case heading, subtitle, field, chips, chip(Int), tools, heroArea, hero, resultsHeading, translation
}

struct MinimalSearchFrames: PreferenceKey {
    static var defaultValue: [MinimalSearchPart: CGRect] = [:]
    static func reduce(value: inout [MinimalSearchPart: CGRect], nextValue: () -> [MinimalSearchPart: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func minimalSearchFrame(_ part: MinimalSearchPart) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: MinimalSearchFrames.self, value: [part: geometry.frame(in: .global)])
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

struct SearchHeaderHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}