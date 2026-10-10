import XCTest
import Photos
import UIKit
import CoreImage
@testable import LocalImageIQ

/// Tests real request options and production completion gates, never PHAsset or
/// private Photos. Requested HQ/224 is NOT an assertion about returned detail.
@MainActor
final class PhotoViewerHQTests: XCTestCase {
    private typealias Reply = ViewerHQRequests.Reply
    private let target = CGSize(width: 224, height: 448)

    func testSuccessfulLocalHQIsOneCallAndAvoidsFastAndCloudWithEitherOptIn() async throws {
        let image = try pixels()
        for allowed in [false, true] {
            let requests = ViewerHQRequests(replies: [[Reply(image: image, info: [PHImageResultIsDegradedKey: false])]])
            let result = try await load(requests, network: allowed)
            XCTAssertTrue(result.image === image)
            XCTAssertEqual(result.stage, .localHQ224)
            XCTAssertEqual(result.degraded, false)
            XCTAssertEqual(result.attempts.count, 1, "Publish HQ224 immediately; never wait for a viewport upgrade")
            assertOptions(requests, deliveries: [.highQualityFormat], networks: [false])
            XCTAssertEqual(requests.plans.map(\.size), [target])
            XCTAssertTrue(requests.cancelledIDs.isEmpty)
        }
    }

    func testAspectTargetsPreservePortraitLandscapeSquareAndExtremeAspectWithoutMaximumSize() async throws {
        let image = try pixels()
        let cases: [(Int, Int, CGSize)] = [
            (1080, 1920, CGSize(width: 224, height: 224 * CGFloat(1920) / 1080)),
            (1920, 1080, CGSize(width: 224 * CGFloat(1920) / 1080, height: 224)),
            (4000, 4000, CGSize(width: 224, height: 224)),
            (1, 100000, CGSize(width: 224, height: 22400000)),
            (0, 0, CGSize(width: 224, height: 224))
        ]
        for (width, height, expected) in cases {
            let requests = ViewerHQRequests(replies: [[Reply(image: image)]])
            _ = try await load(requests, width: width, height: height)
            XCTAssertEqual(requests.plans.map(\.size), [expected])
            XCTAssertNotEqual(expected, PHImageManagerMaximumSize)
        }
    }

