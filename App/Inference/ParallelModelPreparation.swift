import Foundation

/// Three independent initializers, one readiness barrier. This nonisolated async
/// helper schedules structured children rather than synchronous work on the
/// coordinator actor (or MainActor). Actual CPU/Core ML overlap is device-dependent.
enum ParallelModelPreparation {
    private enum Part<Tokenizer: Sendable, Image: Sendable, Text: Sendable>: Sendable {
        case tokenizer(Tokenizer)
        case image(Image)
        case text(Text)
    }

    static func load<Tokenizer: Sendable, Image: Sendable, Text: Sendable>(
        timing: LaunchTimingRecorder?,
        startupProgress: StartupProgressRecorder? = nil,
        tokenizer: @escaping @Sendable () async throws -> Tokenizer,
        image: @escaping @Sendable () async throws -> Image,
        text: @escaping @Sendable () async throws -> Text
    ) async throws -> (tokenizer: Tokenizer, image: Image, text: Text) {
        try Task.checkCancellation()
        timing?.mark(.parallelModels)
        // The task-group scope drains every child even on failure/cancellation;
        // the parent stage must include that drain, not just the first error.
        defer { timing?.mark(.modelAssembly) }
        return try await withThrowingTaskGroup(of: Part<Tokenizer, Image, Text>.self) { group in
            group.addTask {
                .tokenizer(try await measured(.tokenizer, step: .tokenizer, timing: timing,
                                             startupProgress: startupProgress, operation: tokenizer))
            }
            group.addTask {
                .image(try await measured(.imageModel, step: .imageModel, timing: timing,
                                         startupProgress: startupProgress, operation: image))
            }
            group.addTask {
                .text(try await measured(.textModel, step: .textModel, timing: timing,
                                        startupProgress: startupProgress, operation: text))
            }
            var loadedTokenizer: Tokenizer?
            var loadedImage: Image?
            var loadedText: Text?
            for try await part in group {
                switch part {
                case .tokenizer(let value): loadedTokenizer = value
                case .image(let value): loadedImage = value
                case .text(let value): loadedText = value
                }
            }
            try Task.checkCancellation()
            guard let loadedTokenizer, let loadedImage, let loadedText else {
                throw AppFailure.modelContract("Model initialization did not complete.")
            }
            return (loadedTokenizer, loadedImage, loadedText)
        }
    }

    private static func measured<Value: Sendable>(
        _ stage: LaunchTimingStage, step: StartupStep, timing: LaunchTimingRecorder?,
        startupProgress: StartupProgressRecorder?,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        // A child cancelled before execution must not invent a load interval.
        try Task.checkCancellation()
        let span = timing?.beginComponent(stage)
        do {
            let value = try await operation()
            try Task.checkCancellation()
            timing?.endComponent(span, outcome: .completed)
            startupProgress?.complete(step)
            return value
        } catch is CancellationError {
            timing?.endComponent(span, outcome: .interrupted)
            throw CancellationError()
        } catch {
            timing?.endComponent(span, outcome: .failed)
            throw error
        }
    }
}