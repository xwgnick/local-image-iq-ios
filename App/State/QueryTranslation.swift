import Foundation
import NaturalLanguage

enum QueryTranslationLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplified = "zh-Hans"
    case traditional = "zh-Hant"

    var id: String { rawValue }
    var title: String { self == .simplified ? "简体中文 → 英文" : "繁體中文 → 英文" }
}

enum QueryTranslationAvailability: Equatable, Sendable {
    case unchecked, installed, downloadRequired, unsupported, unavailable

    var message: String {
        switch self {
        case .unchecked: return "尚未检查离线语言包"
        case .installed: return "离线语言包已就绪"
        case .downloadRequired: return "需要先下载离线语言包"
        case .unsupported: return "此系统或语言对暂不支持；仍可原文搜索"
        case .unavailable: return "暂时无法检查语言包；仍可原文搜索"
        }
    }
}

enum QueryTranslationFailure: Error {
    case notInstalled, unsupported, unavailable, emptyResult

    var fallbackMessage: String {
        switch self {
        case .notInstalled: return "离线语言包未就绪，本次使用原文。可在设置中下载。"
        case .unsupported: return "此系统或语言对不支持离线翻译，本次使用原文。"
        case .unavailable, .emptyResult: return "离线翻译未完成，本次使用原文。"
        }
    }
}

/// Injectable boundary. Implementations must never upload text or download a
/// language model from translate(). Only explicit prepare() may ask for a download.
@MainActor
protocol QueryTranslating: AnyObject {
    var isSupported: Bool { get }
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String
    func prepare(_ language: QueryTranslationLanguage) async throws
}

struct SearchQueryResolution: Equatable, Sendable {
    let original: String
    let effective: String
    let translated: Bool
    let notice: String?
}

enum ChineseQueryRouter {
    /// Translate Chinese/mixed Chinese-English queries as ONE string. Han is
    /// not synonymous with Chinese: kana/Hangul explicitly bypass this feature.
    /// Bare Han short queries can be ambiguous; the original-text action remains
    /// available. There is deliberately no vocabulary/ID-card substitution table.
    static func sourceLanguage(for text: String) -> QueryTranslationLanguage? {
        let scalars = text.unicodeScalars
        let hasHan = scalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
        }
        guard hasHan else { return nil }
        let otherScript = scalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value)
                || (0xFF66...0xFF9F).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value)
                || (0x3130...0x318F).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
        }
        guard !otherScript else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .traditionalChinese ? .traditional : .simplified
    }
}