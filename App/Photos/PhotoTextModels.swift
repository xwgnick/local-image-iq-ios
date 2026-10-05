import Foundation
import ImageIQCore

enum PhotoTextPolicy {
    static let version: String = "vision-ocr-r3-accurate-zh-en-fit-v1"
}

struct RecognizedPhotoText: Sendable {
    let text: String
    let pixelWidth: Int
    let pixelHeight: Int
    let isReduced: Bool
}

protocol PhotoTextRecognizing: Sendable {
    func recognize(id: String, networkAllowed: Bool) async throws -> RecognizedPhotoText
}

struct PhotoTextRecord: Sendable {
    let id: String
    let revision: Double
    let policy: String
    let text: String
    let pixelWidth: Int
    let pixelHeight: Int
    let isReduced: Bool
}

struct TextIndexCounts: Sendable, Equatable {
    var records = 0
    var withText = 0
    var reduced = 0
}

struct TextIndexProgress: Sendable, Equatable {
    var total = 0
    var completed = 0
    var recognized = 0
    var reused = 0
    var withText = 0
    var reduced = 0
    var cloudSkipped = 0
    var failed = 0
    var staleSkipped = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    /// Counters only: neither photo identifiers nor recognized text belong in UI progress.
    var summary: String {
        "已检查 \(completed)/\(total) · 已识别 \(recognized) · 已复用 \(reused) · 含文字 \(withText) · 降低分辨率 \(reduced) · 需云端 \(cloudSkipped) · 失败 \(failed) · 已变化跳过 \(staleSkipped)"
    }
}

/// Search exposes lexical relevance, never the actual recognized text.
struct PhotoTextMatch: Sendable, Equatable {
    let id: String
    let score: Double
}

enum PhotoTextRanking {
    /// Equal-weight reciprocal rank fusion: 1/(60 + visualRank) + 1/(60 + textRank),
    /// with one-based ranks and zero text contribution for a nonmatch. This is a
    /// documented rank-combination algorithm, NOT calibrated relevance weights.
    /// Both input arrays are already ranked; score magnitudes are not combined.
    /// Keep first occurrences, intersect text with visual IDs BEFORE assigning ranks.
    /// Pass the FULL visual ranking here; apply result filters/limits afterwards.
    /// SearchHit.score remains the original image+place diagnostic, not the RRF score.
    static func fuse(visual: [SearchHit], text: [PhotoTextMatch]) -> [SearchHit] {
        guard !text.isEmpty, !visual.isEmpty else { return visual }
        let visualIDs = Set(visual.map(\.id))
        var textRanks: [String: Int] = [:]
        for match in text where visualIDs.contains(match.id) {
            if textRanks[match.id] == nil { textRanks[match.id] = textRanks.count + 1 }
        }
        // Preserve even duplicate entries and all floating-point bits on this path.
        guard !textRanks.isEmpty else { return visual }
        var seen: Set<String> = []
        let unique = visual.filter { seen.insert($0.id).inserted }
        let ranked = unique.enumerated().map { offset, hit -> (hit: SearchHit, rank: Int, fused: Double) in
            let rank = offset + 1
            let lexical = textRanks[hit.id].map { 1.0 / (60.0 + Double($0)) } ?? 0
            return (hit, rank, 1.0 / (60.0 + Double(rank)) + lexical)
        }
        return ranked.sorted {
            $0.fused == $1.fused ? $0.rank < $1.rank : $0.fused > $1.fused
        }.map(\.hit)
    }
}

/// Deterministic lexical matching, not language segmentation or semantic understanding.
/// Documents store Han unigrams AND adjacent bigrams. Each query Han run uses only
/// bigrams if its length is >= 2, otherwise a unigram. Partial Chinese overlap is
/// intentionally possible under OR matching. Punctuation breaks runs; non-Han
/// letters/digits form whole identifiers (123 never matches the token 1234).
enum PhotoTextLexicon {
    struct Analysis {
        let terms: Set<String>
        /// Space-delimited lexical units, including boundary spaces. This prevents
        /// phrase bonuses for substrings of identifiers; punctuation becomes separation.
        let phrase: String
    }

    static func analyze(_ text: String, query: Bool) -> Analysis {
        let normalized = text.folding(options: [.widthInsensitive, .caseInsensitive],
                                      locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        var terms: Set<String> = []
        var units: [String] = []
        var run: [Unicode.Scalar] = []
        var hanRun = false

        func flush() {
            guard !run.isEmpty else { return }
            if hanRun {
                let characters = run.map { String($0) }
                units.append(contentsOf: characters)
                if !query || characters.count == 1 {
                    for character in characters { terms.insert("h:" + character) }
                }
                for index in characters.indices.dropFirst() {
                    terms.insert("b:" + characters[index - 1] + characters[index])
                }
            } else {
                let word = String(String.UnicodeScalarView(run))
                units.append(word)
                terms.insert("w:" + word)
            }
            run.removeAll(keepingCapacity: true)
        }

        for scalar in normalized.unicodeScalars {
            let han = isHan(scalar)
            let word = CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
            let continuation = CharacterSet.nonBaseCharacters.contains(scalar) && !run.isEmpty && !hanRun
            guard han || word || continuation else { flush(); continue }
            if !run.isEmpty && han != hanRun { flush() }
            hanRun = han
            run.append(scalar)
        }
        flush()
        return Analysis(terms: terms, phrase: units.isEmpty ? "" : " " + units.joined(separator: " ") + " ")
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F,
             0x2B820...0x2CEAF, 0x2CEB0...0x2EBEF, 0x2EBF0...0x2EE5F,
             0x2F800...0x2FA1F, 0x30000...0x3134F, 0x31350...0x323AF:
            return true
        default: return false
        }
    }
}