import SwiftUI
import Photos
import UIKit

@MainActor
struct LibrarySheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showLimitedPicker = false

    var body: some View {
        NavigationStack {
            Form {
                accessSection
                coverageSection
                errorSection
                cloudSection
                detailsSection
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
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(state.summary.indexedCount.formatted()) / \(state.summary.authorizedCount.formatted())")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
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

            Text(coverageDescription)
                .font(.subheadline)
                .foregroundStyle(IQStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if modelProblem != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Requires a model-enabled build", systemImage: "shippingbox")
                        .font(.headline)
                    Text("Install a build with the on-device models to index and search. You can still choose Photos access. Technical information is in Details.")
                        .font(.subheadline)
                        .foregroundStyle(IQStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Button { state.index() } label: {
                Label("Index / resume", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(IQStyle.background)
            .disabled(!state.canIndex)
            .accessibilityIdentifier("index-photos")

            if state.activity == .indexing {
                Button("Stop", systemImage: "stop.fill") { state.cancel() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityHint("Stops indexing and keeps completed work")
            }

            if state.canRead && (state.activity == .indexing || state.progress.total > 0) {
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
        VStack(alignment: .leading, spacing: 12) {
            Text(state.activity == .indexing ? "Current scan" : "Last scan")
                .font(.subheadline.weight(.semibold))
            if state.activity == .indexing {
                if state.progress.total > 0 {
                    ProgressView(value: state.progress.fraction)
                        .accessibilityLabel("Photos checked")
                        .accessibilityValue("\(state.progress.completed) of \(state.progress.total)")
                } else {
                    ProgressView("Preparing photos…")
                }
            }
            Text("\(state.progress.completed.formatted()) of \(state.progress.total.formatted()) checked")
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
            LabeledContent("Ready", value: (state.progress.encoded + state.progress.reused).formatted())
            LabeledContent("Missing previews", value: state.progress.cloudSkipped.formatted())
            LabeledContent("Read errors", value: state.progress.failed.formatted())
            if state.progress.cloudSkipped > 0 {
                Text("Missing previews need iCloud access; those photos are not searchable yet.")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            }
            if state.activity != .indexing {
                Text("These counts describe the last scan, not the whole index. Refresh to check saved coverage.")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
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
            Text("Local previews come first, including reduced-quality previews; indexing does not request originals. When this is on, Photos may download image data for missing previews using Wi-Fi or mobile data, and controls the download size. No whole-library download is required. Off keeps photo requests offline.")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var detailsSection: some View {
        Section {
            DisclosureGroup("Details") {
                diagnostic("Status", state.status)
                LabeledContent("Authorized photos", value: state.summary.authorizedCount.formatted())
                LabeledContent("Current index at last check", value: state.summary.indexedCount.formatted())
                LabeledContent("Offline place labels", value: state.summary.locatedCount.formatted())
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
                Text("Unchanged completed records are reused. Source counts describe newly encoded photos in that scan; online-fallback counts are not download or byte counts. Reduced previews can affect matches and are reused until the photo or index version changes.")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        if state.activity == .indexing { return "Building your index on this device. Live scan counts appear below." }
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