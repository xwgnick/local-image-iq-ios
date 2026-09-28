import Foundation
import XCTest
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Model-free contracts: all text, IDs, embeddings, scores and errors are synthetic.
/// No Apple translation session, Photos fetch, encoder, database or network service
/// is used by either fake. AppState still owns its normal library/observer wrapper.
/// Held calls deliberately ignore cancellation until released by the test/teardown.
@MainActor
final class QueryTranslationStateTests: XCTestCase {
    // MARK: Routing without depending on NaturalLanguage's ambiguous dialect guesses

    func testRouterBypassesEnglishNumbersWhitespaceAndNonHanScripts() {
        for text in ["a dog with a white pen", " 12345 \n", "", " \t\r\n",
                     "café e\u{301} 🖊️", "مرحبا", "Привет"] {
            XCTAssertNil(ChineseQueryRouter.sourceLanguage(for: text), text)
        }
    }

    func testRouterAcceptsChineseAndMixedStringsWithoutAssumingDialect() {
        for text in ["一只小狗叼着白色的笔", " \t小狗 with a white pen\n ",
                     "這是一張在臺灣拍攝的風景照片"] {
            // Routing Han is the contract; do not freeze NLLanguageRecognizer's
            // simplified/traditional decision for a short or mixed query.
            XCTAssertNotNil(ChineseQueryRouter.sourceLanguage(for: text), text)
        }
    }

    func testRouterBypassesJapaneseKanaAndKoreanEvenWhenHanIsPresent() {
        for text in ["白い犬の写真", "犬 カメラ", "犬 ｶﾒﾗ", "犬 ㇰ",
                     "강아지 사진", "犬 사진", "犬 ᄀ", "犬 ㄱ"] {
            XCTAssertNil(ChineseQueryRouter.sourceLanguage(for: text), text)
        }
    }

    // MARK: Original bytes and the unchanged search boundary

    func testEnglishAndNonHanSearchesBypassTranslationAndPreserveWhitespace() async {
        let context = await readyContext()
        let queries = [" \tDog with a WHITE pen\r\n ", " 12345 \n",
                       " café e\u{301} 🖊️ ", " 犬の写真 ", " 犬 사진 "]
        for query in queries {
            context.state.query = query
            context.state.search()
            await drain(context)
            assertResolution(context, original: query, effective: query, translated: false)
            assertLastSearch(context, text: query)
        }
        XCTAssertEqual(context.worker.searchRequests.count, queries.count)
        assertTranslationCounts(context, availability: 0, translation: 0, preparation: 0)
        assertNoIndexWork(context)
    }

    func testWhitespaceOnlyQueriesStartNeitherSearchNorTranslation() async {
        let context = await readyContext()
        for query in ["", " ", "\t\r\n", " \u{3000} \n"] {
            context.state.query = query
            XCTAssertFalse(context.state.canSearch)
            context.state.search()
            await drain(context)
            assertNoPublishedSearch(context.state)
        }
        XCTAssertTrue(context.worker.searchRequests.isEmpty)
        assertTranslationCounts(context, availability: 0, translation: 0, preparation: 0)
        assertNoIndexWork(context)
    }

    func testDisabledChineseSearchBypassesEvenAnUnsupportedTranslator() async {
        let context = await readyContext()
        context.state.chineseSearchEnabled = false
        context.translator.isSupported = false
        let query = " \t小狗 with a white pen\n "
        context.state.query = query
        context.state.search()
        await drain(context)
        assertResolution(context, original: query, effective: query, translated: false)
        assertLastSearch(context, text: query)
        assertTranslationCounts(context, availability: 0, translation: 0, preparation: 0)
        assertNoIndexWork(context)
    }

    func testChineseAndMixedQueriesAreTranslatedAsOneWholeString() async {
        let context = await readyContext()
        let queries = ["一只小狗叼着白色的笔", " \t小狗 with a WHITE pen\n ",
                       "這是一張在臺灣拍攝的風景照片"]
        for (index, original) in queries.enumerated() {
            let effective = " \tTEST FIXTURE translated whole query \(index)\n "
            context.translator.translationResult = .success(effective)
            context.state.query = original
            context.state.search()
            await drain(context)

            assertTranslationCounts(context, availability: index + 1, translation: index + 1, preparation: 0)
            guard let request = context.translator.translationRequests.last else {
                XCTFail("The complete query must reach the translator")
                return
            }
            XCTAssertEqual(Array(request.text.utf8), Array(original.utf8))
            XCTAssertEqual(request.language, context.translator.availabilityRequests.last)
            assertResolution(context, original: original, effective: effective, translated: true)
            assertLastSearch(context, text: effective)
        }
        assertNoIndexWork(context)
    }

    func testTranslationPreservesHitOrderExactScoresLimitWeightAndIndexSummary() async {
        let context = await readyContext()
        let original = "白色的笔和小狗"
        let effective = "TEST FIXTURE a white pen and a dog"
        context.translator.translationResult = .success(effective)
        context.state.query = original
        context.state.resultLimit = 12
        context.state.locationWeight = 0.37
        context.state.search()
        await drain(context)

        assertResolution(context, original: original, effective: effective, translated: true)
        assertLastSearch(context, text: effective, limit: 12, weight: 0.37)
        let expected = context.worker.response
        XCTAssertEqual(context.state.results.map(\.id), expected.hits.map(\.id))
        XCTAssertEqual(context.state.results.map { $0.score.bitPattern }, expected.hits.map { $0.score.bitPattern })
        XCTAssertEqual(context.state.results.map { $0.photo.modelVersion }, expected.hits.map { $0.photo.modelVersion })
        XCTAssertEqual(context.state.results.map { $0.photo.imageEmbedding }, expected.hits.map { $0.photo.imageEmbedding })
        XCTAssertEqual(context.state.summary.authorizedCount, expected.summary.authorizedCount)
        XCTAssertEqual(context.state.summary.indexedCount, expected.summary.indexedCount)
        XCTAssertEqual(context.state.summary.locatedCount, expected.summary.locatedCount)
        XCTAssertEqual(context.state.summary.modelVersion, expected.summary.modelVersion)
        XCTAssertEqual(context.state.summary.placesDescription, expected.summary.placesDescription)
        XCTAssertEqual(context.worker.refreshCount, 1, "Translation must not refresh/rebuild the index")
        assertTranslationCounts(context, availability: 1, translation: 1, preparation: 0)
        assertNoIndexWork(context)
    }

