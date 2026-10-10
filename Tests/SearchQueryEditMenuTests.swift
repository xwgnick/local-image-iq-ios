import XCTest
import SwiftUI
import UIKit
@testable import LocalImageIQ

/// Tests the icon alternative, not a delegate proxy. No synthetic assertion is
/// presented as proof of actual OS cut/paste gestures or a rendered popup menu.
@MainActor
final class SearchQueryEditMenuTests: XCTestCase {
    func testEmptyActionsLeaveADecorativeIconWithoutMenuOrAccessibilityActions() {
        let button = makeButton([])
        XCTAssertNotNil(button.image(for: .normal))
        XCTAssertEqual(button.intrinsicContentSize, CGSize(width: 44, height: 44))
        XCTAssertNil(button.menu)
        XCTAssertNil(button.accessibilityCustomActions)
        XCTAssertFalse(button.showsMenuAsPrimaryAction)
        XCTAssertFalse(button.isEnabled)
        XCTAssertFalse(button.isAccessibilityElement)
        XCTAssertTrue(button.accessibilityElementsHidden)
        XCTAssertFalse(button.isUserInteractionEnabled)
        XCTAssertNil(button.accessibilityIdentifier)
        XCTAssertNil(button.accessibilityHint)
    }

    func testDefaultEnabledActionAndExplicitDisabledActionKeepOrderAndIdentifiers() throws {
        let show = SearchQueryMenuAction(id: "show", title: "显示译文") {}
        XCTAssertTrue(show.enabled)
        let button = makeButton([show, SearchQueryMenuAction(id: "original", title: "使用原文", enabled: false) {}])
        let children = try menuActions(button)
        XCTAssertEqual(children.map(\.title), ["显示译文", "使用原文"])
        XCTAssertEqual(children.map { $0.identifier.rawValue }, ["show", "original"])
        XCTAssertFalse(children[0].attributes.contains(.disabled))
        XCTAssertTrue(children[1].attributes.contains(.disabled))
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertFalse(button.accessibilityElementsHidden)
        XCTAssertTrue(button.isUserInteractionEnabled)
        XCTAssertEqual(button.accessibilityIdentifier, "search-query-menu")
        XCTAssertEqual(button.accessibilityCustomActions?.map(\.name), ["显示译文"])
    }

    func testPreviouslyCreatedNativeMenuActionRunsLatestClosureForItsStableID() throws {
        var calls: [String] = []
        let button = makeButton([SearchQueryMenuAction(id: "original", title: "Old") { calls.append("old query") }])
        let retained = try XCTUnwrap(menuActions(button).first)
        button.update(actions: [SearchQueryMenuAction(id: "original", title: "New") { calls.append("new query") }])
        UIControl().sendAction(retained)
        XCTAssertEqual(calls, ["new query"], "A presented menu must not retain the old query closure")
        XCTAssertEqual(button.menu?.children.first?.title, "New")
    }

    func testDisabledOrRemovedActionsCannotBeInvokedThroughRetainedNativeMenu() throws {
        var calls = 0
        let action = SearchQueryMenuAction(id: "retry", title: "Retry") { calls += 1 }
        let button = makeButton([action])
        let retained = try XCTUnwrap(menuActions(button).first)
        button.update(actions: [SearchQueryMenuAction(id: "retry", title: "Retry", enabled: false) { calls += 1 }])
        UIControl().sendAction(retained)
        button.update(actions: []) // Draft no longer matches the completed query.
        UIControl().sendAction(retained)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(button.menu)
        XCTAssertNil(button.accessibilityCustomActions)
    }

    func testAccessibilityActionUsesLatestClosureAndRejectsDisabledRemovedAndDismantledState() throws {
        var calls: [String] = []
        let button = makeButton([SearchQueryMenuAction(id: "show", title: "Old") { calls.append("old") }])
        let retained = try XCTUnwrap(button.accessibilityCustomActions?.first)
        button.update(actions: [SearchQueryMenuAction(id: "show", title: "New") { calls.append("new") }])
        XCTAssertEqual(retained.actionHandler?(retained), true)
        XCTAssertEqual(calls, ["new"])
        XCTAssertEqual(button.accessibilityCustomActions?.first?.name, "New")
        button.update(actions: [SearchQueryMenuAction(id: "show", title: "New", enabled: false) { calls.append("disabled") }])
        XCTAssertEqual(retained.actionHandler?(retained), false)
        button.update(actions: [])
        XCTAssertEqual(retained.actionHandler?(retained), false)
        SearchQueryEditMenu.dismantleUIView(button, coordinator: ())
        XCTAssertEqual(retained.actionHandler?(retained), false)
        XCTAssertEqual(calls, ["new"])
    }

