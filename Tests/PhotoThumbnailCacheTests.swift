import XCTest
import Foundation
import UIKit
@testable import LocalImageIQ

/// Generated pixels and a lock-protected provider only: no Photos client,
/// authorization prompts, assets, network, model, database or index operations.
@MainActor
final class PhotoThumbnailCacheTests: XCTestCase {
    func testSameKeyReusesImageAndExistingCallDefaultsTo480Pixels() async throws {
        func requireProvider<T: PhotoThumbnailProviding>(_: T.Type) {}
        requireProvider(PhotoLibraryClient.self) // Conformance only; do not initialize it.
        let image = fixture(.red)
        let provider = ThumbnailCacheProvider(image: image)
        let cache = PhotoThumbnailCache(library: provider)
        let first = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        provider.image = fixture(.blue)
        let second = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        XCTAssertTrue(first === image)
        XCTAssertTrue(second === image)
        XCTAssertEqual(provider.plans.count, 1)
        XCTAssertEqual(provider.plans.first?.targetSize, CGSize(width: 480, height: 480))
        XCTAssertEqual(provider.plans.first?.networkAllowed, false)
    }

    func testAssetIDAndStoredEmbeddingRevisionAreBothCacheIdentity() async throws {
        let first = fixture(.red)
        let second = fixture(.blue)
        let third = fixture(.green)
        let provider = ThumbnailCacheProvider(image: first)
        provider.setRevision(PhotoRevision(id: "photo|1", modificationTime: 200), for: "photo|1")
        let cache = PhotoThumbnailCache(library: provider)
        let a = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        provider.image = second
        let b = try await cache.image(id: "photo|1", revision: 1, networkAllowed: false)
        provider.image = third
        let c = try await cache.image(id: "photo", revision: 2, networkAllowed: false)
        let again = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        XCTAssertTrue(a === first)
        XCTAssertTrue(b === second)
        XCTAssertTrue(c === third)
        XCTAssertTrue(again === first)
        XCTAssertEqual(provider.plans.map(\.id), ["photo", "photo|1", "photo"])
    }

    func testNetworkOptInNeverReusesOfflineEntryAndIsPassedExplicitly() async throws {
        let offline = fixture(.red)
        let online = fixture(.blue)
        let provider = ThumbnailCacheProvider(image: offline)
        let cache = PhotoThumbnailCache(library: provider)
        let a = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        provider.image = online
        let b = try await cache.image(id: "photo", revision: 1, networkAllowed: true)
        let c = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        let d = try await cache.image(id: "photo", revision: 1, networkAllowed: true)
        XCTAssertTrue(a === offline)
        XCTAssertTrue(b === online)
        XCTAssertTrue(c === offline)
        XCTAssertTrue(d === online)
        XCTAssertEqual(provider.plans.map(\.networkAllowed), [false, true])
    }

    func testBothPixelDimensionsSeparateTinyAndLargeRequestsWithoutCeiling() async throws {
        let provider = ThumbnailCacheProvider(image: fixture(.red))
        let cache = PhotoThumbnailCache(library: provider)
        let sizes = [CGSize(width: 32, height: 32), CGSize(width: 480, height: 600),
                     CGSize(width: 481, height: 600), CGSize(width: 480, height: 601),
                     CGSize(width: 27000, height: 18000)]
        var images: [UIImage] = []
        for size in sizes {
            let image = fixture(.blue)
            images.append(image)
            provider.image = image
            let result = try await cache.image(id: "photo", revision: 1, targetSize: size, networkAllowed: false)
            XCTAssertTrue(result === image, "A smaller request must not mask a larger tile.")
        }
        for (size, expected) in zip(sizes, images) {
            let result = try await cache.image(id: "photo", revision: 1, targetSize: size, networkAllowed: false)
            XCTAssertTrue(result === expected)
        }
        XCTAssertEqual(provider.plans.map(\.targetSize), sizes)
    }