    // MARK: Offline failures use the original, with visible sanitized notices

    func testEmptyAndWhitespaceTranslationResultsFallBackVisibly() async {
        for result in ["", " \t\r\n "] {
            let context = await readyContext()
            context.translator.translationResult = .success(result)
            await assertFallback(context, failure: .emptyResult)
            assertTranslationCounts(context, availability: 1, translation: 1, preparation: 0)
        }
    }

    func testTypedTranslationFailuresFallBackVisiblyWithoutGlobalError() async {
        for failure in [QueryTranslationFailure.notInstalled, .unsupported, .unavailable, .emptyResult] {
            let context = await readyContext()
            context.translator.translationResult = .failure(failure)
            await assertFallback(context, failure: failure)
            assertTranslationCounts(context, availability: 1, translation: 1, preparation: 0)
        }
    }

    func testPrivateTranslationErrorFallsBackWithoutLeakingItsDescription() async {
        let context = await readyContext()
        context.translator.translationResult = .failure(QueryTranslationPrivateError())
        await assertFallback(context, failure: .unavailable)
        assertTranslationCounts(context, availability: 1, translation: 1, preparation: 0)
        assertNoPrivateErrorDetails(context.state)
    }

    func testUnsupportedSystemSearchesOriginalWithoutAvailabilityTranslateOrPrepare() async {
        let context = await readyContext()
        context.translator.isSupported = false
        XCTAssertFalse(context.state.translationSupported)
        await assertFallback(context, failure: .unsupported)
        context.state.prepareTranslation()
        await drain(context)
        assertTranslationCounts(context, availability: 0, translation: 0, preparation: 0)
        XCTAssertEqual(context.worker.searchRequests.count, 1)
        assertNoIndexWork(context)
    }

    func testMissingUnsupportedAndUnavailablePacksNeverTranslateOrPrepareDuringSearch() async {
        let cases: [(QueryTranslationAvailability, QueryTranslationFailure)] = [
            (.downloadRequired, .notInstalled), (.unsupported, .unsupported),
            (.unchecked, .unavailable), (.unavailable, .unavailable)
        ]
        for (availability, failure) in cases {
            let context = await readyContext()
            context.translator.availabilityResult = availability
            await assertFallback(context, failure: failure)
            assertTranslationCounts(context, availability: 1, translation: 0, preparation: 0)
        }
    }

    // MARK: Preparation is explicit, isolated from Photos and index work

    func testAvailabilityChecksAloneNeverPrepareTranslateOrStartPhotoWork() async {
        let context = makeContext()
        XCTAssertEqual(context.state.translationAvailability, .unchecked)
        XCTAssertTrue(context.state.chineseSearchEnabled)
        XCTAssertNil(context.state.appleTranslationService, "The injected fake must replace the Apple service")
        assertTranslationCounts(context, availability: 0, translation: 0, preparation: 0)
        for language in QueryTranslationLanguage.allCases {
            context.state.translationLanguage = language
            context.translator.availabilityResult = .downloadRequired
            await checkAvailability(context)
            XCTAssertEqual(context.state.translationAvailability, .downloadRequired)
            XCTAssertEqual(context.translator.availabilityRequests.last, language)
        }
        assertTranslationCounts(context, availability: 2, translation: 0, preparation: 0)
        XCTAssertEqual(context.worker.refreshCount, 0)
        XCTAssertTrue(context.worker.searchRequests.isEmpty)
        assertNoIndexWork(context)
    }

    func testPendingSettingsAvailabilityCannotOverwriteCompletedPreparation() async {
        let context = makeContext()
        context.translator.availabilityResult = .downloadRequired
        let oldCheck = await startHeldAvailabilityCheck(context)

        context.state.prepareTranslation()
        await drain(context, expectedActiveCalls: 1)
        XCTAssertEqual(context.state.translationAvailability, .installed)
        XCTAssertNil(context.state.translationPreparationIssue)
        XCTAssertEqual(context.translator.prepareRequests, [.simplified])
        assertTranslationCounts(context, availability: 2, translation: 0, preparation: 1)

        // Preparation, including its ready check, has finished before the old
        // Settings check returns its captured missing-pack result.
        context.translator.release(.availability)
        await oldCheck.value
        await drain(context)
        XCTAssertEqual(context.state.translationAvailability, .installed)
        XCTAssertNil(context.state.translationPreparationIssue)
        XCTAssertTrue(context.translator.cancelledPhases.isEmpty)
        assertTranslationCounts(context, availability: 2, translation: 0, preparation: 1)
        XCTAssertEqual(context.worker.refreshCount, 0)
        XCTAssertTrue(context.worker.searchRequests.isEmpty)
        assertNoPublishedSearch(context.state)
        assertNoIndexWork(context)
    }

    func testOnlyExplicitPreparationInstallsPackAndDoesNotChangePhotoNetworkPreference() async {
        for cloudEnabled in [false, true] {
            let context = await readyContext()
            context.state.allowICloudDownload = cloudEnabled
            context.translator.availabilityResult = .downloadRequired
            await checkAvailability(context)
            await assertFallback(context, failure: .notInstalled, cloudEnabled: cloudEnabled)
            assertTranslationCounts(context, availability: 2, translation: 0, preparation: 0)

            context.state.prepareTranslation()
            await drain(context)
            XCTAssertEqual(context.state.translationAvailability, .installed)
            XCTAssertNil(context.state.translationPreparationIssue)
            XCTAssertEqual(context.translator.prepareRequests, [.simplified])
            assertTranslationCounts(context, availability: 3, translation: 0, preparation: 1)
            XCTAssertEqual(context.worker.searchRequests.count, 1, "Preparing a pack must not run a photo search")

            context.state.search()
            await drain(context)
            assertResolution(context, original: context.state.query,
                             effective: QueryTranslationFixtures.english, translated: true)
            assertTranslationCounts(context, availability: 4, translation: 1, preparation: 1)
            XCTAssertEqual(context.worker.refreshCount, 1)
            XCTAssertEqual(context.worker.searchRequests.count, 2)
            assertNoIndexWork(context, cloudEnabled: cloudEnabled)
        }
    }