    func testEnvironmentDisableRejectsAlreadyCreatedHandlersAndCanBeReenabled() throws {
        var calls = 0
        let actions = [SearchQueryMenuAction(id: "retry", title: "Retry") { calls += 1 }]
        let button = makeButton(actions)
        let menuAction = try XCTUnwrap(menuActions(button).first)
        let axAction = try XCTUnwrap(button.accessibilityCustomActions?.first)
        button.update(actions: actions, enabled: false)
        UIControl().sendAction(menuAction)
        XCTAssertEqual(axAction.actionHandler?(axAction), false)
        XCTAssertNil(button.accessibilityCustomActions)
        XCTAssertEqual(calls, 0)
        button.update(actions: actions)
        UIControl().sendAction(menuAction)
        XCTAssertEqual(calls, 1)
    }

    func testLiveParentGuardHandlesEditOrAdmissionChangeBeforeUIViewUpdate() throws {
        var query = "completed"
        var canSearch = true
        var calls = 0
        let button = makeButton([SearchQueryMenuAction(id: "original", title: "Original") {
            // Required integration pattern: read live parent state here too.
            guard query == "completed", canSearch else { return }
            calls += 1
        }])
        let retained = try XCTUnwrap(menuActions(button).first)
        query = "new draft"
        UIControl().sendAction(retained)
        query = "completed"
        canSearch = false
        UIControl().sendAction(retained)
        XCTAssertEqual(calls, 0)
        canSearch = true
        UIControl().sendAction(retained)
        XCTAssertEqual(calls, 1)
    }

    func testUpdatingReleasesOldCapturedStateEvenIfUIKitRetainsItsHandlers() throws {
        var capture: MenuCapture? = MenuCapture()
        weak var oldCapture = capture
        let button = makeButton([SearchQueryMenuAction(id: "show", title: "Old") { [held = capture!] in held.calls += 1 }])
        let retained = try XCTUnwrap(menuActions(button).first)
        let retainedAX = try XCTUnwrap(button.accessibilityCustomActions?.first)
        capture = nil
        XCTAssertNotNil(oldCapture)
        button.update(actions: [SearchQueryMenuAction(id: "show", title: "New") {}])
        XCTAssertNil(oldCapture, "Native handlers may retain identity, not obsolete action values")
        UIControl().sendAction(retained)
        XCTAssertEqual(retainedAX.actionHandler?(retainedAX), true)
    }

    func testTwoFieldsWithSameActionIDRemainIndependentAndDismantleIndependently() throws {
        var calls: [String] = []
        let first = makeButton([SearchQueryMenuAction(id: "show", title: "First") { calls.append("first") }])
        let second = makeButton([SearchQueryMenuAction(id: "show", title: "Second") { calls.append("second") }])
        let firstAction = try XCTUnwrap(menuActions(first).first)
        let secondAction = try XCTUnwrap(menuActions(second).first)
        first.update(actions: [SearchQueryMenuAction(id: "show", title: "First updated") { calls.append("updated") }])
        UIControl().sendAction(firstAction)
        UIControl().sendAction(secondAction)
        SearchQueryEditMenu.dismantleUIView(first, coordinator: ())
        UIControl().sendAction(firstAction)
        UIControl().sendAction(secondAction)
        XCTAssertEqual(calls, ["updated", "second", "second"])
        XCTAssertNil(first.menu)
        XCTAssertNil(first.accessibilityCustomActions)
        XCTAssertNotNil(second.menu)
    }

    func testDismantleIsIdempotentAndOldHandlersCannotBecomeActiveAfterReinstallation() throws {
        var calls = 0
        let actions = [SearchQueryMenuAction(id: "show", title: "Show") { calls += 1 }]
        let button = makeButton(actions)
        let old = try XCTUnwrap(menuActions(button).first)
        let oldAX = try XCTUnwrap(button.accessibilityCustomActions?.first)
        SearchQueryEditMenu.dismantleUIView(button, coordinator: ())
        SearchQueryEditMenu.dismantleUIView(button, coordinator: ())
        XCTAssertNil(button.menu)
        XCTAssertFalse(button.showsMenuAsPrimaryAction)
        button.update(actions: actions)
        UIControl().sendAction(old)
        XCTAssertEqual(oldAX.actionHandler?(oldAX), false)
        XCTAssertEqual(calls, 0)
        UIControl().sendAction(try XCTUnwrap(menuActions(button).first))
        XCTAssertEqual(calls, 1)
    }

