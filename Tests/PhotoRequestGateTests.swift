import XCTest
import Photos
@testable import LocalImageIQ

final class PhotoRequestGateTests: XCTestCase {
    func testDuplicateCallbacksResumeExactlyOnce() async throws {
        let gate = PhotoRequestGate<Int> { _ in }
        let value = try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            gate.finish(.success(7))
            gate.finish(.success(99))
            gate.finish(.failure(AppFailure.cloudOnly))
        }
        XCTAssertEqual(value, 7)
    }

    func testCancellationBeforeRequestIDAndContinuationIsNotLost() async {
        let recorder = RequestRecorder()
        let gate = PhotoRequestGate<Int> { recorder.record($0) }
        gate.cancel()
        gate.setRequestID(42)
        do {
            _ = try await withCheckedThrowingContinuation { gate.install($0) }
            XCTFail("Early cancellation must throw.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(recorder.values, [42])
    }

    func testSynchronousCallbackBeforeContinuationInstallation() async throws {
        let gate = PhotoRequestGate<Int> { _ in }
        gate.finish(.success(11))
        let value = try await withCheckedThrowingContinuation { gate.install($0) }
        XCTAssertEqual(value, 11)
    }

    func testCancellationAndCallbackRaceHasSingleWinner() async {
        let gate = PhotoRequestGate<Int> { _ in }
        do {
            let value = try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                DispatchQueue.global().async { gate.cancel() }
                DispatchQueue.global().async { gate.finish(.success(1)) }
            }
            XCTAssertEqual(value, 1)
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PHImageRequestID] = []
    var values: [PHImageRequestID] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func record(_ value: PHImageRequestID) {
        lock.lock(); defer { lock.unlock() }
        stored.append(value)
    }
}