    func testPreparationPrivateErrorIsVisibleButSanitizedAndStartsNoPhotoWork() async {
        let context = makeContext()
        context.translator.preparationError = QueryTranslationPrivateError()
        context.state.prepareTranslation()
        await drain(context)
        XCTAssertFalse(context.state.translationPreparationIssue?.isEmpty ?? true)
        XCTAssertEqual(context.state.translationAvailability, .unchecked)
        XCTAssertNil(context.state.errorMessage)
        XCTAssertNil(context.state.actionHint)
        assertNoPrivateErrorDetails(context.state)
        assertTranslationCounts(context, availability: 0, translation: 0, preparation: 1)
        XCTAssertEqual(context.worker.refreshCount, 0)
        XCTAssertTrue(context.worker.searchRequests.isEmpty)
        assertNoIndexWork(context)
    }

    // MARK: Per-search original action and diagnostic query semantics

    func testUseOriginalAppliesOnceThenNormalSearchTranslatesAgain() async {
        let context = await readyContext()
        let original = " \t小狗和白色的笔\n "
        context.state.query = original
        context.state.search()
        await drain(context)
        assertResolution(context, original: original, effective: QueryTranslationFixtures.english, translated: true)

        context.state.search(useOriginal: true)
        await drain(context)
        assertResolution(context, original: original, effective: original, translated: false)
        XCTAssertEqual(context.state.photoCheckInitialQuery, original)
        XCTAssertTrue(context.state.chineseSearchEnabled, "Use original is not a persistent toggle")
        assertTranslationCounts(context, availability: 1, translation: 1, preparation: 0)

        context.state.search()
        await drain(context)
        assertResolution(context, original: original, effective: QueryTranslationFixtures.english, translated: true)
        assertTranslationCounts(context, availability: 2, translation: 2, preparation: 0)
        XCTAssertEqual(context.worker.searchRequests.map(\.text),
                       [QueryTranslationFixtures.english, original, QueryTranslationFixtures.english])
        assertNoIndexWork(context)
    }

    func testDiagnosticStartsWithEffectiveQueryAndNeverRetranslatesEvenEditedChinese() async throws {
        let context = await readyContext()
        let state = context.state
        state.query = "小狗和白色的笔"
        state.locationWeight = 0.37
        state.search()
        await drain(context)
        let resolution = state.completedSearchQuery
        let hits = state.results
        let selectedID = try XCTUnwrap(hits.first?.id)
        state.selection = AppState.Selection(id: selectedID)
        XCTAssertEqual(state.photoCheckInitialQuery, QueryTranslationFixtures.english)

        XCTAssertFalse(state.debugToolsEnabled)
        state.debugToolsEnabled = true // Only this test invokes the debug-only diagnostic operation.
        for diagnosticQuery in [state.photoCheckInitialQuery, " \t诊断编辑后的中文查询\n "] {
            state.checkPhoto(id: selectedID, query: diagnosticQuery)
            await drain(context)
            let request = try XCTUnwrap(context.worker.checkRequests.last)
            let report = try XCTUnwrap(state.photoCheckReport)
            XCTAssertEqual(request.id, selectedID)
            XCTAssertEqual(Array(request.query.utf8), Array(diagnosticQuery.utf8))
            XCTAssertEqual(Array(report.query.utf8), Array(diagnosticQuery.utf8))
            XCTAssertEqual(request.weight.bitPattern, Float(0.37).bitPattern)
            XCTAssertEqual(report.locationWeight.bitPattern, request.weight.bitPattern)
            XCTAssertEqual(report.photoID, selectedID)
            // This fake did not request pixels. Never invent PhotoKit provenance.
            XCTAssertNil(report.source)
            XCTAssertNil(report.pixelWidth)
            XCTAssertNil(report.pixelHeight)
            XCTAssertEqual(state.completedSearchQuery, resolution)
            XCTAssertEqual(state.results.map(\.id), hits.map(\.id))
            XCTAssertEqual(state.results.map { $0.score.bitPattern }, hits.map { $0.score.bitPattern })
            XCTAssertEqual(state.selection?.id, selectedID)
            XCTAssertEqual(state.photoCheckInitialQuery, QueryTranslationFixtures.english)
            XCTAssertNil(state.photoCheckIssue)
            assertTranslationCounts(context, availability: 1, translation: 1, preparation: 0)
        }
        XCTAssertEqual(context.worker.searchRequests.count, 1)
        XCTAssertEqual(context.worker.checkRequests.count, 2)
        assertNoIndexWork(context, expectedChecks: 2)
    }

    func testDiagnosticInitialQueryUsesOriginalOnFallbackAndCurrentQueryAfterEdit() async {
        let context = await readyContext()
        context.translator.availabilityResult = .downloadRequired
        await assertFallback(context, failure: .notInstalled)
        XCTAssertEqual(context.state.photoCheckInitialQuery, context.state.completedQuery)
        let edited = " \t另一个原文查询\n "
        context.state.query = edited
        await drain(context)
        assertNoPublishedSearch(context.state)
        XCTAssertEqual(Array(context.state.photoCheckInitialQuery.utf8), Array(edited.utf8))
        assertTranslationCounts(context, availability: 1, translation: 0, preparation: 0)
    }

    // MARK: Noninterruptible availability AND translation must reject stale work

    func testCancelDuringHeldAvailabilityRejectsLateCompletion() async {
        await assertInvalidation(.cancel, during: .availability)
    }

    func testCancelDuringHeldTranslationRejectsLateCompletion() async {
        await assertInvalidation(.cancel, during: .translation)
    }