    func testFractionalPixelSizesRoundUpAndEquivalentTargetsReuseEntry() async throws {
        let image = fixture(.red)
        let provider = ThumbnailCacheProvider(image: image)
        let cache = PhotoThumbnailCache(library: provider)
        for size in [CGSize(width: 120.01, height: 150.5), CGSize(width: 120.9, height: 150.01),
                     CGSize(width: 121, height: 151)] {
            let result = try await cache.image(id: "photo", revision: 1, targetSize: size, networkAllowed: false)
            XCTAssertTrue(result === image)
        }
        XCTAssertEqual(provider.plans.map(\.targetSize), [CGSize(width: 121, height: 151)])
        _ = try await cache.image(id: "photo", revision: 1, targetSize: CGSize(width: 0.01, height: 0.2),
                                  networkAllowed: false)
        XCTAssertEqual(provider.plans.last?.targetSize, CGSize(width: 1, height: 1))
    }

    func testOldIndexRevisionLoadsEditedCurrentPixelsWithoutReindexing() async throws {
        let original = fixture(.red)
        let edited = fixture(.blue)
        let changedCreation = fixture(.green)
        let provider = ThumbnailCacheProvider(image: original)
        // Even a provider without notifications must use the actual revision.
        provider.changeGeneration = nil
        let cache = PhotoThumbnailCache(library: provider)
        let first = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        provider.setRevision(PhotoRevision(id: "photo", modificationTime: 300, creationTime: 100), for: "photo")
        provider.image = edited
        let second = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        provider.setRevision(PhotoRevision(id: "photo", modificationTime: 300, creationTime: 101), for: "photo")
        provider.image = changedCreation
        let third = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        let again = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        XCTAssertTrue(first === original)
        XCTAssertTrue(second === edited)
        XCTAssertTrue(third === changedCreation)
        XCTAssertTrue(again === changedCreation)
        XCTAssertEqual(provider.plans.count, 3)
        XCTAssertEqual(provider.currentRevision(id: "photo"),
                       PhotoRevision(id: "photo", modificationTime: 300, creationTime: 101))
    }

    func testClearInvalidatesCompletedEntry() async throws {
        let provider = ThumbnailCacheProvider(image: fixture(.red))
        let cache = PhotoThumbnailCache(library: provider)
        _ = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        cache.clear()
        let fresh = fixture(.blue)
        provider.image = fresh
        let result = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        XCTAssertTrue(result === fresh)
        XCTAssertEqual(provider.plans.count, 2)
    }

    func testClearRejectsLateResultWithoutOverwritingReplacementEntry() async throws {
        let stale = fixture(.red)
        let fresh = fixture(.blue)
        let provider = ThumbnailCacheProvider(image: stale)
        let cache = PhotoThumbnailCache(library: provider)
        provider.holdNextRequest()
        let old = Task { try await cache.image(id: "photo", revision: 1, networkAllowed: false) }
        await provider.waitForRequest(1)
        cache.clear()
        provider.image = fresh
        let replacement = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        XCTAssertTrue(replacement === fresh)
        XCTAssertTrue(provider.complete(1, image: stale))
        await assertCancelled(old)
        let again = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        XCTAssertTrue(again === fresh)
        XCTAssertEqual(provider.plans.count, 2)
    }

