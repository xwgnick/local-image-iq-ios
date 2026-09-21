import XCTest
@testable import LocalImageIQ

final class AppInfoContractTests: XCTestCase {
    func testAppBundleHasReadUsageDescriptionWithoutWriteUsageOrATSExceptions() throws {
        let bundle = Bundle(for: AppState.self)
        let info = try XCTUnwrap(bundle.infoDictionary)
        let usage = try XCTUnwrap(info["NSPhotoLibraryUsageDescription"] as? String)
        XCTAssertFalse(usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNil(info["NSPhotoLibraryAddUsageDescription"])
        XCTAssertNil(info["NSAppTransportSecurity"])
        XCTAssertEqual(info["PHPhotoLibraryPreventAutomaticLimitedAccessAlert"] as? Bool, true)
    }
}