    func testQueryEditDuringHeldAvailabilityRejectsLateCompletion() async {
        await assertInvalidation(.query, during: .availability)
    }

    func testQueryEditDuringHeldTranslationRejectsLateCompletion() async {
        await assertInvalidation(.query, during: .translation)
    }

    func testWeightEditDuringHeldAvailabilityRejectsLateCompletion() async {
        await assertInvalidation(.weight, during: .availability)
    }

    func testWeightEditDuringHeldTranslationRejectsLateCompletion() async {
        await assertInvalidation(.weight, during: .translation)
    }

    func testToggleDuringHeldAvailabilityRejectsLateCompletion() async {
        await assertInvalidation(.toggle, during: .availability)
    }

    func testToggleDuringHeldTranslationRejectsLateCompletion() async {
        await assertInvalidation(.toggle, during: .translation)
    }

    func testBackgroundDuringHeldAvailabilityRejectsLateCompletion() async {
        await assertInvalidation(.background, during: .availability)
    }

    func testBackgroundDuringHeldTranslationRejectsLateCompletion() async {
        await assertInvalidation(.background, during: .translation)
    }

    func testResultLimitEditRejectsLateAvailabilityAndTranslation() async {
        for phase in [QueryTranslationTestPhase.availability, .translation] {
            await assertInvalidation(.limit, during: phase)
        }
    }

    // MARK: Cancellation is not completion; successors must await the entire drain

    func testSuccessorRefreshWaitsForHeldAvailabilityToDrain() async {
        await assertSuccessorWaits(during: .availability, throughBackground: false)
    }

    func testSuccessorRefreshWaitsForHeldTranslationToDrain() async {
        await assertSuccessorWaits(during: .translation, throughBackground: false)
    }

    func testForegroundRefreshWaitsForCancelledAvailabilityAndTranslationToDrain() async {
        for phase in [QueryTranslationTestPhase.availability, .translation] {
            await assertSuccessorWaits(during: phase, throughBackground: true)
        }
    }

    // MARK: Inactive/active consent transitions are not background transitions

    func testRepeatedForegroundWithoutBackgroundDoesNotCancelHeldPreparation() async {
        let context = makeContext()
        await startHeldPreparation(context, phase: .preparation)
        // Scene .inactive has no AppState callback. A consent dialog returning to
        // .active calls enterForeground again without first calling enterBackground.
        context.state.enterForeground()
        context.state.enterForeground()
        XCTAssertEqual(context.state.activity, .preparingTranslation)
        XCTAssertEqual(context.worker.refreshCount, 0)
        context.translator.release(.preparation)
        await drain(context)
        XCTAssertEqual(context.state.translationAvailability, .installed)
        XCTAssertNil(context.state.translationPreparationIssue)
        XCTAssertTrue(context.translator.cancelledPhases.isEmpty)
        assertTranslationCounts(context, availability: 1, translation: 0, preparation: 1)
        XCTAssertEqual(context.worker.refreshCount, 0)
        assertNoIndexWork(context)
    }

    func testBackgroundDiscardsHeldPreparationAndDoesNotPublishInstalledStatus() async {
        await assertBackgroundDiscardsPreparation(during: .preparation)
    }

    func testBackgroundDiscardsHeldPostPreparationAvailability() async {
        await assertBackgroundDiscardsPreparation(during: .availability)
    }

    func testLateSettingsAvailabilityAfterBackgroundAndSameLanguageReentryIsIgnored() async {
        let context = await readyContext()
        await checkAvailability(context)
        XCTAssertEqual(context.state.translationAvailability, .installed)
        context.translator.availabilityResult = .downloadRequired
        let oldCheck = await startHeldAvailabilityCheck(context)

        context.state.enterBackground()
        context.state.enterForeground()
        await drain(context, expectedActiveCalls: 1)
        XCTAssertEqual(context.state.translationLanguage, .simplified)
        XCTAssertEqual(context.state.translationAvailability, .installed)
        XCTAssertEqual(context.worker.refreshCount, 2)

        // Do not launch another check or cancel this one: only background
        // invalidation can reject it once foreground and language match again.
        context.translator.release(.availability)
        await oldCheck.value
        await drain(context)
        XCTAssertEqual(context.state.translationAvailability, .installed)
        XCTAssertNil(context.state.translationPreparationIssue)
        XCTAssertEqual(context.translator.availabilityRequests, [.simplified, .simplified])
        XCTAssertTrue(context.translator.cancelledPhases.isEmpty)
        assertTranslationCounts(context, availability: 2, translation: 0, preparation: 0)
        XCTAssertEqual(context.worker.refreshCount, 2)
        XCTAssertTrue(context.worker.searchRequests.isEmpty)
        assertNoPublishedSearch(context.state)
        assertNoIndexWork(context)
    }

    func testDirectSearchAfterBackgroundIsRejectedEvenWhenIdleAndOtherwiseReady() async {
        let context = await readyContext()
        context.state.query = "小狗和白色的笔"
        XCTAssertTrue(context.state.canSearch)
        context.state.enterBackground()
        await drain(context)
        XCTAssertTrue(context.state.canRead)
        XCTAssertTrue(context.state.modelsReady)
        XCTAssertGreaterThan(context.state.summary.indexedCount, 0)
        XCTAssertFalse(context.state.canSearch)

        context.state.search()
        await drain(context)
        XCTAssertFalse(context.state.canSearch)
        assertTranslationCounts(context, availability: 0, translation: 0, preparation: 0)
        XCTAssertEqual(context.worker.refreshCount, 1)
        XCTAssertTrue(context.worker.searchRequests.isEmpty)
        XCTAssertTrue(context.trace.events.isEmpty)
        XCTAssertNil(context.state.errorMessage)
        XCTAssertNil(context.state.actionHint)
        assertNoPublishedSearch(context.state)
        assertNoIndexWork(context)
    }

