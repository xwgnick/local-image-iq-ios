import XCTest
@testable import LocalImageIQ

@MainActor
final class SearchLayoutDeliveryTests: XCTestCase {
    func testBoundaryExitsCallbackAndLatestMeasurementWins() async {
        let delivery = SearchLayoutDelivery()
        var received: [Int] = []
        delivery.deliverBoundary { received.append(12) }
        delivery.deliverBoundary { received.append(24) }
        XCTAssertTrue(received.isEmpty)
        let finished = expectation(description: "Latest boundary delivered after callback")
        DispatchQueue.main.async { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(received, [24])
    }

    func testNilMeasurementReplacesPendingPageAndHeaderIsIndependent() async {
        let delivery = SearchLayoutDelivery()
        var received: [Int?] = []
        var header = 0
        delivery.deliverBoundary { received.append(12) }
        delivery.deliverHeader { header = 100 }
        delivery.deliverBoundary { received.append(nil) }
        delivery.deliverHeader { header = 200 }
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(header, 0)
        let finished = expectation(description: "Independent latest layout writes")
        DispatchQueue.main.async { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(received.count, 1)
        XCTAssertNil(received.first!)
        XCTAssertEqual(header, 200)
    }
}