    func testCancellationRejectsCachedHitAtEntryAndDuringMetadataValidation() async throws {
        let provider = ThumbnailCacheProvider(image: fixture(.red))
        let cache = PhotoThumbnailCache(library: provider)
        _ = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        let cancelledAtEntry = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        }
        await assertCancelled(cancelledAtEntry)
        // Cancel after the initial cancellation check, during the hit's final
        // metadata read. No suspension/timing assumption is needed.
        provider.onRevisionRead(after: 2) { withUnsafeCurrentTask { $0?.cancel() } }
        let cancelledDuringHit = Task { try await cache.image(id: "photo", revision: 1, networkAllowed: false) }
        await assertCancelled(cancelledDuringHit)
        XCTAssertEqual(provider.plans.count, 1)
    }

    func testCancelledPendingProviderCannotPublishOrPopulateCache() async throws {
        let stale = fixture(.red)
        let provider = ThumbnailCacheProvider(image: stale)
        let cache = PhotoThumbnailCache(library: provider)
        provider.holdNextRequest()
        let pending = Task { try await cache.image(id: "photo", revision: 1, networkAllowed: false) }
        await provider.waitForRequest(1)
        pending.cancel()
        // Deliberately cancellation-uncooperative provider: the cache must check.
        XCTAssertTrue(provider.complete(1, image: stale))
        await assertCancelled(pending)
        let fresh = fixture(.blue)
        provider.image = fresh
        let result = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        XCTAssertTrue(result === fresh)
        XCTAssertEqual(provider.plans.count, 2)
    }

    func testRevokedPermissionRejectsExistingCachedPixels() async throws {
        let provider = ThumbnailCacheProvider(image: fixture(.red))
        let cache = PhotoThumbnailCache(library: provider)
        _ = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        provider.canReadImages = false
        do {
            _ = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
            XCTFail("Cached pixels must not bypass revoked access.")
        } catch AppFailure.permission { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(provider.plans.count, 1)
        provider.changeGeneration = 2
        provider.canReadImages = true
        let fresh = fixture(.blue)
        provider.image = fresh
        let result = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        XCTAssertTrue(result === fresh)
        XCTAssertEqual(provider.plans.count, 2)
    }

    func testInvalidGeometryMissingAssetAndDeniedAccessStartNoRequests() async {
        let provider = ThumbnailCacheProvider(image: fixture(.red))
        let cache = PhotoThumbnailCache(library: provider)
        let invalidValues: [CGFloat] = [0, -1, .nan, .infinity, -.infinity]
        for value in invalidValues {
            for size in [CGSize(width: value, height: 20), CGSize(width: 20, height: value)] {
                do {
                    _ = try await cache.image(id: "photo", revision: 1, targetSize: size, networkAllowed: true)
                    XCTFail("Invalid geometry must not request pixels.")
                } catch AppFailure.photo { }
                catch { XCTFail("Unexpected error: \(error)") }
            }
        }
        provider.canReadImages = false
        do {
            _ = try await cache.image(id: "photo", revision: 1, networkAllowed: true)
            XCTFail("Denied access must not request pixels.")
        } catch AppFailure.permission { }
        catch { XCTFail("Unexpected error: \(error)") }
        provider.canReadImages = true
        for revision in [nil, PhotoRevision(id: "wrong-id", modificationTime: 200)] as [PhotoRevision?] {
            provider.setRevision(revision, for: "photo")
            do {
                _ = try await cache.image(id: "photo", revision: 1, networkAllowed: true)
                XCTFail("Missing or mismatched assets must not request pixels.")
            } catch AppFailure.photo { }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(provider.plans.isEmpty)
    }

    func testGenerationChangeInvalidatesEntryEvenWhenRevisionIsUnchanged() async throws {
        let first = fixture(.red)
        let second = fixture(.blue)
        let provider = ThumbnailCacheProvider(image: first)
        let cache = PhotoThumbnailCache(library: provider)
        _ = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        provider.changeGeneration = 1
        provider.image = second
        let result = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        let again = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
        XCTAssertTrue(result === second)
        XCTAssertTrue(again === second)
        XCTAssertEqual(provider.plans.count, 2)
    }

    func testInFlightEditDeletionRevocationAndGenerationChangeRejectReturnedPixels() async throws {
        for change in InFlightChange.allCases {
            let stale = fixture(.red)
            let provider = ThumbnailCacheProvider(image: stale)
            let cache = PhotoThumbnailCache(library: provider)
            provider.holdNextRequest()
            let pending = Task { try await cache.image(id: "photo", revision: 1, networkAllowed: false) }
            await provider.waitForRequest(1)
            switch change {
            case .edit:
                provider.setRevision(PhotoRevision(id: "photo", modificationTime: 300), for: "photo")
            case .delete:
                provider.setRevision(nil, for: "photo")
            case .revoke:
                provider.canReadImages = false
            case .generation:
                provider.changeGeneration = 1
            }
            XCTAssertTrue(provider.complete(1, image: stale))
            do {
                _ = try await pending.value
                XCTFail("Changed provider state must reject returned pixels: \(change)")
            } catch {
                if change == .revoke {
                    if let failure = error as? AppFailure, case .permission = failure { }
                    else { XCTFail("Expected permission failure, got \(error)") }
                } else {
                    XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
                }
            }
            // Return to the exact original identity. A rejected result must
            // never have been inserted, even if metadata is later restored.
            provider.canReadImages = true
            provider.changeGeneration = 0
            provider.setRevision(PhotoRevision(id: "photo", modificationTime: 200, creationTime: 100), for: "photo")
            let fresh = fixture(.blue)
            provider.image = fresh
            let result = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
            XCTAssertTrue(result === fresh)
            XCTAssertEqual(provider.plans.count, 2)
        }
    }

    func testAuthorizationAndGenerationRacesDuringMetadataReadsRejectHitsAndMisses() async throws {
        for primed in [false, true] {
            for revoke in [false, true] {
                for read in [1, 2] {
                    let provider = ThumbnailCacheProvider(image: fixture(.red))
                    let cache = PhotoThumbnailCache(library: provider)
                    if primed { _ = try await cache.image(id: "photo", revision: 1, networkAllowed: false) }
                    provider.onRevisionRead(after: read) {
                        if revoke { provider.canReadImages = false }
                        else { provider.changeGeneration = 1 }
                    }
                    do {
                        _ = try await cache.image(id: "photo", revision: 1, networkAllowed: false)
                        XCTFail("Metadata-read races must not publish or start pixel requests.")
                    } catch {
                        if revoke {
                            if let failure = error as? AppFailure, case .permission = failure { }
                            else { XCTFail("Expected permission failure, got \(error)") }
                        } else {
                            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
                        }
                    }
                    XCTAssertEqual(provider.plans.count, primed ? 1 : 0)
                }
            }
        }
    }

    private enum InFlightChange: CaseIterable { case edit, delete, revoke, generation }

    private func fixture(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
    }

    private func assertCancelled(_ task: Task<UIImage, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line)
        }
    }
}

