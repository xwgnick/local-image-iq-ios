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

    func encode(_ text: String) throws -> TokenizedText {
        // Swift's Unicode lowercasing still requires exact multilingual parity fixtures
        // against the exporter's reference tokenizer; do not claim blanket equivalence.
        let encoded = tokenizer.encode(text: text.lowercased(), addSpecialTokens: false)
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