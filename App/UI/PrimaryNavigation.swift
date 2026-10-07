import SwiftUI
import Combine
import UIKit

enum PrimaryPage: String, CaseIterable, Identifiable {
    case search, cleanup
    var id: Self { self }
    var title: String { self == .search ? "照片搜索" : "相似清理" }
    var symbol: String { self == .search ? "magnifyingglass" : "square.on.square" }
    var accessibilityID: String { self == .search ? "primary-search-tab" : "primary-cleanup-tab" }
}

/// UI routing only. The two page trees, their scroll views and controllers stay
/// mounted; switching is not a search cancellation or a new grouping request.
@MainActor
final class PrimaryNavigationPresentation: ObservableObject {
    @Published private(set) var page: PrimaryPage = .search

    func select(_ page: PrimaryPage, switchingDisabled: Bool = false) {
        guard !switchingDisabled, self.page != page else { return }
        self.page = page
    }
}

struct RetainedPrimaryPage: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}

/// Native ownership marker only: no app state, scroll behavior or AX identifier.
/// Place in search ScrollView content, not outside the scroll view itself.
struct PrimarySearchScrollAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> PrimarySearchScrollAnchorView {
        let view = PrimarySearchScrollAnchorView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ uiView: PrimarySearchScrollAnchorView, context: Context) { }
}

final class PrimarySearchScrollAnchorView: UIView {
    /// Resolve the live ancestry without retaining or caching a scroll view.
    var owningScrollView: UIScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView { return scrollView }
            ancestor = view.superview
        }
        return nil
    }
}

struct PrimaryNavigationBar: View {
    let page: PrimaryPage
    let switchingDisabled: Bool
    let select: (PrimaryPage) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PrimaryPage.allCases) { item in
                Button { select(item) } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .padding(.horizontal, 8)
                        .foregroundStyle(page == item ? IQStyle.accent : IQStyle.secondary)
                        .background(page == item ? IQStyle.accentSoft : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(switchingDisabled)
                .accessibilityIdentifier(item.accessibilityID)
                .accessibilityAddTraits(page == item ? .isSelected : [])
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: PrimaryNavigationFrames.self,
                                               value: [item: geometry.frame(in: .global)])
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(IQStyle.background)
        .overlay(alignment: .top) { Rectangle().fill(IQStyle.line).frame(height: 1) }
    }
}

/// The identifier/value belong to the actual header button, never the footer.
struct PrimaryLibraryButton: View {
    let canRead: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("我的图库", systemImage: "photo.stack")
                .font(.subheadline).frame(minHeight: 44)
        }
        .accessibilityIdentifier("open-library")
        .accessibilityValue(canRead ? "library-accessible" : "authorization-required")
    }
}

struct PrimarySettingsButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("设置").accessibilityIdentifier("open-settings")
    }
}

/// Public SwiftUI layout preferences, with no AX traversal or runtime state.
/// Native presentation hosts can measure the actual production controls.
struct PrimaryNavigationFrames: PreferenceKey {
    static var defaultValue: [PrimaryPage: CGRect] = [:]
    static func reduce(value: inout [PrimaryPage: CGRect], nextValue: () -> [PrimaryPage: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}