import XCTest
import SwiftUI
import UIKit
@testable import LocalImageIQ

/// Direct native production controls and intrinsic label measurements. No
/// AppState, Photos, models, history persistence, translation or network.
@MainActor
final class AdaptiveSearchQueryChipPresentationTests: XCTestCase {
    func testShortLabelsKeepMeasuredIntrinsicWidthsAt320And393() async throws {
        for width in [CGFloat(320), CGFloat(393)] {
            let model = AdaptiveChipModel(width: width, queries: ["猫", "海边", "身份证"])
            let (host, measured) = try mount(model)
            defer { host.close() }
            try await wait(host, measured)
            try assertAllocation(host, measured, model)
            let last = try XCTUnwrap(measured.frames[.chip(2)])
            let row = try XCTUnwrap(measured.frames[.chips])
            XCTAssertLessThan(last.maxX, row.maxX - 20, "Fitting chips must not stretch to fill the row")
            for index in 0..<3 {
                let ideal = max(44, try XCTUnwrap(measured.ideal[index]))
                XCTAssertEqual(try XCTUnwrap(measured.frames[.chip(index)]).width, ideal, accuracy: host.pixel)
            }
        }
    }

    func testLongQueryGetsExtraWidthInEveryHistoryPositionAtBothWidthsAndFonts() async throws {
        let queries = ["猫", "身份证", String(repeating: "海边日落和追逐逗猫棒 ", count: 20) + "END"]
        for width in [CGFloat(320), CGFloat(393)] {
            for font in [DynamicTypeSize.large, .accessibility5] {
                let model = AdaptiveChipModel(width: width, queries: queries, font: font)
                let (host, measured) = try mount(model)
                defer { host.close() }
                try await wait(host, measured)
                try assertAllocation(host, measured, model)
                let original = try widths(measured)
                XCTAssertGreaterThan(original[2], original[0])
                XCTAssertLessThan(original[2], try XCTUnwrap(measured.ideal[2]), "Long label must truncate")
                for order in [[2, 0, 1], [1, 2, 0], [0, 1, 2]] {
                    model.suggestions = order.map { SearchQuerySuggestion(label: queries[$0], query: queries[$0]) }
                    try await host.wait {
                        order.enumerated().allSatisfy { position, source in
                            guard let frame = measured.frames[.chip(position)] else { return false }
                            return abs(frame.width - original[source]) <= host.pixel
                        }
                    }
                    try assertAllocation(host, measured, model)
                    XCTAssertEqual(model.suggestions.map(\.query), order.map { queries[$0] })
                }
            }
        }
    }

    func testSameHostWidthAndDynamicTypeChangesRemeasureThenRestore() async throws {
        let model = AdaptiveChipModel(width: 393, queries: ["猫", "海边日落", "猫猫追逐逗猫棒"])
        let (host, measured) = try mount(model)
        defer { host.close() }
        try await wait(host, measured)
        try assertAllocation(host, measured, model)
        let initial = try widths(measured)
        let ideal = try XCTUnwrap(measured.ideal[2])
        model.width = 320
        try await host.wait { abs((measured.frames[.chips]?.width ?? 0) - 280) <= host.pixel }
        try assertAllocation(host, measured, model)
        model.font = .accessibility5
        try await host.wait { (measured.ideal[2] ?? 0) > ideal + 10 }
        try assertAllocation(host, measured, model)
        model.width = 393
        try await host.wait { abs((measured.frames[.chips]?.width ?? 0) - 353) <= host.pixel }
        try assertAllocation(host, measured, model)
        model.font = .large
        try await host.wait { abs((measured.ideal[2] ?? 0) - ideal) <= host.pixel }
        try assertAllocation(host, measured, model)
        for (actual, original) in zip(try widths(measured), initial) {
            XCTAssertEqual(actual, original, accuracy: host.pixel)
        }
    }

    func testNativeThreeTimes44ViewportSacrificesGapsNotTouchWidths() async throws {
        let model = AdaptiveChipModel(width: 172, queries: ["猫", "海边日落", "猫猫追逐逗猫棒"])
        let (host, measured) = try mount(model)
        defer { host.close() }
        try await wait(host, measured)
        try assertAllocation(host, measured, model)
        for width in try widths(measured) { XCTAssertEqual(width, 44, accuracy: host.pixel) }
    }

