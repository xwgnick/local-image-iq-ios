import XCTest
@testable import ImageIQCore

final class WordPieceTokenizerTests: XCTestCase {
    // Deliberately nonstandard special-token IDs. These are synthetic tokens,
    // not a redistributed model vocabulary or claimed HF reference fixtures.
    private static let vocabulary = [
        "[UNK]", "Hello", "[SEP]", "[PAD]", "[CLS]", "[MASK]",
        "hello", "HELLO", "world", "play", "##ing", "playing", "playi", "##ng",
        "中", "文", "你", "好", "Café", "café", "Cafe", "é", "e",
        "\u{0301}", "##\u{0301}", "e\u{0301}",
        "!", ",", ".", "?", "'", "-", "_", "$", "+", "^", "`", "~",
        "，", "。", "—", "’", "«", "»", "€", "😀", "👩", "💻", "##💻",
        "CLS", "SEP", "MASK", "cls", "[", "]", "a", "##a", "ab", "##b", "b",
        "(", ")", ":", ";", "/", "\\", "=", "#"
    ]

    private func id(_ token: String, vocabulary: [String]) -> Int32 {
        // Do not accidentally canonicalize the test oracle with String equality.
        guard let index = vocabulary.firstIndex(where: { $0.utf8.elementsEqual(token.utf8) }) else {
            XCTFail("Missing synthetic expected token: \(token)")
            return -1
        }
        return Int32(index)
    }

    private func assertEncoding(
        _ text: String,
        tokens: [String],
        vocabulary: [String] = WordPieceTokenizerTests.vocabulary,
        length: Int = 128,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let tokenizer = try WordPieceTokenizer(vocabulary: vocabulary, sequenceLength: length)
        let actual = tokenizer.encode(text)
        let expectedTokens = ["[CLS]"] + Array(tokens.prefix(length - 2)) + ["[SEP]"]
        let expectedIDs = expectedTokens.map { id($0, vocabulary: vocabulary) }
            + [Int32](repeating: id("[PAD]", vocabulary: vocabulary), count: length - expectedTokens.count)
        let expectedMask = [Int32](repeating: 1, count: expectedTokens.count)
            + [Int32](repeating: 0, count: length - expectedTokens.count)
        XCTAssertEqual(actual.inputIDs, expectedIDs, file: file, line: line)
        XCTAssertEqual(actual.attentionMask, expectedMask, file: file, line: line)
        XCTAssertEqual(actual.inputIDs.count, length, file: file, line: line)
        XCTAssertEqual(actual.attentionMask.count, length, file: file, line: line)
    }

    func testEmptyInputUsesVocabularyIDsAndFixed128Padding() throws {
        let tokenizer = try WordPieceTokenizer(vocabulary: Self.vocabulary)
        let result = tokenizer.encode("")
        XCTAssertEqual(tokenizer.sequenceLength, 128)
        XCTAssertEqual(Array(result.inputIDs.prefix(3)), [4, 2, 3])
        XCTAssertEqual(Array(result.attentionMask.prefix(3)), [1, 1, 0])
        try assertEncoding("", tokens: [])
    }

    func testEnglishCaseIsPreserved() throws {
        try assertEncoding("Hello hello HELLO", tokens: ["Hello", "hello", "HELLO"])
        try assertEncoding("hELLO", tokens: ["[UNK]"])
    }

    func testGreedyLongestMatchAndContinuationPrefix() throws {
        try assertEncoding("playing", tokens: ["playing"])
        let withoutWhole = Self.vocabulary.filter { $0 != "playing" }
        try assertEncoding("playing", tokens: ["playi", "##ng"], vocabulary: withoutWhole)
        let onlyShorter = withoutWhole.filter { $0 != "playi" }
        try assertEncoding("playing", tokens: ["play", "##ing"], vocabulary: onlyShorter)
    }

    func testFailedSuffixReplacesWholeWordWithUnknown() throws {
        try assertEncoding("playx", tokens: ["[UNK]"])
        try assertEncoding("playx world", tokens: ["[UNK]", "world"])
    }

    func testContinuationCannotStartAWordAndPlainTokenCannotContinue() throws {
        try assertEncoding("ing", tokens: ["[UNK]"])
        try assertEncoding("Helloworld", tokens: ["[UNK]"])
        try assertEncoding(
            "Helloworld", tokens: ["Hello", "##world"], vocabulary: Self.vocabulary + ["##world"]
        )
    }

