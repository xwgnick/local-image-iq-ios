import SwiftUI
import UIKit
import ImageIQCore

/// Only the current pair requests pixels. Group/selection state remains owned by
/// cleanup; marking a photo here never prepares or submits a deletion.
@MainActor
struct SimilarPhotoComparisonSheet: View {
    let group: SimilarPhotoGroup
    @ObservedObject var cleanup: SimilarPhotoCleanupState
    @ObservedObject var appState: AppState
    private let imageSource: SimilarComparisonImageSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var leftID: String
    @State private var rightID: String
    @State private var isVisible = false
    @State private var attempt = 0
    @State private var activeRequest: Request?
    @State private var loadedPair: LoadedPair?

    private struct Member: Hashable {
        let id: String
        let modificationTime: Double
        let creationTime: Double?

        init(_ photo: IndexedPhoto) {
            id = photo.id
            modificationTime = photo.modificationTime
            creationTime = photo.creationTime
        }

        var revision: PhotoRevision {
            PhotoRevision(id: id, modificationTime: modificationTime, creationTime: creationTime)
        }
    }

    private struct Request: Hashable {
        let members: [Member]
        let left: Member
        let right: Member
        let pixelWidth: CGFloat
        let pixelHeight: CGFloat
        let networkAllowed: Bool
        let libraryEpoch: UUID
        let authorization: Int
        let libraryGeneration: UInt64?
        let attempt: Int

        var targetSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    }

    private struct LoadedPair {
        let request: Request
        let left: Result<DisplayThumbnailResult, Error>
        let right: Result<DisplayThumbnailResult, Error>
    }

    init(group: SimilarPhotoGroup, cleanup: SimilarPhotoCleanupState, appState: AppState,
         imageSource: SimilarComparisonImageSource? = nil) {
        self.group = group
        self.cleanup = cleanup
        self.appState = appState
        self.imageSource = imageSource ?? SimilarComparisonImageSource(library: appState.library)
        _leftID = State(initialValue: group.photos.first?.id ?? "")
        _rightID = State(initialValue: group.photos.dropFirst().first?.id ?? "")
    }

