import SwiftUI

/// Geometry, not onAppear: LazyVGrid may pre-create offscreen cells. Only a
/// boundary intersecting the visible ScrollView requests the next ranked page.
struct ResultPageBoundaryValue: Equatable {
    let sessionID: UUID
    let visibleCount: Int
    let frame: CGRect
}

struct ResultPageBoundaryPreference: PreferenceKey {
    static var defaultValue: ResultPageBoundaryValue? { nil }
    static func reduce(value: inout ResultPageBoundaryValue?, nextValue: () -> ResultPageBoundaryValue?) {
        if let next = nextValue() { value = next }
    }
}

struct ResultPageBoundary: View {
    static let coordinateSpace = "search-results-scroll"
    let sessionID: UUID
    let visibleCount: Int

    var body: some View {
        Color.clear
            .frame(height: 1)
            .overlay {
                GeometryReader { geometry in
                    Color.clear.preference(key: ResultPageBoundaryPreference.self,
                        value: ResultPageBoundaryValue(sessionID: sessionID, visibleCount: visibleCount,
                                                       frame: geometry.frame(in: .named(Self.coordinateSpace))))
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}