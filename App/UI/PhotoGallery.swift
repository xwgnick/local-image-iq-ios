import SwiftUI
import Photos
import UIKit
import ImageIQCore

private enum PhotoGalleryStyle {
    static let background = Color(red: 11 / 255, green: 12 / 255, blue: 20 / 255)
    static let surface = Color(red: 22 / 255, green: 23 / 255, blue: 34 / 255)
    static let accent = Color(red: 183 / 255, green: 160 / 255, blue: 1)
}

/// Intrinsic-height content for the parent's ScrollView; never nests a scroll
/// view or measures an unbounded scroll axis. The supplied thumbnail is not a button.
@MainActor
struct PhotoResultsGrid<Thumbnail: View>: View {
    let hits: [SearchHit]
    let compact: Bool
    let onSelect: (String) -> Void
    @ViewBuilder let thumbnail: (IndexedPhoto) -> Thumbnail

    init(hits: [SearchHit], compact: Bool, onSelect: @escaping (String) -> Void,
         @ViewBuilder thumbnail: @escaping (IndexedPhoto) -> Thumbnail) {
        self.hits = hits
        self.compact = compact
        self.onSelect = onSelect
        self.thumbnail = thumbnail
    }

    var body: some View {
        VStack(spacing: 12) {
            if !compact, hits.count <= 3, let first = hits.first {
                tile(first, rank: 1, aspectRatio: 4.0 / 3.0)
                if hits.count > 1 {
                    LazyVGrid(columns: columns(count: 2), spacing: 12) {
                        ForEach(Array(hits.dropFirst().enumerated()), id: \.element.id) { offset, hit in
                            tile(hit, rank: offset + 2, aspectRatio: 1)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: columns(count: compact ? 3 : 2), spacing: 12) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { offset, hit in
                        tile(hit, rank: offset + 1, aspectRatio: compact ? 1 : 4.0 / 5.0)
                    }
                }
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func columns(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12), count: count)
    }

    private func tile(_ hit: SearchHit, rank: Int, aspectRatio: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button {
            onSelect(hit.photo.id)
        } label: {
            // An aspect-constrained base gives even GeometryReader thumbnails
            // a finite height. Overlays cannot enlarge the tile's layout bounds.
            shape.fill(PhotoGalleryStyle.surface)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    thumbnail(hit.photo)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .overlay(alignment: .topLeading) {
                    Text("\(rank)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(minWidth: 28, minHeight: 28)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .padding(10)
                        .accessibilityHidden(true)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.07), lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open result \(rank)")
        .accessibilityIdentifier("result-tile-\(rank)")
    }
}

/// Present from the parent's selection-driven fullScreenCover. The input order
/// is the search order; no sorting, score transformation or synthetic hits.
@MainActor
struct PhotoResultsViewer: View {
    let hits: [SearchHit]
    let initialID: String
    let library: PhotoLibraryClient
    let networkAllowed: Bool
    let state: AppState?

    init(hits: [SearchHit], initialID: String, library: PhotoLibraryClient,
         networkAllowed: Bool, state: AppState? = nil) {
        self.hits = hits
        self.initialID = initialID
        self.library = library
        self.networkAllowed = networkAllowed
        self.state = state
    }

    var body: some View {
        PhotoGalleryViewer(ids: hits.map(\.id), initialID: initialID,
                           library: library, networkAllowed: networkAllowed, state: state)
    }
}

/// Also backs the single-photo compatibility wrapper without manufacturing an
/// IndexedPhoto. Only the selected page owns a full-size display-image request.
@MainActor
struct PhotoGalleryViewer: View {
    let ids: [String]
    let library: PhotoLibraryClient
    let networkAllowed: Bool
    let state: AppState?

    private struct Request: Hashable {
        let id: String
        let networkAllowed: Bool
        let attempt: Int
    }

    private struct LoadedPhoto {
        let request: Request
        let image: UIImage
    }

    private struct FailedPhoto {
        let request: Request
        let issue: PhotoPreviewIssue
    }

    private struct ShareItem: Identifiable {
        let id = UUID()
        let photoID: String
        let image: UIImage
    }

    private struct PhotoCheckSelection: Identifiable {
        let id: String
        let initialQuery: String
    }

    private struct PreviewComparisonSelection: Identifiable {
        let id: String
        let state: LocalPreviewComparisonState
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedID: String
    @State private var attempt = 0
    @State private var loadedPhoto: LoadedPhoto?
    @State private var failedPhoto: FailedPhoto?
    @State private var shareItem: ShareItem?
    @State private var photoCheckSelection: PhotoCheckSelection?
    @State private var previewComparisonSelection: PreviewComparisonSelection?

    init(ids: [String], initialID: String, library: PhotoLibraryClient,
         networkAllowed: Bool, state: AppState? = nil) {
        self.ids = ids
        self.library = library
        self.networkAllowed = networkAllowed
        self.state = state
        _selectedID = State(initialValue: ids.contains(initialID) ? initialID : (ids.first ?? ""))
    }

    private var request: Request {
        Request(id: selectedID, networkAllowed: networkAllowed, attempt: attempt)
    }

    // A page change invalidates sharing immediately, even before the new task
    // starts or the previous PhotoKit callback observes its cancellation.
    private var currentImage: UIImage? {
        guard ids.contains(selectedID), let loadedPhoto, loadedPhoto.request == request else { return nil }
        return loadedPhoto.image
    }

    var body: some View {
        ZStack {
            Color.black
            if ids.isEmpty {
                ContentUnavailableView("No photos to preview", systemImage: "photo.on.rectangle",
                                       description: Text("Close this preview and try another search."))
            } else {
                TabView(selection: $selectedID) {
                    ForEach(ids, id: \.self) { id in
                        page(id: id)
                            .tag(id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task(id: request) { await load(request) }
        .onChange(of: selectedID) { _, _ in
            shareItem = nil
            clearPhotoCheck()
        }
        .onChange(of: ids) { _, updated in
            if !updated.contains(selectedID) {
                selectedID = updated.first ?? ""
                shareItem = nil
                clearPhotoCheck()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recheckAccess() } else { clearPhotoCheck() }
        }
        .onDisappear { clearPhotoCheck() }
        .sheet(item: $shareItem) { item in
            // The sheet uses an immutable snapshot, never whichever UIImage
            // happens to finish loading after the Share button was pressed.
            if item.photoID == selectedID, library.currentRevision(id: item.photoID) != nil {
                PhotoShareSheet(image: item.image)
            } else {
                ContentUnavailableView("Photo access changed", systemImage: "lock",
                                       description: Text("Close sharing and check Photos access."))
            }
        }
        .sheet(item: $photoCheckSelection, onDismiss: { state?.dismissPhotoCheck() }) { selection in
            if let state {
                PhotoCheckSheet(state: state, photoID: selection.id, initialQuery: selection.initialQuery)
            }
        }
        .sheet(item: $previewComparisonSelection) { selection in
            LocalPreviewComparisonSheet(state: selection.state)
        }
    }

    private var topBar: some View {
        HStack {
            Button { clearPhotoCheck(); dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close photo preview")
            .accessibilityIdentifier("close-photo-preview")
            Spacer()
            let position = ids.firstIndex(of: selectedID).map { $0 + 1 } ?? 0
            Text("\(position) / \(ids.count)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityLabel("Photo \(position) of \(ids.count)")
                .accessibilityIdentifier("photo-preview-counter")
            Spacer()
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PhotoGalleryStyle.background.opacity(0.8))
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    shareButton
                    checkButton
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 8) {
                    shareButton
                    checkButton
                }
            }
            Button {
                guard ids.contains(selectedID), library.currentRevision(id: selectedID) != nil else { return }
                clearPhotoCheck()
                previewComparisonSelection = PreviewComparisonSelection(
                    id: selectedID, state: LocalPreviewComparisonState(service: library, photoID: selectedID))
            } label: {
                Label("本地预览对比", systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PhotoGalleryStyle.accent)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(!hasCheckableSelection)
            .accessibilityIdentifier("compare-local-previews")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PhotoGalleryStyle.background.opacity(0.8))
    }

    private var shareButton: some View {
        Button(action: shareCurrentPhoto) {
            Label("Share", systemImage: "square.and.arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(PhotoGalleryStyle.accent)
                .padding(.horizontal, 28)
                .frame(minHeight: 48)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(currentImage == nil)
        .opacity(currentImage == nil ? 0.4 : 1)
        .accessibilityHint("Shares the displayed photo without location metadata")
        .accessibilityIdentifier("share-photo-preview")
    }

    private var checkButton: some View {
        Group {
            if let state {
                PhotoCheckPreviewButton(state: state, hasSelection: hasCheckableSelection, action: openPhotoCheck)
            } else {
                Button {} label: { PhotoCheckPreviewLabel() }
                    .disabled(true)
                    .opacity(0.4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Compare the saved index with a fresh local preview without changing the index")
        .accessibilityIdentifier("check-photo-preview")
    }

    private var hasCheckableSelection: Bool {
        guard !selectedID.isEmpty, ids.contains(selectedID) else { return false }
        if let failedPhoto, failedPhoto.request == request, case .access = failedPhoto.issue { return false }
        return true
    }

    private func openPhotoCheck() {
        guard let state, state.canRead, hasCheckableSelection else { return }
        guard library.currentRevision(id: selectedID) != nil else {
            recheckAccess()
            return
        }
        state.dismissPhotoCheck()
        // Independent of the display-image task, so this action works while
        // that image is loading. The sheet never follows subsequent paging.
        photoCheckSelection = PhotoCheckSelection(id: selectedID, initialQuery: state.completedQuery ?? state.query)
    }

    private func clearPhotoCheck() {
        previewComparisonSelection?.state.cancelAndClear()
        previewComparisonSelection = nil
        photoCheckSelection = nil
        state?.dismissPhotoCheck()
    }

    private func page(id: String) -> some View {
        ZStack {
            Color.black
            if id == selectedID, let image = currentImage {
                PhotoFitZoomView(image: image)
                    .id(request)
            } else if id == selectedID, let failedPhoto, failedPhoto.request == request {
                failureView(failedPhoto.issue)
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(PhotoGalleryStyle.accent)
                    Text("Loading photo…").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .clipped()
    }

    private func failureView(_ issue: PhotoPreviewIssue) -> some View {
        // This scroll view contains only error copy, so accessibility text sizes
        // and landscape do not push the retry action offscreen.
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: issue.symbol)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(PhotoGalleryStyle.accent)
                    .accessibilityHidden(true)
                Text(issue.title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text(issue.message(networkAllowed: networkAllowed))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    attempt += 1
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .frame(minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(PhotoGalleryStyle.accent)
                .foregroundStyle(PhotoGalleryStyle.background)
                .accessibilityIdentifier("retry-photo-preview")
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }

    private func load(_ requested: Request) async {
        guard !Task.isCancelled, request == requested else { return }
        loadedPhoto = nil
        failedPhoto = nil
        shareItem = nil
        guard ids.contains(requested.id) else { return }
        do {
            guard library.currentRevision(id: requested.id) != nil else { throw AppFailure.permission }
            let image = try await library.displayImage(id: requested.id, targetSize: PHImageManagerMaximumSize,
                                                       networkAllowed: requested.networkAllowed)
            try Task.checkCancellation()
            guard request == requested else { return }
            guard library.currentRevision(id: requested.id) != nil else { throw AppFailure.permission }
            loadedPhoto = LoadedPhoto(request: requested, image: image)
        } catch {
            guard !Task.isCancelled, request == requested else { return }
            let issue: PhotoPreviewIssue = library.currentRevision(id: requested.id) == nil
                ? .access : PhotoPreviewIssue(error: error)
            failedPhoto = FailedPhoto(request: requested, issue: issue)
        }
    }

    private func recheckAccess() {
        guard ids.contains(selectedID), library.currentRevision(id: selectedID) == nil else { return }
        loadedPhoto = nil
        shareItem = nil
        clearPhotoCheck()
        failedPhoto = FailedPhoto(request: request, issue: .access)
    }

    private func shareCurrentPhoto() {
        guard let image = currentImage else { return }
        guard library.currentRevision(id: selectedID) != nil else {
            recheckAccess()
            return
        }
        let rendered = PhotoShareSheet.renderedCopy(of: image)
        // Authorization can change outside the main actor while rendering.
        guard library.currentRevision(id: selectedID) != nil else {
            recheckAccess()
            return
        }
        shareItem = ShareItem(photoID: selectedID, image: rendered)
    }
}

/// Observe authorization without requiring AppState in the compatibility viewer.
@MainActor
private struct PhotoCheckPreviewButton: View {
    @ObservedObject var state: AppState
    let hasSelection: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { PhotoCheckPreviewLabel() }
            .disabled(!hasSelection || !state.canRead)
            .opacity(hasSelection && state.canRead ? 1 : 0.4)
    }
}

private struct PhotoCheckPreviewLabel: View {
    var body: some View {
        Label("Check this photo", systemImage: "magnifyingglass")
            .font(.body.weight(.semibold))
            .foregroundStyle(PhotoGalleryStyle.accent)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(.ultraThinMaterial, in: Capsule())
            .contentShape(Capsule())
    }
}

/// Two-finger zoom only: no horizontal drag recognizer competes with TabView.
/// Swiping always turns the page; returning to a page starts at full-image fit.
@MainActor
private struct PhotoFitZoomView: View {
    let image: UIImage
    @State private var settledScale: CGFloat = 1
    @GestureState private var pinchScale: CGFloat = 1

    private func bounded(_ scale: CGFloat) -> CGFloat { min(max(scale, 1), 4) }

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(bounded(settledScale * pinchScale))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .clipped()
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($pinchScale) { value, scale, _ in scale = value.magnification }
                        .onEnded { value in settledScale = bounded(settledScale * value.magnification) }
                )
                .onTapGesture(count: 2) { settledScale = 1 }
                .accessibilityLabel("Selected photo")
                .accessibilityHint("Pinch to zoom. Double-tap to reset. Swipe horizontally for another photo.")
                .accessibilityAction(named: Text("Reset zoom")) { settledScale = 1 }
                .accessibilityIdentifier("photo-preview-image")
        }
        .clipped()
    }
}