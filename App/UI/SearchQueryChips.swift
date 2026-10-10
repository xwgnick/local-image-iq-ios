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
                    SearchQueryChipLabel(label: suggestion.label)
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

struct SearchQueryChipLabel: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(IQStyle.line, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Content-driven allocation, independent of history position. Keep intrinsic
/// widths when they fit; otherwise scale by content, freezing 44-point targets
/// and redistributing the remaining width among the still-flexible chips.
struct SearchQueryChipAllocation {
    static let minimumWidth: CGFloat = 44
    static let preferredSpacing: CGFloat = 6
    let widths: [CGFloat]
    let spacing: CGFloat

    init(intrinsicWidths: [CGFloat], availableWidth: CGFloat) {
        guard !intrinsicWidths.isEmpty else {
            widths = []; spacing = 0
            return
        }
        let ideal = intrinsicWidths.map { max(Self.minimumWidth, $0) }
        let width = max(0, availableWidth)
        let minimumTotal = Self.minimumWidth * CGFloat(ideal.count)
        // Preserve all three touch widths even when only the gaps must shrink.
        spacing = ideal.count > 1
            ? min(Self.preferredSpacing, max(0, width - minimumTotal) / CGFloat(ideal.count - 1)) : 0
        let available = max(0, width - spacing * CGFloat(ideal.count - 1))
        let total = ideal.reduce(0, +)
        if total <= available {
            widths = ideal
        } else if available < minimumTotal {
            // A viewport narrower than N * 44 cannot meet all minimums. Keep
            // one bounded row; do not introduce overflow or a scrolling strip.
            widths = ideal.map { available * $0 / total }
        } else {
            var result = Array(repeating: CGFloat.zero, count: ideal.count)
            var flexible = Array(ideal.indices)
            var remaining = available
            while !flexible.isEmpty {
                let flexibleTotal = flexible.reduce(CGFloat.zero) { $0 + ideal[$1] }
                let scale = remaining / flexibleTotal
                let atMinimum = flexible.filter { ideal[$0] * scale < Self.minimumWidth }
                if atMinimum.isEmpty {
                    for index in flexible { result[index] = ideal[index] * scale }
                    break
                }
                for index in atMinimum { result[index] = Self.minimumWidth }
                remaining -= Self.minimumWidth * CGFloat(atMinimum.count)
                flexible.removeAll { atMinimum.contains($0) }
            }
            widths = result
        }
    }
}

/// Never switches to a flow/scroll layout, even at accessibility text sizes.
/// Measure again for each proposal/placement; history and font changes must not
/// reuse a position-based width or an obsolete cached measurement.
private struct SearchQueryChipRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { max(44, $0.sizeThatFits(.unspecified).width) }.reduce(0, +)
        let intrinsic = ideal + SearchQueryChipAllocation.preferredSpacing * CGFloat(max(0, subviews.count - 1))
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? intrinsic
        return CGSize(width: width, height: 44)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let allocation = SearchQueryChipAllocation(
            intrinsicWidths: subviews.map { $0.sizeThatFits(.unspecified).width }, availableWidth: bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = allocation.widths[index]
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: 44))
            x += width + allocation.spacing
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