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

    func testBothPixelDimensionsSeparateTinyAndLargeReusableRequests() async throws {
        let provider = ThumbnailCacheProvider(image: fixture(.red))
        let cache = PhotoThumbnailCache(library: provider)
        // Identity/reuse requires real returned pixels covering each target.
        // The no-ceiling case is separate: a small raster cannot satisfy it.
        let sizes = [CGSize(width: 32, height: 32), CGSize(width: 480, height: 600),
                     CGSize(width: 481, height: 600), CGSize(width: 480, height: 601)]
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

    func testOversizedValidTargetHasNoCeilingButUndersizedPixelsAreNotReused() async throws {
        // Preserve the valid 27000x18000 request, not the old unconditional
        // reuse expectation. The quality policy requires actual pixel coverage;
        // allocating a matching multi-GB test image would test something else.
        let target = CGSize(width: 27000, height: 18000)
        let firstImage = fixture(.red)
        let secondImage = fixture(.blue)
        let provider = ThumbnailCacheProvider(image: firstImage)
        let cache = PhotoThumbnailCache(library: provider)
        let first = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: false)
        XCTAssertTrue(first.result.image === firstImage)
        XCTAssertFalse(first.cacheHit)
        XCTAssertEqual(first.result.stage, .localHQ)
        XCTAssertEqual(first.result.degraded, false)
        XCTAssertEqual(first.result.requestedSize, target)
        XCTAssertEqual(first.result.returnedSize, CGSize(width: 640, height: 800))
        XCTAssertFalse(first.result.isSufficientForDisplay)
        XCTAssertFalse(first.result.isReusable)
        XCTAssertEqual(provider.plans.count, 1)
        provider.image = secondImage
        let second = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: false)
        XCTAssertTrue(second.result.image === secondImage)
        XCTAssertFalse(second.cacheHit)
        XCTAssertEqual(second.result.requestedSize, target)
        XCTAssertEqual(second.result.returnedSize, CGSize(width: 640, height: 800))
        XCTAssertFalse(second.result.isSufficientForDisplay)
        XCTAssertFalse(second.result.isReusable)
        XCTAssertEqual(provider.plans.map(\.targetSize), [target, target])
        XCTAssertEqual(provider.plans.map(\.networkAllowed), [false, false])
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

    func testHQMetadataAndFreshVersusCachedHitArePreserved() async throws {
        let target = CGSize(width: 480, height: 600)
        let stages: [DisplayThumbnailStage] = [.localHQ, .localHQ224, .networkHQ]
        for stage in stages {
            for degraded in [nil, false] as [Bool?] {
                let image = fixture(.red)
                let provider = ThumbnailCacheProvider(image: image)
                provider.reportedStage = stage
                provider.reportedDegraded = degraded
                // A returned raster may exceed a stage's requested size. Do
                // not substitute either request size for its actual CG pixels.
                let requested = stage == .localHQ224 ? CGSize(width: 224, height: 280) : target
                provider.reportedRequestedSize = requested
                let allowed = stage == .networkHQ
                let cache = PhotoThumbnailCache(library: provider)
                let first = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target,
                                                       networkAllowed: allowed)
                XCTAssertFalse(first.cacheHit)
                XCTAssertEqual(provider.plans.count, 1)
                provider.image = fixture(.blue)
                provider.reportedStage = .localFast224
                provider.reportedDegraded = true
                provider.reportedRequestedSize = CGSize(width: 1, height: 1)
                let cached = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target,
                                                        networkAllowed: allowed)
                XCTAssertTrue(cached.cacheHit)
                let expectedAttempts = [DisplayThumbnailAttempt(stage: stage, requestedSize: requested,
                    returnedSize: CGSize(width: 640, height: 800), degraded: degraded, outcome: "native return")]
                for value in [first, cached] {
                    XCTAssertTrue(value.result.image === image)
                    XCTAssertEqual(value.result.stage, stage)
                    XCTAssertEqual(value.result.requestedSize, requested)
                    XCTAssertEqual(value.result.returnedSize, CGSize(width: 640, height: 800))
                    XCTAssertEqual(value.result.degraded, degraded)
                    XCTAssertTrue(value.result.isSufficientForDisplay)
                    XCTAssertTrue(value.result.isReusable)
                    assertAttempts(value.result.attempts, equalTo: expectedAttempts)
                }
                XCTAssertEqual(provider.plans.map(\.targetSize), [target])
                XCTAssertEqual(provider.plans.map(\.networkAllowed), [allowed])
            }
        }
    }

    func testDegradedHQIsReturnedButNotCachedEvenWithEnoughPixels() async throws {
        let target = CGSize(width: 480, height: 480)
        let stages: [DisplayThumbnailStage] = [.localHQ, .localHQ224, .networkHQ]
        for stage in stages {
            let image = fixture(.red)
            let provider = ThumbnailCacheProvider(image: image)
            provider.reportedStage = stage
            provider.reportedDegraded = true
            let requested = stage == .localHQ224 ? CGSize(width: 224, height: 280) : target
            provider.reportedRequestedSize = requested
            let cache = PhotoThumbnailCache(library: provider)
            for requestNumber in 1...2 {
                let value = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target,
                                                       networkAllowed: stage == .networkHQ)
                XCTAssertTrue(value.result.image === image)
                XCTAssertFalse(value.cacheHit)
                XCTAssertEqual(value.result.stage, stage)
                XCTAssertEqual(value.result.degraded, true)
                XCTAssertEqual(value.result.requestedSize, requested)
                XCTAssertEqual(value.result.returnedSize, CGSize(width: 640, height: 800))
                XCTAssertTrue(value.result.isSufficientForDisplay)
                XCTAssertFalse(value.result.isReusable)
                XCTAssertEqual(provider.plans.count, requestNumber)
            }
        }
    }

    func testFastIsReturnedButNeverCachedRegardlessOfDegradedFlagOrPixelCoverage() async throws {
        let target = CGSize(width: 480, height: 480)
        let fastTarget = CGSize(width: 224, height: 280)
        for degraded in [nil, false, true] as [Bool?] {
            let image = fixture(.red)
            let provider = ThumbnailCacheProvider(image: image)
            provider.reportedStage = .localFast224
            provider.reportedDegraded = degraded
            provider.reportedRequestedSize = fastTarget
            let cache = PhotoThumbnailCache(library: provider)
            for requestNumber in 1...2 {
                let value = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target,
                                                       networkAllowed: false)
                XCTAssertTrue(value.result.image === image)
                XCTAssertFalse(value.cacheHit)
                XCTAssertEqual(value.result.stage, .localFast224)
                XCTAssertEqual(value.result.degraded, degraded)
                XCTAssertEqual(value.result.requestedSize, fastTarget)
                XCTAssertEqual(value.result.returnedSize, CGSize(width: 640, height: 800))
                XCTAssertTrue(value.result.isSufficientForDisplay)
                XCTAssertFalse(value.result.isReusable)
                XCTAssertEqual(provider.plans.count, requestNumber)
            }
            XCTAssertEqual(provider.plans.map(\.networkAllowed), [false, false])
        }
    }

    func testUndersizedHQIsNotCachedWhenEitherAxisFallsShortWithNilOrFalseDegradedFlag() async throws {
        let target = CGSize(width: 480, height: 480)
        let sizes = [CGSize(width: 479, height: 640), CGSize(width: 640, height: 479)]
        let stages: [DisplayThumbnailStage] = [.localHQ, .localHQ224, .networkHQ]
        for stage in stages {
            for degraded in [nil, false] as [Bool?] {
                for size in sizes {
                    let image = fixture(.red, size: size)
                    let provider = ThumbnailCacheProvider(image: image)
                    provider.reportedStage = stage
                    provider.reportedDegraded = degraded
                    let requested = stage == .localHQ224 ? CGSize(width: 224, height: 280) : target
                    provider.reportedRequestedSize = requested
                    let cache = PhotoThumbnailCache(library: provider)
                    for requestNumber in 1...2 {
                        let value = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target,
                                                               networkAllowed: stage == .networkHQ)
                        XCTAssertTrue(value.result.image === image)
                        XCTAssertFalse(value.cacheHit)
                        XCTAssertEqual(value.result.stage, stage)
                        XCTAssertEqual(value.result.degraded, degraded)
                        XCTAssertEqual(value.result.requestedSize, requested)
                        XCTAssertEqual(value.result.returnedSize, size)
                        XCTAssertFalse(value.result.isSufficientForDisplay)
                        XCTAssertFalse(value.result.isReusable)
                        XCTAssertEqual(provider.plans.count, requestNumber)
                    }
                }
            }
        }
    }

    func testNonReusableResultsUpgradeOnlyOnALaterExplicitRequest() async throws {
        let target = CGSize(width: 480, height: 480)
        let fullSize = CGSize(width: 640, height: 800)
        let cases: [(stage: DisplayThumbnailStage, degraded: Bool?, size: CGSize)] = [
            (.localHQ, true, fullSize), (.localFast224, false, fullSize),
            (.localHQ, nil, CGSize(width: 224, height: 280)), (.unknown, nil, fullSize)
        ]
        for delivery in cases {
            let low = fixture(.red, size: delivery.size)
            let provider = ThumbnailCacheProvider(image: low)
            provider.reportedStage = delivery.stage
            provider.reportedDegraded = delivery.degraded
            let cache = PhotoThumbnailCache(library: provider)
            let first = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: false)
            XCTAssertTrue(first.result.image === low)
            XCTAssertFalse(first.cacheHit)
            XCTAssertEqual(first.result.stage, delivery.stage)
            XCTAssertEqual(first.result.degraded, delivery.degraded)
            XCTAssertEqual(first.result.returnedSize, delivery.size)
            XCTAssertFalse(first.result.isReusable)
            XCTAssertEqual(provider.plans.count, 1, "Returning usable low-quality pixels must not retry implicitly.")

            let high = fixture(.blue)
            provider.image = high
            provider.reportedStage = .localHQ
            provider.reportedDegraded = false
            let upgraded = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target,
                                                       networkAllowed: false)
            XCTAssertFalse(upgraded.cacheHit)
            XCTAssertEqual(provider.plans.count, 2)
            let cached = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: false)
            XCTAssertTrue(cached.cacheHit)
            for value in [upgraded, cached] {
                XCTAssertTrue(value.result.image === high)
                XCTAssertEqual(value.result.stage, .localHQ)
                XCTAssertEqual(value.result.degraded, false)
                XCTAssertEqual(value.result.returnedSize, fullSize)
                XCTAssertTrue(value.result.isSufficientForDisplay)
                XCTAssertTrue(value.result.isReusable)
            }
            XCTAssertEqual(provider.plans.map(\.targetSize), [target, target])
            XCTAssertEqual(provider.plans.map(\.networkAllowed), [false, false])
        }
    }

    func testGenuineHQ224BelowDisplayTargetIsReturnedAndRetriedWithoutCaching() async throws {
        let target = CGSize(width: 521, height: 651)
        let hq224Target = CGSize(width: 224, height: 398)
        let image = fixture(.red, size: hq224Target)
        let pixels = try XCTUnwrap(image.cgImage)
        let returnedSize = CGSize(width: pixels.width, height: pixels.height)
        let provider = ThumbnailCacheProvider(image: image)
        provider.reportedStage = .localHQ224
        provider.reportedDegraded = false
        provider.reportedRequestedSize = hq224Target
        let attempts = [
            DisplayThumbnailAttempt(stage: .localHQ, requestedSize: target, returnedSize: nil,
                                    degraded: nil, outcome: "no resource"),
            DisplayThumbnailAttempt(stage: .localHQ224, requestedSize: hq224Target, returnedSize: returnedSize,
                                    degraded: false, outcome: "native return")
        ]
        provider.reportedAttempts = attempts
        let cache = PhotoThumbnailCache(library: provider)
        for requestNumber in 1...2 {
            let value = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: false)
            XCTAssertTrue(value.result.image === image)
            XCTAssertFalse(value.cacheHit)
            XCTAssertEqual(value.result.stage, .localHQ224)
            XCTAssertEqual(value.result.degraded, false)
            XCTAssertEqual(value.result.requestedSize, hq224Target)
            XCTAssertEqual(value.result.returnedSize, hq224Target)
            XCTAssertFalse(value.result.isSufficientForDisplay)
            XCTAssertFalse(value.result.isReusable)
            assertAttempts(value.result.attempts, equalTo: attempts)
            XCTAssertEqual(provider.plans.count, requestNumber)
        }
        XCTAssertEqual(provider.plans.map(\.targetSize), [target, target])
        XCTAssertEqual(provider.plans.map(\.networkAllowed), [false, false])
    }

    func testLegacyImageOnlyAdapterCannotClaimSourceOrCacheEvenSufficientPixels() async throws {
        let target = CGSize(width: 480, height: 480)
        let source = ThumbnailCacheProvider(image: fixture(.red))
        // Deliberately known metadata behind the image-only boundary: the
        // protocol default must not invent or recover this discarded provenance.
        source.reportedStage = .networkHQ
        source.reportedDegraded = false
        let legacy = LegacyThumbnailCacheProvider(source: source)
        let cache = PhotoThumbnailCache(library: legacy)
        for requestNumber in 1...2 {
            let image = fixture(requestNumber == 1 ? .red : .blue)
            source.image = image
            let value = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: true)
            XCTAssertTrue(value.result.image === image)
            XCTAssertFalse(value.cacheHit)
            XCTAssertEqual(value.result.stage, .unknown)
            XCTAssertNil(value.result.degraded)
            XCTAssertEqual(value.result.requestedSize, target)
            XCTAssertEqual(value.result.returnedSize, CGSize(width: 640, height: 800))
            XCTAssertTrue(value.result.attempts.isEmpty)
            XCTAssertTrue(value.result.isSufficientForDisplay)
            XCTAssertFalse(value.result.isReusable)
            XCTAssertEqual(source.plans.count, requestNumber)
        }
        let third = fixture(.green)
        source.image = third
        let compatible = try await cache.image(id: "photo", revision: 1, networkAllowed: true)
        XCTAssertTrue(compatible === third)
        XCTAssertEqual(source.plans.map(\.targetSize), [target, target, target])
        XCTAssertEqual(source.plans.map(\.networkAllowed), [true, true, true])
    }

    func testRightOrientedPortraitRasterCoversLandscapeTargetIndependentOfImageScale() async throws {
        let raw = fixture(.red, size: CGSize(width: 180, height: 240))
        let pixels = try XCTUnwrap(raw.cgImage)
        let image = UIImage(cgImage: pixels, scale: 3, orientation: .right)
        let target = CGSize(width: 240, height: 180)
        let provider = ThumbnailCacheProvider(image: image)
        let cache = PhotoThumbnailCache(library: provider)
        let first = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: false)
        let cached = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: false)
        XCTAssertFalse(first.cacheHit)
        XCTAssertTrue(cached.cacheHit)
        for value in [first, cached] {
            XCTAssertTrue(value.result.image === image)
            XCTAssertTrue(value.result.image.cgImage === pixels)
            XCTAssertEqual(value.result.image.scale, 3)
            XCTAssertEqual(value.result.image.imageOrientation, .right)
            XCTAssertEqual(value.result.requestedSize, target)
            XCTAssertEqual(value.result.returnedSize, CGSize(width: 180, height: 240))
            XCTAssertEqual(value.result.attempts.first?.returnedSize, CGSize(width: 180, height: 240))
            XCTAssertEqual(DisplayThumbnailResult.displayCoverage(returnedSize: value.result.returnedSize,
                orientation: value.result.image.imageOrientation, targetSize: target), 1, accuracy: 0.000001)
            XCTAssertTrue(value.result.isSufficientForDisplay)
            XCTAssertTrue(value.result.isReusable)
        }
        XCTAssertEqual(provider.plans.map(\.targetSize), [target])
    }

    func testRightOrientedPortraitRasterDoesNotCoverUnrotatedPortraitTarget() async throws {
        let rawSize = CGSize(width: 180, height: 240)
        let raw = fixture(.red, size: rawSize)
        let image = UIImage(cgImage: try XCTUnwrap(raw.cgImage), scale: 3, orientation: .right)
        let provider = ThumbnailCacheProvider(image: image)
        let cache = PhotoThumbnailCache(library: provider)
        // Raw dimensions match, but rotation makes the display height only 180.
        for requestNumber in 1...2 {
            let value = try await cache.thumbnail(id: "photo", revision: 1, targetSize: rawSize, networkAllowed: false)
            XCTAssertTrue(value.result.image === image)
            XCTAssertFalse(value.cacheHit)
            XCTAssertEqual(value.result.stage, .localHQ)
            XCTAssertEqual(value.result.degraded, false)
            XCTAssertEqual(value.result.returnedSize, rawSize)
            XCTAssertEqual(DisplayThumbnailResult.displayCoverage(returnedSize: value.result.returnedSize,
                orientation: value.result.image.imageOrientation, targetSize: rawSize), 0.75, accuracy: 0.000001)
            XCTAssertFalse(value.result.isSufficientForDisplay)
            XCTAssertFalse(value.result.isReusable)
            XCTAssertEqual(provider.plans.count, requestNumber)
        }
    }

    func testFullAttemptHistorySurvivesFreshResultAndCacheHit() async throws {
        let target = CGSize(width: 521, height: 651)
        let small = fixture(.red, size: CGSize(width: 32, height: 16))
        let hq224 = fixture(.green, size: CGSize(width: 224, height: 280))
        let image = fixture(.blue)
        let smallPixels = try XCTUnwrap(small.cgImage)
        let hq224Pixels = try XCTUnwrap(hq224.cgImage)
        let pixels = try XCTUnwrap(image.cgImage)
        let attempts = [
            DisplayThumbnailAttempt(stage: .localHQ, requestedSize: target,
                returnedSize: CGSize(width: smallPixels.width, height: smallPixels.height),
                degraded: true, outcome: "native return"),
            DisplayThumbnailAttempt(stage: .localHQ224, requestedSize: CGSize(width: 224, height: 280),
                returnedSize: CGSize(width: hq224Pixels.width, height: hq224Pixels.height),
                degraded: false, outcome: "native return"),
            DisplayThumbnailAttempt(stage: .networkHQ, requestedSize: target,
                returnedSize: CGSize(width: pixels.width, height: pixels.height),
                degraded: nil, outcome: "native return")
        ]
        let provider = ThumbnailCacheProvider(image: image)
        provider.reportedStage = .networkHQ
        provider.reportedDegraded = nil
        provider.reportedAttempts = attempts
        let cache = PhotoThumbnailCache(library: provider)
        let first = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: true)
        XCTAssertFalse(first.cacheHit)
        provider.reportedAttempts = []
        provider.reportedStage = .unknown
        let cached = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: true)
        XCTAssertTrue(cached.cacheHit)
        for value in [first, cached] {
            XCTAssertTrue(value.result.image === image)
            XCTAssertEqual(value.result.stage, .networkHQ)
            XCTAssertEqual(value.result.requestedSize, target)
            XCTAssertEqual(value.result.returnedSize, CGSize(width: 640, height: 800))
            XCTAssertNil(value.result.degraded)
            XCTAssertTrue(value.result.isSufficientForDisplay)
            XCTAssertTrue(value.result.isReusable)
            assertAttempts(value.result.attempts, equalTo: attempts)
        }
        XCTAssertEqual(provider.plans.count, 1)
    }

    func testLowQualityMetadataResultStillRejectsInFlightAccessAndRevisionChanges() async throws {
        let target = CGSize(width: 480, height: 480)
        for change in InFlightChange.allCases {
            let stale = fixture(.red, size: CGSize(width: 224, height: 280))
            let provider = ThumbnailCacheProvider(image: stale)
            provider.reportedStage = .localHQ224
            provider.reportedRequestedSize = CGSize(width: 224, height: 280)
            let cache = PhotoThumbnailCache(library: provider)
            provider.holdNextRequest()
            let pending = Task {
                try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: false)
            }
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
                XCTFail("Non-reusable pixels must not bypass publication validation: \(change)")
            } catch {
                if change == .revoke {
                    if let failure = error as? AppFailure, case .permission = failure { }
                    else { XCTFail("Expected permission failure, got \(error)") }
                } else {
                    XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
                }
            }
            provider.canReadImages = true
            provider.changeGeneration = 0
            provider.setRevision(PhotoRevision(id: "photo", modificationTime: 200, creationTime: 100), for: "photo")
            let fresh = fixture(.blue)
            provider.image = fresh
            provider.reportedStage = .localHQ
            provider.reportedRequestedSize = nil
            let replacement = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target,
                                                         networkAllowed: false)
            let cached = try await cache.thumbnail(id: "photo", revision: 1, targetSize: target, networkAllowed: false)
            XCTAssertFalse(replacement.cacheHit)
            XCTAssertTrue(cached.cacheHit)
            XCTAssertTrue(replacement.result.image === fresh)
            XCTAssertTrue(cached.result.image === fresh)
            XCTAssertEqual(provider.plans.count, 2)
        }
    }

    private enum InFlightChange: CaseIterable { case edit, delete, revoke, generation }

    private func fixture(_ color: UIColor, size: CGSize = CGSize(width: 640, height: 800)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        // Default identity fixtures cover ordinary display targets (~2 MB at
        // 4 bytes/pixel), unlike the old 32x24 raster. Never allocate the huge
        // target used to check that request geometry has no arbitrary ceiling.
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
        }
        if let pixels = image.cgImage {
            XCTAssertLessThan(pixels.bytesPerRow * pixels.height, 10_000_000, "Fixture-only memory budget.")
        } else { XCTFail("Generated fixtures must have real CGImage pixels.") }
        return image
    }

    private func assertAttempts(_ actual: [DisplayThumbnailAttempt], equalTo expected: [DisplayThumbnailAttempt],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual.stage, expected.stage, file: file, line: line)
            XCTAssertEqual(actual.requestedSize, expected.requestedSize, file: file, line: line)
            XCTAssertEqual(actual.returnedSize, expected.returnedSize, file: file, line: line)
            XCTAssertEqual(actual.degraded, expected.degraded, file: file, line: line)
            XCTAssertEqual(actual.outcome, expected.outcome, file: file, line: line)
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
    private struct Metadata {
        var stage: DisplayThumbnailStage = .localHQ
        var requestedSize: CGSize?
        var degraded: Bool? = false
        var attempts: [DisplayThumbnailAttempt]?
    }
    private struct PendingRequest {
        let continuation: CheckedContinuation<DisplayThumbnailResult, Error>
        let targetSize: CGSize
        let metadata: Metadata

        func resume(returning image: UIImage) {
            // Report the actual returned raster, including for late completions.
            // Requested sizes, UIImage points/scale and orientation never replace
            // raw CG dimensions; DisplayThumbnailResult applies orientation once.
            let returned = image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            let requested = metadata.requestedSize ?? targetSize
            let attempts = metadata.attempts ?? [DisplayThumbnailAttempt(stage: metadata.stage,
                requestedSize: requested, returnedSize: returned, degraded: metadata.degraded,
                outcome: "native return")]
            continuation.resume(returning: DisplayThumbnailResult(image: image, stage: metadata.stage,
                requestedSize: requested, returnedSize: returned, degraded: metadata.degraded,
                attempts: attempts, targetSize: targetSize))
        }
    }
    private var metadata = Metadata()
    private var requests: [Plan] = []
    private var holdNext = false
    private var pending: [Int: PendingRequest] = [:]
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

    var reportedStage: DisplayThumbnailStage {
        get { locked { metadata.stage } }
        set { locked { metadata.stage = newValue } }
    }

    var reportedDegraded: Bool? {
        get { locked { metadata.degraded } }
        set { locked { metadata.degraded = newValue } }
    }

    var reportedRequestedSize: CGSize? {
        get { locked { metadata.requestedSize } }
        set { locked { metadata.requestedSize = newValue } }
    }

    var reportedAttempts: [DisplayThumbnailAttempt]? {
        get { locked { metadata.attempts } }
        set { locked { metadata.attempts = newValue } }
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
        try await thumbnailResult(id: id, targetSize: targetSize, networkAllowed: networkAllowed).image
    }

    func thumbnailResult(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> DisplayThumbnailResult {
        try await withCheckedThrowingContinuation { continuation in
            var immediate: (request: PendingRequest, image: UIImage)?
            var ready: [CheckedContinuation<Void, Never>] = []
            locked {
                requests.append(Plan(id: id, targetSize: targetSize, networkAllowed: networkAllowed))
                let number = requests.count
                // Snapshot under the same lock as request registration. A held
                // request keeps its own provenance while a replacement starts.
                let request = PendingRequest(continuation: continuation, targetSize: targetSize, metadata: metadata)
                if holdNext {
                    holdNext = false
                    pending[number] = request
                } else { immediate = (request, output) }
                ready = waiters.removeValue(forKey: number) ?? []
            }
            if let immediate { immediate.request.resume(returning: immediate.image) }
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
        guard let request = locked({ pending.removeValue(forKey: number) }) else { return false }
        request.resume(returning: image)
        return true
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

/// Intentionally omits thumbnailResult: exercise the actual protocol default,
/// not another fake that manufactures a known source for UIImage-only clients.
private final class LegacyThumbnailCacheProvider: PhotoThumbnailProviding, Sendable {
    let source: ThumbnailCacheProvider

    init(source: ThumbnailCacheProvider) { self.source = source }

    var canReadImages: Bool { source.canReadImages }
    var changeGeneration: UInt64? { source.changeGeneration }
    func currentRevision(id: String) -> PhotoRevision? { source.currentRevision(id: id) }

    func thumbnailImage(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> UIImage {
        try await source.thumbnailImage(id: id, targetSize: targetSize, networkAllowed: networkAllowed)
    }
}