    func testChangingPreparationLanguageRejectsLateCompletion() async {
        let context = makeContext()
        await startHeldPreparation(context, phase: .preparation)
        context.state.translationLanguage = .traditional
        context.translator.release(.preparation)
        await drain(context)
        XCTAssertEqual(context.state.translationLanguage, .traditional)
        XCTAssertEqual(context.state.translationAvailability, .unchecked)
        XCTAssertEqual(context.translator.prepareRequests, [.simplified])
        XCTAssertEqual(context.translator.cancelledPhases, [.preparation])
        assertTranslationCounts(context, availability: 0, translation: 0, preparation: 1)
        XCTAssertEqual(context.worker.refreshCount, 0)
        assertNoIndexWork(context)
    }

    // MARK: Dedicated preference domains; no query/translation/asset persistence

    func testSavedChineseSearchPreferenceRestoresFalseAndTrue() async throws {
        let (defaults, _) = try isolatedPreferences()
        defaults.set(false, forKey: QueryTranslationFixtures.preferenceKey)
        let disabled = await readyContext(preferences: defaults)
        XCTAssertFalse(disabled.state.chineseSearchEnabled)
        disabled.state.query = "偏好设置测试中的小狗"
        disabled.state.search()
        await drain(disabled)
        assertResolution(disabled, original: disabled.state.query, effective: disabled.state.query, translated: false)
        assertTranslationCounts(disabled, availability: 0, translation: 0, preparation: 0)

        disabled.state.chineseSearchEnabled = true
        XCTAssertEqual(defaults.object(forKey: QueryTranslationFixtures.preferenceKey) as? Bool, true)
        let enabled = makeContext(preferences: defaults)
        XCTAssertTrue(enabled.state.chineseSearchEnabled)
        XCTAssertEqual(enabled.state.query, "")
        XCTAssertNil(enabled.state.completedQuery)
        XCTAssertNil(enabled.state.completedSearchQuery)
        XCTAssertEqual(enabled.state.translationAvailability, .unchecked)
        await drain(enabled)

        enabled.state.chineseSearchEnabled = false
        let restored = makeContext(preferences: defaults)
        XCTAssertFalse(restored.state.chineseSearchEnabled)
        XCTAssertEqual(restored.state.query, "")
        await drain(restored)
    }

    func testPreferencesSaveOnlyToggleNotQueriesTranslationsOrPhotoData() async throws {
        let (defaults, suite) = try isolatedPreferences()
        let context = await readyContext(preferences: defaults)
        XCTAssertTrue(context.state.chineseSearchEnabled)
        context.state.chineseSearchEnabled = false
        context.state.chineseSearchEnabled = true
        context.state.query = "测试专用的私人查询不能被保存"
        context.state.search()
        await drain(context)
        context.state.search(useOriginal: true)
        await drain(context)
        context.state.translationLanguage = .traditional
        context.state.prepareTranslation()
        await drain(context)

        let domain = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(Set(domain.keys), Set([QueryTranslationFixtures.preferenceKey]))
        XCTAssertEqual(domain[QueryTranslationFixtures.preferenceKey] as? Bool, true)
        let restored = makeContext(preferences: defaults)
        XCTAssertEqual(restored.state.query, "")
        assertNoPublishedSearch(restored.state)
        XCTAssertNil(restored.state.photoCheckReport)
        XCTAssertEqual(restored.state.translationAvailability, .unchecked)
        await drain(restored)
        assertNoIndexWork(context)
    }

    // MARK: Shared, explicitly awaited test harness

    private func makeContext(preferences: UserDefaults? = nil) -> QueryTranslationTestContext {
        let context = QueryTranslationTestContext(preferences: preferences)
        // Also runs after an assertion or thrown XCTUnwrap: never abandon a checked
        // continuation, and never let a previous test's operation outlive teardown.
        addTeardownBlock {
            await context.releaseAndDrain()
        }
        return context
    }

    private func readyContext(preferences: UserDefaults? = nil) async -> QueryTranslationTestContext {
        let context = makeContext(preferences: preferences)
        context.state.refresh()
        await drain(context)
        XCTAssertTrue(context.state.canRead)
        XCTAssertTrue(context.state.modelsReady)
        XCTAssertEqual(context.state.summary.indexedCount, context.worker.response.summary.indexedCount)
        XCTAssertNil(context.state.appleTranslationService)
        context.trace.events.removeAll()
        return context
    }

    private func drain(_ context: QueryTranslationTestContext, expectedActiveCalls: Int = 0,
                       file: StaticString = #filePath, line: UInt = #line) async {
        let finished = expectation(description: "AppState task chain completely drained")
        let waiter = Task { @MainActor in
            await context.state.waitUntilIdle()
            finished.fulfill()
        }
        // Timeouts are exclusively test failures, never production deadlines.
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(result, .completed, "The operation did not drain", file: file, line: line)
        if result != .completed {
            // Record the failure first, then unblock our fakes so teardown can
            // still run rather than abandoning a noninterruptible continuation.
            context.state.cancel()
            context.translator.releaseAll()
        }
        await waiter.value
        XCTAssertFalse(context.state.isBusy, file: file, line: line)
        XCTAssertNil(context.state.activity, file: file, line: line)
        XCTAssertEqual(context.translator.activeCalls, expectedActiveCalls, file: file, line: line)
    }

