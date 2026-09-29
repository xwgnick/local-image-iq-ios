import XCTest
import SwiftUI
import UIKit
import Foundation
@testable import LocalImageIQ

/// Approved prototype B tokens, not a copy of the production color provider.
/// Exercise the actual SwiftUI -> UIKit bridge: a separate UIColor helper would
/// hide a regression where the Color exposed to views has lost its dynamic traits.
@MainActor
final class IQStyleTests: XCTestCase {
    private var palette: [(name: String, color: Color, light: UInt32, dark: UInt32)] {
        [
            ("background", IQStyle.background, 0xF7F8FA, 0x121416),
            ("surface", IQStyle.surface, 0xFFFFFF, 0x1D2023),
            ("text", IQStyle.text, 0x1C232B, 0xF4F6F8),
            ("secondary", IQStyle.secondary, 0x626E79, 0xA7B1BA),
            ("line", IQStyle.line, 0xE5E9ED, 0x30373D),
            ("muted", IQStyle.muted, 0xEFF2F5, 0x252A2F),
            ("accent", IQStyle.accent, 0x006B63, 0x73D5C5),
            ("accentSoft", IQStyle.accentSoft, 0xE5F3EF, 0x193B36),
            ("onAccent", IQStyle.onAccent, 0xFFFFFF, 0x0E2B27),
            ("warning", IQStyle.warning, 0x815000, 0xE9BB75),
            ("viewerBackground", IQStyle.viewerBackground, 0x090B0C, 0x090B0C)
        ]
    }

    func testLightPaletteMatchesPrototypeB() throws {
        for token in palette {
            try assertRGB(UIColor(token.color), appearance: .light, hex: token.light, name: token.name)
        }
    }

    func testDarkPaletteMatchesPrototypeB() throws {
        for token in palette {
            try assertRGB(UIColor(token.color), appearance: .dark, hex: token.dark, name: token.name)
        }
    }

    func testSameBridgedUIColorInstancesResolveLightDarkAndLightAgain() throws {
        let colors = palette.map { (name: $0.name, color: UIColor($0.color), light: $0.light, dark: $0.dark) }
        // Reuse each UIColor instance; rebuilding tokens after changing traits
        // would fail to detect colors frozen at their creation-time appearance.
        for appearance in [UIUserInterfaceStyle.light, .dark, .light] {
            for token in colors {
                try assertRGB(token.color, appearance: appearance,
                              hex: appearance == .dark ? token.dark : token.light, name: token.name)
            }
        }
    }

    func testLightTextAndButtonContrastMeetsAA() throws {
        try assertTextContrast(appearance: .light)
    }

    func testDarkTextAndButtonContrastMeetsAA() throws {
        try assertTextContrast(appearance: .dark)
    }

    func testViewerBackgroundRemainsNearBlackInBothAppearances() throws {
        let color = UIColor(IQStyle.viewerBackground)
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            try assertRGB(color, appearance: appearance, hex: 0x090B0C, name: "viewerBackground")
        }
    }

    private func traits(_ appearance: UIUserInterfaceStyle) -> UITraitCollection {
        UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: appearance),
                                      UITraitCollection(accessibilityContrast: .normal),
                                      UITraitCollection(displayGamut: .SRGB)])
    }

    private func rgb(_ color: UIColor, appearance: UIUserInterfaceStyle,
                     file: StaticString = #filePath, line: UInt = #line) throws -> (red: Double, green: Double, blue: Double) {
        let resolved = color.resolvedColor(with: traits(appearance))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            XCTFail("The actual IQStyle Color must resolve to RGB", file: file, line: line)
            throw ColorFailure.notRGB
        }
        XCTAssertEqual(alpha, 1, accuracy: 0.00001, "Prototype tokens are opaque", file: file, line: line)
        return (Double(red), Double(green), Double(blue))
    }

    private func assertRGB(_ color: UIColor, appearance: UIUserInterfaceStyle, hex: UInt32, name: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try rgb(color, appearance: appearance, file: file, line: line)
        let label = "\(name), \(appearance == .dark ? "dark" : "light")"
        XCTAssertEqual(actual.red, Double((hex >> 16) & 0xFF) / 255, accuracy: 0.00001, label, file: file, line: line)
        XCTAssertEqual(actual.green, Double((hex >> 8) & 0xFF) / 255, accuracy: 0.00001, label, file: file, line: line)
        XCTAssertEqual(actual.blue, Double(hex & 0xFF) / 255, accuracy: 0.00001, label, file: file, line: line)
    }

    private func assertTextContrast(appearance: UIUserInterfaceStyle,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let backgrounds: [(String, Color)] = [("background", IQStyle.background), ("surface", IQStyle.surface),
                                              ("muted", IQStyle.muted), ("accentSoft", IQStyle.accentSoft)]
        let foregrounds: [(String, Color)] = [("text", IQStyle.text), ("secondary", IQStyle.secondary)]
        for (foregroundName, foreground) in foregrounds {
            for (backgroundName, background) in backgrounds {
                let ratio = try contrast(UIColor(foreground), UIColor(background), appearance: appearance)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(foregroundName) on \(backgroundName)", file: file, line: line)
            }
        }
        let buttonRatio = try contrast(UIColor(IQStyle.onAccent), UIColor(IQStyle.accent), appearance: appearance)
        XCTAssertGreaterThanOrEqual(buttonRatio, 4.5, "onAccent on accent", file: file, line: line)
    }

    private func contrast(_ foreground: UIColor, _ background: UIColor,
                          appearance: UIUserInterfaceStyle) throws -> Double {
        let first = try luminance(foreground, appearance: appearance)
        let second = try luminance(background, appearance: appearance)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func luminance(_ color: UIColor, appearance: UIUserInterfaceStyle) throws -> Double {
        let value = try rgb(color, appearance: appearance)
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(value.red) + 0.7152 * linear(value.green) + 0.0722 * linear(value.blue)
    }

    private enum ColorFailure: Error { case notRGB }
}