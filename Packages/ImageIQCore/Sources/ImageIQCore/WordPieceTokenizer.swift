import Foundation

public enum TokenizerError: Error, Equatable, Sendable {
    case sequenceLengthTooSmall
    case duplicateVocabularyToken(String)
    case missingSpecialToken(String)
    case vocabularyIDOutOfRange
}

/// Cased BERT normalization + BERT pre-tokenization + greedy WordPiece.
/// Does not lowercase, strip accents, or apply NFC/NFD normalization.
public struct WordPieceTokenizer: Sendable {
    public let sequenceLength: Int
    private let vocabulary: [[UInt8]: Int32]
    private let classificationID: Int32
    private let separatorID: Int32
    private let paddingID: Int32
    private let unknownID: Int32
    private let specialTokens: [SpecialToken]

    // This is WordPiece's max_input_chars_per_word, not a query-length ceiling.
    // "Characters" here means Unicode scalar values, NOT Swift grapheme clusters.
    private static let maximumWordScalars = 100

    private struct SpecialToken: Sendable {
        let scalars: [Unicode.Scalar]
        let id: Int32
    }

    public init(vocabulary: [String], sequenceLength: Int = 128) throws {
        guard sequenceLength >= 2 else { throw TokenizerError.sequenceLengthTooSmall }
        var lookup: [[UInt8]: Int32] = [:]
        for (index, token) in vocabulary.enumerated() {
            guard let id = Int32(exactly: index) else { throw TokenizerError.vocabularyIDOutOfRange }
            let key = Array(token.utf8)
            guard lookup.updateValue(id, forKey: key) == nil else {
                throw TokenizerError.duplicateVocabularyToken(token)
            }
        }
        func required(_ token: String) throws -> Int32 {
            guard let id = lookup[Array(token.utf8)] else {
                throw TokenizerError.missingSpecialToken(token)
            }
            return id
        }
        classificationID = try required("[CLS]")
        separatorID = try required("[SEP]")
        paddingID = try required("[PAD]")
        unknownID = try required("[UNK]")
        self.vocabulary = lookup
        self.sequenceLength = sequenceLength
        // Standard HF BERT added tokens: literal, case-sensitive, normalized=false,
        // single_word=false, lstrip=false, rstrip=false. [MASK] is optional in the
        // shared API's vocabulary requirements; recognize it when it is present.
        specialTokens = ["[CLS]", "[SEP]", "[PAD]", "[UNK]", "[MASK]"].compactMap { token in
            lookup[Array(token.utf8)].map {
                SpecialToken(scalars: Array(token.unicodeScalars), id: $0)
            }
        }
    }

    public func encode(_ text: String) -> TokenizedText {
        var ids = [classificationID]
        ids.reserveCapacity(sequenceLength)
        let payloadEnd = sequenceLength - 1 // Reserve one final [SEP].
        var word: [Unicode.Scalar] = []
        var wordTooLong = false

        func flushWord() {
            guard !word.isEmpty || wordTooLong else { return }
            if ids.count < payloadEnd {
                let pieces = wordTooLong ? [unknownID] : wordPiece(word)
                ids.append(contentsOf: pieces.prefix(payloadEnd - ids.count))
            }
            word.removeAll(keepingCapacity: true)
            wordTooLong = false
        }

        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex && ids.count < payloadEnd {
            // Added-token recognition precedes cleanup. A control character
            // inserted inside "[CLS]" must not manufacture an added-token match.
            if scalars[index].value == 0x5B, let match = specialMatch(in: scalars, at: index) {
                flushWord()
                if ids.count < payloadEnd { ids.append(match.id) }
                index = match.end
                continue
            }

            let scalar = scalars[index]
            index = scalars.index(after: index)
            if scalar.value == 0 || scalar.value == 0xFFFD || Self.isControl(scalar) {
                continue
            }
            if scalar.properties.isWhitespace {
                flushWord()
            } else if Self.isChinese(scalar) || Self.isPunctuation(scalar) {
                flushWord()
                if ids.count < payloadEnd { ids.append(contentsOf: wordPiece([scalar])) }
            } else if !wordTooLong {
                if word.count == Self.maximumWordScalars {
                    wordTooLong = true
                } else {
                    word.append(scalar)
                }
            }
        }
        flushWord()
        ids.append(separatorID)
        let attendedCount = ids.count
        ids.append(contentsOf: repeatElement(paddingID, count: sequenceLength - attendedCount))
        let mask = [Int32](repeating: 1, count: attendedCount)
            + [Int32](repeating: 0, count: sequenceLength - attendedCount)
        return TokenizedText(inputIDs: ids, attentionMask: mask)
    }

    private func wordPiece(_ scalars: [Unicode.Scalar]) -> [Int32] {
        guard scalars.count <= Self.maximumWordScalars else { return [unknownID] }
        var result: [Int32] = []
        var start = 0
        while start < scalars.count {
            var end = scalars.count
            var matchedID: Int32?
            while end > start {
                var candidate = start == 0 ? "" : "##"
                for scalar in scalars[start..<end] { candidate.unicodeScalars.append(scalar) }
                if let id = vocabulary[Array(candidate.utf8)] {
                    matchedID = id
                    break
                }
                end -= 1
            }
            // Failed suffix invalidates the WHOLE original pre-tokenized word.
            guard let matchedID else { return [unknownID] }
            result.append(matchedID)
            start = end
        }
        return result
    }

    private func specialMatch(
        in scalars: String.UnicodeScalarView,
        at start: String.UnicodeScalarView.Index
    ) -> (id: Int32, end: String.UnicodeScalarView.Index)? {
        for token in specialTokens {
            var end = start
            var matches = true
            for expected in token.scalars {
                if end == scalars.endIndex || scalars[end] != expected {
                    matches = false
                    break
                }
                end = scalars.index(after: end)
            }
            if matches { return (token.id, end) }
        }
        return nil
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        // BERT exempts these three controls so they act as word boundaries.
        if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D { return false }
        // Fast BertNormalizer's unicode_categories "other" set is Cc/Cf/Co.
        // Do not substitute the slow Python tokenizer's category.startswith("C"):
        // that also removes unassigned (Cn) scalars. Swift cannot hold surrogates.
        switch scalar.properties.generalCategory {
        case .control, .format, .privateUse: return true
        default: return false
        }
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        // BERT includes ASCII symbols such as $, + and ^ as punctuation.
        switch scalar.value {
        case 33...47, 58...64, 91...96, 123...126: return true
        default: break
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default: return false
        }
    }

    private static func isChinese(_ scalar: Unicode.Scalar) -> Bool {
        // BERT's explicit legacy ranges, not all characters of Unicode script Han.
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF,
             0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF,
             0xF900...0xFAFF, 0x2F800...0x2FA1F:
            return true
        default: return false
        }
    }
}