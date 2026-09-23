import Foundation
import ImageIQCore
import Tokenizers

/// Local-only SigLIP 2 text preprocessing. CoreMLEncoders owns the shared load task.
struct SigLIPTokenizer: Sendable {
    private let tokenizer: any Tokenizer

    static func load(directory: URL) async throws -> SigLIPTokenizer {
        try Task.checkCancellation()
        guard directory.isFileURL else {
            throw AppFailure.modelsMissing("the tokenizer must be loaded from a local directory")
        }
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw AppFailure.modelsMissing("\(name) is missing from the tokenizer directory")
            }
        }
        // This overload only reads the local folder. Never use pretrained/Hub loading
        // or a permissive tokenizer fallback when bundled files are missing/unsupported.
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory, strict: true)
        try Task.checkCancellation()
        return SigLIPTokenizer(tokenizer: tokenizer)
    }

    /// Locale-independent default lowercase, including Python str.lower's Final_Sigma rule.
    /// Leave normalization and accent handling to the pinned tokenizer unchanged.
    static func normalizedQuery(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var normalized = ""
        var precededByCased = false
        for (index, scalar) in scalars.enumerated() {
            if scalar.value == 0x03A3 {
                // Context is evaluated on the original input, skipping Case_Ignorable
                // before checking Cased: a scalar such as U+0345 has both properties.
                var nextIndex = index + 1
                while nextIndex < scalars.count && scalars[nextIndex].properties.isCaseIgnorable {
                    nextIndex += 1
                }
                let followedByCased = nextIndex < scalars.count && scalars[nextIndex].properties.isCased
                normalized += precededByCased && !followedByCased ? "\u{03C2}" : "\u{03C3}"
            } else {
                // Keep full, potentially multi-scalar mappings, e.g. İ -> i + U+0307.
                normalized += String(scalar).lowercased()
            }
            if !scalar.properties.isCaseIgnorable {
                precededByCased = scalar.properties.isCased
            }
        }
        return normalized
    }

    func encode(_ text: String) throws -> TokenizedText {
        let encoded = tokenizer.encode(text: Self.normalizedQuery(text), addSpecialTokens: false)
        guard encoded.allSatisfy({ (0..<256_000).contains($0) }) else {
            throw AppFailure.modelContract("Tokenizer IDs must be in 0..<256000.")
        }
        // Truncate content first so EOS is always present, even for an overlong query.
        var ids = encoded.prefix(63).map { Int32($0) }
        ids.append(1)
        let contentLength = ids.count
        ids.append(contentsOf: repeatElement(Int32(0), count: 64 - contentLength))
        let mask = [Int32](repeating: 1, count: contentLength) +
            [Int32](repeating: 0, count: 64 - contentLength)
        // The mask is exposed for parity only; SigLIP 2's CoreML input is IDs alone.
        return TokenizedText(inputIDs: ids, attentionMask: mask)
    }
}