    func testUndersizedOrDegradedLocalHQIsImmediatelyUsableWithoutInventingPixelRejection() async throws {
        let small = try pixels(width: 32, height: 16)
        let infos: [[AnyHashable: Any]?] = [nil, [PHImageResultIsDegradedKey: false], [PHImageResultIsDegradedKey: true]]
        for allowed in [false, true] {
            for info in infos {
                let requests = ViewerHQRequests(replies: [[Reply(image: small, info: info)]])
                let result = try await load(requests, network: allowed)
                XCTAssertTrue(result.image === small)
                XCTAssertEqual(result.returnedSize, CGSize(width: 32, height: 16))
                XCTAssertEqual(result.degraded, (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue)
                XCTAssertFalse(result.isSufficientForDisplay)
                XCTAssertEqual(result.stage, .localHQ224)
                assertOptions(requests, deliveries: [.highQualityFormat], networks: [false])
            }
        }
    }

    func testSourceRasterScaleOrientationAndBytesAreUnchanged() async throws {
        let raw = try pixels(width: 61, height: 29)
        let cg = try XCTUnwrap(raw.cgImage)
        let before = try XCTUnwrap(cg.dataProvider?.data) as Data
        let image = UIImage(cgImage: cg, scale: 3, orientation: .rightMirrored)
        let requests = ViewerHQRequests(replies: [[Reply(image: image)]])
        let result = try await load(requests)
        XCTAssertTrue(result.image === image)
        XCTAssertTrue(result.image.cgImage === cg)
        XCTAssertEqual(result.image.scale, 3)
        XCTAssertEqual(result.image.imageOrientation, .rightMirrored)
        XCTAssertEqual(try XCTUnwrap(result.image.cgImage?.dataProvider?.data) as Data, before)
        XCTAssertEqual(result.returnedSize, CGSize(width: 61, height: 29))
    }

    func testCIBackedLocalImagePreservesExtentScaleAndOrientationWithoutEncodeRoundtrip() async throws {
        let ci = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 17, height: 31))
        let image = UIImage(ciImage: ci, scale: 2, orientation: .left)
        let requests = ViewerHQRequests(replies: [[Reply(image: image)]])
        let result = try await load(requests)
        XCTAssertEqual(result.returnedSize, CGSize(width: 17, height: 31))
        XCTAssertEqual(result.image.imageOrientation, .left)
        XCTAssertEqual(result.image.scale, 2)
        XCTAssertNil(image.cgImage, "Source UIImage is not mutated")
        XCTAssertEqual(requests.plans.count, 1)
    }

    func testMissingHQAloneAllowsExistingOfflineFastFallback() async throws {
        let image = try pixels(width: 68, height: 120)
        let misses = [Reply(), Reply(image: UIImage()), Reply(info: [PHImageResultIsInCloudKey: true]),
                      Reply(info: [PHImageErrorKey: NSError(domain: PHPhotosErrorDomain, code: 3164)])]
        for missing in misses {
            let requests = ViewerHQRequests(replies: [[missing], [Reply(image: image, info: [PHImageResultIsDegradedKey: true])]])
            let result = try await load(requests)
            XCTAssertTrue(result.image === image)
            XCTAssertEqual(result.stage, .localFast224)
            XCTAssertEqual(result.degraded, true)
            XCTAssertFalse(result.isReusable)
            assertOptions(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
            XCTAssertEqual(requests.plans.map(\.size), [target, target])
        }
    }

    func testOptInTriesLocalHQFirstThenCloudHQAndPreservesNondegradedNetworkCompletion() async throws {
        let small = try pixels(width: 32, height: 16)
        let final = try pixels()
        let requests = ViewerHQRequests(replies: [[Reply()], [
            Reply(info: [PHImageResultIsDegradedKey: true]),
            Reply(image: small, info: [PHImageResultIsDegradedKey: true]),
            Reply(image: final, info: [PHImageResultIsDegradedKey: false])
        ]])
        let result = try await load(requests, network: true)
        XCTAssertTrue(result.image === final)
        XCTAssertEqual(result.stage, .networkHQ)
        XCTAssertEqual(result.degraded, false)
        XCTAssertEqual(result.attempts.count, 2)
        assertOptions(requests, deliveries: [.highQualityFormat, .highQualityFormat], networks: [false, true])
        XCTAssertEqual(requests.plans.map(\.size), [target, target])
    }

    func testCloudHQMissRetainsOfflineFastCompatibility() async throws {
        let image = try pixels(width: 68, height: 120)
        let requests = ViewerHQRequests(replies: [[Reply()], [Reply()], [Reply(image: image)]])
        let result = try await load(requests, network: true)
        XCTAssertTrue(result.image === image)
        XCTAssertEqual(result.stage, .localFast224)
        assertOptions(requests, deliveries: [.highQualityFormat, .highQualityFormat, .fastFormat], networks: [false, true, false])
    }

    func testCloudFlagOr3164WithReadableHQDoesNotTriggerFastOrDownload() async throws {
        let image = try pixels()
        let infos: [[AnyHashable: Any]] = [
            [PHImageResultIsInCloudKey: true],
            [PHImageErrorKey: NSError(domain: PHPhotosErrorDomain, code: 3164)]
        ]
        for info in infos {
            let requests = ViewerHQRequests(replies: [[Reply(image: image, info: info)]])
            let result = try await load(requests, network: true)
            XCTAssertTrue(result.image === image)
            XCTAssertEqual(requests.plans.count, 1)
            XCTAssertEqual(requests.plans.map(\.network), [false])
        }
    }

    func testOfflineExhaustionClassifiesCloudOnlyWithoutEverEnablingDownload() async {
        for cloud in [false, true] {
            let missing = Reply(info: cloud ? [PHImageResultIsInCloudKey: true] : nil)
            let requests = ViewerHQRequests(replies: [[missing], [missing]])
            do { _ = try await load(requests); XCTFail("Expected unavailable preview") }
            catch AppFailure.cloudOnly { XCTAssertTrue(cloud) }
            catch AppFailure.photo { XCTAssertFalse(cloud) }
            catch { XCTFail("Unexpected classification: \(error)") }
            XCTAssertEqual(requests.plans.map(\.network), [false, false])
        }
    }

    func testErrorsAndPermissionFailuresNeverBecomeFallbackEvenWithPixelsAndCloudFlags() async throws {
        let image = try pixels()
        let failures: [Error] = [AppFailure.permission, NSError(domain: "SyntheticViewer", code: 7),
            NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.accessUserDenied.rawValue),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)]
        for failure in failures {
            for stage in 0..<3 {
                var replies = Array(repeating: [Reply()], count: stage)
                replies.append([Reply(image: image, info: [PHImageErrorKey: failure,
                    PHImageResultIsInCloudKey: true, PHImageResultIsDegradedKey: true])])
                let requests = ViewerHQRequests(replies: replies)
                do { _ = try await load(requests, network: true); XCTFail("Error must propagate") }
                catch AppFailure.permission { }
                catch {
                    XCTAssertEqual((error as NSError).domain, (failure as NSError).domain)
                    XCTAssertEqual((error as NSError).code, (failure as NSError).code)
                }
                XCTAssertEqual(requests.plans.count, stage + 1)
            }
        }
    }

    func testAlreadyCancelledCallerMakesNoRequestsOrValidationReads() async {
        let requests = ViewerHQRequests(replies: [])
        let validation = ViewerHQValidation()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await load(requests, validate: { try validation.check() })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(requests.plans.isEmpty)
        XCTAssertEqual(validation.count, 0)
    }

    func testSynchronousCancellationBeforeIDAssignmentCancelsEventualIDAndRejectsSuccess() async throws {
        let image = try pixels()
        for replies in [[], [Reply(image: image)]] {
            let requests = ViewerHQRequests(replies: [replies], cancelBeforeID: true)
            let task = Task { @MainActor in try await load(requests, network: true) }
            do { _ = try await task.value; XCTFail("Cancellation must win") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(requests.cancelledIDs, [1])
            XCTAssertEqual(requests.plans.count, 1)
        }
    }

    func testCancellationAndLateCallbacksCannotPublishOrStartFallback() async throws {
        let image = try pixels()
        for cancelTask in [true, false] {
            let requested = expectation(description: "Captured viewer request")
            let requests = ViewerHQRequests(replies: [[]], didRequest: { requested.fulfill() })
            let task = Task { @MainActor in try await load(requests, network: true) }
            defer { task.cancel(); requests.clearCallbacks() }
            await fulfillment(of: [requested], timeout: 5)
            if cancelTask { task.cancel() }
            else { requests.complete(1, Reply(info: [PHImageCancelledKey: true])) }
            requests.complete(1, Reply(image: image))
            requests.complete(1, Reply(info: [PHImageErrorKey: AppFailure.permission]))
            do { _ = try await task.value; XCTFail("Late pixels must not escape cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(requests.plans.count, 1)
            XCTAssertEqual(requests.cancelledIDs, cancelTask ? [1] : [])
        }
    }

    func testDuplicateCallbackKeepsFirstImageAndRawQualityMetadata() async throws {
        let first = try pixels(width: 17, height: 19)
        let second = try pixels()
        let requests = ViewerHQRequests(replies: [[Reply(image: first, info: [PHImageResultIsDegradedKey: true]),
                                                  Reply(image: second, info: [PHImageResultIsDegradedKey: false])]])
        let result = try await load(requests)
        XCTAssertTrue(result.image === first)
        XCTAssertEqual(result.degraded, true)
        XCTAssertEqual(requests.plans.count, 1)
    }

    func testValidationBeforeReadAfterReadAndBeforeFallbackRejectsWithoutPublishing() async throws {
        let image = try pixels()
        for (rejectAt, success) in [(1, false), (2, false), (3, false), (3, true), (4, false)] {
            let validation = ViewerHQValidation(rejectAt: rejectAt)
            let requests = ViewerHQRequests(replies: [[Reply(image: success ? image : nil)]])
            do {
                _ = try await load(requests, network: true, validate: { try validation.check() })
                XCTFail("Invalid access must prevent fallback and publication")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(validation.count, rejectAt)
            XCTAssertEqual(requests.plans.count, rejectAt < 3 ? 0 : 1)
            XCTAssertTrue(requests.plans.allSatisfy { !$0.network })
        }
    }

    func testSnapshotRejectsMissingChangedModificationCreationAndExactIdentifier() {
        let snapshot = fixtureSnapshot()
        let changes: [PhotoRevision?] = [nil,
            PhotoRevision(id: "viewer", modificationTime: 11, creationTime: 5),
            PhotoRevision(id: "viewer", modificationTime: 10, creationTime: 6),
            PhotoRevision(id: "viewer", modificationTime: 10, creationTime: nil),
            PhotoRevision(id: "other", modificationTime: 10, creationTime: 5)]
        for revision in changes {
            XCTAssertThrowsError(try snapshot.validate(id: "viewer", authorization: { .authorized },
                generation: { 3 }, currentRevision: { _ in revision })) { XCTAssertTrue($0 is CancellationError) }
        }
        XCTAssertThrowsError(try snapshot.validate(id: "other", authorization: { .authorized },
            generation: { 3 }, currentRevision: { _ in snapshot.revision }))
    }

    func testCanonicalEquivalentUnicodeIDStillRequiresByteExactIdentity() {
        let composed = "\u{00e9}"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed, "Swift equality alone would miss this identity mismatch")
        let snapshot = PhotoViewerSnapshot(revision: PhotoRevision(id: composed, modificationTime: 1),
                                           authorization: .authorized, generation: nil)
        XCTAssertThrowsError(try snapshot.validate(id: decomposed, authorization: { .authorized },
            generation: { nil }, currentRevision: { _ in snapshot.revision }))
        XCTAssertThrowsError(try snapshot.validate(id: composed, authorization: { .authorized },
            generation: { nil }, currentRevision: { _ in PhotoRevision(id: decomposed, modificationTime: 1) }))
    }

    func testAuthorizationAndGenerationCheckedBeforeAndAfterMetadataRead() {
        let snapshot = fixtureSnapshot()
        let statuses: [PHAuthorizationStatus] = [.denied, .restricted, .notDetermined, .limited]
        for access in statuses {
            var reads = 0
            XCTAssertThrowsError(try snapshot.validate(id: "viewer", authorization: { access },
                generation: { 3 }, currentRevision: { _ in reads += 1; return snapshot.revision }))
            XCTAssertEqual(reads, 0)
        }
        for changedAccess in [false, true] {
            var access = PHAuthorizationStatus.authorized
            var generation: UInt64? = 3
            XCTAssertThrowsError(try snapshot.validate(id: "viewer", authorization: { access },
                generation: { generation }, currentRevision: { _ in
                    if changedAccess { access = .limited } else { generation = 4 }
                    return snapshot.revision
                }))
        }
        XCTAssertThrowsError(try snapshot.validate(id: "viewer", authorization: { .authorized },
            generation: { 4 }, currentRevision: { _ in XCTFail("Must reject before metadata"); return snapshot.revision }))
    }

    func testUnchangedLimitedSnapshotAndNilGenerationRemainCompatible() throws {
        let snapshot = PhotoViewerSnapshot(revision: PhotoRevision(id: "viewer", modificationTime: 1),
                                           authorization: .limited, generation: nil)
        try snapshot.validate(id: "viewer", authorization: { .limited }, generation: { nil },
                              currentRevision: { _ in snapshot.revision })
    }

    func testInjectedSourceFactoryDoesNotExecuteAnyReadAtConstruction() {
        let source = PhotoViewerImageSource(load: { _, _ in
            XCTFail("Construction must not request pixels")
            throw CancellationError()
        }, validate: { _ in XCTFail("Construction must not read authorization or metadata") })
        withExtendedLifetime(source) { }
    }

    func testHDUpgradeIsOneExactAspectFitCurrentRequestWithOnlyExplicitCloudPermission() async throws {
        let image = try pixels(width: 900, height: 1800)
        let target = CGSize(width: 900, height: 1800)
        for cloud in [false, true] {
            let requests = ViewerHQRequests(replies: [[Reply(image: image, info: [PHImageResultIsDegradedKey: false])]])
            let result = try await upgrade(requests, target: target, cloud: cloud)
            XCTAssertTrue(result.image === image)
            XCTAssertEqual(result.stage, cloud ? .networkHQ : .localHQ)
            XCTAssertEqual(requests.plans.count, 1)
            let plan = try XCTUnwrap(requests.plans.first)
            XCTAssertEqual(plan.size, target)
            XCTAssertEqual(plan.mode, .aspectFit)
            XCTAssertEqual(plan.delivery, .highQualityFormat)
            XCTAssertEqual(plan.resize, .exact)
            XCTAssertEqual(plan.version, .current)
            XCTAssertEqual(plan.network, cloud)
            XCTAssertFalse(plan.synchronous)
        }
    }

    func testHDUpgradeReadableUndersizedLocalResultIsReturnedNotRejectedOrReplacedByFast() async throws {
        let image = try pixels(width: 17, height: 31)
        let requests = ViewerHQRequests(replies: [[Reply(image: image, info: [PHImageResultIsDegradedKey: true])]])
        let result = try await upgrade(requests)
        XCTAssertTrue(result.image === image)
        XCTAssertEqual(result.returnedSize, CGSize(width: 17, height: 31))
        XCTAssertEqual(result.degraded, true)
        XCTAssertFalse(result.isSufficientForDisplay)
        XCTAssertEqual(requests.plans.map(\.network), [false])
        XCTAssertEqual(requests.plans.map(\.delivery), [.highQualityFormat])
    }

    func testHDCloudUpgradeWaitsForFinalAndKeepsFirstFinalAgainstDuplicates() async throws {
        let low = try pixels(width: 17, height: 31)
        let high = try pixels(width: 900, height: 1800)
        let requests = ViewerHQRequests(replies: [[
            Reply(image: low, info: [PHImageResultIsDegradedKey: true]),
            Reply(image: high, info: [PHImageResultIsDegradedKey: false]),
            Reply(image: low, info: [PHImageResultIsDegradedKey: false])]])
        let result = try await upgrade(requests, cloud: true)
        XCTAssertTrue(result.image === high)
        XCTAssertEqual(result.degraded, false)
        XCTAssertEqual(requests.plans.map(\.network), [true])
    }

    func testHDUpgradeMissingAndOrdinaryErrorsNeverStartAnotherRequest() async throws {
        let errors: [Error] = [AppFailure.cloudOnly, AppFailure.permission,
            NSError(domain: PHPhotosErrorDomain, code: 3164), NSError(domain: "SyntheticHD", code: 7)]
        for failure in errors {
            let requests = ViewerHQRequests(replies: [[Reply(info: [PHImageErrorKey: failure])]])
            do { _ = try await upgrade(requests); XCTFail("Expected missing/error result") }
            catch { }
            XCTAssertEqual(requests.plans.count, 1)
            XCTAssertEqual(requests.plans.map(\.network), [false])
        }
    }

    func testHDUpgradeCancellationBeforeIDAssignmentCancelsEventualID() async throws {
        let requests = ViewerHQRequests(replies: [[Reply(image: try pixels())]], cancelBeforeID: true)
        let task = Task { @MainActor in try await upgrade(requests, cloud: true) }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.cancelledIDs, [1])
        XCTAssertEqual(requests.plans.count, 1)
    }

    func testHDUpgradeCancellationWhileWaitingDiscardsLateFinalCallbacks() async throws {
        let entered = expectation(description: "HD request pending")
        let requests = ViewerHQRequests(replies: [[]], didRequest: { entered.fulfill() })
        let task = Task { @MainActor in try await upgrade(requests, cloud: true) }
        defer { task.cancel(); requests.clearCallbacks() }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        requests.complete(1, Reply(image: try pixels(width: 900, height: 1800)))
        do { _ = try await task.value; XCTFail("Late result must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.cancelledIDs, [1])
        XCTAssertEqual(requests.plans.count, 1)
    }

    func testHDUpgradePostReadValidationRejectsChangedAuthorityWithoutFallback() async throws {
        let validation = ViewerHQValidation(rejectAt: 2)
        let requests = ViewerHQRequests(replies: [[Reply(image: try pixels())]])
        do { _ = try await upgrade(requests, validate: { try validation.check() }); XCTFail("Changed source must reject") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(validation.count, 2)
        XCTAssertEqual(requests.plans.count, 1)
    }

    private func upgrade(_ requests: ViewerHQRequests, target: CGSize = CGSize(width: 900, height: 1800),
                         cloud: Bool = false, validate: @escaping @Sendable () throws -> Void = {}) async throws -> DisplayThumbnailResult {
        try await PhotoViewerImageLoader.upgrade(targetSize: target, cloudConsent: cloud,
            request: { requests.request($0, $1, $2, $3) }, cancel: { requests.cancel($0) }, validate: validate)
    }

    private func fixtureSnapshot() -> PhotoViewerSnapshot {
        PhotoViewerSnapshot(revision: PhotoRevision(id: "viewer", modificationTime: 10, creationTime: 5),
                            authorization: .authorized, generation: 3)
    }

    private func load(_ requests: ViewerHQRequests, width: Int = 1200, height: Int = 2400,
                      network: Bool = false, validate: @escaping @Sendable () throws -> Void = {}) async throws -> DisplayThumbnailResult {
        try await PhotoViewerImageLoader.load(pixelWidth: width, pixelHeight: height, networkAllowed: network,
            request: { requests.request($0, $1, $2, $3) }, cancel: { requests.cancel($0) }, validate: validate)
    }

    private func assertOptions(_ requests: ViewerHQRequests, deliveries: [PHImageRequestOptionsDeliveryMode],
                               networks: [Bool], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(requests.plans.map(\.delivery), deliveries, file: file, line: line)
        XCTAssertEqual(requests.plans.map(\.network), networks, file: file, line: line)
        for plan in requests.plans {
            XCTAssertEqual(plan.version, .current, file: file, line: line)
            XCTAssertEqual(plan.resize, .fast, file: file, line: line)
            XCTAssertEqual(plan.mode, .aspectFit, file: file, line: line)
            XCTAssertFalse(plan.synchronous, file: file, line: line)
            XCTAssertNotEqual(plan.size, PHImageManagerMaximumSize, file: file, line: line)
        }
    }

    private func pixels(width: Int = 224, height: Int = 448) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        XCTAssertNotNil(image.cgImage)
        return image
    }
}

/// Snapshot actual typed options at invocation, not an expected policy plan.
private final class ViewerHQRequests: @unchecked Sendable {
    struct Reply {
        var image: UIImage? = nil
        var info: [AnyHashable: Any]? = nil
    }
    struct Plan {
        let size: CGSize
        let mode: PHImageContentMode
        let delivery: PHImageRequestOptionsDeliveryMode
        let resize: PHImageRequestOptionsResizeMode
        let version: PHImageRequestOptionsVersion
        let network: Bool
        let synchronous: Bool
    }
    private let lock = NSLock()
    private let replies: [[Reply]]
    private let cancelBeforeID: Bool
    private let didRequest: @Sendable () -> Void
    private var storedPlans: [Plan] = []
    private var cancelled: [PHImageRequestID] = []
    private var callbacks: [PHImageRequestID: DisplayThumbnailLoader.Callback] = [:]
    var plans: [Plan] { locked { storedPlans } }
    var cancelledIDs: [PHImageRequestID] { locked { cancelled } }

    init(replies: [[Reply]], cancelBeforeID: Bool = false, didRequest: @escaping @Sendable () -> Void = {}) {
        self.replies = replies
        self.cancelBeforeID = cancelBeforeID
        self.didRequest = didRequest
    }

    func request(_ size: CGSize, _ mode: PHImageContentMode, _ options: PHImageRequestOptions,
                 _ callback: @escaping DisplayThumbnailLoader.Callback) -> PHImageRequestID {
        let (id, responses): (PHImageRequestID, [Reply]) = locked {
            storedPlans.append(Plan(size: size, mode: mode, delivery: options.deliveryMode, resize: options.resizeMode,
                                   version: options.version, network: options.isNetworkAccessAllowed, synchronous: options.isSynchronous))
            let id = PHImageRequestID(storedPlans.count)
            callbacks[id] = callback
            guard replies.indices.contains(storedPlans.count - 1) else {
                XCTFail("Unexpected extra image request")
                return (id, [Reply(info: [PHImageErrorKey: CancellationError()])])
            }
            return (id, replies[storedPlans.count - 1])
        }
        didRequest()
        if cancelBeforeID { withUnsafeCurrentTask { $0?.cancel() } }
        for reply in responses { callback(reply.image, reply.info) }
        return id
    }

    func cancel(_ id: PHImageRequestID) { locked { cancelled.append(id) } }
    func complete(_ id: PHImageRequestID, _ reply: Reply) {
        let callback = locked { callbacks[id] }
        XCTAssertNotNil(callback)
        callback?(reply.image, reply.info)
    }
    func clearCallbacks() { locked { callbacks.removeAll() } }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private final class ViewerHQValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let rejectAt: Int?
    init(rejectAt: Int? = nil) { self.rejectAt = rejectAt }
    var count: Int { lock.lock(); defer { lock.unlock() }; return checks }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        checks += 1
        if checks == rejectAt { throw CancellationError() }
    }
}