    private func startHeldAvailabilityCheck(_ context: QueryTranslationTestContext) async -> Task<Void, Never> {
        let started = expectation(description: "Settings availability check is suspended")
        context.translator.holdNext(.availability, started: started)
        let task = Task { @MainActor in
            await context.state.checkTranslationAvailability()
        }
        // Settings checks are outside AppState's operation chain. Drain this
        // task too, even if the test fails before its explicit release/await.
        addTeardownBlock {
            task.cancel()
            await context.translator.releaseAll()
            await task.value
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(context.translator.activeCalls, 1)
        XCTAssertFalse(context.state.isBusy)
        return task
    }

    private func checkAvailability(_ context: QueryTranslationTestContext) async {
        let finished = expectation(description: "Explicit availability check completed")
        let task = Task { @MainActor in
            await context.state.checkTranslationAvailability()
            finished.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(result, .completed, "The availability check did not finish")
        if result != .completed {
            task.cancel()
            context.translator.releaseAll()
        }
        await task.value
        await drain(context)
    }

    private func isolatedPreferences() throws -> (UserDefaults, String) {
        let suite = "LocalImageIQ.QueryTranslationStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, suite)
    }

    private func assertResolution(_ context: QueryTranslationTestContext, original: String,
                                  effective: String, translated: Bool, notice: String? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let state = context.state
        XCTAssertEqual(state.completedSearchQuery,
                       SearchQueryResolution(original: original, effective: effective, translated: translated, notice: notice),
                       file: file, line: line)
        XCTAssertEqual(Array(state.query.utf8), Array(original.utf8), file: file, line: line)
        XCTAssertEqual(state.completedQuery.map { Array($0.utf8) }, Array(original.utf8), file: file, line: line)
        XCTAssertEqual(state.completedSearchQuery.map { Array($0.original.utf8) }, Array(original.utf8), file: file, line: line)
        XCTAssertEqual(state.completedSearchQuery.map { Array($0.effective.utf8) }, Array(effective.utf8), file: file, line: line)
        XCTAssertNil(state.errorMessage, file: file, line: line)
        XCTAssertNil(state.actionHint, file: file, line: line)
    }

    private func assertLastSearch(_ context: QueryTranslationTestContext, text: String,
                                  limit: Int = 3, weight: Double = 0.6,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let request = context.worker.searchRequests.last else {
            XCTFail("The worker must receive exactly the resolved search text", file: file, line: line)
            return
        }
        XCTAssertEqual(Array(request.text.utf8), Array(text.utf8), file: file, line: line)
        XCTAssertEqual(request.limit, limit, file: file, line: line)
        XCTAssertEqual(request.weight.bitPattern, Float(weight).bitPattern, file: file, line: line)
        XCTAssertEqual(context.state.results.map(\.id), context.worker.response.hits.map(\.id), file: file, line: line)
        XCTAssertEqual(context.state.results.map { $0.score.bitPattern },
                       context.worker.response.hits.map { $0.score.bitPattern }, file: file, line: line)
    }

    private func assertTranslationCounts(_ context: QueryTranslationTestContext, availability: Int,
                                         translation: Int, preparation: Int,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(context.translator.availabilityCount, availability, file: file, line: line)
        XCTAssertEqual(context.translator.translationCount, translation, file: file, line: line)
        XCTAssertEqual(context.translator.prepareCount, preparation, file: file, line: line)
    }

    private func assertNoIndexWork(_ context: QueryTranslationTestContext, cloudEnabled: Bool = false,
                                   expectedChecks: Int = 0,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(context.worker.indexCount, 0, file: file, line: line)
        XCTAssertEqual(context.worker.clearCount, 0, file: file, line: line)
        XCTAssertTrue(context.worker.indexNetworkFlags.isEmpty, file: file, line: line)
        XCTAssertEqual(context.worker.checkRequests.count, expectedChecks, file: file, line: line)
        XCTAssertEqual(context.state.allowICloudDownload, cloudEnabled, file: file, line: line)
        XCTAssertEqual(context.state.progress, IndexProgress(), file: file, line: line)
    }

    private func assertNoPublishedSearch(_ state: AppState,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.results.isEmpty, file: file, line: line)
        XCTAssertNil(state.completedQuery, file: file, line: line)
        XCTAssertNil(state.completedSearchQuery, file: file, line: line)
        XCTAssertNil(state.selection, file: file, line: line)
        XCTAssertNil(state.photoCheckReport, file: file, line: line)
    }

    private func assertNoPrivateErrorDetails(_ state: AppState,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let messages = [state.completedSearchQuery?.notice, state.translationPreparationIssue,
                        state.errorMessage, state.actionHint, state.photoCheckIssue, state.status].compactMap { $0 }
        for message in messages {
            XCTAssertFalse(message.contains(QueryTranslationPrivateError.detail), file: file, line: line)
            XCTAssertFalse(message.contains("test-only-private-asset"), file: file, line: line)
        }
    }

    private func assertFallback(_ context: QueryTranslationTestContext, failure: QueryTranslationFailure,
                                cloudEnabled: Bool = false) async {
        let original = " \t小狗和白色的笔\n "
        context.state.query = original
        context.state.search()
        await drain(context)
        assertResolution(context, original: original, effective: original, translated: false, notice: failure.fallbackMessage)
        XCTAssertFalse(context.state.completedSearchQuery?.notice?.isEmpty ?? true,
                       "Silent fallback would conceal that translation did not run")
        assertLastSearch(context, text: original)
        XCTAssertEqual(context.worker.searchRequests.count, 1)
        assertNoPrivateErrorDetails(context.state)
        assertNoIndexWork(context, cloudEnabled: cloudEnabled)
    }

    private func startHeldSearch(_ context: QueryTranslationTestContext, phase: QueryTranslationTestPhase) async {
        let started = expectation(description: "Search is suspended in \(phase.rawValue)")
        context.translator.holdNext(phase, started: started)
        context.state.query = "小狗和白色的笔"
        context.state.search()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(context.state.activity, .searching)
        XCTAssertEqual(context.translator.activeCalls, 1)
        XCTAssertTrue(context.worker.searchRequests.isEmpty)
    }

    private enum Invalidation: Equatable { case cancel, query, weight, toggle, background, limit }

    private func assertInvalidation(_ change: Invalidation, during phase: QueryTranslationTestPhase) async {
        for failsAfterRelease in [false, true] {
            await assertInvalidationCompletion(change, during: phase, failsAfterRelease: failsAfterRelease)
        }
    }

    private func assertInvalidationCompletion(_ change: Invalidation, during phase: QueryTranslationTestPhase,
                                              failsAfterRelease: Bool) async {
        let context = await readyContext()
        if failsAfterRelease {
            if phase == .availability { context.translator.availabilityResult = .unavailable }
            else { context.translator.translationResult = .failure(QueryTranslationPrivateError()) }
        }
        await startHeldSearch(context, phase: phase)
        switch change {
        case .cancel: context.state.cancel()
        case .query: context.state.query = "另一个查询"
        case .weight: context.state.locationWeight = 0.25
        case .toggle: context.state.chineseSearchEnabled = false
        case .background:
            context.state.enterBackground()
            context.state.refresh() // Still backgrounded: must not schedule worker work.
        case .limit: context.state.resultLimit = 12
        }
        // Cancellation is intentionally not an early continuation resume.
        XCTAssertEqual(context.translator.activeCalls, 1)
        XCTAssertEqual(context.state.activity, .searching)
        assertNoPublishedSearch(context.state)
        context.translator.release(phase)
        await drain(context)
        assertNoPublishedSearch(context.state)
        XCTAssertNil(context.state.errorMessage)
        XCTAssertNil(context.state.actionHint)
        assertNoPrivateErrorDetails(context.state)
        XCTAssertEqual(context.translator.cancelledPhases, [phase])
        XCTAssertTrue(context.translator.finishedPhases.contains(phase))
        XCTAssertTrue(context.worker.searchRequests.isEmpty, "Cancelled text must never reach the SigLIP search boundary")
        XCTAssertEqual(context.worker.refreshCount, 1)
        assertTranslationCounts(context, availability: 1, translation: phase == .translation ? 1 : 0, preparation: 0)
        XCTAssertEqual(context.state.query, change == .query ? "另一个查询" : "小狗和白色的笔")
        XCTAssertEqual(context.state.locationWeight, change == .weight ? 0.25 : 0.6)
        XCTAssertEqual(context.state.resultLimit, change == .limit ? 12 : 3)
        XCTAssertEqual(context.state.chineseSearchEnabled, change != .toggle)
        assertNoIndexWork(context)
    }

    private func assertSuccessorWaits(during phase: QueryTranslationTestPhase, throughBackground: Bool) async {
        let context = await readyContext()
        await startHeldSearch(context, phase: phase)
        let prematureRefresh = expectation(description: "Refresh must not overtake a held translator")
        prematureRefresh.isInverted = true
        context.worker.refreshStarted = prematureRefresh
        if throughBackground {
            context.state.enterBackground()
            context.state.enterForeground()
        } else {
            context.state.refresh()
        }
        XCTAssertEqual(context.state.activity, .refreshing)
        await fulfillment(of: [prematureRefresh], timeout: 0.05)
        context.worker.refreshStarted = nil
        XCTAssertEqual(context.worker.refreshCount, 1)
        XCTAssertEqual(context.translator.activeCalls, 1)
        context.translator.release(phase)
        await drain(context)

        let expected = phase == .availability
            ? ["availability.start", "availability.finish", "worker.refresh"]
            : ["availability.start", "availability.finish", "translation.start", "translation.finish", "worker.refresh"]
        XCTAssertEqual(context.trace.events, expected, "The full predecessor must finish before its successor starts")
        XCTAssertEqual(context.worker.refreshCount, 2)
        XCTAssertTrue(context.worker.searchRequests.isEmpty)
        XCTAssertEqual(context.translator.cancelledPhases, [phase])
        XCTAssertEqual(context.translator.peakActiveCalls, 1)
        XCTAssertNil(context.state.errorMessage)
        assertNoPublishedSearch(context.state)
        assertNoIndexWork(context)
    }

    private func startHeldPreparation(_ context: QueryTranslationTestContext, phase: QueryTranslationTestPhase) async {
        let started = expectation(description: "Preparation is suspended in \(phase.rawValue)")
        context.translator.holdNext(phase, started: started)
        context.state.prepareTranslation()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(context.state.activity, .preparingTranslation)
        XCTAssertEqual(context.translator.activeCalls, 1)
    }

    private func assertBackgroundDiscardsPreparation(during phase: QueryTranslationTestPhase) async {
        let context = makeContext()
        await startHeldPreparation(context, phase: phase)
        context.state.enterBackground()
        context.translator.release(phase)
        await drain(context)
        XCTAssertEqual(context.state.translationAvailability, .unchecked)
        XCTAssertFalse(context.state.translationPreparationIssue?.isEmpty ?? true)
        XCTAssertEqual(context.translator.cancelledPhases, [phase])
        XCTAssertNil(context.state.errorMessage)
        assertNoPrivateErrorDetails(context.state)
        context.state.prepareTranslation() // Also reject preparation once background work has drained.
        await drain(context)
        assertTranslationCounts(context, availability: phase == .availability ? 1 : 0, translation: 0, preparation: 1)
        XCTAssertEqual(context.worker.refreshCount, 0)
        XCTAssertTrue(context.worker.searchRequests.isEmpty)
        assertNoPublishedSearch(context.state)
        assertNoIndexWork(context)
    }
}

// MARK: Test-only fixtures and deterministic, noninterruptible services

private enum QueryTranslationFixtures {
    static let preferenceKey = "chineseSearchEnabled.v1"
    static let english = "TEST FIXTURE a dog with a white pen"
    static let modelVersion = "query-translation-test-model"

