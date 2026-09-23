import Foundation
import SwiftUI

@MainActor
struct PhotoCheckSheet: View {
    @ObservedObject var state: AppState
    let photoID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isQueryFocused: Bool
    @State private var query: String
    @State private var showAdvanced = false

    init(state: AppState, photoID: String, initialQuery: String) {
        self.state = state
        self.photoID = photoID
        _query = State(initialValue: initialQuery)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isChecking: Bool { state.activity == .checkingPhoto }
    private var canCheck: Bool {
        !state.isBusy && state.canRead && !photoID.isEmpty && !trimmedQuery.isEmpty
    }

    private var currentReport: PhotoDiagnosticReport? {
        guard let report = state.photoCheckReport,
              report.photoID == photoID,
              report.query.utf8.elementsEqual(query.utf8) else { return nil }
        return report
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Enter the search that missed this photo. Tap Check, then send a screenshot.")
                        .font(.subheadline)
                        .foregroundStyle(IQStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    queryControls

                    if let report = currentReport {
                        resultCard(report)
                        advancedDetails(report)
                    } else if let issue = state.photoCheckIssue {
                        issueView(title: "Couldn't complete this check", message: issue)
                    }

                    Text("This check stays on your device. It does not change the saved index or download photos from iCloud.")
                        .font(.caption)
                        .foregroundStyle(IQStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(IQStyle.background)
            .navigationTitle("Photo check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isQueryFocused = false
                        state.dismissPhotoCheck()
                        dismiss()
                    }
                    .accessibilityIdentifier("close-photo-check")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isQueryFocused = false }
                        .accessibilityLabel("Hide keyboard")
                        .accessibilityIdentifier("photo-check-keyboard-done")
                }
            }
        }
        .tint(IQStyle.accent)
        .preferredColorScheme(.dark)
        .onChange(of: query) { previous, updated in
            // Local edits only: never write back to the gallery's search query
            // or seed this field from a report, which could create a feedback loop.
            guard previous != updated else { return }
            state.dismissPhotoCheck()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                isQueryFocused = false
                state.dismissPhotoCheck()
            }
        }
        .onDisappear { state.dismissPhotoCheck() }
    }

    private var queryControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Enter a search", text: $query)
                .focused($isQueryFocused)
                .submitLabel(.search)
                .onSubmit(runCheck)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(isQueryFocused ? IQStyle.accent : .white.opacity(0.1), lineWidth: 1))
                .accessibilityLabel("Search that missed this photo")
                .accessibilityIdentifier("photo-check-query")

            Button(action: runCheck) {
                Text("Check")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(IQStyle.background)
            .disabled(!canCheck)
            .accessibilityIdentifier("run-photo-check")

            if isChecking {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView("Checking this photo…")
                        .tint(IQStyle.accent)
                        .accessibilityIdentifier("photo-check-running")
                    Button { state.dismissPhotoCheck() } label: {
                        Text("Cancel").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("cancel-photo-check")
                }
            } else if state.isBusy {
                Text("Wait for the current task to finish, then tap Check.")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            }
        }
    }

    private func resultCard(_ report: PhotoDiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline(report))
                .font(.title3.weight(.bold))
                .foregroundStyle(IQStyle.accent)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 4) {
                Text("Original query").font(.caption).foregroundStyle(IQStyle.secondary)
                Text(report.query).font(.body.weight(.medium))
            }

            VStack(spacing: 8) {
                detailRow("Saved index", value: rankText(report.cachedRank))
                detailRow("Fresh local preview", value: rankText(report.freshRank))
                detailRow("Gallery photos", value: report.galleryCount.formatted())
                Divider().overlay(.white.opacity(0.08))
                detailRow("Requested pixels", value: dimensions(report.requestedWidth, report.requestedHeight))
                detailRow("Returned pixels", value: dimensions(report.pixelWidth, report.pixelHeight))
                detailRow("Reduced flag", value: report.degraded.map { $0 ? "Yes" : "No" } ?? "Unknown")
                detailRow("Vector cosine", value: scalar(report.cachedFreshCosine))
            }

            if report.cachedStatus != "current" {
                Text(cacheStatus(report.cachedStatus))
                    .font(.subheadline)
                    .foregroundStyle(IQStyle.secondary)
            }
            if let issue = report.freshIssue {
                issueView(title: "Fresh preview unavailable", message: issue)
            }

            Text("Lower rank is better. A rank change does not explain why the search missed this photo.")
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
            Text("Index unchanged · No iCloud download")
                .font(.caption.weight(.semibold))
                .foregroundStyle(IQStyle.accent)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("photo-check-result")
    }

    private func advancedDetails(_ report: PhotoDiagnosticReport) -> some View {
        DisclosureGroup("Advanced details", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                detailRow("Saved score", value: scalar(report.cachedScore))
                detailRow("Fresh score", value: scalar(report.freshScore))
                detailRow("Vector cosine", value: scalar(report.cachedFreshCosine))
                detailRow("Location weight", value: report.locationWeight.formatted(.percent.precision(.fractionLength(0))))
                detailRow("Orientation", value: orientation(report.orientationRawValue))
                detailRow("Preview source", value: source(report.source))
                detailRow("Saved entry", value: cacheStatus(report.cachedStatus))
                detailRow("Historical input dimensions", value: "Not recorded")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cache version").foregroundStyle(IQStyle.secondary)
                    Text(safeText(report.modelVersion)).textSelection(.enabled)
                }
                Text("Scores are not probabilities. Pixel sizes describe this fresh request, before orientation is applied. The reduced flag is reported by Photos, not inferred from size.")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        }
        .padding(16)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("photo-check-advanced")
    }

    private func detailRow(_ title: String, value: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(IQStyle.secondary)
                    Text(value).fontWeight(.medium)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).foregroundStyle(IQStyle.secondary)
                    Spacer(minLength: 0)
                    Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
                }
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func issueView(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold))
            Text(safeText(message)).font(.subheadline).foregroundStyle(IQStyle.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func runCheck() {
        isQueryFocused = false
        guard canCheck else { return }
        state.checkPhoto(id: photoID, query: query)
    }

    private func headline(_ report: PhotoDiagnosticReport) -> String {
        guard let saved = report.cachedRank, let fresh = report.freshRank else { return "Comparison unavailable" }
        if fresh < saved { return "Rank improved" }
        if fresh > saved { return "Rank worse" }
        return "Rank unchanged"
    }

    private func rankText(_ rank: Int?) -> String {
        rank.map { "#\($0.formatted())" } ?? "Unavailable"
    }

    private func dimensions(_ width: Int?, _ height: Int?) -> String {
        guard let width, let height else { return "Unknown" }
        return "\(width) × \(height)"
    }

    private func scalar(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(6)))
    }

    private func cacheStatus(_ value: String) -> String {
        switch value {
        case "current": return "Up to date"
        case "missing": return "This photo is not in the saved index. Ranks are unavailable."
        case "stale": return "The saved entry is out of date. Ranks are unavailable."
        default: return "Unknown"
        }
    }

    private func source(_ value: String?) -> String {
        switch value {
        case "localPreview": return "Local preview"
        case "localReducedPreview": return "Local reduced preview"
        case "networkPreview": return "Network preview"
        default: return "Unknown"
        }
    }

    private func orientation(_ value: UInt32?) -> String {
        switch value {
        case 1: return "Up (1)"
        case 2: return "Up, mirrored (2)"
        case 3: return "Down (3)"
        case 4: return "Down, mirrored (4)"
        case 5: return "Left, mirrored (5)"
        case 6: return "Right (6)"
        case 7: return "Right, mirrored (7)"
        case 8: return "Left (8)"
        default: return "Unknown"
        }
    }

    private func safeText(_ text: String) -> String {
        let redacted = photoID.isEmpty ? text : text.replacingOccurrences(of: photoID, with: "[photo identifier hidden]")
        return IQStyle.diagnosticText(redacted)
    }
}