    func testGreedyWordPieceDoesNotBacktrackAfterLongerPrefixFails() throws {
        let vocabulary = Self.vocabulary + ["##bc"]
        // "a"+"##bc" could cover it, but greedy WordPiece selects "ab" first.
        try assertEncoding("abc", tokens: ["[UNK]"], vocabulary: vocabulary)
    }

    func testChineseCharactersSplitWithoutWhitespace() throws {
        try assertEncoding("Hello中文world你好", tokens: ["Hello", "中", "文", "world", "你", "好"])
    }

    func testBertLegacyCJKRangesIncludingSupplementaryScalars() throws {
        let characters = ["\u{4E00}", "\u{3400}", "\u{20000}", "\u{2A700}",
                          "\u{2B740}", "\u{2B820}", "\u{F900}", "\u{2F800}"]
        let vocabulary = Self.vocabulary + characters
        for character in characters {
            try assertEncoding("Hello\(character)world", tokens: ["Hello", character, "world"], vocabulary: vocabulary)
        }
    }

    func testNewerHanRangeDoesNotSilentlyExpandBertSplittingRules() throws {
        let word = "a\u{30000}b" // Extension G is outside BERT's explicit ranges.
        try assertEncoding(word, tokens: [word], vocabulary: Self.vocabulary + [word])
    }

    func testAccentsArePreservedWithoutLowercaseOrStripping() throws {
        try assertEncoding("Café café Cafe", tokens: ["Café", "café", "Cafe"])
        let withoutAccented = Self.vocabulary.filter { !$0.utf8.elementsEqual("Café".utf8) }
        try assertEncoding("Café", tokens: ["[UNK]"], vocabulary: withoutAccented)
    }

    func testCanonicalEquivalentsHaveDistinctVocabularyIDs() throws {
        let tokenizer = try WordPieceTokenizer(vocabulary: Self.vocabulary)
        let composed = tokenizer.encode("é").inputIDs[1]
        let decomposed = tokenizer.encode("e\u{0301}").inputIDs[1]
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(composed, id("é", vocabulary: Self.vocabulary))
        XCTAssertEqual(decomposed, id("e\u{0301}", vocabulary: Self.vocabulary))
    }

    func testCombiningAccentCanBeAContinuationWithoutNormalization() throws {
        let vocabulary = Self.vocabulary.filter { !$0.utf8.elementsEqual("e\u{0301}".utf8) }
        try assertEncoding("e\u{0301}", tokens: ["e", "##\u{0301}"], vocabulary: vocabulary)
        try assertEncoding("\u{0301}", tokens: ["\u{0301}"])
    }

    func testASCIIPunctuationAndSymbolsSplitIndividually() throws {
        try assertEncoding(
            "Hello,world!a_b$+^`~?('-).:/\\=#;",
            tokens: ["Hello", ",", "world", "!", "a", "_", "b", "$", "+", "^", "`", "~",
                     "?", "(", "'", "-", ")", ".", ":", "/", "\\", "=", "#", ";"]
        )
    }

    func testUnicodePunctuationSplitsWithoutChangingItsSpelling() throws {
        try assertEncoding(
            "«Café»—Hello’world，中文。",
            tokens: ["«", "Café", "»", "—", "Hello", "’", "world", "，", "中", "文", "。"]
        )
    }

    func testNonASCIISymbolIsNotAutomaticallyPunctuation() throws {
        try assertEncoding("Hello€world", tokens: ["[UNK]"])
        try assertEncoding("€", tokens: ["€"])
    }

    func testWhitespaceIncludesTabsNewlinesAndUnicodeSeparators() throws {
        try assertEncoding(
            " Hello\tworld\r\n中\u{00A0}文\u{2003}Hello\u{2028}world\u{2029}中 ",
            tokens: ["Hello", "world", "中", "文", "Hello", "world", "中"]
        )
    }

