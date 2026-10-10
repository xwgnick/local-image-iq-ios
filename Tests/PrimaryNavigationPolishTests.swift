import XCTest
import SwiftUI
import UIKit
@testable import LocalImageIQ

/// Same native host, same pixel positions, only selection changes. No Photos,
/// AppState or private accessibility traversal. Existing real-app navigation
/// tests continue to check button labels, selected traits and actual taps.
@MainActor
final class PrimaryNavigationPolishTests: XCTestCase {
    func testSelectionChangesOnlyTitleForegroundNotIconsOrBackground() async throws {
        for width in [CGFloat(320), CGFloat(393)] {
            for font in [DynamicTypeSize.large, .accessibility5] {
                for scheme in [ColorScheme.light, .dark] {
                    let model = NavigationPolishModel()
                    let measured = NavigationPolishMeasurements()
                    let host = try mount(model, measured, width: width, font: font, scheme: scheme)
                    defer { host.close() }
                    try await host.wait { host.tabs.count == 2 && measured.labels.count == 4 }
                    try assertTargets(host, width: width)
                    let firstFrames = measured.labels
                    let firstImage = try host.capture()
                    let first = try NavigationPolishPixels(firstImage)
                    model.page = .cleanup
                    try await host.settle()
                    let secondImage = try host.capture()
                    let second = try NavigationPolishPixels(secondImage)
                    XCTAssertEqual(measured.labels, firstFrames, "Selection must not move either label or icon")
                    let geometry = try regions(host, measured, pixels: first)
                    let separatorPixels = CGFloat(first.width) / host.controller.view.bounds.width
                    let background: [UInt8] = scheme == .dark ? [0x12, 0x14, 0x16] : [0xF7, 0xF8, 0xFA]
                    let gray: [UInt8] = scheme == .dark ? [0xA7, 0xB1, 0xBA] : [0x62, 0x6E, 0x79]
                    let gold: [UInt8] = scheme == .dark ? [0xD8, 0xB5, 0x7C] : [0x80, 0x60, 0x25]
                    XCTAssertEqual(first.width, second.width)
                    XCTAssertEqual(first.height, second.height)
                    for page in PrimaryPage.allCases {
                        let tab = try XCTUnwrap(geometry.tabs[page])
                        let title = try XCTUnwrap(geometry.labels[.title(page)])
                        let icon = try XCTUnwrap(geometry.labels[.icon(page)])
                        var outsideTitleChanges = 0
                        var titleChanges = 0
                        var backgroundSamples = 0
                        var wrongBackground = 0
                        var grayIconSamples = 0
                        var firstTitleColorSamples = 0
                        var secondTitleColorSamples = 0
                        first.forEachPixel(in: tab) { offset, point in
                            let changed = first.differs(from: second, at: offset)
                            if title.contains(point) {
                                if changed { titleChanges += 1 }
                                if first.matches(page == .search ? gold : gray, at: offset) { firstTitleColorSamples += 1 }
                                if second.matches(page == .search ? gray : gold, at: offset) { secondTitleColorSamples += 1 }
                            } else {
                                if changed { outsideTitleChanges += 1 }
                                if icon.contains(point) {
                                    if first.matches(gray, at: offset) { grayIconSamples += 1 }
                                } else if point.y > tab.minY + separatorPixels + 1 {
                                    // Exclude only the unchanged one-point top separator.
                                    backgroundSamples += 1
                                    if !first.matches(background, at: offset) || !second.matches(background, at: offset) {
                                        wrongBackground += 1
                                    }
                                }
                            }
                        }
                        XCTAssertEqual(outsideTitleChanges, 0, "Icons and tab background are pixel-identical")
                        XCTAssertGreaterThan(titleChanges, 0, "Selection visibly changes each title")
                        XCTAssertGreaterThan(grayIconSamples, 0, "Icons actually render the same gray, not blank")
                        XCTAssertGreaterThan(firstTitleColorSamples, 0)
                        XCTAssertGreaterThan(secondTitleColorSamples, 0)
                        XCTAssertGreaterThan(backgroundSamples, 100)
                        XCTAssertEqual(wrongBackground, 0, "No selected/unselected rounded background block")
                        if outsideTitleChanges != 0 || titleChanges == 0 || wrongBackground != 0
                            || grayIconSamples == 0 || firstTitleColorSamples == 0 || secondTitleColorSamples == 0 {
                            for (name, image) in [("search-selected", firstImage), ("cleanup-selected", secondImage)] {
                                let attachment = XCTAttachment(image: image)
                                attachment.name = "Navigation-polish-\(Int(width))-\(font)-\(scheme)-\(name)"
                                attachment.lifetime = .keepAlways
                                add(attachment)
                            }
                            let details = XCTAttachment(string: "Tabs: \(geometry.tabs)\nGlyphs: \(geometry.labels)")
                            details.name = "Navigation-polish-geometry"
                            details.lifetime = .keepAlways
                            add(details)
                        }
                    }
                    model.page = .search
                    try await host.settle()
                    XCTAssertEqual(try NavigationPolishPixels(host.capture()).rgba, first.rgba,
                                   "Same-host round trip restores the exact raster")
                    XCTAssertTrue(model.selections.isEmpty, "Rendering alone must never dispatch navigation")
                }
            }
        }
    }

