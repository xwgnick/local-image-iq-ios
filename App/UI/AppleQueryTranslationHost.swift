import SwiftUI
import Translation

/// Mount .search in the root background, and .preparation in the Settings sheet
/// background so Apple's explicit download prompt has the current presenter.
/// Keep the service instance stable. Scene inactivity is deliberately ignored:
/// a system permission prompt can make the scene inactive without backgrounding.
@MainActor
struct AppleQueryTranslationHost: View {
    typealias Purpose = AppleQueryTranslationService.Purpose

    @ObservedObject private var service: AppleQueryTranslationService
    private let purpose: Purpose
    @State private var hostID = UUID()

    init(service: AppleQueryTranslationService, purpose: Purpose) {
        _service = ObservedObject(wrappedValue: service)
        self.purpose = purpose
    }

    var body: some View {
        // A stable container owns registration; inserting/removing a job child
        // must not run the presenter's disappearance hook between requests.
        ZStack {
            Color.clear
            #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
            if #available(iOS 18.0, *),
               let job = service.job, job.hostID == hostID, job.purpose == purpose {
                AppleQueryTranslationJobHost(service: service, job: job)
                    .id(job.id)
            }
            #endif
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if service.isSupported { service.registerHost(id: hostID, purpose: purpose) }
        }
        .onDisappear {
            service.unregisterHost(id: hostID, purpose: purpose)
        }
    }
}

#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
@available(iOS 18.0, *)
@MainActor
private struct AppleQueryTranslationJobHost: View {
    private let service: AppleQueryTranslationService
    private let job: AppleQueryTranslationService.Job
    private let configuration: TranslationSession.Configuration

    init(service: AppleQueryTranslationService, job: AppleQueryTranslationService.Job) {
        self.service = service
        self.job = job
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: job.language.rawValue),
            target: Locale.Language(identifier: "en")
        )
    }

    var body: some View {
        Color.clear
            .translationTask(configuration) { @MainActor session in
                guard service.beginJob(id: job.id, hostID: job.hostID) else { return }
                let outcome: Result<AppleQueryTranslationService.Job.Output, Error>
                do {
                    // Fresh LanguageAvailability check INSIDE the provided
                    // closure, not just the public method's earlier preflight.
                    let status = try await service.availability(for: job)
                    try service.checkActiveJob(job.id)
                    try AppleQueryTranslationService.requireAvailability(status, for: job.purpose)

                    switch job.kind {
                    case .translation(let text):
                        // .installed is required. Never prepare/download here.
                        try service.checkActiveJob(job.id)
                        let response = try await session.translate(text)
                        try service.checkActiveJob(job.id)
                        guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw QueryTranslationFailure.emptyResult
                        }
                        outcome = .success(.translated(response.targetText))

                    case .preparation:
                        if status != .installed {
                            try service.checkActiveJob(job.id)
                            try await session.prepareTranslation()
                            try service.checkActiveJob(job.id)
                        }
                        // Preparation may return while a download is still in
                        // progress. Do not report ready until packs are installed.
                        let refreshed = try await service.availability(for: job)
                        try service.checkActiveJob(job.id)
                        try AppleQueryTranslationService.requireAvailability(refreshed, for: .search)
                        outcome = .success(.prepared)
                    }
                } catch {
                    outcome = .failure(AppleQueryTranslationService.typedFailure(error))
                }
                // Last synchronous action; the service defers continuation
                // resumption/child removal until this MainActor closure returns.
                // The session is NEVER stored, returned or captured by a Task.
                service.finishAfterClosure(id: job.id, result: outcome)
            }
            .onDisappear {
                service.jobHostDisappeared(id: job.id, hostID: job.hostID)
            }
    }
}
#endif