    func testDismantleDoesNotOverwriteMenusOrAccessibilityActionsItNoLongerOwns() throws {
        var calls = 0
        var foreignMenuCalls = 0
        var foreignAXCalls = 0
        let button = makeButton([SearchQueryMenuAction(id: "show", title: "Show") { calls += 1 }])
        let old = try XCTUnwrap(menuActions(button).first)
        let oldAX = try XCTUnwrap(button.accessibilityCustomActions?.first)
        let foreignMenu = UIMenu(children: [UIAction(title: "Other owner") { _ in foreignMenuCalls += 1 }])
        let foreignAX = UIAccessibilityCustomAction(name: "Other owner") { _ in
            foreignAXCalls += 1
            return true
        }
        button.menu = foreignMenu
        button.accessibilityCustomActions = [foreignAX]
        // UIButton.menu has copy semantics. Ownership is the object read back
        // after assignment, not necessarily the UIMenu passed to the setter.
        let installedForeignMenu = try XCTUnwrap(button.menu)
        XCTAssertEqual(installedForeignMenu.children.map(\.title), ["Other owner"])
        SearchQueryEditMenu.dismantleUIView(button, coordinator: ())
        XCTAssertTrue(button.menu === installedForeignMenu, "Dismantle must leave the installed foreign menu untouched")
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        XCTAssertTrue(button.accessibilityCustomActions?.first === foreignAX)
        UIControl().sendAction(old)
        XCTAssertEqual(oldAX.actionHandler?(oldAX), false)
        XCTAssertEqual(calls, 0)
        UIControl().sendAction(try XCTUnwrap(menuActions(button).first))
        let currentAX = try XCTUnwrap(button.accessibilityCustomActions?.first)
        XCTAssertEqual(currentAX.actionHandler?(currentAX), true)
        XCTAssertEqual(foreignMenuCalls, 1)
        XCTAssertEqual(foreignAXCalls, 1)
        XCTAssertEqual(calls, 0, "Foreign actions must not invoke the dismantled search handler")
    }

    func testRetainedMenuAndAccessibilityActionsDoNotRetainTheButton() throws {
        var button: SearchQueryEditMenuButton? = makeButton([SearchQueryMenuAction(id: "show", title: "Show") {}])
        weak var weakButton = button
        let action = try XCTUnwrap(menuActions(try XCTUnwrap(button)).first)
        let ax = try XCTUnwrap(button?.accessibilityCustomActions?.first)
        button = nil
        XCTAssertNil(weakButton)
        UIControl().sendAction(action)
        XCTAssertEqual(ax.actionHandler?(ax), false)
    }

    func testExistingTextFieldDelegatesCallbacksAndSuggestedSystemMenuAreUntouched() throws {
        let container = UIView()
        let first = UITextField()
        let second = UITextField()
        let original = MenuTextFieldDelegate()
        let replacement = MenuTextFieldDelegate()
        first.delegate = original
        first.autocorrectionType = .yes
        first.text = "unchanged"
        // Second field deliberately keeps a nil delegate.
        container.addSubview(first)
        container.addSubview(second)
        let button = makeButton([SearchQueryMenuAction(id: "show", title: "Show") {}])
        container.addSubview(button)
        let suggested: [UIMenuElement] = [
            UIAction(title: "Cut") { _ in }, UIAction(title: "Copy") { _ in },
            UIAction(title: "Paste") { _ in }, UIAction(title: "Select") { _ in }
        ]
        let range = NSRange(location: 0, length: 3)
        let before = try XCTUnwrap(first.delegate?.textField?(first, editMenuForCharactersIn: range, suggestedActions: suggested))
        button.update(actions: [SearchQueryMenuAction(id: "retry", title: "Retry") {}])
        XCTAssertTrue(first.delegate === original)
        XCTAssertNil(second.delegate)
        XCTAssertEqual(first.delegate?.textField?(first, shouldChangeCharactersIn: range, replacementString: "new"), false)
        first.delegate?.textFieldDidChangeSelection?(first)
        XCTAssertEqual(first.delegate?.textFieldShouldReturn?(first), false)
        XCTAssertEqual(original.changes, 1)
        XCTAssertEqual(original.selections, 1)
        XCTAssertEqual(original.returns, 1)
        let after = try XCTUnwrap(first.delegate?.textField?(first, editMenuForCharactersIn: range, suggestedActions: suggested))
        XCTAssertEqual(after.children.count, suggested.count)
        XCTAssertTrue(zip(before.children, after.children).allSatisfy { $0.0 === $0.1 })
        XCTAssertTrue(zip(after.children, suggested).allSatisfy { $0.0 === $0.1 })
        first.delegate = replacement // A later owner must never be "restored" over.
        SearchQueryEditMenu.dismantleUIView(button, coordinator: ())
        XCTAssertTrue(first.delegate === replacement)
        XCTAssertNil(second.delegate)
        XCTAssertEqual(first.autocorrectionType, .yes)
        XCTAssertEqual(first.text, "unchanged")
    }