    func testCoveredAndDisabledNavigationKeep44PointGeometryAndRestoreTargets() async throws {
        for width in [CGFloat(320), CGFloat(393)] {
            let model = NavigationPolishModel()
            let measured = NavigationPolishMeasurements()
            let host = try mount(model, measured, width: width, font: .accessibility5, scheme: .dark)
            defer { host.close() }
            try await host.wait { host.tabs.count == 2 && measured.labels.count == 4 }
            try assertTargets(host, width: width)
            let originalTabs = host.tabs
            let originalLabels = measured.labels
            model.disabled = true
            try await host.settle()
            XCTAssertEqual(host.tabs, originalTabs)
            XCTAssertEqual(measured.labels, originalLabels)
            model.accessible = false
            try await host.wait { host.tabs.isEmpty }
            // Hidden placeholders retain label geometry but remove real Buttons.
            XCTAssertEqual(measured.labels, originalLabels)
            model.page = .cleanup
            model.accessible = true
            model.disabled = false
            try await host.wait { host.tabs.count == 2 }
            XCTAssertEqual(host.tabs, originalTabs)
            XCTAssertEqual(measured.labels, originalLabels)
            XCTAssertTrue(model.selections.isEmpty)
        }
    }

    private func mount(_ model: NavigationPolishModel, _ measured: NavigationPolishMeasurements,
                       width: CGFloat, font: DynamicTypeSize, scheme: ColorScheme) throws -> ControlsNativeHost {
        try ControlsNativeHost(content: AnyView(NavigationPolishHarness(model: model, measured: measured)
            .environment(\.colorScheme, scheme)), size: CGSize(width: width, height: 300), dynamicType: font)
    }

    private func assertTargets(_ host: ControlsNativeHost, width: CGFloat) throws {
        let search = try XCTUnwrap(host.tabs[.search])
        let cleanup = try XCTUnwrap(host.tabs[.cleanup])
        XCTAssertEqual(search.height, 44, accuracy: host.pixel)
        XCTAssertEqual(cleanup.height, 44, accuracy: host.pixel)
        XCTAssertGreaterThanOrEqual(search.width, 44)
        XCTAssertGreaterThanOrEqual(cleanup.width, 44)
        XCTAssertEqual(search.width, cleanup.width, accuracy: host.pixel)
        XCTAssertEqual(search.minY, cleanup.minY, accuracy: host.pixel)
        XCTAssertEqual(search.minX, 20, accuracy: host.pixel)
        XCTAssertEqual(cleanup.maxX, width - 20, accuracy: host.pixel)
        XCTAssertEqual(cleanup.minX - search.maxX, 8, accuracy: host.pixel)
    }

    private func regions(_ host: ControlsNativeHost, _ measured: NavigationPolishMeasurements,
                         pixels: NavigationPolishPixels) throws
        -> (tabs: [PrimaryPage: CGRect], labels: [PrimaryNavigationLabelPart: CGRect]) {
        let view = host.controller.view!
        func rect(_ frame: CGRect, glyph: Bool = false) -> CGRect {
            let local = view.convert(frame, from: host.window)
            let scale = CGFloat(pixels.width) / view.bounds.width
            let result = local.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            // One backing pixel covers glyph antialiasing at fractional edges;
            // this is not a whole-tab mask that could conceal a selected block.
            return glyph ? result.insetBy(dx: -1, dy: -1) : result
        }
        let tabs = host.tabs.mapValues { rect($0) }
        let labels = measured.labels.mapValues { rect($0, glyph: true) }
        for frame in tabs.values {
            XCTAssertTrue(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height).contains(frame))
        }
        for page in PrimaryPage.allCases {
            let tab = try XCTUnwrap(tabs[page])
            for part in [PrimaryNavigationLabelPart.title(page), .icon(page)] {
                let glyph = try XCTUnwrap(labels[part])
                XCTAssertGreaterThan(glyph.width, 0)
                XCTAssertGreaterThan(glyph.height, 0)
                XCTAssertTrue(tab.insetBy(dx: -1, dy: -1).contains(glyph))
            }
        }
        return (tabs, labels)
    }
}

@MainActor
private final class NavigationPolishModel: ObservableObject {
    @Published var page: PrimaryPage = .search
    @Published var disabled = false
    @Published var accessible = true
    var selections: [PrimaryPage] = []
}

@MainActor
private final class NavigationPolishMeasurements {
    var labels: [PrimaryNavigationLabelPart: CGRect] = [:]
}

@MainActor
private struct NavigationPolishHarness: View {
    @ObservedObject var model: NavigationPolishModel
    let measured: NavigationPolishMeasurements
    var body: some View {
        VStack(spacing: 0) {
            PrimaryNavigationBar(page: model.page, switchingDisabled: model.disabled,
                                 accessibilityActive: model.accessible) {
                model.selections.append($0); model.page = $0
            }
            Spacer(minLength: 0)
        }
        .background(IQStyle.background)
        .onPreferenceChange(PrimaryNavigationLabelFrames.self) { measured.labels = $0 }
    }
}

/// Decode native captures into sRGB, top-left-addressed premultiplied RGBA.
private struct NavigationPolishPixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(_ image: UIImage) throws {
        let cg = try XCTUnwrap(image.cgImage)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        width = cg.width; height = cg.height; rgba = bytes
    }

    func forEachPixel(in rect: CGRect, _ body: (Int, CGPoint) -> Void) {
        for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                body((y * width + x) * 4, CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
            }
        }
    }

    func differs(from other: Self, at offset: Int) -> Bool {
        (0..<4).contains { rgba[offset + $0] != other.rgba[offset + $0] }
    }

    func matches(_ rgb: [UInt8], at offset: Int) -> Bool {
        rgba[offset + 3] == 255 && (0..<3).allSatisfy { abs(Int(rgba[offset + $0]) - Int(rgb[$0])) <= 1 }
    }
}