    private var expectedMembers: [Member] { group.photos.map(Member.init) }
    private var currentMembers: [Member] {
        cleanup.groups.first(where: { $0.id == group.id })?.photos.map(Member.init) ?? []
    }
    private var isCurrentGroup: Bool {
        group.photos.count >= 2 && currentMembers == expectedMembers
            && !cleanup.isGrouping && !cleanup.isDeleting
    }
    private var groupNumber: Int {
        cleanup.groups.firstIndex(where: { $0.id == group.id }).map { $0 + 1 } ?? 0
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                // The two panes stay side by side, including portrait and large
                // text. Controls can grow vertically inside the outer ScrollView.
                let width = max(0, (geometry.size.width - 44) / 2)
                let height = max(1, geometry.size.height * 0.6)
                let requested = request(for: CGSize(width: width, height: height))
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("第\(groupNumber)组 · \(group.photos.count)张")
                                .font(.headline)
                            Text("最低相似度 \(String(format: "%.3f", Double(group.minimumSimilarity)))")
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(IQStyle.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 12) {
                            pane(title: "左侧", photoID: leftID, selection: leftSelection,
                                 width: width, height: height, requested: requested, isLeft: true)
                            pane(title: "右侧", photoID: rightID, selection: rightSelection,
                                 width: width, height: height, requested: requested, isLeft: false)
                        }
                        Text("仅勾选待删除，返回后统一确认")
                            .font(.footnote)
                            .foregroundStyle(IQStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                }
                .task(id: requested) { await load(requested) }
            }
            .background(IQStyle.viewerBackground.ignoresSafeArea())
            .navigationTitle("照片对比")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("返回") { close() }
                        .disabled(cleanup.isDeleting)
                        .accessibilityIdentifier("close-similar-comparison")
                }
            }
        }
        .foregroundStyle(IQStyle.text)
        .tint(IQStyle.accent)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(cleanup.isDeleting)
        .onAppear {
            guard scenePhase != .background, isCurrentGroup, appState.canRead else { close(); return }
            isVisible = true
        }
        .onDisappear { clearPixels() }
        .onChange(of: cleanup.groups.map(\.id)) { _, ids in
            if !ids.contains(group.id) { close() }
        }
        .onChange(of: currentMembers) { _, members in
            if members != expectedMembers { close() }
        }
        .onChange(of: isCurrentGroup) { _, current in
            if !current { close() }
        }
        .onChange(of: appState.photoLibraryEpoch) { _, _ in accessChanged() }
        .onChange(of: appState.authorization) { _, _ in accessChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                close()
            } else if phase == .active, let activeRequest, !validate(activeRequest) {
                accessChanged()
            }
            // Do not treat a system confirmation's inactive phase as background.
        }
    }

    // Change both IDs synchronously when selecting the other pane's photo. This
    // swaps the pair without ever starting a request for two identical photos.
    private var leftSelection: Binding<String> {
        Binding(get: { leftID }, set: { id in
            guard isCurrentGroup, group.photos.contains(where: { $0.id == id }) else { return }
            if id == rightID { rightID = leftID }
            leftID = id
        })
    }

    private var rightSelection: Binding<String> {
        Binding(get: { rightID }, set: { id in
            guard isCurrentGroup, group.photos.contains(where: { $0.id == id }) else { return }
            if id == leftID { leftID = rightID }
            rightID = id
        })
    }

    private func pane(title: String, photoID: String, selection: Binding<String>, width: CGFloat,
                      height: CGFloat, requested: Request?, isLeft: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(IQStyle.secondary)
                Picker("\(title)照片", selection: selection) {
                    ForEach(Array(group.photos.enumerated()), id: \.element.id) { index, photo in
                        Text("照片\(index + 1)").tag(photo.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityLabel("\(title)对比照片")
                .accessibilityIdentifier(isLeft ? "similar-comparison-left-picker" : "similar-comparison-right-picker")
                .disabled(!isCurrentGroup)
            }
            ZStack {
                IQStyle.viewerBackground
                if let requested, let loadedPair, loadedPair.request == requested {
                    imageContent(isLeft ? loadedPair.left : loadedPair.right, request: requested, title: title)
                } else if isVisible && isCurrentGroup && scenePhase != .background {
                    ProgressView().tint(IQStyle.accent).accessibilityLabel("正在加载\(title)照片")
                }
            }
            .frame(width: width, height: height)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(IQStyle.line, lineWidth: 1))
            Button { cleanup.toggleSelection(photoID) } label: {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: cleanup.selectedIDs.contains(photoID) ? "checkmark.square.fill" : "square")
                        .font(.title3)
                    Text("勾选删除")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(IQStyle.accent)
            .disabled(!isCurrentGroup || scenePhase == .background)
            .accessibilityLabel("\(title)照片，勾选删除")
            .accessibilityValue(cleanup.selectedIDs.contains(photoID) ? "已勾选" : "未勾选")
            .accessibilityHint("仅更改待删除选择，返回后统一确认")
            .accessibilityIdentifier(isLeft ? "similar-comparison-left-selection" : "similar-comparison-right-selection")
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func imageContent(_ outcome: Result<DisplayThumbnailResult, Error>, request: Request,
                              title: String) -> some View {
        switch outcome {
        case .success(let result):
            // UIImage retains the loader's orientation; SwiftUI applies it while
            // fitting the entire image. No crop or encode/decode normalization.
            SimilarComparisonFitImage(image: result.image, label: "\(title)完整照片")
                .id(request)
        case .failure(let error):
            let issue = PhotoPreviewIssue(error: error)
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: issue.symbol).font(.title2)
                    Text(issue.localizedCaption).font(.subheadline.weight(.medium))
                    Text(issue.localizedMessage(networkAllowed: request.networkAllowed))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") { attempt += 1 }
                        .frame(minHeight: 44)
                }
                .foregroundStyle(IQStyle.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(10)
            }
        }
    }

    private func request(for points: CGSize) -> Request? {
        guard isVisible, scenePhase != .background, isCurrentGroup, appState.canRead,
              leftID != rightID,
              let left = expectedMembers.first(where: { $0.id == leftID }),
              let right = expectedMembers.first(where: { $0.id == rightID }),
              let pixels = DisplayThumbnailLoader.targetSize(points: points, displayScale: displayScale) else { return nil }
        return Request(members: expectedMembers, left: left, right: right,
                       pixelWidth: pixels.width, pixelHeight: pixels.height,
                       networkAllowed: appState.allowICloudDownload,
                       libraryEpoch: appState.photoLibraryEpoch, authorization: appState.authorization.rawValue,
                       libraryGeneration: appState.library.changeGeneration, attempt: attempt)
    }

    /// Synchronous checks bracket both awaits, including the entire captured
    /// group's membership and the expected revisions of the two visible photos.
    private func validate(_ request: Request) -> Bool {
        guard isVisible, scenePhase != .background, isCurrentGroup,
              expectedMembers == request.members, currentMembers == request.members,
              leftID == request.left.id, rightID == request.right.id,
              appState.allowICloudDownload == request.networkAllowed,
              appState.photoLibraryEpoch == request.libraryEpoch, appState.canRead,
              appState.authorization.rawValue == request.authorization,
              appState.library.changeGeneration == request.libraryGeneration else { return false }
        do {
            try imageSource.validate([request.left.revision, request.right.revision],
                                     request.authorization, request.libraryGeneration)
            return true
        } catch {
            return false
        }
    }

    private func load(_ requested: Request?) async {
        guard !Task.isCancelled else { return }
        activeRequest = requested
        loadedPair = nil
        guard let requested else { return }
        guard validate(requested) else { accessChanged(); return }
        // Structured children are cancelled with this pair/geometry task. No
        // detached prefetch, group-wide decoding, original-data or OCR request.
        async let left = readPhoto(requested.left.id, request: requested)
        async let right = readPhoto(requested.right.id, request: requested)
        let outcomes = await (left, right)
        guard !Task.isCancelled, activeRequest == requested, isVisible,
              leftID == requested.left.id, rightID == requested.right.id,
              appState.allowICloudDownload == requested.networkAllowed else { return }
        guard validate(requested) else { accessChanged(); return }
        loadedPair = LoadedPair(request: requested, left: outcomes.0, right: outcomes.1)
    }

    private func readPhoto(_ id: String, request: Request) async -> Result<DisplayThumbnailResult, Error> {
        do {
            try Task.checkCancellation()
            let result = try await imageSource.load(id, request.targetSize, request.networkAllowed)
            try Task.checkCancellation()
            guard validate(request) else { throw CancellationError() }
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func clearPixels() {
        isVisible = false
        activeRequest = nil
        loadedPair = nil
    }

    private func close() {
        clearPixels()
        dismiss()
    }

    private func accessChanged() {
        clearPixels()
        cleanup.invalidateAccess()
        dismiss()
    }
}

/// PhotoGallery's fit/zoom view is file-private. Keep this small presentation
/// equivalent local rather than changing the existing gallery or its gestures.
@MainActor
private struct SimilarComparisonFitImage: View {
    let image: UIImage
    let label: String
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
                .accessibilityLabel(label)
                .accessibilityHint("双指捏合缩放，轻点两下还原完整照片")
                .accessibilityAction(named: Text("还原缩放")) { settledScale = 1 }
        }
        .clipped()
    }
}