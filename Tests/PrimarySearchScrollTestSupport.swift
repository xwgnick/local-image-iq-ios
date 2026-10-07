import XCTest
import UIKit
@testable import LocalImageIQ

/// Search ownership is independent of visibility, AX propagation and content
/// height. Retained cleanup scroll views must never be candidates or fallbacks.
@MainActor
func primarySearchScrollView(in root: UIView,
                             file: StaticString = #filePath, line: UInt = #line) throws -> UIScrollView {
    func anchors(in view: UIView) -> [PrimarySearchScrollAnchorView] {
        let own = (view as? PrimarySearchScrollAnchorView).map { [$0] } ?? []
        return own + view.subviews.flatMap { anchors(in: $0) }
    }

    // Include descendants of hidden/transparent ancestors intentionally.
    let candidates = anchors(in: root)
    XCTAssertEqual(candidates.count, 1, "Exactly one search content owner, not one scroll view across both pages",
                   file: file, line: line)
    let anchor = try XCTUnwrap(candidates.count == 1 ? candidates.first : nil,
                               "Missing or ambiguous search content anchor", file: file, line: line)
    let scroll = try XCTUnwrap(anchor.owningScrollView,
                               "Search content anchor must have an actual UIScrollView ancestor", file: file, line: line)
    let window = try XCTUnwrap(root.window, "Search host must be mounted", file: file, line: line)
    XCTAssertTrue(anchor.window === window, file: file, line: line)
    XCTAssertTrue(scroll.window === window, file: file, line: line)
    XCTAssertFalse(anchor.isUserInteractionEnabled, file: file, line: line)
    XCTAssertFalse(anchor.isAccessibilityElement, file: file, line: line)
    XCTAssertTrue(anchor.accessibilityElementsHidden, file: file, line: line)
    // Do not assert inherited SwiftUI identifiers on native descendants. The
    // marker sets none and lookup depends only on its type and live ancestry.
    XCTAssertEqual(anchor.bounds.height, 0, file: file, line: line)
    XCTAssertGreaterThan(scroll.bounds.width, 0, file: file, line: line)
    XCTAssertGreaterThan(scroll.bounds.height, 0, file: file, line: line)
    return scroll
}