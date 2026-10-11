import SwiftUI

enum ThirdPartyNotices {
    enum ReadError: Error { case missingResource, invalidContent }

    static func load(bundle: Bundle = .main) throws -> String {
        guard let url = bundle.url(forResource: "ThirdPartyNotices", withExtension: "txt", subdirectory: "Legal") else {
            throw ReadError.missingResource
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard text.hasPrefix("Local Image IQ - Third-party notices"), text.contains("Apache License") else {
            throw ReadError.invalidContent
        }
        return text
    }
}

struct ThirdPartyNoticesView: View {
    @State private var content: String?
    @State private var readFailed = false

    var body: some View {
        Group {
            if let content {
                ScrollView {
                    Text(content)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityIdentifier("third-party-notices-content")
                }
            } else if readFailed {
                ContentUnavailableView("声明暂时无法读取", systemImage: "exclamationmark.triangle",
                                       description: Text("请返回后重试。此问题不会删除照片或索引。"))
                    .accessibilityIdentifier("third-party-notices-error")
            } else {
                ProgressView("读取声明")
            }
        }
        .managementPage("第三方声明")
        .task {
            do {
                content = try ThirdPartyNotices.load()
                readFailed = false
            } catch {
                readFailed = true
            }
        }
    }
}
