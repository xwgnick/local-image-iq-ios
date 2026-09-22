import SwiftUI
import Photos
import UIKit
import ImageIQCore

@MainActor
struct ContentView: View {
    @ObservedObject var state: AppState
    @Environment(\.openURL) private var openURL
    @State private var showLimitedPicker = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    accessCard
                    modelNotice
                    indexCard
                    searchCard
                    results
                    privacyNote
                }
                .padding(20)
                .frame(maxWidth: 850)
                .frame(maxWidth: .infinity)
            }
            .background(LinearGradient(colors: [Color(red: 0.12, green: 0.07, blue: 0.23), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
            .navigationTitle("Local Image IQ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh authorized library", systemImage: "arrow.clockwise") { state.refresh() }
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Clear local index", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Library actions")
                }
            }
            .confirmationDialog("Delete the local index? Your original photos will not be changed.", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete local index", role: .destructive) { state.clearIndex() }
            }
            .sheet(isPresented: $showLimitedPicker, onDismiss: { state.libraryChanged() }) {
                LimitedLibraryPicker {
                    showLimitedPicker = false
                    state.libraryChanged()
                }
            }
            .fullScreenCover(item: $state.selection) { selection in
                PhotoPreviewView(id: selection.id, library: state.library, networkAllowed: state.allowICloudDownload)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("PRIVATE BY DESIGN", systemImage: "lock.shield")
                .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.purple.opacity(0.95))
            Text("Your memories.\nYour words.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Find images by meaning, right on your device.")
                .foregroundStyle(.secondary)
        }.padding(.vertical, 12)
    }

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("01  ·  Connect Photos", systemImage: "photo.stack")
                .font(.headline)
            Text(accessDescription).font(.subheadline).foregroundStyle(.secondary)
            if state.authorization == .notDetermined {
                Button("Choose photo access") { state.authorize() }.buttonStyle(.borderedProminent)
            } else if state.authorization == .limited {
                Button("Manage selected photos") { showLimitedPicker = true }.buttonStyle(.borderedProminent)
                Button("Refresh selection") { state.refresh() }.buttonStyle(.bordered)
            } else if !state.canRead {
                Button("Open Photos permission settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.buttonStyle(.borderedProminent)
            } else {
                Label("Photos connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Manage access in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.font(.subheadline)
            }
        }.iqCard()
    }

    private var accessDescription: String {
        switch state.authorization {
        case .authorized: return "Full image-library access. Only images you authorize are indexed."
        case .limited: return "Limited access is supported. Only your selected images are visible here."
        case .denied: return "Access is off. Enable Selected Photos or Full Access in Settings."
        case .restricted: return "Photos access is restricted by this device's settings or management policy."
        default: return "Choose a few photos or your library. Originals stay in Photos; this app never changes them."
        }
    }

    @ViewBuilder private var modelNotice: some View {
        if let issue = state.summary.modelIssue {
            VStack(alignment: .leading, spacing: 10) {
                Label("Model unavailable", systemImage: "exclamationmark.triangle").font(.headline)
                Text(issue).font(.subheadline)
                Button("Recheck bundled models") { state.refresh() }
            }.foregroundStyle(.orange).iqCard()
        }
        if let error = state.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.subheadline)
                if let action = state.actionHint { Text(action).font(.caption).foregroundStyle(.secondary) }
                Button("Dismiss") { state.dismissError() }
            }.foregroundStyle(.orange).iqCard()
        }
    }

    private var indexCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("02  ·  Build your local index", systemImage: "sparkles.rectangle.stack").font(.headline)
            HStack(alignment: .top, spacing: 24) {
                metric(state.summary.authorizedCount, "authorized images")
                metric(state.summary.indexedCount, "current indexed")
                metric(state.summary.locatedCount, "offline place labels")
            }
            Toggle("Fetch missing images from iCloud", isOn: $state.allowICloudDownload)
                .disabled(state.isBusy)
                .accessibilityIdentifier("icloud-download-opt-in")
            Text("Indexing uses locally available previews first, including reduced-quality images, without requesting originals. When off, it stays offline. Enable only to fetch missing images on demand; Photos controls the actual download size and may use mobile data. You do not need to download your entire library first.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Index / resume", systemImage: "play.fill") { state.index() }
                    .buttonStyle(.borderedProminent).disabled(!state.canIndex)
                    .accessibilityIdentifier("index-photos")
                if state.isBusy {
                    Button("Cancel", role: .cancel) { state.cancel() }.buttonStyle(.bordered)
                }
            }
            if state.activity == .indexing {
                ProgressView(value: state.progress.fraction)
            } else if state.isBusy { ProgressView() }
            if state.progress.completed > 0 {
                Text(state.progress.summary).font(.caption).foregroundStyle(.secondary)
                if let failure = state.progress.lastFailure {
                    Text("Last skipped-image issue: \(failure)").font(.caption).foregroundStyle(.orange)
                }
            }
            Text(state.status).font(.footnote).foregroundStyle(.secondary)
            Text("Keep the app in the foreground. Completed records are kept. This preview-index update rebuilds the previous index once; later runs reuse unchanged records.")
                .font(.caption).foregroundStyle(.secondary)
        }.iqCard()
    }

    private func metric(_ value: Int, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value, format: .number).font(.title2.bold()).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("03  ·  Describe a memory", systemImage: "magnifyingglass").font(.headline)
            TextField("A dog playing on the beach…", text: $state.query, axis: .vertical)
                .textFieldStyle(.plain).padding(14).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                .submitLabel(.search).onSubmit { state.search() }
                .accessibilityIdentifier("photo-query")
            Picker("Results", selection: $state.resultLimit) {
                Text("Top 3").tag(3)
                Text("Top 12").tag(12)
            }.pickerStyle(.segmented)
            HStack {
                Text("Location contribution").font(.subheadline)
                Spacer()
                Text(state.locationWeight, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }
            Slider(value: $state.locationWeight, in: 0...1, step: 0.01) { Text("Location contribution") }
                .accessibilityIdentifier("location-weight")
            Text("0% = image only · 100% = place only. Missing places contribute zero; at 100%, their scores are zero and can outrank negative place scores. This is a soft score, not a location filter.")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(state.summary.locatedCount) of \(state.summary.indexedCount) indexed photos have an offline label. \(state.summary.placesDescription)")
                .font(.caption).foregroundStyle(.secondary)
            Button("Search locally", systemImage: "magnifyingglass") { state.search() }
                .buttonStyle(.borderedProminent).disabled(!state.canSearch)
                .accessibilityIdentifier("search-photos")
        }.iqCard()
    }

    @ViewBuilder private var results: some View {
        if !state.results.isEmpty {
            Text("Closest matches").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                ForEach(state.results) { hit in
                    Button { state.selection = AppState.Selection(id: hit.photo.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            PhotoThumbnailView(photo: hit.photo, cache: state.thumbnails, networkAllowed: state.allowICloudDownload)
                            Text("Score \(hit.score.formatted(.number.precision(.fractionLength(3))))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.primary)
                            Text(hit.photo.location?.text ?? "No offline place label")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain).accessibilityLabel("Open matching photo, score \(hit.score)")
                }
            }
        } else if state.summary.indexedCount == 0 {
            ContentUnavailableView("Start with your photos", systemImage: "photo.on.rectangle.angled",
                                   description: Text("Authorize images, then build the local index. No sample results or synthetic embeddings are used."))
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("On-device search. No application server.", systemImage: "lock.fill")
            Text("The local cache stores authorized photo IDs, revisions, embeddings and optional place labels—not originals or GPS. It is excluded from backups and protected until the first unlock after restart.")
            Text("Preview index v1 · Image + optional place-text retrieval only. Reduced-quality inputs can affect matches. No OCR, date filters, agentic search or production search-stack integration. Native resizing is not pixel-identical to the reference preprocessing.")
        }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
    }
}

private extension View {
    func iqCard() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.09), lineWidth: 1))
    }
}