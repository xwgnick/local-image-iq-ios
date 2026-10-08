import Foundation
import Photos
import XCTest
@testable import LocalImageIQ

/// Real options, no client instance, authorization, fetch, observer or Photos data.
/// These factory contracts do not prove hidden/burst access on a device.
final class PhotoFetchScopeTests: XCTestCase {
    func testSearchFetchOptionsIncludeHiddenAndAllBurstAssets() {
        let options = PhotoLibraryClient.searchFetchOptions()
        XCTAssertTrue(options.includeHiddenAssets)
        XCTAssertTrue(options.includeAllBurstAssets)
    }

    func testSearchFetchOptionsHaveNoPredicateOrFetchLimit() {
        let options = PhotoLibraryClient.searchFetchOptions()
        XCTAssertNil(options.predicate)
        XCTAssertEqual(options.fetchLimit, 0)
    }

    func testSearchFetchOptionsAreFreshAndMutationsDoNotLeak() {
        let first = PhotoLibraryClient.searchFetchOptions()
        let second = PhotoLibraryClient.searchFetchOptions()
        XCTAssertFalse(first === second)
        first.includeHiddenAssets = false
        first.includeAllBurstAssets = false
        first.predicate = NSPredicate(value: false)
        first.fetchLimit = 1
        XCTAssertFalse(first.includeHiddenAssets)
        XCTAssertFalse(first.includeAllBurstAssets)
        XCTAssertNotNil(first.predicate)
        XCTAssertEqual(first.fetchLimit, 1)

        let third = PhotoLibraryClient.searchFetchOptions()
        XCTAssertFalse(first === third)
        XCTAssertFalse(second === third)
        for options in [second, third] {
            XCTAssertTrue(options.includeHiddenAssets)
            XCTAssertTrue(options.includeAllBurstAssets)
            XCTAssertNil(options.predicate)
            XCTAssertEqual(options.fetchLimit, 0)
        }
    }
}