import SwiftUI
import Photos

@main
struct StorePhotoPreparationApp: App {
    var body: some Scene {
        WindowGroup { PreparationView() }
    }
}

private enum PreparationError: Error {
    case notDisposableSimulator, missingPhotos, unauthorized, unexpectedLibrary, verificationFailed
}

@MainActor
private struct PreparationView: View {
    @State private var status = "Ready"
    @State private var audit = ""
    @State private var started = false

    var body: some View {
        VStack {
            Text(status).accessibilityIdentifier("store-preparation-status")
            Text(audit).accessibilityIdentifier("store-preparation-audit")
            Button("Prepare disposable photo library") {
                started = true
                Task {
                    do {
                        try await prepare()
                        status = "Prepared 12 licensed photos"
                    } catch {
                        status = "Failed: \(error)"
                        NSLog("Store photo preparation failed: %@", String(describing: error))
                    }
                }
            }
            .disabled(started)
            .accessibilityIdentifier("prepare-store-library")
        }
        .padding()
    }

    private func prepare() async throws {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments
        guard let device = environment["SIMULATOR_UDID"],
              let name = environment["SIMULATOR_DEVICE_NAME"],
              name.range(of: #"^Store-(iphone-medium|iphone-large|ipad-13)-[0-9]+$"#,
                         options: .regularExpression) != nil,
              let marker = arguments.firstIndex(of: "--disposable-store-simulator"),
              arguments.indices.contains(marker + 1), arguments[marker + 1] == device else {
            throw PreparationError.notDisposableSimulator
        }
        #else
        throw PreparationError.notDisposableSimulator
        #endif

        let names = ["coffee", "chelsea"].flatMap { family in
            (0..<6).map { "\(family)-crop-\($0).png" }
        }
        let urls = try names.map { name -> URL in
            guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "store-photos"),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw PreparationError.missingPhotos
            }
            return url
        }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard authorization == .authorized else {
            throw PreparationError.unauthorized
        }
        let existing = PHAsset.fetchAssets(with: nil)
        guard existing.count == 0 || existing.count == 6 else {
            throw PreparationError.unexpectedLibrary
        }
        var originalNames: [String] = []
        existing.enumerateObjects { asset, _, _ in
            originalNames.append(contentsOf: PHAssetResource.assetResources(for: asset).map(\.originalFilename))
        }
        audit = "Initial simulator assets: \(existing.count); \(originalNames.joined(separator: ", "))"
        if existing.count > 0 {
            status = "Confirm removal of simulator sample photos"
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(existing)
            }
        }
        guard PHAsset.fetchAssets(with: nil).count == 0 else {
            throw PreparationError.verificationFailed
        }
        status = "Importing licensed photos"
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
            }
        }
        let imported = PHAsset.fetchAssets(with: nil)
        var actualNames: [String] = []
        imported.enumerateObjects { asset, _, _ in
            actualNames.append(contentsOf: PHAssetResource.assetResources(for: asset).map(\.originalFilename))
        }
        guard imported.count == 12, actualNames.sorted() == names.sorted() else {
            throw PreparationError.verificationFailed
        }
        audit += "\nVerified imported filenames: \(actualNames.sorted().joined(separator: ", "))"
    }
}
