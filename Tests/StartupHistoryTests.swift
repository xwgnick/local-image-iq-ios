import CryptoKit
import Foundation
import XCTest
@testable import LocalImageIQ

/// Isolated preferences and tiny synthetic temporary bundles only. No real model
/// payloads, standard defaults, cache probes, Photos, network or model loading.
@MainActor
final class StartupHistoryTests: XCTestCase {
    func testFingerprintIsStableLowercaseSHA256() {
        let inputs = FingerprintInputs()
        let first = inputs.fingerprint
        XCTAssertEqual(first, inputs.fingerprint)
        XCTAssertEqual(first.utf8.count, 64)
        XCTAssertNotNil(first.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertEqual(StartupContext(fingerprint: first), StartupContext(fingerprint: inputs.fingerprint))
        XCTAssertEqual(StartupContext.modelConfigurationIdentity, ".all/image+text/input64/primary")
    }

    func testFingerprintFramesUTF8ByteLengthsAndUsesSHA256RatherThanSwiftHasher() {
        var inputs = FingerprintInputs()
        inputs.manifestData = Data([0, 255, 1]) // The pure seam does not decode; current(bundle:) does.
        inputs.bundleURL = URL(fileURLWithPath: "/synthetic/模型.app")
        inputs.bundleIdentifier = "照片🔍"
        inputs.bundleVersion = "a\0b"
        inputs.resourceURLs = []
        let fields = [
            Data("startupPreparation.context.v1".utf8), inputs.manifestData,
            Data(inputs.bundleURL.standardizedFileURL.path.utf8), Data(inputs.bundleIdentifier.utf8),
            Data(inputs.bundleVersion.utf8), Data(inputs.shortVersion.utf8),
            Data(inputs.operatingSystemVersion.utf8), Data(inputs.modelConfigurationIdentity.utf8),
            Data("0".utf8)
        ]
        var framed = Data()
        for field in fields {
            // Independent explicit byte framing, rather than the production
            // withUnsafeBytes/native-integer representation implementation.
            for shift in stride(from: 56, through: 0, by: -8) {
                framed.append(UInt8(truncatingIfNeeded: UInt64(field.count) >> shift))
            }
            framed.append(field)
        }
        let expected = SHA256.hash(data: framed).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(inputs.fingerprint, expected)
    }

    func testEveryManifestBuildOSConfigurationAndResourceIdentityFieldAffectsFingerprint() {
        let original = FingerprintInputs()
        let mutations: [(inout FingerprintInputs) -> Void] = [
            { $0.manifestData.append(32) }, // Even a whitespace-only byte change is a different manifest.
            { $0.bundleURL = URL(fileURLWithPath: "/synthetic/OtherInstall/App.app") },
            { $0.bundleIdentifier = "test.other.app" },
            { $0.bundleVersion = "21" },
            { $0.shortVersion = "0.5.8" },
            { $0.operatingSystemVersion = "Synthetic OS build B" },
            { $0.modelConfigurationIdentity = ".cpuOnly/image+text/input64/primary" },
            { $0.resourceURLs[0] = URL(fileURLWithPath: "/synthetic/Models/other-manifest.json") },
            { $0.resourceURLs[1] = URL(fileURLWithPath: "/synthetic/Models/OtherImage.mlmodelc") },
            { $0.resourceURLs[2] = URL(fileURLWithPath: "/synthetic/Models/OtherText.mlmodelc") },
            { $0.resourceURLs[3] = URL(fileURLWithPath: "/synthetic/Models/other-tokenizer.json") },
            { $0.resourceURLs[4] = URL(fileURLWithPath: "/synthetic/Models/other-config.json") }
        ]
        var fingerprints: Set<String> = [original.fingerprint]
        for (index, mutate) in mutations.enumerated() {
            var changed = original
            mutate(&changed)
            XCTAssertNotEqual(changed.fingerprint, original.fingerprint, "Unrepresented identity field at mutation \(index)")
            XCTAssertTrue(fingerprints.insert(changed.fingerprint).inserted)
        }
    }

    func testLengthDelimitedFieldsDoNotAliasConcatenationOrEmbeddedSeparators() {
        var first = FingerprintInputs()
        var second = first
        first.bundleIdentifier = "ab"
        first.bundleVersion = "c"
        second.bundleIdentifier = "a"
        second.bundleVersion = "bc"
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        first.bundleIdentifier = "a\0b"
        first.bundleVersion = "c"
        second.bundleIdentifier = "a"
        second.bundleVersion = "b\0c"
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    func testBundleAndResourcePathsAreStandardizedBeforeHashing() {
        var first = FingerprintInputs()
        first.bundleURL = URL(fileURLWithPath: "/synthetic/Install/unused/../App.app")
        first.resourceURLs = [URL(fileURLWithPath: "/synthetic/Install/App.app/Models/unused/../ImageEncoder.mlmodelc")]
        var second = first
        second.bundleURL = URL(fileURLWithPath: "/synthetic/Install/App.app")
        second.resourceURLs = [URL(fileURLWithPath: "/synthetic/Install/App.app/Models/ImageEncoder.mlmodelc")]
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testResourceListOrderCountAndMissingPathsHaveDistinctIdentities() {
        let original = FingerprintInputs()
        var reordered = original
        reordered.resourceURLs.swapAt(1, 2)
        XCTAssertNotEqual(reordered.fingerprint, original.fingerprint)
        var missing = original
        missing.resourceURLs[1] = nil
        XCTAssertNotEqual(missing.fingerprint, original.fingerprint)
        var empty = original
        empty.resourceURLs = []
        var oneMissing = original
        oneMissing.resourceURLs = [nil]
        XCTAssertNotEqual(empty.fingerprint, oneMissing.fingerprint)
    }

    func testCurrentContextMatchesPureAlgorithmUsingSmallManifestAndResourceURLs() throws {
        let bundle = try makeBundle(resourcesInModels: true)
        let context = try XCTUnwrap(StartupContext.current(bundle: bundle))
        let manifestURL = try XCTUnwrap(BundleResources.url("model-manifest", extension: "json", bundle: bundle))
        let expected = StartupContext.makeFingerprint(
            manifestData: Data(TestFixtures.manifest.utf8), bundleURL: bundle.bundleURL,
            bundleIdentifier: try XCTUnwrap(bundle.bundleIdentifier),
            bundleVersion: "20", shortVersion: "0.5.7",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            resourceURLs: [
                manifestURL,
                BundleResources.url("ImageEncoder", extension: "mlmodelc", bundle: bundle),
                BundleResources.url("TextEncoder", extension: "mlmodelc", bundle: bundle),
                BundleResources.url("tokenizer", extension: "json", bundle: bundle),
                BundleResources.url("tokenizer_config", extension: "json", bundle: bundle)
            ])
        XCTAssertEqual(context.fingerprint, expected)
        XCTAssertEqual(StartupContext.current(bundle: bundle), context)
    }

    func testCurrentContextRejectsMissingMalformedAndContractInvalidManifest() throws {
        let invalidContract = TestFixtures.manifest.replacingOccurrences(of: "\"dimension\":768", with: "\"dimension\":512")
        let manifests: [String?] = [nil, "not JSON", "{}", invalidContract]
        for manifest in manifests {
            let bundle = try makeBundle(manifest: manifest)
            XCTAssertNil(StartupContext.current(bundle: bundle))
        }
    }

    func testCurrentContextDoesNotRequireLoadingOrHashingRuntimePayloads() throws {
        let bundle = try makeBundle()
        let original = try XCTUnwrap(StartupContext.current(bundle: bundle))
        // The tokenizer files are invalid JSON and the compiled models are empty
        // directories. Replacing tiny fixture payloads must not change identity.
        let tokenizer = try XCTUnwrap(BundleResources.url("tokenizer", extension: "json", bundle: bundle))
        let config = try XCTUnwrap(BundleResources.url("tokenizer_config", extension: "json", bundle: bundle))
        let image = try XCTUnwrap(BundleResources.url("ImageEncoder", extension: "mlmodelc", bundle: bundle))
        try Data("different invalid tokenizer".utf8).write(to: tokenizer)
        try Data("different invalid config".utf8).write(to: config)
        try Data([1, 2, 3]).write(to: image.appendingPathComponent("synthetic-payload.bin"))
        XCTAssertEqual(StartupContext.current(bundle: bundle), original)

        let manifestOnly = try makeBundle(includeRuntimeResources: false)
        XCTAssertNotNil(StartupContext.current(bundle: manifestOnly), "Context is not a replacement for prepare/resource validation.")
    }

    func testAbsentContextOrHistoryAndNoPreviousSuccessPredictSlow() {
        let context = contextA
        let history = StartupHistoryMemory()
        XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: nil, history: nil))
        XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: context, history: nil))
        XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: nil, history: history))
        XCTAssertEqual(history.lookups, 0)
        XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: context, history: history))
        XCTAssertEqual(history.lookups, 1)
        XCTAssertEqual(history.records, 0)
    }

    func testInMemoryHistoryReducesRiskOnlyForExactSuccessfulContext() {
        let history = StartupHistoryMemory()
        history.recordSuccessfulPreparation(for: contextA)
        XCTAssertFalse(StartupDisplayPolicy.predictsSlow(context: contextA, history: history))
        XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: contextB, history: history))
        XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: nil, history: history))
        XCTAssertEqual(history.records, 1)
    }

    func testEightSecondFallbackIsOnlyAVisibilityConstantAndNeverRecordsSuccess() throws {
        XCTAssertEqual(StartupDisplayPolicy.fallbackDelaySeconds, 8)
        let (defaults, _) = try isolatedDefaults()
        let history = StartupHistoryStore(defaults: defaults)
        let progress = StartupProgressRecorder()
        progress.complete(Set(StartupStep.allCases))
        progress.freeze()
        XCTAssertEqual(progress.snapshot.fraction, 1)
        XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: contextA, history: history))
        XCTAssertNil(defaults.object(forKey: StartupHistoryStore.key), "Only the owner's explicit ready recording may persist success.")
    }

    func testExplicitSuccessPersistsAcrossStoreInstancesAndOnlyLatestContextMatches() throws {
        let (defaults, suite) = try isolatedDefaults()
        let store = StartupHistoryStore(defaults: defaults)
        XCTAssertFalse(store.hasSuccessfulPreparation(for: contextA))
        store.recordSuccessfulPreparation(for: contextA)
        let reopened = StartupHistoryStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertTrue(reopened.hasSuccessfulPreparation(for: contextA))
        XCTAssertFalse(StartupDisplayPolicy.predictsSlow(context: contextA, history: reopened))
        XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: contextB, history: reopened))
        reopened.recordSuccessfulPreparation(for: contextB)
        XCTAssertTrue(store.hasSuccessfulPreparation(for: contextB))
        XCTAssertFalse(store.hasSuccessfulPreparation(for: contextA))
    }

    func testStoredJSONContainsOnlyVersionedSchemaAndDigestAndPreservesOtherKeys() throws {
        let (defaults, suite) = try isolatedDefaults()
        defaults.set("preserve", forKey: "unrelated.preference")
        defaults.set(false, forKey: "chineseSearchEnabled.v1")
        let inputs = FingerprintInputs()
        let context = StartupContext(fingerprint: inputs.fingerprint)
        let store = StartupHistoryStore(defaults: defaults)
        XCTAssertEqual(StartupHistoryStore.key, "startupPreparation.success.v1")
        store.recordSuccessfulPreparation(for: context)

        let data = try XCTUnwrap(defaults.data(forKey: StartupHistoryStore.key))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schema", "fingerprint"])
        XCTAssertEqual(json["schema"] as? Int, 1)
        XCTAssertEqual(json["fingerprint"] as? String, context.fingerprint)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic"))
        let domain = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(Set(domain.keys), [StartupHistoryStore.key, "unrelated.preference", "chineseSearchEnabled.v1"])
        XCTAssertEqual(defaults.string(forKey: "unrelated.preference"), "preserve")
        XCTAssertEqual(defaults.object(forKey: "chineseSearchEnabled.v1") as? Bool, false)
    }

    func testMissingOrWrongStorageTypeRemainsRiskAndReadingDoesNotRepairDefaults() throws {
        let (defaults, suite) = try isolatedDefaults()
        let store = StartupHistoryStore(defaults: defaults)
        XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: contextA, history: store))
        XCTAssertNil(defaults.object(forKey: StartupHistoryStore.key))
        let wrongTypes: [Any] = ["{}", 1, true, ["schema": 1, "fingerprint": contextA.fingerprint]]
        for value in wrongTypes {
            defaults.set(value, forKey: StartupHistoryStore.key)
            let before = try XCTUnwrap(defaults.persistentDomain(forName: suite)) as NSDictionary
            XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: contextA, history: store))
            XCTAssertEqual(try XCTUnwrap(defaults.persistentDomain(forName: suite)) as NSDictionary, before)
        }
    }

    func testCorruptJSONSchemaMismatchAndInvalidFingerprintAllRemainRisk() throws {
        let (defaults, _) = try isolatedDefaults()
        let store = StartupHistoryStore(defaults: defaults)
        var records = [Data("broken JSON".utf8), Data("null".utf8), Data("[]".utf8)]
        let invalidObjects: [[String: Any]] = [
            [:], ["schema": 1], ["fingerprint": contextA.fingerprint],
            ["schema": 0, "fingerprint": contextA.fingerprint],
            ["schema": 2, "fingerprint": contextA.fingerprint],
            ["schema": "1", "fingerprint": contextA.fingerprint],
            ["schema": true, "fingerprint": contextA.fingerprint],
            ["schema": 1, "fingerprint": 123]
        ]
        for object in invalidObjects { records.append(try JSONSerialization.data(withJSONObject: object)) }
        for fingerprint in invalidFingerprints {
            records.append(try JSONSerialization.data(withJSONObject: ["schema": 1, "fingerprint": fingerprint]))
        }
        for data in records {
            defaults.set(data, forKey: StartupHistoryStore.key)
            XCTAssertFalse(store.hasSuccessfulPreparation(for: contextA))
            XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: contextA, history: store))
            XCTAssertEqual(defaults.data(forKey: StartupHistoryStore.key), data, "A read must not rewrite corrupt history.")
        }
    }

    func testInvalidContextCannotPersistPathsOrOverwritePreviousSuccess() throws {
        let (defaults, _) = try isolatedDefaults()
        let store = StartupHistoryStore(defaults: defaults)
        for value in invalidFingerprints {
            store.recordSuccessfulPreparation(for: StartupContext(fingerprint: value))
            XCTAssertNil(defaults.object(forKey: StartupHistoryStore.key))
        }
        store.recordSuccessfulPreparation(for: contextA)
        let saved = try XCTUnwrap(defaults.data(forKey: StartupHistoryStore.key))
        for value in invalidFingerprints {
            let invalid = StartupContext(fingerprint: value)
            store.recordSuccessfulPreparation(for: invalid)
            XCTAssertFalse(store.hasSuccessfulPreparation(for: invalid))
            XCTAssertTrue(StartupDisplayPolicy.predictsSlow(context: invalid, history: store))
            XCTAssertEqual(defaults.data(forKey: StartupHistoryStore.key), saved)
        }
        XCTAssertTrue(store.hasSuccessfulPreparation(for: contextA))
    }

    func testValidHexIsAcceptedButComparisonRemainsExact() throws {
        let (defaults, _) = try isolatedDefaults()
        let store = StartupHistoryStore(defaults: defaults)
        let uppercase = StartupContext(fingerprint: String(repeating: "A", count: 64))
        store.recordSuccessfulPreparation(for: uppercase)
        XCTAssertTrue(store.hasSuccessfulPreparation(for: uppercase))
        XCTAssertFalse(store.hasSuccessfulPreparation(for: contextA))
    }

    private var contextA: StartupContext { StartupContext(fingerprint: String(repeating: "a", count: 64)) }
    private var contextB: StartupContext { StartupContext(fingerprint: String(repeating: "b", count: 64)) }
    private var invalidFingerprints: [String] {
        ["", "/private/synthetic/App.app", String(repeating: "a", count: 63),
         String(repeating: "a", count: 65), String(repeating: "g", count: 64),
         String(repeating: "é", count: 64), String(repeating: "a", count: 63) + " "]
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "LocalImageIQ.StartupHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, suite)
    }

    private func makeBundle(manifest: String? = TestFixtures.manifest,
                            includeRuntimeResources: Bool = true,
                            resourcesInModels: Bool = false) throws -> Bundle {
        let temporary = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent("StartupHistory.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "test.localimageiq.startup.\(UUID().uuidString)",
            "CFBundleName": "StartupHistory", "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "20", "CFBundleShortVersionString": "0.5.7"
        ], format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Info.plist"))
        let resources = resourcesInModels ? url.appendingPathComponent("Models", isDirectory: true) : url
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if let manifest { try Data(manifest.utf8).write(to: resources.appendingPathComponent("model-manifest.json")) }
        if includeRuntimeResources {
            for name in ["ImageEncoder.mlmodelc", "TextEncoder.mlmodelc"] {
                try FileManager.default.createDirectory(at: resources.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            for name in ["tokenizer.json", "tokenizer_config.json"] {
                try Data("not valid tokenizer JSON".utf8).write(to: resources.appendingPathComponent(name))
            }
        }
        // As in EncoderResourceInspectionTests, write before constructing Bundle
        // rather than relying on resource-lookup cache invalidation.
        return try XCTUnwrap(Bundle(url: url))
    }
}

private struct FingerprintInputs {
    var manifestData = Data(TestFixtures.manifest.utf8)
    var bundleURL = URL(fileURLWithPath: "/synthetic/Install/App.app")
    var bundleIdentifier = "test.localimageiq.app"
    var bundleVersion = "20"
    var shortVersion = "0.5.7"
    var operatingSystemVersion = "Synthetic OS build A"
    var modelConfigurationIdentity = StartupContext.modelConfigurationIdentity
    var resourceURLs: [URL?] = [
        "model-manifest.json", "ImageEncoder.mlmodelc", "TextEncoder.mlmodelc", "tokenizer.json", "tokenizer_config.json"
    ].map { URL(fileURLWithPath: "/synthetic/Install/App.app/Models/\($0)") }

    var fingerprint: String {
        StartupContext.makeFingerprint(
            manifestData: manifestData, bundleURL: bundleURL, bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion, shortVersion: shortVersion, operatingSystemVersion: operatingSystemVersion,
            modelConfigurationIdentity: modelConfigurationIdentity, resourceURLs: resourceURLs)
    }
}

@MainActor
private final class StartupHistoryMemory: StartupHistoryStoring {
    private var successful: StartupContext?
    private(set) var lookups = 0
    private(set) var records = 0

    func hasSuccessfulPreparation(for context: StartupContext) -> Bool {
        lookups += 1
        return successful == context
    }

    func recordSuccessfulPreparation(for context: StartupContext) {
        records += 1
        successful = context
    }
}