import SwiftUI
import UIKit

/// Supply unique, stable IDs and rebuild this array from current parent state.
/// The closure should also recheck live query/resolution and search admission:
/// UIKit can deliver an action before SwiftUI has applied its next view update.
@MainActor
struct SearchQueryMenuAction: Identifiable {
    let id: String
    let title: String
    let enabled: Bool
    let action: @MainActor () -> Void

    init(id: String, title: String, enabled: Bool = true,
         action: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.enabled = enabled
        self.action = action
    }
}

/// Safe alternative to borrowing SwiftUI's undocumented UITextField delegate.
/// Replace ONLY the decorative magnifying-glass Image beside the TextField with
/// SearchQueryEditMenu(actions: actions).frame(width: 44, height: 44).
/// This button supports tap/long-press menus and named accessibility actions.
/// It is NOT an overlay on the TextField and does NOT append to its edit menu.
/// No field lookup, delegate replacement, focus changes or gesture borrowing.
/// Cut/copy/paste/select, autocorrection and editing callbacks remain UIKit /
/// SwiftUI's responsibility, with their existing configuration unchanged.
///
/// Parent integration contract (no AppState dependency here):
/// - Supply [] unless the current draft matches a completed text resolution;
///   also supply [] for image searches or an inaccessible/covered search page.
/// - For a translated resolution: show translation and use-original actions.
/// - For an eligible original resolution: retry/use-translation action.
/// - Gate search actions with canSearch, including a live check in the closure.
/// - Read the CURRENT resolution inside each closure, not a captured original.
/// - Remove the old result ellipsis, not translation failure notices/settings.
@MainActor
struct SearchQueryEditMenu: UIViewRepresentable {
    let actions: [SearchQueryMenuAction]
    var tintColor: UIColor = .secondaryLabel
    var accessibilityLabel: String = "本次搜索"
    @Environment(\.isEnabled) private var isEnabled

    init(actions: [SearchQueryMenuAction], tintColor: UIColor = .secondaryLabel,
         accessibilityLabel: String = "本次搜索") {
        self.actions = actions
        self.tintColor = tintColor
        self.accessibilityLabel = accessibilityLabel
    }

    func makeUIView(context: Context) -> SearchQueryEditMenuButton {
        let button = SearchQueryEditMenuButton(frame: .zero)
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ uiView: SearchQueryEditMenuButton, context: Context) {
        uiView.tintColor = tintColor
        uiView.accessibilityLabel = accessibilityLabel
        uiView.update(actions: actions, enabled: isEnabled)
    }

    static func dismantleUIView(_ uiView: SearchQueryEditMenuButton, coordinator: ()) {
        uiView.dismantle()
    }
}

/// Owns only this newly created button. No objects belonging to any text field
/// are retained, mutated or "restored". Internal visibility supports native tests.
@MainActor
final class SearchQueryEditMenuButton: UIButton {
    private var actions: [SearchQueryMenuAction] = []
    private var installed = false
    private var installation = UUID()
    private var ownedMenu: UIMenu?
    private var ownedAccessibilityActions: [UIAccessibilityCustomAction] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setImage(UIImage(systemName: "magnifyingglass",
                         withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)), for: .normal)
        imageView?.adjustsImageSizeForAccessibilityContentSizeCategory = true
        accessibilityIdentifier = "search-query-menu"
        accessibilityLabel = "本次搜索"
        tintColor = .secondaryLabel
        isAccessibilityElement = false
        isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var intrinsicContentSize: CGSize { CGSize(width: 44, height: 44) }

    func update(actions: [SearchQueryMenuAction], enabled: Bool = true) {
        self.actions = actions
        installed = true
        isEnabled = enabled && !actions.isEmpty
        isAccessibilityElement = !actions.isEmpty
        accessibilityHint = actions.isEmpty ? nil : "轻点或长按查看搜索选项"
        showsMenuAsPrimaryAction = !actions.isEmpty

        // The retained native handlers capture ONLY identity, never an action
        // value (which would also retain its obsolete query-capturing closure).
        let token = installation
        let children: [UIMenuElement] = actions.map { item in
            let id = item.id
            return UIAction(title: item.title, identifier: UIAction.Identifier(id),
                            attributes: item.enabled ? [] : [.disabled]) { [weak self] _ in
                self?.performAction(id: id, installation: token)
            }
        }
        let newMenu = children.isEmpty ? nil : UIMenu(children: children)
        menu = newMenu
        ownedMenu = menu

        ownedAccessibilityActions = actions.filter { enabled && $0.enabled }.map { item in
            let id = item.id
            return UIAccessibilityCustomAction(name: item.title) { [weak self] _ in
                self?.performAction(id: id, installation: token) ?? false
            }
        }
        accessibilityCustomActions = ownedAccessibilityActions.isEmpty ? nil : ownedAccessibilityActions
    }

    @discardableResult
    private func performAction(id: String, installation token: UUID) -> Bool {
        guard installed, installation == token, isEnabled,
              let current = actions.first(where: { $0.id == id }), current.enabled else { return false }
        current.action()
        return true
    }

    func dismantle() {
        // Invalidate before releasing any closures, including handlers in an
        // already presented menu or an accessibility action retained by UIKit.
        installed = false
        installation = UUID()
        actions = []
        if let ownedMenu, menu === ownedMenu {
            menu = nil
            showsMenuAsPrimaryAction = false
        }
        if let current = accessibilityCustomActions,
           current.count == ownedAccessibilityActions.count,
           zip(current, ownedAccessibilityActions).allSatisfy({ $0.0 === $0.1 }) {
            accessibilityCustomActions = nil
        }
        ownedMenu = nil
        ownedAccessibilityActions = []
    }
}