    static var response: SearchResponse {
        let scores: [Float] = [0.8125, 0.3125, -0.125]
        let hits = scores.enumerated().map { index, score in
            SearchHit(photo: IndexedPhoto(id: "query-translation-test-only-\(index)", modificationTime: 123,
                                          modelVersion: modelVersion, imageEmbedding: TestFixtures.vector(axis: index)),
                      score: score)
        }
        return SearchResponse(summary: LibrarySummary(authorizedCount: 3, indexedCount: 3, locatedCount: 0,
                                                       modelVersion: modelVersion, placesDescription: "TEST FIXTURE unchanged places"),
                              hits: hits)
    }
}

private struct QueryTranslationPrivateError: LocalizedError {
    static let detail = "TEST ONLY private service details: test-only-private-asset / secret internal request"
    var errorDescription: String? { Self.detail }
}

private enum QueryTranslationTestPhase: String, Hashable {
    case availability, translation, preparation
}

@MainActor
private final class QueryTranslationTestTrace {
    var events: [String] = []
}

@MainActor
private final class QueryTranslationTestGate {
    private let started: XCTestExpectation
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            precondition(self.continuation == nil, "A gate holds exactly one fake call")
            self.continuation = continuation
            started.fulfill()
        }
    }

    func open() {
        opened = true
        let pending = continuation
        continuation = nil
        pending?.resume() // Idempotent, including teardown after an explicit release.
    }
}

