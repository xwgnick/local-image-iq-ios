import Foundation
import SwiftUI
import UIKit

enum IQStyle {
    // B02: charcoal with warm champagne-gold actions. Light appearance uses
    // a deeper gold for readable controls; dark appearance uses a lighter gold
    // with charcoal labels on filled buttons. Resolve at display time so sheets
    // and live system appearance changes share the same palette.
    // Keep the outer canvas matched to the existing icon-only launch background.
    static let background = adaptive(light: 0xF7F8FA, dark: 0x121416)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x202123)
    static let text = adaptive(light: 0x1C232B, dark: 0xF4F6F8)
    static let secondary = adaptive(light: 0x626E79, dark: 0xA7B1BA)
    static let line = adaptive(light: 0xE5E9ED, dark: 0x393A3D)
    static let muted = adaptive(light: 0xEFF2F5, dark: 0x2B2C2E)
    static let accent = adaptive(light: 0x806025, dark: 0xD8B57C)
    static let accentSoft = adaptive(light: 0xF6F0E5, dark: 0x352C20)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x201A12)
    static let warning = adaptive(light: 0x815000, dark: 0xE9BB75)
    static let viewerBackground = Color(uiColor: rgb(0x090B0C))

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            rgb(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Keep system error explanations useful without exposing local paths or coordinates.
    /// This is display-only: the underlying diagnostic and application state are unchanged.
    static func diagnosticText(_ text: String) -> String {
        let paths = #"(?i)(?:file://|\b[a-z]:[\\/]|(?<![\w/])/(?!\s))[^\r\n\"'<>]*"#
        let namedCoordinates = #"(?i)\b(?:latitude|longitude|lat|lon|lng)\s*[:=]\s*[+-]?\d+(?:\.\d+)?"#
        let coordinatePairs = #"(?<![\w.])[+-]?\d{1,3}\.\d+\s*[,;]\s*[+-]?\d{1,3}\.\d+(?![\w.])"#
        return text
            .replacingOccurrences(of: paths, with: "[local path hidden]", options: .regularExpression)
            .replacingOccurrences(of: namedCoordinates, with: "[coordinate hidden]", options: .regularExpression)
            .replacingOccurrences(of: coordinatePairs, with: "[coordinates hidden]", options: .regularExpression)
    }
}