import XCTest
@testable import LocalImageIQ

final class ReleaseResourceTests: XCTestCase {
    func testAppPrivacyManifestDeclaresOnlyActualLocalUses() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(plist["NSPrivacyTrackingDomains"] as? [String], [])
        XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        let items = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertEqual(items.count, 3)
        var reasons: [String: [String]] = [:]
        for item in items {
            let category = try XCTUnwrap(item["NSPrivacyAccessedAPIType"] as? String)
            XCTAssertNil(reasons[category], "Duplicate required-reason category")
            reasons[category] = try XCTUnwrap(item["NSPrivacyAccessedAPITypeReasons"] as? [String])
        }
        XCTAssertEqual(reasons, [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
        ])
    }

    func testThirdPartyNoticesAreReadableWithoutNetworkOrModelLoading() throws {
        let text = try ThirdPartyNotices.load()
        for expected in ["SigLIP 2", "Pillow 11.1.0", "geoBoundaries", "CHN / ADM1",
                         "swift-transformers 1.3.4", "swift-huggingface 0.13.0", "swift-jinja 2.5.1",
                         "swift-collections 1.6.0", "swift-crypto 4.5.2", "eventsource 1.5.1",
                         "yyjson 0.12.0", "Apache License", "Permission to use, copy, modify and distribute"] {
            XCTAssertTrue(text.contains(expected), "Missing bundled notice: \(expected)")
        }
        let manifestURL = try XCTUnwrap(Bundle.main.url(forResource: "third-party-manifest",
                                                        withExtension: "json", subdirectory: "Legal"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertEqual((manifest["packages"] as? [[String: Any]])?.count, 7)
    }

    func testMissingNoticesAreAnErrorNotAnEmptySuccess() {
        XCTAssertThrowsError(try ThirdPartyNotices.load(bundle: Bundle(for: Self.self)))
    }

    func testSDKUpgradeKeepsExistingUIDesignCompatibility() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility") as? Bool, true)
    }
}
