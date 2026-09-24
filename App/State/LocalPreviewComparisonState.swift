import Combine
import Foundation

/// Sheet-local work only: no indexing worker, encoder, persistence or AppState.
@MainActor
final class LocalPreviewComparisonState: ObservableObject {
    @Published private(set) var result: LocalPreviewComparison?
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    private let service: any LocalPreviewComparing
    private let photoID: String
    private var generation = UUID()
    private var taskID: UUID?
    private var operationTask: Task<Void, Never>?

    init(service: any LocalPreviewComparing, photoID: String) {
        self.service = service
        self.photoID = photoID
    }

    deinit { operationTask?.cancel() }

    func start() {
        // Repeated taps/appearance callbacks must not enqueue more comparisons.
        guard !isRunning else { return }
        let predecessor = operationTask
        predecessor?.cancel()
        let token = UUID()
        generation = token
        taskID = token
        result = nil
        errorMessage = nil
        isRunning = true

        operationTask = Task { @MainActor [weak self, service = self.service, photoID = self.photoID] in
            defer { self?.finish(token) }
            // Cancellation alone is not a completion boundary. Even a service
            // that delivers a late callback must drain before the next request.
            await predecessor?.value
            guard !Task.isCancelled, self?.generation == token else { return }
            do {
                let comparison = try await service.compareLocalPreviews(id: photoID)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                // Check the entire snapshot (revision AND authorization) through
                // the service immediately before publishing, with no intervening await.
                guard comparison.photoID == photoID,
                      comparison.revision.id == photoID,
                      service.isCurrent(comparison) else {
                    self.errorMessage = "照片或访问权限已变化，请关闭后重新打开对比。"
                    return
                }
                self.result = comparison
            } catch {
                guard let self, self.generation == token,
                      !Task.isCancelled, !(error is CancellationError) else { return }
                // Never surface localizedDescription: PhotoKit/service errors can
                // contain private asset identifiers, paths or other photo metadata.
                self.errorMessage = "未能完成本地预览对比。请确认仍可访问这张照片，保持应用在前台后重试。"
            }
        }
    }

    func cancelAndClear() {
        generation = UUID()
        operationTask?.cancel()
        result = nil
        errorMessage = nil
        isRunning = false
        // Keep the tail until it drains; start() must await it, not overlap it.
    }

    /// Includes cancelled predecessors and any replacement scheduled while waiting.
    func waitUntilIdle() async {
        while let task = operationTask { await task.value }
    }

    private func finish(_ token: UUID) {
        if generation == token { isRunning = false }
        // An old completion must never clear a newer task's handle or running flag.
        if taskID == token {
            operationTask = nil
            taskID = nil
        }
    }
}