    func testTruncatedLabelsStillDispatchTheEntireStoredQueryAfterReordering() async throws {
        let query = String(repeating: "TEST unabridged query 海边日落 ", count: 30) + "END"
        let model = AdaptiveChipModel(width: 320, queries: ["猫", "身份证", query], font: .accessibility5)
        let (host, measured) = try mount(model)
        defer { host.close() }
        try await wait(host, measured)
        try assertAllocation(host, measured, model)
        XCTAssertLessThan(try XCTUnwrap(measured.frames[.chip(2)]).width, try XCTUnwrap(measured.ideal[2]))
        model.suggestions.reverse()
        try await host.settle()
        let chips = SearchQueryChips(suggestions: model.suggestions) { model.selected.append($0) }
        for suggestion in model.suggestions { chips.choose(suggestion) }
        XCTAssertEqual(model.selected, [query, "身份证", "猫"])
        // Production choose(), not a simulated touch/VoiceOver activation.
        // The button's explicit AX label remains suggestion.query, not label.
    }

    private func mount(_ model: AdaptiveChipModel) throws -> (ControlsNativeHost, AdaptiveChipMeasurements) {
        let measured = AdaptiveChipMeasurements()
        let host = try ControlsNativeHost(content: AnyView(AdaptiveChipHarness(model: model, measured: measured)),
                                          size: CGSize(width: model.width, height: 300))
        return (host, measured)
    }

    private func wait(_ host: ControlsNativeHost, _ measured: AdaptiveChipMeasurements) async throws {
        try await host.wait { measured.frames[.chip(2)] != nil && measured.ideal.count == 3 }
    }

    private func widths(_ measured: AdaptiveChipMeasurements) throws -> [CGFloat] {
        try (0..<3).map { try XCTUnwrap(measured.frames[.chip($0)]).width }
    }

    private func assertAllocation(_ host: ControlsNativeHost, _ measured: AdaptiveChipMeasurements,
                                  _ model: AdaptiveChipModel) throws {
        let row = try XCTUnwrap(measured.frames[.chips])
        let ideal = try (0..<3).map { try XCTUnwrap(measured.ideal[$0]) }
        let expected = SearchQueryChipAllocation(intrinsicWidths: ideal, availableWidth: model.width - 40)
        XCTAssertEqual(row.width, model.width - 40, accuracy: host.pixel)
        XCTAssertEqual(row.height, 44, accuracy: host.pixel)
        var x = row.minX
        for index in 0..<3 {
            let frame = try XCTUnwrap(measured.frames[.chip(index)])
            XCTAssertEqual(frame.minX, x, accuracy: host.pixel)
            XCTAssertEqual(frame.minY, row.minY, accuracy: host.pixel)
            XCTAssertEqual(frame.height, 44, accuracy: host.pixel)
            XCTAssertEqual(frame.width, expected.widths[index], accuracy: host.pixel)
            XCTAssertGreaterThanOrEqual(frame.width + host.pixel, 44)
            XCTAssertLessThanOrEqual(frame.maxX, row.maxX + host.pixel)
            x = frame.maxX + expected.spacing
        }
        XCTAssertEqual(model.selected, [])
    }
}

@MainActor
private final class AdaptiveChipModel: ObservableObject {
    @Published var width: CGFloat
    @Published var font: DynamicTypeSize
    @Published var suggestions: [SearchQuerySuggestion]
    var selected: [String] = []
    init(width: CGFloat, queries: [String], font: DynamicTypeSize = .large) {
        self.width = width; self.font = font
        suggestions = queries.map { SearchQuerySuggestion(label: $0, query: $0) }
    }
}

@MainActor
private final class AdaptiveChipMeasurements {
    var frames: [MinimalSearchPart: CGRect] = [:]
    var ideal: [Int: CGFloat] = [:]
}

private struct AdaptiveChipIdealWidths: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
private struct AdaptiveChipHarness: View {
    @ObservedObject var model: AdaptiveChipModel
    let measured: AdaptiveChipMeasurements
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchQueryChips(suggestions: model.suggestions) { model.selected.append($0) }
                .frame(width: model.width - 40, height: 44)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
        .onPreferenceChange(MinimalSearchFrames.self) { measured.frames = $0 }
        .overlay(alignment: .topLeading) {
            // Measure the same production label unconstrained, without taking
            // space from the visible row or creating duplicate AX controls.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.suggestions.enumerated()), id: \.offset) { index, suggestion in
                    SearchQueryChipLabel(label: suggestion.label)
                        .fixedSize(horizontal: true, vertical: true)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: AdaptiveChipIdealWidths.self,
                                                       value: [index: geometry.size.width])
                            }
                        }
                }
            }
            .hidden().allowsHitTesting(false).accessibilityHidden(true)
        }
        .onPreferenceChange(AdaptiveChipIdealWidths.self) { measured.ideal = $0 }
        .environment(\.dynamicTypeSize, model.font)
    }
}