    func testRealSwiftUITextFieldIdentityDelegateFocusAndBindingSurviveMenuUpdateAndRemoval() async throws {
        let model = MenuHostModel()
        let controller = UIHostingController(rootView: MenuHostView(model: model))
        let previousKey = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }
        try await wait(controller) {
            self.descendants(controller.view, UITextField.self).count == 1
                && self.descendants(controller.view, SearchQueryEditMenuButton.self).first?.menu != nil
        }
        let field = try XCTUnwrap(descendants(controller.view, UITextField.self).first)
        let delegate = try XCTUnwrap(field.delegate)
        let button = try XCTUnwrap(descendants(controller.view, SearchQueryEditMenuButton.self).first)
        let oldAction = try XCTUnwrap(menuActions(button).first)
        let correction = field.autocorrectionType
        model.focused = true // The parent still owns FocusState, not this adapter.
        try await wait(controller) { field.isFirstResponder }
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument,
            to: try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 3)))
        let selected = try XCTUnwrap(field.selectedTextRange)
        model.version = 2
        try await wait(controller) { button.menu?.children.first?.title == "Version 2" }
        UIControl().sendAction(oldAction)
        XCTAssertEqual(model.invokedVersions, [2])
        model.menuEnabled = false
        try await wait(controller) { !button.isEnabled }
        UIControl().sendAction(oldAction)
        XCTAssertEqual(model.invokedVersions, [2])
        model.menuEnabled = true
        try await wait(controller) { button.isEnabled }
        XCTAssertTrue(descendants(controller.view, UITextField.self).first === field)
        XCTAssertTrue(field.delegate === delegate)
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertEqual(field.autocorrectionType, correction)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: try XCTUnwrap(field.selectedTextRange).start),
                       field.offset(from: field.beginningOfDocument, to: selected.start))
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: try XCTUnwrap(field.selectedTextRange).end),
                       field.offset(from: field.beginningOfDocument, to: selected.end))
        model.query = "new draft"
        try await wait(controller) { field.text == "new draft" && button.menu == nil }
        UIControl().sendAction(oldAction)
        XCTAssertEqual(model.invokedVersions, [2])
        model.query = "completed"
        try await wait(controller) { field.text == "completed" && button.menu != nil }
        model.showIcon = false
        try await wait(controller) { button.menu == nil && button.window == nil }
        XCTAssertTrue(descendants(controller.view, UITextField.self).first === field)
        XCTAssertTrue(field.delegate === delegate)
        XCTAssertTrue(field.isFirstResponder)
        UIControl().sendAction(oldAction)
        XCTAssertEqual(model.invokedVersions, [2])
        field.insertText("!")
        try await wait(controller) { model.query == field.text && model.query.contains("!") }
        model.focused = false
        try await wait(controller) { !field.isFirstResponder }
    }

    private func makeButton(_ actions: [SearchQueryMenuAction]) -> SearchQueryEditMenuButton {
        let button = SearchQueryEditMenuButton(frame: .zero)
        button.update(actions: actions)
        return button
    }

    private func menuActions(_ button: SearchQueryEditMenuButton) throws -> [UIAction] {
        let menu = try XCTUnwrap(button.menu)
        let actions = menu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.count, menu.children.count)
        return actions
    }

    private func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? [])
            + view.subviews.flatMap { descendants($0, type) }
    }

    private func wait(_ controller: UIViewController, until predicate: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), "Native host did not settle", file: file, line: line)
    }
}

@MainActor
private final class MenuCapture { var calls = 0 }

@MainActor
private final class MenuTextFieldDelegate: NSObject, UITextFieldDelegate {
    var changes = 0
    var selections = 0
    var returns = 0
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        changes += 1
        return false
    }
    func textFieldDidChangeSelection(_ textField: UITextField) { selections += 1 }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { returns += 1; return false }
    func textField(_ textField: UITextField, editMenuForCharactersIn range: NSRange,
                   suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: suggestedActions)
    }
}

@MainActor
private final class MenuHostModel: ObservableObject {
    @Published var query = "completed"
    @Published var version = 1
    @Published var showIcon = true
    @Published var menuEnabled = true
    @Published var focused = false
    var invokedVersions: [Int] = []
}

@MainActor
private struct MenuHostView: View {
    @ObservedObject var model: MenuHostModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            if model.showIcon {
                SearchQueryEditMenu(actions: actions).frame(width: 44, height: 44)
                    .disabled(!model.menuEnabled)
            }
            TextField("Query", text: $model.query)
                .focused($focused).autocorrectionDisabled(false)
        }
        .onChange(of: model.focused) { _, newValue in focused = newValue }
    }

    private var actions: [SearchQueryMenuAction] {
        guard model.query == "completed" else { return [] }
        let version = model.version
        return [SearchQueryMenuAction(id: "show", title: "Version \(version)") {
            guard model.query == "completed" else { return }
            model.invokedVersions.append(version)
        }]
    }
}