/// All mutable state is under one lock. Continuations and hooks run outside it.
/// A held request intentionally ignores cancellation to exercise the cache gate.
private final class ThumbnailCacheProvider: PhotoThumbnailProviding, @unchecked Sendable {
    struct Plan {
        let id: String
        let targetSize: CGSize
        let networkAllowed: Bool
    }

    private let lock = NSLock()
    private var readable = true
    private var generation: UInt64? = 0
    private var revisions = ["photo": PhotoRevision(id: "photo", modificationTime: 200, creationTime: 100)]
    private var output: UIImage
    private var requests: [Plan] = []
    private var holdNext = false
    private var pending: [Int: CheckedContinuation<UIImage, Error>] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var revisionHook: (remaining: Int, action: @Sendable () -> Void)?

    init(image: UIImage) { output = image }

    var canReadImages: Bool {
        get { locked { readable } }
        set { locked { readable = newValue } }
    }

    var changeGeneration: UInt64? {
        get { locked { generation } }
        set { locked { generation = newValue } }
    }

    var image: UIImage {
        get { locked { output } }
        set { locked { output = newValue } }
    }

    var plans: [Plan] { locked { requests } }

    func setRevision(_ revision: PhotoRevision?, for id: String) {
        locked { revisions[id] = revision }
    }

    func currentRevision(id: String) -> PhotoRevision? {
        var action: (@Sendable () -> Void)?
        let revision = locked {
            let result = revisions[id]
            if var hook = revisionHook {
                hook.remaining -= 1
                if hook.remaining == 0 {
                    action = hook.action
                    revisionHook = nil
                } else { revisionHook = hook }
            }
            return result
        }
        action?()
        return revision
    }

    func onRevisionRead(after count: Int, _ action: @escaping @Sendable () -> Void) {
        locked { revisionHook = (count, action) }
    }

    func holdNextRequest() { locked { holdNext = true } }

    func thumbnailImage(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            var immediate: UIImage?
            var ready: [CheckedContinuation<Void, Never>] = []
            locked {
                requests.append(Plan(id: id, targetSize: targetSize, networkAllowed: networkAllowed))
                let number = requests.count
                if holdNext {
                    holdNext = false
                    pending[number] = continuation
                } else { immediate = output }
                ready = waiters.removeValue(forKey: number) ?? []
            }
            if let immediate { continuation.resume(returning: immediate) }
            for waiter in ready { waiter.resume() }
        }
    }

    func waitForRequest(_ number: Int) async {
        await withCheckedContinuation { continuation in
            let alreadyStarted = locked {
                if requests.count >= number { return true }
                waiters[number, default: []].append(continuation)
                return false
            }
            if alreadyStarted { continuation.resume() }
        }
    }

    func complete(_ number: Int, image: UIImage) -> Bool {
        guard let continuation = locked({ pending.removeValue(forKey: number) }) else { return false }
        continuation.resume(returning: image)
        return true
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}