    func testNullReplacementAndControlsAreRemovedNotWordBoundaries() throws {
        try assertEncoding("He\u{0000}ll\u{0001}o\u{FFFD}", tokens: ["Hello"])
        try assertEncoding("\u{0000}\u{FFFD}\u{0001}", tokens: [])
        for removed in ["\u{000B}", "\u{000C}", "\u{0085}", "\u{001C}",
                        "\u{200D}", "\u{200B}", "\u{FEFF}", "\u{E000}"] {
            try assertEncoding("He\(removed)llo", tokens: ["Hello"])
        }
    }

    func testUnassignedScalarIsNotRemovedByFastBertOtherCategoryRules() throws {
        let word = "He\u{0378}llo"
        try assertEncoding(word, tokens: [word], vocabulary: Self.vocabulary + [word])
        try assertEncoding(word, tokens: ["[UNK]"])
    }

    func testEmojiUnknownAndKnownScalarBehavior() throws {
        try assertEncoding("😀 🦊", tokens: ["😀", "[UNK]"])
        // Emoji is a symbol, not a punctuation/whitespace token boundary.
        try assertEncoding("Hello😀world", tokens: ["[UNK]"])
    }

    func testEmojiJoinerIsRemovedButVariationSelectorIsRetained() throws {
        try assertEncoding("👩\u{200D}💻", tokens: ["👩", "##💻"])
        try assertEncoding(
            "☀\u{FE0F}", tokens: ["☀", "##\u{FE0F}"],
            vocabulary: Self.vocabulary + ["☀", "##\u{FE0F}"]
        )
    }

    func testLiteralSpecialTokensArePreservedEvenWithoutWordBoundaries() throws {
        try assertEncoding(
            "Hello[CLS][SEP][MASK]world[PAD][UNK]",
            tokens: ["Hello", "[CLS]", "[SEP]", "[MASK]", "world", "[PAD]", "[UNK]"]
        )
    }

    func testLiteralPaddingTokenIsAttendedButGeneratedPaddingIsNot() throws {
        let result = try WordPieceTokenizer(vocabulary: Self.vocabulary).encode("[PAD]")
        XCTAssertEqual(Array(result.inputIDs.prefix(4)), [4, 3, 2, 3])
        XCTAssertEqual(Array(result.attentionMask.prefix(4)), [1, 1, 1, 0])
    }

    func testSpecialTokensAreCaseSensitive() throws {
        try assertEncoding("[cls]", tokens: ["[", "cls", "]"])
    }

    func testControlCleanupDoesNotManufactureASpecialToken() throws {
        try assertEncoding("Hello[CL\u{0000}S]world", tokens: ["Hello", "[", "CLS", "]", "world"])
        try assertEncoding("\u{0000}[CLS]\u{0001}", tokens: ["[CLS]"])
    }

    func testCombiningMarksAdjacentToSpecialTokensRemainSeparateScalars() throws {
        try assertEncoding(
            "\u{0301}[CLS]e\u{0301}[MASK]\u{0301}",
            tokens: ["\u{0301}", "[CLS]", "e\u{0301}", "[MASK]", "\u{0301}"]
        )
    }

    func testMaskIsRecognizedOnlyWhenInVocabulary() throws {
        let vocabulary = Self.vocabulary.filter { $0 != "[MASK]" }
        try assertEncoding("[MASK]", tokens: ["[", "MASK", "]"], vocabulary: vocabulary)
    }

    func testWordPiece100ScalarBoundaryIsNotAQueryCap() throws {
        let hundred = String(repeating: "a", count: 100)
        try assertEncoding(hundred, tokens: ["a"] + [String](repeating: "##a", count: 99))
        try assertEncoding(hundred + "a", tokens: ["[UNK]"])
        // Even an exact full vocabulary entry is rejected beyond WordPiece's limit.
        try assertEncoding(hundred + "a", tokens: ["[UNK]"], vocabulary: Self.vocabulary + [hundred + "a"])
        try assertEncoding(String(repeating: "a", count: 5000) + " world", tokens: ["[UNK]", "world"])
    }

    func testWordLengthCountsScalarsNotGraphemeClustersOrUTF8Bytes() throws {
        let vocabulary = Self.vocabulary + ["##e\u{0301}", "##é", "##😀"]
        try assertEncoding(
            String(repeating: "e\u{0301}", count: 50),
            tokens: ["e\u{0301}"] + [String](repeating: "##e\u{0301}", count: 49), vocabulary: vocabulary
        )
        try assertEncoding(String(repeating: "e\u{0301}", count: 51), tokens: ["[UNK]"], vocabulary: vocabulary)
        try assertEncoding(
            String(repeating: "é", count: 100),
            tokens: ["é"] + [String](repeating: "##é", count: 99), vocabulary: vocabulary
        )
        try assertEncoding(
            String(repeating: "😀", count: 100),
            tokens: ["😀"] + [String](repeating: "##😀", count: 99), vocabulary: vocabulary
        )
    }

