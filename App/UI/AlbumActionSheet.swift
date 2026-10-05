import Foundation
import SwiftUI

/// Presentation only: the parent loads albums, validates current access, performs
/// the action and decides when to dismiss. isLoading also covers an in-flight action.
@MainActor
struct AlbumActionSheet: View {
    static let membershipText = "加入系统相册，不复制或删除原照片"
    static let emptyAlbumsText = "暂无可加入的相册。若仅允许访问部分照片，相册列表可能不完整；也可以新建相册。"
    let albums: [PhotoAlbum]
    let isLoading: Bool
    let issue: String?
    private let onAction: (PhotoBatchAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newAlbumName = ""

    init(albums: [PhotoAlbum], isLoading: Bool = false, issue: String? = nil,
         onAction: @escaping (PhotoBatchAction) -> Void) {
        self.albums = albums
        self.isLoading = isLoading
        self.issue = issue
        self.onAction = onAction
    }

    var addableAlbums: [PhotoAlbum] { albums.filter(\.canAdd) }

    static func trimmedTitle(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func add(to albumID: String) -> Bool {
        guard !isLoading, addableAlbums.contains(where: { $0.id == albumID }) else { return false }
        onAction(.addToAlbum(albumID)) // Opaque local identifier, not the display title.
        return true
    }

    @discardableResult
    func createAlbum(named name: String) -> Bool {
        let title = Self.trimmedTitle(name)
        guard !isLoading, !title.isEmpty else { return false }
        onAction(.createAlbum(title))
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Self.membershipText)
                        .font(.subheadline).foregroundStyle(IQStyle.secondary)
                        .accessibilityIdentifier("album-membership-note")
                    if isLoading {
                        ProgressView("正在加载或处理相册…")
                            .accessibilityIdentifier("album-action-loading")
                    }
                    if let issue {
                        Text(IQStyle.diagnosticText(issue))
                            .foregroundStyle(IQStyle.warning)
                            .accessibilityIdentifier("album-action-issue")
                    }
                }
                .listRowBackground(IQStyle.surface)
                Section("已有相册") {
                    ForEach(addableAlbums) { album in
                        Button { add(to: album.id) } label: {
                            Label(album.title, systemImage: "rectangle.stack.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .disabled(isLoading)
                        .accessibilityIdentifier("album-action-add-\(album.id)")
                    }
                    if !isLoading && addableAlbums.isEmpty {
                        Text(Self.emptyAlbumsText)
                            .font(.footnote).foregroundStyle(IQStyle.secondary)
                    }
                }
                .listRowBackground(IQStyle.surface)
                Section {
                    TextField("新相册名称", text: $newAlbumName)
                        .disabled(isLoading)
                        .submitLabel(.done)
                        .onSubmit { createAlbum(named: newAlbumName) }
                        .accessibilityIdentifier("new-album-name")
                    Button("创建并加入") { createAlbum(named: newAlbumName) }
                        .disabled(isLoading || Self.trimmedTitle(newAlbumName).isEmpty)
                        .accessibilityIdentifier("create-album-and-add")
                } header: {
                    Text("新建相册")
                } footer: {
                    Text("创建系统相册并加入所选照片，仅修改相册归属，不生成照片副本。")
                }
                .listRowBackground(IQStyle.surface)
            }
            .scrollContentBackground(.hidden)
            .background(IQStyle.background)
            .foregroundStyle(IQStyle.text)
            .navigationTitle("加入相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("cancel-album-action")
                }
            }
        }
        .tint(IQStyle.accent)
    }
}