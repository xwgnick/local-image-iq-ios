import Foundation
import SwiftUI

enum IQStyle {
    static let background = Color(red: 11.0 / 255, green: 12.0 / 255, blue: 20.0 / 255)
    static let surface = Color(red: 23.0 / 255, green: 24.0 / 255, blue: 36.0 / 255)
    static let accent = Color(red: 185.0 / 255, green: 164.0 / 255, blue: 1)
    static let secondary = Color(red: 160.0 / 255, green: 165.0 / 255, blue: 184.0 / 255)

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