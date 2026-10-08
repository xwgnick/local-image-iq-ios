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
            // This outer hint does not cross NavigationStack's native AX
            // boundary. Each page also installs an inner native anchor below.
            .accessibilityHidden(!active)
    }
}

/// Keep the original search ownership marker inside ScrollView content. Besides
/// locating that exact scroller, it gates its native AX subtree and the owning
/// NavigationStack without replacing either view or changing scroll behavior.
struct PrimarySearchScrollAnchor: UIViewRepresentable {
    var active = true

    func makeUIView(context: Context) -> PrimarySearchScrollAnchorView {
        let view = PrimarySearchScrollAnchorView(frame: .zero)
        view.setPageActive(active)
        return view
    }

    func updateUIView(_ uiView: PrimarySearchScrollAnchorView, context: Context) {
        uiView.setPageActive(active)
    }

    static func dismantleUIView(_ uiView: PrimarySearchScrollAnchorView, coordinator: ()) {
        uiView.stopTracking()
    }
}

/// Place inside a NavigationStack's content root, never around the two pages.
/// Its native scope includes that page's navigation bar and any native detail
/// children, but not the other page, the shared tabs or a presented sheet.
struct PrimaryPageAccessibilityAnchor: UIViewRepresentable {
    let active: Bool

    func makeUIView(context: Context) -> PrimaryPageAccessibilityAnchorView {
        let view = PrimaryPageAccessibilityAnchorView(frame: .zero)
        view.setPageActive(active)
        return view
    }

    func updateUIView(_ uiView: PrimaryPageAccessibilityAnchorView, context: Context) {
        uiView.setPageActive(active)
    }

    static func dismantleUIView(_ uiView: PrimaryPageAccessibilityAnchorView, coordinator: ()) {
        uiView.stopTracking()
    }
}

final class PrimarySearchScrollAnchorView: PrimaryPageAccessibilityAnchorView { }

class PrimaryPageAccessibilityAnchorView: UIView {
    private var pageActive = true
    private var tracking = true
    private let scrollBoundary = PrimaryPageAccessibilityBoundary()
    private let navigationBoundary = PrimaryPageAccessibilityBoundary()

    /// Resolve the live ancestry without retaining or caching a scroll view.
    var owningScrollView: UIScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView { return scrollView }
            ancestor = view.superview
        }
        return nil
    }

    /// Only public UIKit containment/responder APIs; never match SwiftUI's
    /// private class names or fall back to the window/shared hosting root.
    var owningNavigationController: UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController,
               let navigation = (controller as? UINavigationController) ?? controller.navigationController,
               let root = navigation.viewIfLoaded, isDescendant(of: root) {
                return navigation
            }
            responder = current.next
        }
        return nil
    }

    func setPageActive(_ active: Bool) {
        pageActive = active
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        updateBoundaries()
        // SwiftUI may update the representable before attaching its enclosing
        // controller. Re-resolve once after that transaction, using the latest
        // value (not a captured old tab value). No polling or AX notifications.
        DispatchQueue.main.async { [weak self] in self?.updateBoundaries() }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateBoundaries()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBoundaries()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBoundaries()
    }

    func stopTracking() {
        tracking = false
        scrollBoundary.restore()
        navigationBoundary.restore()
    }

    private func updateBoundaries() {
        guard tracking, window != nil else {
            scrollBoundary.restore()
            navigationBoundary.restore()
            return
        }
        scrollBoundary.update(owningScrollView, active: pageActive)
        navigationBoundary.update(owningNavigationController?.viewIfLoaded, active: pageActive)
    }
}

/// Own the page flag while attached; restore the borrowed UIView on detach or
/// reparent. In particular, an initially inactive page must become accessible.
@MainActor
private final class PrimaryPageAccessibilityBoundary {
    private weak var view: UIView?
    private var originalHidden = false

    func update(_ target: UIView?, active: Bool) {
        if view !== target {
            restore()
            view = target
            originalHidden = target?.accessibilityElementsHidden ?? false
        }
        target?.accessibilityElementsHidden = !active
    }

    func restore() {
        view?.accessibilityElementsHidden = originalHidden
        view = nil
    }
}

struct PrimaryNavigationBar: View {
    let page: PrimaryPage
    let switchingDisabled: Bool
    var accessibilityActive: Bool = true
    let select: (PrimaryPage) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PrimaryPage.allCases) { item in
                if accessibilityActive {
                    Button { select(item) } label: { tabLabel(item) }
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
                } else {
                    // No Button or tab identifier behind a presented surface.
                    // The same noninteractive label keeps its natural height,
                    // including Dynamic Type, without measuring/caching a size.
                    tabLabel(item).hidden()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(IQStyle.background)
        .overlay(alignment: .top) { Rectangle().fill(IQStyle.line).frame(height: 1) }
        .accessibilityHidden(!accessibilityActive)
    }

    private func tabLabel(_ item: PrimaryPage) -> some View {
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
}

/// The identifier/value belong to the actual header button, never the footer.
struct PrimaryLibraryButton: View {
    let canRead: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("我的图库", systemImage: "photo.stack")
                .labelStyle(.titleAndIcon)
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