    func testCJKAndPunctuationBoundariesPrecedeWordLengthLimit() throws {
        try assertEncoding(String(repeating: "中", count: 200), tokens: [String](repeating: "中", count: 126))
        let word = String(repeating: "a", count: 100)
        try assertEncoding(
            word + "," + word,
            tokens: ["a"] + [String](repeating: "##a", count: 99) + [","]
                + ["a"] + [String](repeating: "##a", count: 99)
        )
    }

    func testTextTruncatesTo126AndAlwaysEndsWithSeparator() throws {
        for count in [125, 126, 127, 200] {
            let text = [String](repeating: "Hello", count: count).joined(separator: " ")
            try assertEncoding(text, tokens: [String](repeating: "Hello", count: min(count, 126)))
        }
        let text = [String](repeating: "Hello", count: 200).joined(separator: " ")
        let result = try WordPieceTokenizer(vocabulary: Self.vocabulary).encode(text)
        XCTAssertEqual(result.inputIDs.last, id("[SEP]", vocabulary: Self.vocabulary))
        XCTAssertEqual(result.attentionMask, [Int32](repeating: 1, count: 128))
    }

    func testTruncationMayCutAWordPieceSequence() throws {
        let first = String(repeating: "a", count: 100)
        let second = String(repeating: "a", count: 50)
        let all = ["a"] + [String](repeating: "##a", count: 99)
            + ["a"] + [String](repeating: "##a", count: 49)
        try assertEncoding(first + " " + second, tokens: all)
    }

    func testSpecialTokensCountTowardPayloadAndDoNotSuppressOuterTokens() throws {
        let text = String(repeating: "[CLS][SEP][MASK]", count: 60)
        let payload = (0..<126).map { ["[CLS]", "[SEP]", "[MASK]"][$0 % 3] }
        try assertEncoding(text, tokens: payload)
        try assertEncoding("[CLS][SEP]", tokens: ["[CLS]", "[SEP]"])
    }

    func testConfigurableSequenceLengthReservesBothBoundaryTokens() throws {
        try assertEncoding("Hello world", tokens: [], length: 2)
        try assertEncoding("Hello world", tokens: ["Hello"], length: 3)
        try assertEncoding("Hello", tokens: ["Hello"], length: 5)
        for length in [-1, 0, 1] {
            XCTAssertThrowsError(try WordPieceTokenizer(vocabulary: Self.vocabulary, sequenceLength: length)) {
                XCTAssertEqual($0 as? TokenizerError, .sequenceLengthTooSmall)
            }
        }
    }

    func testMissingRequiredSpecialTokensAreRejected() {
        for token in ["[CLS]", "[SEP]", "[PAD]", "[UNK]"] {
            let vocabulary = Self.vocabulary.filter { $0 != token }
            XCTAssertThrowsError(try WordPieceTokenizer(vocabulary: vocabulary)) {
                XCTAssertEqual($0 as? TokenizerError, .missingSpecialToken(token))
            }
        }
    }

    func testByteIdenticalDuplicateVocabularyEntriesAreRejected() {
        XCTAssertThrowsError(try WordPieceTokenizer(vocabulary: Self.vocabulary + ["Hello"])) {
            XCTAssertEqual($0 as? TokenizerError, .duplicateVocabularyToken("Hello"))
        }
    }

    func testRepeatedEncodingHasNoMutableCarryover() throws {
        let tokenizer = try WordPieceTokenizer(vocabulary: Self.vocabulary)
        let first = tokenizer.encode("Hello中[MASK]e\u{0301}")
        _ = tokenizer.encode(String(repeating: "a", count: 1000))
        _ = tokenizer.encode("")
        let second = tokenizer.encode("Hello中[MASK]e\u{0301}")
        XCTAssertEqual(first.inputIDs, second.inputIDs)
        XCTAssertEqual(first.attentionMask, second.attentionMask)
    }
}