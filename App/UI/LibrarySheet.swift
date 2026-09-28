import SwiftUI
import Photos
import UIKit

@MainActor
struct LibrarySheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showLimitedPicker = false
    @State private var detailsExpanded = false
    @State private var placesExpanded = false

    var body: some View {
        NavigationStack {
            Form {
                if state.canRead {
                    coverageSection
                    accessSection
                } else {
                    accessSection
                    coverageSection
                }
                errorSection
                cloudSection
                if state.debugToolsEnabled {
                    detailsSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(IQStyle.background)
            .tint(IQStyle.accent)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("close-library")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: state.debugToolsEnabled) { _, enabled in
            if !enabled {
                detailsExpanded = false
                placesExpanded = false
            }
        }
        .sheet(isPresented: $showLimitedPicker, onDismiss: {
            // The completion only dismisses. Refresh once here, including swipe dismissal.
            state.libraryChanged()
        }) {
            LimitedLibraryPicker { showLimitedPicker = false }
        }
    }

    private var accessSection: some View {
        Section("Photos access") {
            VStack(alignment: .leading, spacing: 6) {
                Label(accessTitle, systemImage: state.canRead ? "checkmark.circle" : "photo.on.rectangle")
                    .font(.headline)
                    .foregroundStyle(IQStyle.accent)
                Text(accessDescription)
                    .font(.subheadline)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            if state.authorization == .notDetermined {
                Button("Choose photos", systemImage: "photo.badge.plus") { state.authorize() }
                    .accessibilityIdentifier("authorize-photos")
                    .frame(minHeight: 44)
            } else {
                if state.authorization == .limited {
                    Button("Manage selected photos", systemImage: "photo.stack") { showLimitedPicker = true }
                        .frame(minHeight: 44)
                }
                Button(state.canRead ? "Manage access in Settings" : "Open Settings", systemImage: "arrow.up.right.square") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .frame(minHeight: 44)
            }
        }
        .listRowBackground(IQStyle.surface)
    }

    private var coverageSection: some View {
        Section {
            if state.canRead {
                if state.activity == .refreshing || state.activity == .clearing {
                    ProgressView(state.activity == .clearing ? "Clearing local index…" : "Checking authorized photos…")
                } else if state.activity == .indexing {
                    scanProgress
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(state.summary.indexedCount.formatted()) / \(state.summary.authorizedCount.formatted())")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(IQStyle.accent)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Ready / authorized photos")
                            .font(.subheadline.weight(.medium))
                        Text("At the last library check")
                            .font(.caption)
                            .foregroundStyle(IQStyle.secondary)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(state.summary.indexedCount) of \(state.summary.authorizedCount) authorized photos ready at the last library check")
                }
            }

            if state.activity != .indexing {
                Text(coverageDescription)
                    .font(.subheadline)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if modelProblem != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Search isn't ready", systemImage: "exclamationmark.circle")
                        .font(.headline)
                    Text("Indexing and search are unavailable right now. You can still choose Photos access; your original photos are unchanged.")
                        .font(.subheadline)
                        .foregroundStyle(IQStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if state.activity == .indexing {
                Button("Stop", systemImage: "stop.fill") { state.cancel() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityHint("Stops indexing and keeps completed work")
            } else {
                Button { state.index() } label: {
                    Label("Index / resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(IQStyle.background)
                .disabled(!state.canIndex)
                .accessibilityIdentifier("index-photos")
            }

            if state.canRead && state.activity != .indexing && state.progress.total > 0 {
                scanProgress
            }
        } header: {
            Text("Search coverage")
        } footer: {
            Text("Keep the app open while indexing; completed work is saved.")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(state.activity == .indexing ? "Current scan" : "Last scan", systemImage: "photo.stack")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IQStyle.accent)
            if state.activity == .indexing {
                if state.progress.total > 0 {
                    ProgressView(value: state.progress.fraction)
                        .accessibilityLabel("Photos checked")
                        .accessibilityValue("\(state.progress.completed) of \(state.progress.total)")
                } else {
                    ProgressView("Preparing photos…")
                }
            }
            if state.progress.total > 0 {
                Text("\(state.progress.completed.formatted()) of \(state.progress.total.formatted()) checked")
                    .font(.subheadline.weight(.medium))
            }
            LabeledContent("Ready", value: (state.progress.encoded + state.progress.reused).formatted())
            if state.progress.cloudSkipped > 0 {
                LabeledContent("Missing previews", value: state.progress.cloudSkipped.formatted())
                Text("Missing previews need iCloud access; those photos are not searchable yet.")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            }
            if state.progress.failed > 0 {
                LabeledContent("Read errors", value: state.progress.failed.formatted())
            }
            if state.debugToolsEnabled {
                placeProgress
            }
            Text(state.activity == .indexing
                 ? "This scan only; saved index totals update when it finishes."
                 : "Last scan only, including any work completed before stopping. Not whole-library totals.")
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
            if state.activity != .indexing {
                Button("Refresh coverage", systemImage: "arrow.clockwise") { state.refresh() }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy)
                    .frame(minHeight: 44)
            }
        }
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }

    private var placeProgress: some View {
        DisclosureGroup(isExpanded: $placesExpanded) {
            if state.progress.placeChecked > 0 {
                LabeledContent("Locations checked", value: state.progress.placeChecked.formatted())
                LabeledContent("With GPS", value: state.progress.gpsCount.formatted())
                LabeledContent("Place labels found", value: state.progress.placeResolved.formatted())
                LabeledContent("No GPS", value: state.progress.noGPS.formatted())
                LabeledContent("No usable place pack", value: state.progress.noPlacePack.formatted())
                LabeledContent("Outside pack coverage", value: state.progress.outsidePlaceCoverage.formatted())
                LabeledContent("Location unavailable", value: state.progress.placeUnavailable.formatted())
                LabeledContent("Saved place updates", value: state.progress.placeUpdated.formatted())
                Text("Location observations include photos whose images couldn't be indexed. Unavailable means the photo's location couldn't be read or used, not that it has no GPS.")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
                Text("Saved place updates can add, change or remove labels, or refresh their coverage information.")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            } else {
                Text("GPS and place-label counts are unknown until photo locations are checked. Saved labels are separate, in Details.")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.activity == .indexing ? "Places · current scan" : "Places · last scan")
                    .font(.subheadline.weight(.medium))
                Text(state.progress.placeChecked > 0
                     ? "\(state.progress.gpsCount.formatted()) with GPS · \(state.progress.placeResolved.formatted()) labels found"
                     : "Photo locations not checked")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            }
        }
        .accessibilityIdentifier("debug-scan-places")
    }

    @ViewBuilder private var errorSection: some View {
        if state.errorMessage != nil && modelProblem == nil {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn't finish that action", systemImage: "exclamationmark.circle")
                        .font(.headline)
                    Text(state.canRead
                         ? "Refresh the library, then try again. Your original photos are unchanged."
                         : "Check Photos access above, then refresh the library.")
                        .font(.subheadline)
                        .foregroundStyle(IQStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Button("Refresh library", systemImage: "arrow.clockwise") { state.refresh() }
                    .disabled(state.isBusy)
                    .frame(minHeight: 44)
            }
            .listRowBackground(IQStyle.surface)
        }
    }

    private var cloudSection: some View {
        Section {
            Toggle("Use iCloud when needed", isOn: $state.allowICloudDownload)
                .disabled(state.isBusy)
                .accessibilityIdentifier("icloud-download-opt-in")
        } header: {
            Text("iCloud")
        } footer: {
            Text("Indexing uses previews already on your phone. Off means no image downloads for indexing. On lets Photos download missing image data over Wi-Fi or mobile data only when no local preview is available. Photos controls the download size; the app doesn't request originals.")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var detailsSection: some View {
        Section {
            DisclosureGroup("Details", isExpanded: $detailsExpanded) {
                diagnostic("Status", state.status)
                LabeledContent("Authorized photos", value: state.summary.authorizedCount.formatted())
                LabeledContent("Current index at last check", value: state.summary.indexedCount.formatted())
                LabeledContent("Saved place labels at last check", value: state.summary.locatedCount.formatted())
                Text("Labels saved on indexed photos, not a GPS count or last-scan observations.")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                if state.progress.total > 0 {
                    diagnostic(state.activity == .indexing ? "Current scan" : "Last scan", state.progress.summary)
                }
                if let failure = state.progress.lastFailure {
                    diagnostic("Last skipped-photo issue", failure)
                }
                if let issue = modelProblem { diagnostic("Model check", issue) }
                if let error = state.errorMessage, error != modelProblem {
                    diagnostic("Last operation issue", error)
                }
                diagnostic("Preview requests", "Indexing tries a high-quality local preview at short edge 224 first, then a fast local preview if unavailable. Originals are not requested. Only when both are unavailable and iCloud access is on may Photos download image data using Wi-Fi or mobile data; Photos controls the download size. Off keeps both preview requests offline.")
                    .accessibilityIdentifier("debug-indexing-info")
                Text("\(PhotoIndexWorker.indexingWorkerCount) image workers · reads and encodes photos concurrently")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("High quality 224 first · fast local fallback · higher concurrency uses more memory and may cause iOS to close the app.")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Unchanged completed records are reused. Source counts describe newly encoded photos in that scan; online-fallback counts are not download or byte counts. Reduced previews can affect matches and are reused until the photo or index version changes.")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("debug-library-details")
        }
        .listRowBackground(IQStyle.surface)
    }

    private func diagnostic(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(IQStyle.secondary)
            Text(IQStyle.diagnosticText(value))
                .font(.footnote)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var accessTitle: String {
        switch state.authorization {
        case .authorized: return "Full access"
        case .limited: return "Selected photos"
        case .denied: return "Photos access is off"
        case .restricted: return "Photos access is restricted"
        default: return "Connect your photos"
        }
    }

    private var accessDescription: String {
        switch state.authorization {
        case .authorized:
            return state.activity == .refreshing
                ? "Updating your authorized photo count…"
                : "\(state.summary.authorizedCount.formatted()) authorized images in your library."
        case .limited:
            return state.activity == .refreshing
                ? "Updating your selected photo count…"
                : "\(state.summary.authorizedCount.formatted()) authorized images. Only your selected photos are visible."
        case .denied: return "Allow selected photos or full access in Settings."
        case .restricted: return "This device's restrictions limit Photos access."
        default: return "Choose a few photos or your library. Your originals stay in Photos."
        }
    }

    private var coverageDescription: String {
        if !state.canRead { return "Connect Photos to see what is ready to search." }
        if state.activity == .refreshing || state.activity == .clearing { return "Updating search coverage…" }
        if !state.modelsReady { return "Indexing and search are not ready yet." }
        if state.summary.authorizedCount == 0 { return "No images are available with the current Photos access." }
        if state.summary.indexedCount < state.summary.authorizedCount {
            return "Coverage is incomplete. Photos without an index entry are not searchable yet; index or resume to try them."
        }
        return "Ready to search based on the last library check."
    }

    private var modelProblem: String? {
        if let issue = state.summary.modelIssue { return issue }
        // An indexing failure may arrive before a new LibrarySummary is published.
        if let error = state.errorMessage,
           error.hasPrefix("Models unavailable:") || error.hasPrefix("Model contract mismatch:") {
            return error
        }
        return nil
    }
}