@MainActor
private final class QueryTranslationTestTranslator: QueryTranslating {
    struct Request {
        let text: String
        let language: QueryTranslationLanguage
    }

    var isSupported = true
    var availabilityResult: QueryTranslationAvailability = .installed
    var translationResult: Result<String, Error> = .success(QueryTranslationFixtures.english)
    var preparationError: Error?
    private let trace: QueryTranslationTestTrace
    private var gates: [QueryTranslationTestPhase: QueryTranslationTestGate] = [:]
    private var claimedHolds: Set<QueryTranslationTestPhase> = []
    private(set) var availabilityRequests: [QueryTranslationLanguage] = []
    private(set) var translationRequests: [Request] = []
    private(set) var prepareRequests: [QueryTranslationLanguage] = []
    private(set) var finishedPhases: [QueryTranslationTestPhase] = []
    private(set) var cancelledPhases: [QueryTranslationTestPhase] = []
    private(set) var activeCalls = 0
    private(set) var peakActiveCalls = 0
    var availabilityCount: Int { availabilityRequests.count }
    var translationCount: Int { translationRequests.count }
    var prepareCount: Int { prepareRequests.count }

    init(trace: QueryTranslationTestTrace) { self.trace = trace }

    func holdNext(_ phase: QueryTranslationTestPhase, started: XCTestExpectation) {
        precondition(gates[phase] == nil, "Release the previous hold before rearming it")
        gates[phase] = QueryTranslationTestGate(started: started)
    }

    func release(_ phase: QueryTranslationTestPhase) { gates[phase]?.open() }
    func releaseAll() { for gate in gates.values { gate.open() } }

    private func suspendIfHeld(_ phase: QueryTranslationTestPhase) async {
        // A hold belongs only to the next call, not to concurrent later calls.
        guard let gate = gates[phase], claimedHolds.insert(phase).inserted else { return }
        await gate.wait()
        claimedHolds.remove(phase)
        gates.removeValue(forKey: phase)
    }

    private func begin(_ phase: QueryTranslationTestPhase) {
        activeCalls += 1
        peakActiveCalls = max(peakActiveCalls, activeCalls)
        trace.events.append("\(phase.rawValue).start")
    }

    private func finish(_ phase: QueryTranslationTestPhase) {
        if Task.isCancelled { cancelledPhases.append(phase) }
        finishedPhases.append(phase)
        trace.events.append("\(phase.rawValue).finish")
        activeCalls -= 1
    }

    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        availabilityRequests.append(language)
        begin(.availability)
        defer { finish(.availability) }
        let result = availabilityResult
        await suspendIfHeld(.availability)
        return result // Intentionally returns even after cancellation.
    }

    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        translationRequests.append(Request(text: text, language: language))
        begin(.translation)
        defer { finish(.translation) }
        let result = translationResult
        await suspendIfHeld(.translation)
        return try result.get() // A late success/error must be rejected by AppState.
    }

    func prepare(_ language: QueryTranslationLanguage) async throws {
        prepareRequests.append(language)
        begin(.preparation)
        defer { finish(.preparation) }
        let error = preparationError
        await suspendIfHeld(.preparation)
        if let error { throw error }
        availabilityResult = .installed
    }
}

/// MainActor isolation satisfies Sendable in Swift 5 without unchecked sharing.
/// This spy is the entire worker: even an unintended index call cannot touch Photos.
@MainActor
private final class QueryTranslationTestWorker: PhotoWorkServicing {
    struct SearchRequest {
        let text: String
        let limit: Int
        let weight: Float
    }

    struct CheckRequest {
        let id: String
        let query: String
        let weight: Float
    }

    let response = QueryTranslationFixtures.response
    private let trace: QueryTranslationTestTrace
    var refreshStarted: XCTestExpectation?
    private(set) var refreshCount = 0
    private(set) var indexCount = 0
    private(set) var clearCount = 0
    private(set) var indexNetworkFlags: [Bool] = []
    private(set) var searchRequests: [SearchRequest] = []
    private(set) var checkRequests: [CheckRequest] = []

    init(trace: QueryTranslationTestTrace) { self.trace = trace }

    func refresh() async throws -> LibrarySummary {
        refreshCount += 1
        trace.events.append("worker.refresh")
        refreshStarted?.fulfill()
        return response.summary
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        searchRequests.append(SearchRequest(text: text, limit: limit, weight: locationWeight))
        trace.events.append("worker.search")
        return response
    }

    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        checkRequests.append(CheckRequest(id: id, query: query, weight: locationWeight))
        trace.events.append("worker.check")
        return PhotoDiagnosticReport(photoID: id, query: query, locationWeight: locationWeight,
                                     galleryCount: response.hits.count, modelVersion: QueryTranslationFixtures.modelVersion,
                                     cachedStatus: "current")
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        indexCount += 1
        indexNetworkFlags.append(networkAllowed)
        XCTFail("Query translation must not index photos or request photo downloads")
        return response.summary
    }

    func clear() async throws -> LibrarySummary {
        clearCount += 1
        XCTFail("Query translation must not clear the index")
        return response.summary
    }
}

@MainActor
private final class QueryTranslationTestContext {
    let trace: QueryTranslationTestTrace
    let translator: QueryTranslationTestTranslator
    let worker: QueryTranslationTestWorker
    let state: AppState

    init(preferences: UserDefaults?) {
        let trace = QueryTranslationTestTrace()
        let translator = QueryTranslationTestTranslator(trace: trace)
        let worker = QueryTranslationTestWorker(trace: trace)
        self.trace = trace
        self.translator = translator
        self.worker = worker
        state = AppState(worker: worker, authorizationStatus: { .authorized },
                         queryTranslator: translator, translationPreferences: preferences)
    }

    func releaseAndDrain() async {
        state.cancel()
        translator.releaseAll()
        await state.waitUntilIdle()
    }
}