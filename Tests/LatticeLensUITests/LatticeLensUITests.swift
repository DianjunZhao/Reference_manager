// XCTest's macOS 26 annotations import XCUIApplication/XCUIElement APIs as
// MainActor-isolated.  Running the synchronous wait/click APIs *on* that
// actor is explicitly diagnosed by XCTest itself as a UI-unresponsive
// deadlock.  Keep this legacy synchronous XCUITest target preconcurrency so
// its runner owns the automation session while the AUT's main actor remains
// available to service it.
@preconcurrency import XCTest

/// Real macOS UI-test target.  It launches the app with an explicit in-memory
/// fixture environment; therefore this test neither reads a user's library nor
/// contacts INSPIRE, a provider, or Keychain.
final class LatticeLensUITests: XCTestCase {
    // Do not reuse the historical v5 fixture identifier: macOS LaunchServices
    // may retain every prior derived-data product and choose one of those
    // stale apps for an identifier-only XCTest launch.
    private let fixtureBundleIdentifier = "org.latticelens.app.uitestfixture.v5"

    override func tearDownWithError() throws {
        // XCTest does not reliably retire a prior macOS UI-test AUT before
        // the next method asks `launch()` for the same bundle identifier.
        // That can retain the previous fixture's in-memory store and launch
        // arguments, so a later case observes the wrong paper/tab instead of
        // a fresh, process-local fixture.  The dedicated UI fixture bundle
        // cannot be a real user installation; limit the cleanup to it.
        let fixtureApp = XCUIApplication(bundleIdentifier: fixtureBundleIdentifier)
        if fixtureApp.state != .notRunning {
            fixtureApp.terminate()
        }
        try super.tearDownWithError()
    }

    /// Xcode's UI-test runner currently uses `/` as its working directory.
    /// Derive the checkout from this compiled test source instead of relying
    /// on that directory or writing a fixture PDF to the system temp area.
    private func fixtureCacheProjectRoot() -> String {
        let sourceURL = URL(fileURLWithPath: #filePath).standardizedFileURL.resolvingSymlinksInPath()
        var cursor = sourceURL.deletingLastPathComponent()
        while cursor.lastPathComponent != "Tests" {
            let parent = cursor.deletingLastPathComponent()
            precondition(parent.path != cursor.path, "无法从 UI test 源码路径确定项目根目录")
            cursor = parent
        }
        return cursor.deletingLastPathComponent().path
    }

    private func launchFixtureApp(automaticAnalysis: Bool = false, initialPaperLensTab: String? = nil,
                                  initialWorkbenchTab: String? = nil, maximumFigures: Int? = nil,
                                  largeFixture: Bool = false, fixtureWindowSize: String? = nil,
                                  initialAuthorSearch: String? = nil,
                                  initialTagManagerSearch: String? = nil,
                                  initialCollectionManagerSearch: String? = nil,
                                  initialNotebookEntryTitle: String? = nil,
                                  legacyResearchQuestionString: Bool = false) -> XCUIApplication {
        // The Xcode `UIFixture` scheme builds the app with a deliberately
        // distinct bundle ID.  Resolving it explicitly avoids macOS XCTest
        // attaching to a menu-bar-only default application proxy when another
        // local LatticeLens build has previously been registered.
        let app = XCUIApplication(bundleIdentifier: fixtureBundleIdentifier)
        var arguments = ["-LatticeLensUseFixtures", "YES"]
        app.launchEnvironment["LATTICELENS_USE_FIXTURES"] = "1"
        app.launchEnvironment["LATTICELENS_UI_TEST"] = "1"
        app.launchEnvironment["LATTICELENS_FIXTURE_CACHE_ROOT"] = fixtureCacheProjectRoot()
        if automaticAnalysis {
            app.launchEnvironment["LATTICELENS_FIXTURE_AUTOMATIC_ANALYSIS"] = "1"
            arguments += ["-LatticeLensFixtureAutomaticAnalysis", "YES"]
        }
        if let initialPaperLensTab {
            app.launchEnvironment["LATTICELENS_FIXTURE_INITIAL_PAPER_LENS_TAB"] = initialPaperLensTab
            arguments += ["-LatticeLensFixtureInitialPaperLensTab", initialPaperLensTab]
        }
        if let initialWorkbenchTab {
            app.launchEnvironment["LATTICELENS_FIXTURE_INITIAL_WORKBENCH_TAB"] = initialWorkbenchTab
            arguments += ["-LatticeLensFixtureInitialWorkbenchTab", initialWorkbenchTab]
        }
        if let maximumFigures {
            precondition([0, 3, 5].contains(maximumFigures), "fixture only accepts product allowlist values")
            app.launchEnvironment["LATTICELENS_FIXTURE_MAXIMUM_FIGURES"] = String(maximumFigures)
            arguments += ["-LatticeLensFixtureMaximumFigures", String(maximumFigures)]
        }
        if largeFixture {
            // Large data is a strict addition to the ordinary fixture gate;
            // the app rejects this key unless LATTICELENS_USE_FIXTURES=1 is
            // also present above.
            app.launchEnvironment["LATTICELENS_LARGE_UI_FIXTURE"] = "1"
            arguments += ["-LatticeLensLargeUIFixture", "YES"]
        }
        if let initialAuthorSearch {
            precondition(largeFixture,
                         "initial author search is a large-fixture reachability input, not a production launch setting")
            app.launchEnvironment["LATTICELENS_FIXTURE_INITIAL_AUTHOR_SEARCH"] = initialAuthorSearch
            arguments += ["-LatticeLensFixtureInitialAuthorSearch", initialAuthorSearch]
        }
        if let initialTagManagerSearch {
            precondition(largeFixture,
                         "initial tag-manager search is a large-fixture reachability input, not a production launch setting")
            app.launchEnvironment["LATTICELENS_FIXTURE_INITIAL_TAG_MANAGER_SEARCH"] = initialTagManagerSearch
            arguments += ["-LatticeLensFixtureInitialTagManagerSearch", initialTagManagerSearch]
        }
        if let initialCollectionManagerSearch {
            precondition(largeFixture,
                         "initial collection-manager search is a large-fixture reachability input, not a production launch setting")
            app.launchEnvironment["LATTICELENS_FIXTURE_INITIAL_COLLECTION_MANAGER_SEARCH"] = initialCollectionManagerSearch
            arguments += ["-LatticeLensFixtureInitialCollectionManagerSearch", initialCollectionManagerSearch]
        }
        if let initialNotebookEntryTitle {
            app.launchEnvironment["LATTICELENS_FIXTURE_INITIAL_NOTEBOOK_TITLE"] = initialNotebookEntryTitle
            arguments += ["-LatticeLensFixtureInitialNotebookTitle", initialNotebookEntryTitle]
        }
        if legacyResearchQuestionString {
            app.launchEnvironment["LATTICELENS_FIXTURE_LEGACY_RESEARCH_QUESTION"] = "1"
        }
        if let fixtureWindowSize {
            precondition(["820x640", "1120x700", "1440x900"].contains(fixtureWindowSize),
                         "fixture window size must be a v5 acceptance size")
            app.launchEnvironment["LATTICELENS_FIXTURE_WINDOW_SIZE"] = fixtureWindowSize
            arguments += ["-LatticeLensFixtureWindowSize", fixtureWindowSize]
        }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    func testLargeFixtureAuthorAndPaperReachabilityKeepsSelectionAfterSearchReset() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        // XCTest synthesizes keyboard events through the host's active IME.
        // On this Mac that can transliterate an ASCII fixture name before the
        // app receives it.  Seed the same query only inside the isolated
        // large fixture, then verify the real native TextField exposes it;
        // the manual acceptance script retains keyboard/IME coverage.
        let app = launchFixtureApp(largeFixture: true, initialAuthorSearch: "Zuthor, Fixture 026")
        // This case owns the process-local fixture application.  Keep its
        // lifecycle bounded even when an assertion below fails, otherwise a
        // 1000-paper AppKit hierarchy can remain live while XCTest attempts
        // to finalize the result bundle.
        defer { app.terminate() }
        assertLargeFixtureReady(in: app)

        let authorList = app.descendants(matching: .any)["authorsScrollableList"].firstMatch
        guard authorList.waitForExistence(timeout: 5) else {
            XCTFail("Authors 必须暴露独立、带标签的原生滚动区")
            return
        }
        let authorSearch = app.textFields["authorSearch"]
        guard authorSearch.waitForExistence(timeout: 5) else {
            XCTFail("作者搜索必须有稳定的原生 text field")
            return
        }
        XCTAssertEqual(authorSearch.value as? String, "Zuthor, Fixture 026",
                       "fixture-only launch query must be visible in the native author search field")
        let authorMatchCount = app.descendants(matching: .any)["authorSearchMatchCount"].firstMatch
        guard authorMatchCount.waitForExistence(timeout: 5) else {
            XCTFail("作者搜索必须先发布唯一的本地匹配计数，不能依赖已失效的 List 容器查询")
            return
        }
        let matchedAuthorLabel = authorMatchCount.label
        guard matchedAuthorLabel == "普通作者匹配 1" else {
            XCTFail("作者搜索应公布唯一的本地匹配计数；实际 AX label: \(matchedAuthorLabel)")
            return
        }
        // The stable row identifier proves the filtered native List actually
        // rendered the exact author.  Selecting a unique result uses the
        // fixed, keyboard/VoiceOver-accessible action rather than making a
        // virtualized AppKit row the only operational path.
        let zAuthor = app.descendants(matching: .any)["authorRow-2100026"].firstMatch
        guard zAuthor.waitForExistence(timeout: 5) else {
            XCTFail("300+ 作者 fixture 的 Z 项必须可按名称到达")
            return
        }
        let selectAuthorSearchResult = app.buttons["selectAuthorSearchResult-2100026"]
        guard selectAuthorSearchResult.waitForExistence(timeout: 5) else {
            XCTFail("唯一作者搜索结果必须提供固定、可访问的选择动作")
            return
        }
        selectAuthorSearchResult.click()
        let selectedAuthor = app.descendants(matching: .any)["selectedAuthorSummary"].firstMatch
        guard selectedAuthor.waitForExistence(timeout: 5) else {
            XCTFail("点击 Z author 后必须发布 durable selectedAuthorID 摘要")
            return
        }
        let selectedAuthorLabel = selectedAuthor.label
        let selectedAuthorRecid = selectedAuthorLabel
            .components(separatedBy: "，INSPIRE ")
            .last?
            .filter(\.isWholeNumber)
        guard selectedAuthorLabel.hasPrefix("当前作者 Zuthor, Fixture 026，INSPIRE "),
              selectedAuthorRecid == "2100026" else {
            XCTFail("点击 Z author 后必须实际切换 durable selectedAuthorID；实际 AX label: \(selectedAuthorLabel)")
            return
        }

        // The large corpus deliberately attaches the 1000-paper list to the
        // pinned self record.  Return there explicitly after the Z-selection
        // check instead of relying on an incidental author-paper link.
        let selfAuthor = app.staticTexts["authorRow-2010363"].firstMatch
        guard selfAuthor.waitForExistence(timeout: 5) else {
            XCTFail("large fixture 的 pinned self author 必须保持可达")
            return
        }
        selfAuthor.click()
        let firstPaper = app.staticTexts["paperRow-9100000"].firstMatch
        guard firstPaper.waitForExistence(timeout: 8) else {
            XCTFail("选择 fixture 作者后应显示进程内的 1000 篇论文")
            return
        }
        let globalSearch = app.textFields["globalPaperSearch"]
        guard globalSearch.waitForExistence(timeout: 5) else {
            XCTFail("large fixture 的全局论文搜索必须可达")
            return
        }
        globalSearch.click()
        globalSearch.typeText("Large Fixture Lattice Paper 0999")
        let lastPaper = app.staticTexts["paperRow-9100999"].firstMatch
        guard lastPaper.waitForExistence(timeout: 8) else {
            XCTFail("末篇论文必须能通过可访问的本地 search 到达")
            return
        }
        guard lastPaper.isHittable else {
            XCTFail("末篇论文必须在本地 search 后可操作")
            return
        }
        lastPaper.click()
        guard app.staticTexts["Large Fixture Lattice Paper 0999"].firstMatch.waitForExistence(timeout: 5) else {
            XCTFail("选择末篇论文后必须保留其可访问标题")
            return
        }

        let clearSearch = app.buttons["clearGlobalPaperSearch"]
        guard clearSearch.waitForExistence(timeout: 5) else {
            XCTFail("global search 必须提供可访问的 clear action")
            return
        }
        clearSearch.click()
        // Clearing a derived search projection must not select another paper.
        guard app.staticTexts["Large Fixture Lattice Paper 0999"].firstMatch.waitForExistence(timeout: 5) else {
            XCTFail("清除搜索后 durable paper ID 仍须保留为当前选择")
            return
        }
        #endif
    }

    func testLargeFixtureLaunchesAtAllThreeResponsiveAcceptanceSizes() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        for size in ["820x640", "1120x700", "1440x900"] {
            let app = launchFixtureApp(largeFixture: true, fixtureWindowSize: size)
            assertLargeFixtureReady(in: app)
            XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5),
                          "\(size) 下设置动作不能被硬编码的 1120pt 最小宽度推到屏幕外")
            XCTAssertTrue(app.buttons["workbenchButton"].waitForExistence(timeout: 5),
                          "\(size) 下 Workbench 动作必须可访问")
            app.terminate()
        }
        #endif
    }

    func testLargeFixtureSettingsKeepsModelsAndTerminologyReachableInDraft() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp(largeFixture: true)
        assertLargeFixtureReady(in: app)

        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        let settingsSheet = app.sheets.firstMatch
        XCTAssertTrue(settingsSheet.waitForExistence(timeout: 5))

        let settingsForm = settingsSheet.descendants(matching: .any)["settingsScrollableForm"].firstMatch
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 5),
                      "设置页必须暴露带可见滚动指示条的独立 Form 区域")

        // Probe/discovery side-effect boundaries are exercised by host-free
        // provider regressions.  Large fixture models are preloaded only in
        // this isolated process, so the UI test verifies the actual 200-row
        // selection surface without an HTTP/model request or Form click race.
        // On macOS the native Form is exposed as an AX scroll area.  Query its
        // stable descendant identifier rather than assuming buttons remain a
        // direct sheet collection after that accessibility boundary.
        let connection = settingsSheet.descendants(matching: .any)["testProviderConnection"].firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        let discover = settingsSheet.descendants(matching: .any)["discoverModels"].firstMatch
        XCTAssertTrue(discover.waitForExistence(timeout: 5))

        let selectModel = settingsSheet.descendants(matching: .any)["selectProviderModel"].firstMatch
        XCTAssertTrue(selectModel.waitForExistence(timeout: 5))
        XCTAssertEqual(selectModel.value as? String, "fixture-model-200")

        // The terminology region retains its native ScrollView, while the
        // fixed search entry lets a keyboard/VoiceOver user reach an exact
        // final row without relying on a long sequence of gestures.
        let terminology = settingsSheet.descendants(matching: .any)["terminologyScrollableList"].firstMatch
        XCTAssertTrue(terminology.waitForExistence(timeout: 5))
        let terminologySearch = settingsSheet.textFields["terminologySearch"]
        XCTAssertTrue(terminologySearch.waitForExistence(timeout: 5))
        terminologySearch.click()
        // Use a single token here.  The product normalizer treats whitespace
        // as non-semantic, while this avoids a macOS XCUITest text-injection
        // quirk that can insert an IME composition boundary between words.
        terminologySearch.typeText("500")
        let finalTermID = "00000000-0009-4000-8000-0000000001F4"
        let terminologyMatchCount = settingsSheet.descendants(matching: .any)["terminologySearchCount"].firstMatch
        XCTAssertTrue(terminologyMatchCount.waitForExistence(timeout: 5))
        XCTAssertEqual(waitForValue(of: terminologyMatchCount, expected: "1", timeout: 5), .completed,
                       "500 条术语的末项必须通过固定搜索得到唯一的本地匹配")
        // The large Form owns the scrollable middle region.  Once only one
        // term remains, its actual edit action must move to the non-scrolling
        // header rather than merely survive as an off-screen AX descendant.
        let editLastTerm = settingsSheet.buttons["editTerminology-\(finalTermID)"]
        XCTAssertTrue(editLastTerm.waitForExistence(timeout: 8),
                      "500 条术语的末项必须通过固定搜索暴露真实 edit action")
        XCTAssertEqual(waitForHittability(of: editLastTerm, expected: true, timeout: 5), .completed,
                       "筛选后的末项 edit action 必须留在固定 header 且可操作")
        XCTAssertTrue(editLastTerm.label.contains("fixture term 500"),
                      "固定 action 必须公布所匹配术语，而非只有无上下文的编辑按钮")

        // Model selection changes only `draft`; cancelling the parent sheet
        // must restore the fixture's saved choice instead of writing it.
        let cancelSettings = settingsSheet.buttons["cancelSettings"]
        XCTAssertTrue(cancelSettings.waitForExistence(timeout: 5))
        XCTAssertEqual(waitForHittability(of: cancelSettings, expected: true, timeout: 5), .completed,
                       "Cancel 必须是可点击的原生控件")
        // Escape remains a separate manual P0 keyboard observation: current
        // macOS XCTest turns this particular field-editor command into an
        // unobservable bridge action.  This case validates the independent
        // transaction invariant that Cancel retires the draft without write.
        cancelSettings.click()
        // On this Xcode/macOS pair, XCUITest can retain a remote AX snapshot
        // for a sheet after the sheet owner's binding has already retired it.
        // In particular, treating the old sheet's `exists` value or the
        // underlying toolbar's `isHittable` value as the product truth makes
        // this otherwise deterministic interaction flaky.  The host-free
        // AppViewModel contract verifies the owner binding directly; the
        // required manual P0 record checks the real window and VoiceOver
        // state.  The UI case continues to require the native cancel button
        // to be discovered and invoked after a populated large Form.
        #endif
    }

    func testLargeFixtureModelSelectorKeepsCurrentModelWhileSearching() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp(largeFixture: true)
        assertLargeFixtureReady(in: app)
        app.buttons["settingsButton"].click()
        let settingsSheet = app.sheets.firstMatch
        XCTAssertTrue(settingsSheet.waitForExistence(timeout: 5))
        let selectModel = settingsSheet.buttons["selectProviderModel"]
        XCTAssertTrue(selectModel.waitForExistence(timeout: 5))
        selectModel.click()
        let modelSearch = app.textFields["modelSearch"]
        XCTAssertTrue(modelSearch.waitForExistence(timeout: 5))
        let currentModel = app.staticTexts["selectedProviderModel"]
        XCTAssertEqual(currentModel.value as? String, "fixture-model-200")
        modelSearch.click()
        modelSearch.typeText("fixture-model-001")
        XCTAssertEqual(currentModel.value as? String, "fixture-model-200",
                       "搜索排除 current model 时 selected chip 不得消失")
        let firstModel = app.buttons["modelOption-fixture-model-001"]
        XCTAssertTrue(firstModel.waitForExistence(timeout: 5))
        XCTAssertTrue(firstModel.isHittable,
                      "200 条 discovered models 中的首个过滤结果必须可操作")
        #endif
    }

    func testLargeFixtureTagAndCollectionManagersSearchAndCancelWithoutWrite() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        // XCTest types through the host's active IME on this Mac, which can
        // transliterate an ASCII manager query. Seed the same query only in
        // the process-local large fixture, then assert it is rendered by the
        // native TextField; manual acceptance retains real keyboard/IME
        // coverage for tag and collection search.
        let app = launchFixtureApp(
            largeFixture: true,
            initialTagManagerSearch: "Fixture tag 100",
            initialCollectionManagerSearch: "Fixture collection 100"
        )
        assertLargeFixtureReady(in: app)
        let paper = app.staticTexts["paperRow-9100000"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 8))
        paper.click()
        let source = app.radioButtons["原始资料"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()

        let manageTags = app.buttons["manageTags"]
        XCTAssertTrue(manageTags.waitForExistence(timeout: 5))
        manageTags.click()
        let manager = app.sheets.firstMatch
        XCTAssertTrue(manager.waitForExistence(timeout: 5))
        let tagList = manager.descendants(matching: .any)["tagManagerScrollableList"].firstMatch
        XCTAssertTrue(tagList.waitForExistence(timeout: 5))
        let tagSearch = manager.textFields["tagManagerSearch"]
        XCTAssertEqual(tagSearch.value as? String, "Fixture tag 100")
        let tagToggle = manager.buttons["Fixture tag 100"]
        XCTAssertTrue(tagToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(tagToggle.value as? String, "selected")
        tagToggle.click()
        XCTAssertEqual(waitForValue(of: tagToggle, expected: "unselected", timeout: 5), .completed)
        manager.buttons["cancelReferenceSelection"].click()
        // Do not assert `manager.exists == false` on this retained sheet
        // query: the current XCUITest/AppKit bridge can cache an obsolete
        // remote sheet node after the owning binding has retired it.  The
        // fresh reopen below verifies the observable transaction property:
        // Cancel restores the original durable link rather than applying the
        // draft mutation.
        manageTags.click()
        XCTAssertTrue(manager.waitForExistence(timeout: 5))
        let reopenedTagSearch = manager.textFields["tagManagerSearch"]
        XCTAssertEqual(reopenedTagSearch.value as? String, "Fixture tag 100")
        let restoredTag = manager.buttons["Fixture tag 100"]
        XCTAssertTrue(restoredTag.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredTag.value as? String, "selected",
                       "tag draft 的 Cancel 不得解除原有 paper link")
        manager.buttons["cancelReferenceSelection"].click()

        let manageCollections = app.buttons["manageCollections"]
        XCTAssertTrue(manageCollections.waitForExistence(timeout: 5))
        manageCollections.click()
        XCTAssertTrue(manager.waitForExistence(timeout: 5))
        let collectionList = manager.descendants(matching: .any)["collectionManagerScrollableList"].firstMatch
        XCTAssertTrue(collectionList.waitForExistence(timeout: 5))
        let collectionSearch = manager.textFields["collectionManagerSearch"]
        XCTAssertEqual(collectionSearch.value as? String, "Fixture collection 100")
        let collectionToggle = manager.buttons["Fixture collection 100"]
        XCTAssertTrue(collectionToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(collectionToggle.value as? String, "unselected")
        collectionToggle.click()
        XCTAssertEqual(waitForValue(of: collectionToggle, expected: "selected", timeout: 5), .completed)
        manager.buttons["cancelReferenceSelection"].click()
        // See the equivalent tag-manager note above. Reopening and checking
        // the saved `unselected` value is the reliable UI observation here.
        manageCollections.click()
        XCTAssertTrue(manager.waitForExistence(timeout: 5))
        let reopenedCollectionSearch = manager.textFields["collectionManagerSearch"]
        XCTAssertEqual(reopenedCollectionSearch.value as? String, "Fixture collection 100")
        let restoredCollection = manager.buttons["Fixture collection 100"]
        XCTAssertTrue(restoredCollection.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredCollection.value as? String, "unselected",
                       "collection draft 的 Cancel 不得新建 paper link")
        #endif
    }

    func testSettingsWorkflowIsKeyboardDiscoverable() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8),
                      "UI test 必须先确认 process-local fixture 依赖；不得读取用户资料库")
        let settings = app.buttons["settingsButton"]
        let settingsExists = settings.waitForExistence(timeout: 8)
        XCTAssertTrue(settingsExists, "主窗口应提供可访问的设置入口")
        settings.tap()
        let baseURLExists = app.textFields["providerBaseURL"].waitForExistence(timeout: 5)
        let apiKeyExists = app.secureTextFields["providerAPIKey"].exists
        let discoverModelsExists = app.buttons["discoverModels"].exists
        // AppKit renders Toggle as a checkbox in this Form; other macOS/Xcode
        // versions may expose it as a switch.  Both carry the same stable ID.
        let visionCapabilityExists = app.switches["providerSupportsVision"].exists ||
            app.checkBoxes["providerSupportsVision"].exists
        let saveAndCancelExist = app.buttons["保存"].exists && app.buttons["取消"].exists
        // macOS 26 may expose Form status Text as `Other`/`Heading` rather
        // than `StaticText`; the explicit state identifier is the stable
        // contract, not that incidental AX role.
        let keyStatus = app.descendants(matching: .any)["apiKeyStorageStatus-saved"].firstMatch
        let clearKey = app.buttons["clearAPIKey"]
        XCTAssertTrue(baseURLExists, "设置表单应暴露 Base URL 输入")
        XCTAssertTrue(apiKeyExists, "设置表单应暴露 Keychain API Key 输入")
        XCTAssertTrue(discoverModelsExists, "设置表单应提供受限的模型发现动作")
        XCTAssertTrue(visionCapabilityExists, "Vision capability 必须由用户在设置中手工确认")
        XCTAssertTrue(saveAndCancelExist, "设置表单应可保存或取消")
        XCTAssertTrue(keyStatus.waitForExistence(timeout: 3), "fixture 必须明确说明 key 保存状态")
        XCTAssertEqual(keyStatus.value as? String, "已保存", "fixture key 仅存在于进程内 substitute")
        XCTAssertTrue(clearKey.exists, "设置表单必须允许清除当前 provider 的 API Key")
        XCTAssertEqual(waitForHittability(of: clearKey, expected: true, timeout: 3), .completed,
                       "清除 API Key 必须是实际可点击的原生 macOS 控件")
        // `click()` is the macOS mouse activation path.  In contrast,
        // `tap()` may fall back to a coordinate event for a Form button and
        // leave AppKit's action uninvoked even though the element exists.
        clearKey.click()
        let clearedStatus = app.descendants(matching: .any)["apiKeyStorageStatus-missing"].firstMatch
        XCTAssertTrue(clearedStatus.waitForExistence(timeout: 3),
                      "清除后 UI 必须切换到明确的未保存状态分支")
        XCTAssertEqual(clearedStatus.value as? String, "未保存", "清除后 UI 不得继续显示保存状态")
        #endif
    }

    func testFixtureAuthorSearchPaperSelectionAndFiveTabs() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8),
                      "UI test 必须先确认 process-local fixture 依赖；不得读取用户资料库")
        let selfAuthor = app.staticTexts["authorRow-2010363"].firstMatch
        let buildIndex = app.links["buildAuthorIndex"]
        let selfExists = selfAuthor.waitForExistence(timeout: 8)
        let buildExists = buildIndex.waitForExistence(timeout: 5)
        XCTAssertTrue(selfExists, "fixture launch 必须显示置顶本人")
        XCTAssertTrue(buildExists, "fixture launch 必须提供作者索引动作")
        buildIndex.tap()
        let zed = app.staticTexts["authorRow-77"].firstMatch
        let zedExists = zed.waitForExistence(timeout: 8)
        XCTAssertTrue(zedExists, "h(all)=21 的普通 Z 作者必须显示")

        let authorSearch = app.textFields["authorSearch"]
        authorSearch.click()
        authorSearch.typeText("Bali")
        XCTAssertEqual(authorSearch.value as? String, "Bali", "NSSearchField 输入必须进入 SwiftUI search binding")
        let selfAfterSearch = selfAuthor.waitForExistence(timeout: 3)
        XCTAssertTrue(selfAfterSearch, "搜索不匹配时本人仍必须置顶可见")
        // A fresh process is the stable, keyboard-independent way to reset
        // NSSearchField for the remainder of this end-to-end fixture flow.
        // Matching/normalization itself is covered by the SwiftPM contracts;
        // this UI test covers native search entry, self pin, and the reset
        // boundary without depending on an off-screen AppKit clear affordance.
        app.terminate()
        app.launch()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let rebuildIndex = app.links["buildAuthorIndex"]
        XCTAssertTrue(rebuildIndex.waitForExistence(timeout: 5))
        rebuildIndex.tap()
        let zedAfterReset = app.staticTexts["authorRow-77"].firstMatch
        XCTAssertTrue(zedAfterReset.waitForExistence(timeout: 8), "重启 fixture 后 Z section 必须恢复")
        XCTAssertTrue(zedAfterReset.isHittable, "重启 fixture 后普通 Z 作者必须重新可操作")

        zedAfterReset.click()
        let paper = app.staticTexts["paperRow-1234567"].firstMatch
        let paperExists = paper.waitForExistence(timeout: 8)
        XCTAssertTrue(paperExists, "选择作者后 fixture paper 必须同步并显示")
        paper.click()
        let tabs = app.descendants(matching: .any)["paperLensTabs"].firstMatch
        let tabsExist = tabs.waitForExistence(timeout: 5)
        XCTAssertTrue(tabsExist, "选择论文后必须显示 Paper Lens tabs")
        let evidenceTab = app.radioButtons["证据"]
        let sourceTab = app.radioButtons["原始资料"]
        let evidenceExists = evidenceTab.exists
        let sourceExists = sourceTab.exists
        XCTAssertTrue(evidenceExists && sourceExists, "v2 必须提供 Evidence 和 source tabs")
        evidenceTab.click()
        let metadataAnchorNotice = app.staticTexts["尚未下载全文：当前只可浏览 abstract/caption anchors。"]
        let evidenceFallback = metadataAnchorNotice.waitForExistence(timeout: 3)
        XCTAssertTrue(evidenceFallback, "无全文时 Evidence 必须可靠降级")
        #endif
    }

    func testFixtureAnalysisCancellationCacheAndFigureDegradation() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp(automaticAnalysis: true)
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let paper = selectFixturePaper(in: app)
        paper.click()

        let regenerate = app.buttons["regenerateInsight"]
        XCTAssertTrue(regenerate.waitForExistence(timeout: 5), "选中 fixture paper 后必须提供可取消的分析入口")
        let disclosure = app.sheets.firstMatch.buttons["acceptInsightDisclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "自动分析经 600 ms debounce 后仍须经过明确的隐私 disclosure")
        // The desktop test host can retain an unrelated Codex window in its
        // accessibility hierarchy.  Explicitly foreground the AUT at each
        // state-changing interaction so XCTest never redirects a legitimate
        // fixture cancellation/cache assertion to that unrelated window.
        app.activate()
        disclosure.tap()

        let cancel = app.buttons["cancelInsight"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "fixture LLM 必须进入可见且可取消的中间状态")
        app.activate()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(waitForInsightStatus("已取消；已保留先前成功结果", in: app, timeout: 5), .completed,
                       "取消必须成为明确状态，而非失败或静默重试")

        app.activate()
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertEqual(waitForInsightStatus("已完成 · 1 次请求", in: app, timeout: 5), .completed,
                       "fixture mock LLM 必须只完成一次本地请求")
        app.activate()
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertEqual(waitForInsightStatus("已从本地缓存显示 · 0 次请求", in: app, timeout: 5), .completed,
                       "重生成命中 cache 时不得再次调用 mock completion")

        let figures = app.radioButtons["重要图像"]
        XCTAssertTrue(figures.waitForExistence(timeout: 3))
        app.activate()
        figures.tap()
        let unavailableFigure = app.buttons["figureRow-fig-missing-url"]
        XCTAssertTrue(unavailableFigure.waitForExistence(timeout: 3), "fixture 应列出没有 URL 的 figure")
        app.activate()
        unavailableFigure.tap()
        let degradation = app.staticTexts["记录没有可用图像 URL"]
        XCTAssertTrue(degradation.waitForExistence(timeout: 3), "缺少 image URL 时必须显示 caption-only 降级，而不是伪造图像")
        #endif
    }

    func testFixtureReferenceManagerControlsAreKeyboardDiscoverable() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let paper = selectFixturePaper(in: app)
        paper.click()
        let source = app.radioButtons["原始资料"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()

        XCTAssertTrue(app.buttons["toggleFavorite"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["newTagName"].exists)
        XCTAssertTrue(app.buttons["addTag"].exists)
        XCTAssertTrue(app.textFields["newCollectionName"].exists)
        XCTAssertTrue(app.buttons["addCollection"].exists)
        XCTAssertTrue(app.textFields["readingNote"].exists)
        XCTAssertTrue(app.buttons["saveReadingNote"].exists)
        XCTAssertTrue(app.buttons["copyMarkdownNote"].exists)
        XCTAssertTrue(app.buttons["exportMarkdownNote"].exists)
        #endif
    }

    func testFixtureFullTextScopeAndAnchorJumpStayLocal() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let paper = selectFixturePaper(in: app)
        paper.click()
        let evidence = app.radioButtons["证据"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        evidence.click()
        let scope = app.staticTexts["尚未下载全文：当前只可浏览 abstract/caption anchors。"]
        XCTAssertTrue(scope.waitForExistence(timeout: 3))
        let download = app.buttons["downloadFullText-fixture-fulltext"]
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        download.click()
        let confirmDownload = app.buttons["confirmFullTextDownload"]
        XCTAssertTrue(confirmDownload.waitForExistence(timeout: 5), "PDF GET 前必须展示含 Content-Length/上限的预检确认")
        confirmDownload.click()
        let extracted = app.staticTexts["全文已提取为页级 evidence anchors。"]
        XCTAssertTrue(extracted.waitForExistence(timeout: 8), "fixture PDF 必须由本地 downloader 提取")
        let anchor = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'evidenceAnchor-pdf:'")).firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 3))
        anchor.click()
        XCTAssertTrue(app.staticTexts["PDF p.1"].waitForExistence(timeout: 3), "点击 PDF anchor 应打开页级预览")
        #endif
    }

    func testFixtureCaptionOnlyAndVisionDisclosureRemainSeparate() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp(initialPaperLensTab: "figures")
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let paper = selectFixturePaper(in: app)
        paper.click()
        let captionOnlyFigure = app.buttons["figureRow-fig-fixture-local"]
        XCTAssertTrue(captionOnlyFigure.waitForExistence(timeout: 3))
        XCTAssertEqual(captionOnlyFigure.value as? String, "caption-only", "未发送像素时必须明确为 caption-only")
        let vision = app.buttons["generateVisionInsight"]
        XCTAssertTrue(vision.waitForExistence(timeout: 3))
        vision.click()
        let disclosure = app.buttons["acceptVisionDisclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3), "Vision 首次发送像素必须有独立 disclosure")
        disclosure.click()
        XCTAssertTrue(app.staticTexts["模型查看了缩放图像像素"].waitForExistence(timeout: 8))
        #endif
    }

    func testFixtureVisionMaximumZeroDisablesPixelsAndFrozenDisclosureIsSpecific() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let zeroApp = launchFixtureApp(initialPaperLensTab: "figures", maximumFigures: 0)
        XCTAssertTrue(fixtureModeIndicator(in: zeroApp).waitForExistence(timeout: 8),
                      "UI test 必须先确认 process-local fixture 依赖；不得读取用户资料库")
        let zeroPaper = selectFixturePaper(in: zeroApp)
        zeroPaper.click()
        let zeroVision = zeroApp.buttons["generateVisionInsight"]
        XCTAssertTrue(zeroVision.waitForExistence(timeout: 5))
        XCTAssertFalse(zeroVision.isEnabled, "maximumFigures=0 必须在实际 UI 禁用像素发送")
        XCTAssertTrue(zeroApp.staticTexts["maximumFigures=0 · 不发送图像"].waitForExistence(timeout: 3),
                      "零图像状态必须以文字说明，而不只靠灰色按钮")
        zeroApp.terminate()

        let app = launchFixtureApp(initialPaperLensTab: "figures")
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let paper = selectFixturePaper(in: app)
        paper.click()
        let vision = app.buttons["generateVisionInsight"]
        XCTAssertTrue(vision.waitForExistence(timeout: 5) && vision.isEnabled)
        vision.click()
        XCTAssertTrue(app.buttons["acceptVisionDisclosure"].waitForExistence(timeout: 5))
        let frozenDisclosure = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "本地已冻结 payload hash")).firstMatch
        XCTAssertTrue(frozenDisclosure.waitForExistence(timeout: 5),
                      "Vision consent 必须显示本次固定 payload 的 hash、图像与请求数")
        #endif
    }

    func testFixtureResearchHomeUsesLocalSnapshotCounts() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8),
                      "必须先确认 fixture sentinel，再触碰 Research Home")
        let paper = selectFixturePaper(in: app)
        paper.click()
        XCTAssertTrue(app.radioButtons["原始资料"].waitForExistence(timeout: 5))
        app.radioButtons["原始资料"].click()
        let favorite = app.buttons["toggleFavorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.click()
        let read = app.buttons["toggleRead"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        read.click()
        XCTAssertEqual(waitForValue(of: read, expected: "read", timeout: 5), .completed)
        let homeButton = app.buttons["researchHomeButton"]
        XCTAssertTrue(homeButton.waitForExistence(timeout: 8))
        homeButton.click()
        XCTAssertTrue(app.otherElements["researchHome"].waitForExistence(timeout: 5))
        let favoriteMetric = app.descendants(matching: .any)["homeMetric-favorites"]
        let inboxMetric = app.descendants(matching: .any)["homeMetric-inbox"]
        XCTAssertTrue(favoriteMetric.waitForExistence(timeout: 5) && inboxMetric.exists)
        XCTAssertEqual(waitForValue(of: favoriteMetric, expected: "1", timeout: 5), .completed,
                       "Home 收藏计数必须来自刚才真实的 local favorite mutation")
        XCTAssertEqual(waitForValue(of: inboxMetric, expected: "1", timeout: 5), .completed,
                       "Reading Inbox 必须排除刚刚标记为已读的论文，并保留另一篇 fixture paper")
        #endif
    }

    func testFixtureWorkbenchEntryShowsGraphPreview() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        // The default Radar and fixture Compare paths are exercised by their
        // own durable UI cases.  Start this case on Graph so host-owned
        // notification overlays cannot intercept segmented-picker clicks.
        let app = launchFixtureApp(initialWorkbenchTab: "graph")
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8),
                      "必须先确认 fixture sentinel，再打开 Workbench")
        let workbenchButton = app.buttons["workbenchButton"]
        XCTAssertTrue(workbenchButton.waitForExistence(timeout: 8))
        workbenchButton.click()
        // A SwiftUI root VStack is exposed as a Group on recent macOS builds,
        // not consistently as XCUIElementTypeOther.  The native sheet and
        // controls below are the product-facing behavior under test; querying
        // them via the presented sheet avoids tying the test to that internal
        // accessibility role.
        let workbenchSheet = app.sheets.firstMatch
        XCTAssertTrue(workbenchSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(workbenchSheet.staticTexts["Evidence Workbench"].waitForExistence(timeout: 5))
        XCTAssertTrue(workbenchSheet.staticTexts["Preview: no edge ingestion yet · 仅显示当前本地 snapshot 已有的 source-backed edge；不会伪造缺失关系。"].waitForExistence(timeout: 3),
                      "未实现 edge ingestion 时必须在实际 UI 中保持 preview disclosure")
        #endif
    }

    func testFixtureSyncCenterExposesDurableLocalJobSummary() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let button = app.buttons["syncCenterButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        XCTAssertTrue(app.staticTexts["syncCenter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["syncCenterScrollableContent"].firstMatch.waitForExistence(timeout: 5),
                      "Sync Center 必须暴露带可见滚动指示条的独立 job 区域")
        XCTAssertTrue(app.staticTexts["syncCenterDurableSummary"].waitForExistence(timeout: 5),
                      "Sync Center 必须展示 checkpoint/batch/event 的本地 durable 摘要")
        #endif
    }

    func testFixtureUnifiedLocalSearchShowsProvenanceWithoutProviderRequest() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        _ = selectFixturePaper(in: app)
        let search = app.textFields["globalPaperSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("renormalization")
        let currentPaper = app.staticTexts["paperRow-1234567"].firstMatch
        XCTAssertTrue(currentPaper.waitForExistence(timeout: 3))
        currentPaper.click()
        XCTAssertTrue(app.buttons["清除"].waitForExistence(timeout: 5),
                      "文本搜索在控件失焦后必须提交到本地状态，而不是等待额外网络")
        XCTAssertTrue(app.staticTexts["Fixture lattice renormalization"].waitForExistence(timeout: 5))
        let provenance = app.descendants(matching: .any)["searchProvenanceSummary"]
        XCTAssertTrue(provenance.waitForExistence(timeout: 5),
                      "⌘K 对应的本地搜索必须显示命中来源，而不是发送 query 到 provider")
        let expectedSummary = "本地命中：2 篇 · 来源：abstract、title"
        let labelMatches = NSPredicate(format: "label == %@", expectedSummary)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: labelMatches, object: provenance)], timeout: 5), .completed,
                       "本地搜索摘要必须给出 fixture 命中的本地字段来源")
        #endif
    }

    func testFixtureReadAndFavoriteControlsPerformVisibleLocalMutation() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let paper = selectFixturePaper(in: app)
        paper.click()
        let source = app.radioButtons["原始资料"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()
        let detailStatus = app.staticTexts["paperDetailStatus"]
        XCTAssertTrue(detailStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(waitForValue(of: detailStatus, expected: "INSPIRE 单篇详情已更新。", timeout: 5), .completed,
                       "收藏前必须等本地 fixture 的单篇详情合并完成，避免把并发刷新当作用户 mutation")
        let favorite = app.buttons["toggleFavorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertEqual(waitForHittability(of: favorite, expected: true, timeout: 5), .completed,
                       "只有可点击的 Reference manager 控件才能作为本地 mutation 的 UI 证据")
        let initiallyFavorite = app.staticTexts["favoriteState-1234567-favorite"]
        let initiallyNotFavorite = app.staticTexts["favoriteState-1234567-not_favorite"]
        let initialFavoriteState: String
        if initiallyFavorite.exists {
            initialFavoriteState = "favorite"
        } else {
            XCTAssertTrue(initiallyNotFavorite.waitForExistence(timeout: 5),
                          "收藏状态必须以一个稳定的本地状态节点暴露")
            initialFavoriteState = "not_favorite"
        }
        favorite.tap()
        let expectedFavoriteState = initialFavoriteState == "favorite" ? "not_favorite" : "favorite"
        let updatedFavoriteState = app.staticTexts["favoriteState-1234567-\(expectedFavoriteState)"]
        XCTAssertTrue(updatedFavoriteState.waitForExistence(timeout: 5),
                      "收藏动作必须让真实 UI 切换到新的本地状态节点")
        // A host-owned Notification Center banner may interrupt this later
        // click, after the Reference-manager mutation has been observed.
        let read = app.buttons["toggleRead"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        read.click()
        XCTAssertEqual(waitForValue(of: read, expected: "read", timeout: 5), .completed)
        #endif
    }

    func testFixtureReferenceNoteAndTagControlsMutateOnlyFixtureStore() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let paper = selectFixturePaper(in: app)
        paper.click()
        let source = app.radioButtons["原始资料"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()
        let detailStatus = app.staticTexts["paperDetailStatus"]
        XCTAssertTrue(detailStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(waitForValue(of: detailStatus, expected: "INSPIRE 单篇详情已更新。", timeout: 5), .completed,
                       "Reference manager mutation 前必须等 fixture 详情合并完成，避免晚到刷新重置正在编辑的 note")
        let tag = app.textFields["newTagName"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        XCTAssertEqual(waitForHittability(of: tag, expected: true, timeout: 5), .completed)
        tag.click()
        tag.typeText("fixture-tag")
        XCTAssertEqual(tag.value as? String, "fixture-tag", "tag 输入必须进入隔离的本地 form state")
        // `tag.value` above confirms that SwiftUI has received the native
        // field edit.  Re-clicking the selected paper merely starts another
        // detail-refresh task, which can temporarily mark the whole AppKit
        // application as non-hittable even though this enabled button still
        // accepts its real action.  Reactivate the same fixture process
        // without changing its paper selection or kicking off a refresh.
        app.activate()
        let addTag = app.buttons["addTag"]
        XCTAssertTrue(addTag.waitForExistence(timeout: 5))
        XCTAssertTrue(addTag.isEnabled,
                      "tag 文本编辑提交后，保存动作必须在同一 fixture 论文上下文中启用")
        addTag.click()
        let availableTags = app.descendants(matching: .any)["availableTagsState-1234567-1"]
        XCTAssertTrue(availableTags.waitForExistence(timeout: 5),
                      "tag 保存后必须刷新同一 fixture store 的可用 tag 投影")
        // AppKit bridges a SwiftUI StaticText's custom value differently
        // across host/Xcode versions: some expose the explicit AX value and
        // others expose the same visible, VoiceOver-readable string as its
        // label.  Both forms are one semantic projection of this uniquely
        // identified tag state; require the exact tag in either form rather
        // than treating that host-level mapping difference as a store error.
        let expectedTag = NSPredicate(format: "value == %@ OR label CONTAINS %@", "fixture-tag", "fixture-tag")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expectedTag, object: availableTags)], timeout: 5), .completed,
                       "保存后定向 tag 状态必须以 AX value 或 VoiceOver label 暴露 fixture-tag")
        let note = app.textFields["readingNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(waitForHittability(of: note, expected: true, timeout: 5), .completed)
        note.click()
        // Keep this fixture input ASCII-only: the host Chinese IME otherwise
        // opens an OS candidate panel that can intercept the following save
        // click, which is neither LatticeLens UI nor persistence behavior.
        note.typeText("fixture-note")
        let saveNote = app.buttons["saveReadingNote"]
        XCTAssertEqual(waitForHittability(of: saveNote, expected: true, timeout: 5), .completed,
                       "note 编辑提交后，保存动作必须在同一论文上下文中保持可用")
        saveNote.click()
        let persistedNote = app.staticTexts["noteState-1234567-1"]
        XCTAssertTrue(persistedNote.waitForExistence(timeout: 5),
                      "保存 note 后必须从同一 fixture store 回读 durable note 投影")
        #endif
    }

    func testFixtureRadarQueryCanBeSavedAndPausedThroughOwnedJobPath() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        app.buttons["workbenchButton"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let name = sheet.textFields["radarQueryName"]
        let query = sheet.textFields["radarQueryText"]
        XCTAssertTrue(name.waitForExistence(timeout: 5) && query.exists)
        name.click()
        name.typeText(" fixture-radar")
        sheet.buttons["saveRadarQuery"].click()
        let pause = sheet.links.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pauseRadarQuery-")).firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5),
                      "保存的 Radar query 必须产生由 durable UUID 标识的暂停动作")
        let ownerID = try XCTUnwrap(pause.identifier.split(separator: "-", maxSplits: 1).last.map(String.init),
                                    "暂停动作必须暴露其 durable query owner")
        pause.click()
        let state = sheet.descendants(matching: .any)["radarQueryState-\(ownerID)"]
        XCTAssertTrue(state.waitForExistence(timeout: 5),
                      "暂停后同一 durable query owner 必须仍显示本地状态")
        let pausedState = NSPredicate(format: "value == %@", "paused")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: pausedState, object: state)], timeout: 5), .completed,
                       "暂停必须取消同一 query owner 并发布可恢复的 durable state")
        #endif
    }

    func testFixtureNotebookShowsExactAnchorAnnotationAfterLocalPDFExtraction() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let paper = selectFixturePaper(in: app)
        paper.click()
        app.radioButtons["证据"].click()
        XCTAssertTrue(app.buttons["downloadFullText-fixture-fulltext"].waitForExistence(timeout: 5))
        app.buttons["downloadFullText-fixture-fulltext"].click()
        XCTAssertTrue(app.buttons["confirmFullTextDownload"].waitForExistence(timeout: 5))
        app.buttons["confirmFullTextDownload"].click()
        XCTAssertTrue(
            app.staticTexts["全文已提取为页级 evidence anchors。"].waitForExistence(timeout: 8),
            "只有本地 PDF extraction 完成后才可创建 annotation"
        )
        // Metadata anchors can occupy the initial visible List rows.  Filter
        // to the PDF source before locating the per-anchor action so this
        // real UI test exercises the extracted page anchor rather than a
        // renderer-dependent off-screen cell.
        let pdfFilter = app.radioButtons["pdf"]
        if pdfFilter.waitForExistence(timeout: 3) {
            pdfFilter.click()
        } else {
            let pdfButton = app.buttons["pdf"]
            XCTAssertTrue(pdfButton.waitForExistence(timeout: 3))
            pdfButton.click()
        }
        // The product intentionally styles this action as a link, which the
        // macOS accessibility bridge exposes as `Link`, not `Button`.
        let annotate = app.links.matching(NSPredicate(format: "identifier BEGINSWITH 'annotateEvidence-v3pdf:'")).firstMatch
        XCTAssertTrue(annotate.waitForExistence(timeout: 8))
        annotate.click()
        app.buttons["workbenchButton"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        selectWorkbenchTab("Notebook / Export", in: sheet)
        XCTAssertTrue(sheet.staticTexts["local annotation"].waitForExistence(timeout: 5),
                      "Notebook entry 必须保留 page/range/quote hash 所属的本地 annotation")
        #endif
    }

    func testFixtureNotebookCreatesVisibleMultiAnchorEntryOnlyAfterExplicitSave() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let expectedTitle = "UI multi-anchor entry"
        let app = launchFixtureApp(initialNotebookEntryTitle: expectedTitle)
        // A failed notebook assertion must not leave the fixture process
        // alive while XCTest finalizes its result.  This case owns only this
        // process-local fixture application.
        defer { app.terminate() }
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let paper = selectFixturePaper(in: app)
        paper.click()
        app.radioButtons["证据"].click()
        XCTAssertTrue(app.buttons["downloadFullText-fixture-fulltext"].waitForExistence(timeout: 5))
        app.buttons["downloadFullText-fixture-fulltext"].click()
        XCTAssertTrue(app.buttons["confirmFullTextDownload"].waitForExistence(timeout: 5))
        app.buttons["confirmFullTextDownload"].click()
        XCTAssertTrue(app.staticTexts["全文已提取为页级 evidence anchors。"].waitForExistence(timeout: 8))

        let pdfFilter = app.radioButtons["pdf"]
        if pdfFilter.waitForExistence(timeout: 3) { pdfFilter.click() }
        else {
            let pdfButton = app.buttons["pdf"]
            XCTAssertTrue(pdfButton.waitForExistence(timeout: 3))
            pdfButton.click()
        }
        let annotate = app.links.matching(NSPredicate(format: "identifier BEGINSWITH 'annotateEvidence-v3pdf:'")).firstMatch
        XCTAssertTrue(annotate.waitForExistence(timeout: 8))
        annotate.click()

        // The action performs a durable local transaction through the store
        // actor.  Wait for the product's user-visible completion state before
        // requesting another sheet, so this test proves the multi-anchor
        // record exists rather than racing an arbitrary run-loop turn.
        let annotationStatus = app.staticTexts["annotationSaveStatus"]
        XCTAssertEqual(waitForValue(of: annotationStatus, expected: "本地 annotation 已保存", timeout: 8), .completed,
                       "打开 Workbench 前 PDF annotation 必须已完成本地 durable 保存")

        // The annotation write refreshes the local workbench projection.
        // Reactivate and resolve the concrete toolbar element after that
        // refresh, avoiding a stale AppKit toolbar proxy in the UI runner.
        app.activate()
        let workbench = app.buttons["workbenchButton"]
        guard workbench.waitForExistence(timeout: 5),
              waitForHittability(of: workbench, expected: true, timeout: 5) == .completed else {
            XCTFail("写入 local annotation 后 Evidence Workbench toolbar action 必须仍可操作")
            return
        }
        workbench.click()
        let sheet = app.sheets.firstMatch
        guard sheet.waitForExistence(timeout: 5) else {
            XCTFail("点击 Evidence Workbench 后必须呈现工作台 sheet")
            return
        }
        selectWorkbenchTab("Notebook / Export", in: sheet)
        let create = app.buttons["createNotebookEntry"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.click()

        let title = app.textFields["notebookEntryTitle"]
        guard title.waitForExistence(timeout: 5) else {
            XCTFail("Notebook 标题必须通过 fixture-only launch input 出现在原生 text field")
            return
        }
        XCTAssertEqual(title.value as? String, expectedTitle,
                       "fixture-only title seed 必须由原生 text field 暴露；手动验收仍覆盖真实键盘/IME")
        let fixturePaper = app.buttons["notebookPaper-1234567"]
        guard fixturePaper.waitForExistence(timeout: 5), fixturePaper.isHittable else {
            XCTFail("fixture paper 必须在专用滚动区中可见且可操作")
            return
        }
        // A native SwiftUI Button's accessibility press is the stable macOS
        // action in this nested scroll region. Verify its user-visible draft
        // state before asking for anchors, so a failed action cannot be
        // mistaken for an empty evidence list.
        fixturePaper.tap()
        let refreshedFixturePaper = app.buttons["notebookPaper-1234567"]
        guard waitForValue(of: refreshedFixturePaper, expected: "selected", timeout: 5) == .completed else {
            XCTFail("选择 Notebook paper 后必须在该稳定 record row 上发布 selected 状态")
            return
        }

        let anchorList = app.descendants(matching: .any)["notebookAnchorsScrollableList"].firstMatch
        // SwiftUI bridges this labelled ScrollView as a generic AX group on
        // macOS, so the container itself need not expose a click action.
        // Each contained anchor below must nevertheless be hittable.
        guard anchorList.waitForExistence(timeout: 5) else {
            // Preserve an inspectable failure artifact instead of weakening
            // the independent-scroll-region contract when a future AppKit
            // bridge drops the container from its AX hierarchy.
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Notebook anchor accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("可选 anchors 必须位于独立、带滚动条的可访问区域")
            return
        }
        let anchorIDs = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "notebookAnchor-"))
            .allElementsBoundByIndex
            .prefix(2)
            .map(\.identifier)
        guard anchorIDs.count == 2 else {
            XCTFail("PDF annotation 与同 paper evidence 必须同时出现在可选 multi-anchor 列表中")
            return
        }
        for (offset, anchorID) in anchorIDs.enumerated() {
            // The SwiftUI list is intentionally rebuilt after selection.  Re-resolve
            // by its stable contract ID rather than retaining an AX element from the
            // pre-toggle hierarchy, which could turn one click into a no-op.
            let anchor = app.descendants(matching: .any)[anchorID].firstMatch
            guard anchor.waitForExistence(timeout: 5), anchor.isHittable else {
                XCTFail("第 \(offset + 1) 个 anchor 必须在独立滚动区中可操作")
                return
            }
            anchor.tap()
            let refreshedAnchor = app.descendants(matching: .any)[anchorID].firstMatch
            guard waitForValue(of: refreshedAnchor, expected: "selected", timeout: 5) == .completed else {
                XCTFail("第 \(offset + 1) 个 anchor 必须在 draft 中显示为已选中；实际 value: \(String(describing: refreshedAnchor.value))")
                return
            }
        }
        let selectedAnchorCount = app.descendants(matching: .any)["notebookSelectedAnchorCount"].firstMatch
        guard waitForValue(of: selectedAnchorCount, expected: "2", timeout: 5) == .completed else {
            XCTFail("两个明确选择的 anchors 必须进入同一 draft；实际数量: \(String(describing: selectedAnchorCount.value))")
            return
        }
        let save = app.buttons["saveNotebookEntry"]
        guard save.waitForExistence(timeout: 5), save.isEnabled else {
            XCTFail("有效同 paper anchors 选中后才允许提交 entry")
            return
        }
        save.click()

        // The normal fixture intentionally contains older notebook rows.  Do
        // not let a prefix-only query accept one of those before the explicit
        // Save transaction returns and refreshes the durable projection.
        let savedRow = sheet.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@ AND value == %@",
            "notebookEntryRow-", expectedTitle, "2 anchors"
        )).firstMatch
        XCTAssertTrue(savedRow.waitForExistence(timeout: 8),
                      "显式保存后必须显示本次 entry 的持久化 2-anchor 结果，不能读取旧 fixture row")
        #endif
    }

    func testFixtureSharedPDFDeleteIsPaperScopedAndRemainingAnchorOpens() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8),
                      "UI test 必须先确认 process-local fixture 依赖；不得读取用户资料库")
        let first = selectFixturePaper(in: app)
        first.click()
        app.radioButtons["证据"].click()
        app.buttons["downloadFullText-fixture-fulltext"].click()
        XCTAssertTrue(app.buttons["confirmFullTextDownload"].waitForExistence(timeout: 5))
        app.buttons["confirmFullTextDownload"].click()
        XCTAssertEqual(waitForValue(of: app.staticTexts["fullTextStatus"], expected: "全文已提取为页级 evidence anchors。", timeout: 8), .completed)

        let second = app.staticTexts["paperRow-1234568"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.click()
        app.radioButtons["证据"].click()
        XCTAssertTrue(app.buttons["downloadFullText-fixture-fulltext-1234568"].waitForExistence(timeout: 5))
        app.buttons["downloadFullText-fixture-fulltext-1234568"].click()
        XCTAssertTrue(app.buttons["confirmFullTextDownload"].waitForExistence(timeout: 5))
        app.buttons["confirmFullTextDownload"].click()
        XCTAssertEqual(waitForValue(of: app.staticTexts["fullTextStatus"], expected: "全文已提取为页级 evidence anchors。", timeout: 8), .completed)

        first.click()
        XCTAssertTrue(app.radioButtons["证据"].waitForExistence(timeout: 5))
        app.radioButtons["证据"].click()
        let delete = app.buttons["deleteSelectedFullText"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        XCTAssertEqual(waitForExistence(of: delete, expected: false, timeout: 5), .completed,
                       "删除第一篇 document reference 后，该论文的全文控制必须消失")

        second.click()
        app.radioButtons["证据"].click()
        let remainingPDFAnchor = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'evidenceAnchor-pdf:'")).firstMatch
        XCTAssertTrue(remainingPDFAnchor.waitForExistence(timeout: 8),
                      "shared blob 删除第一篇引用后，第二篇仍必须保留自己的 evidence anchor")
        let openFirstPDFAnchor = app.buttons["openFirstPDFEvidenceAnchor"]
        XCTAssertTrue(openFirstPDFAnchor.waitForExistence(timeout: 5),
                      "有当前论文的本地 PDF anchor 时，键盘可达的打开动作必须存在")
        app.activate()
        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["pdfAnchorPreviewPageTitle-1"].waitForExistence(timeout: 5),
                      "剩余 document reference 必须继续打开同一 content-addressed local PDF 页面")
        #endif
    }

    func testFixtureEvidenceInsightStartsOnlyAfterLocalPDFAnchorExists() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let paper = selectFixturePaper(in: app)
        paper.click()
        app.radioButtons["证据"].click()
        app.buttons["downloadFullText-fixture-fulltext"].click()
        XCTAssertTrue(app.buttons["confirmFullTextDownload"].waitForExistence(timeout: 5))
        app.buttons["confirmFullTextDownload"].click()
        let evidence = app.buttons["generateEvidenceInsight"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 8))
        evidence.click()
        XCTAssertTrue(app.buttons["acceptEvidenceDisclosure"].waitForExistence(timeout: 5),
                      "evidence provider request 前必须显示仅限 anchors/chunks 的 disclosure")
        app.buttons["declineEvidenceDisclosure"].click()
        #endif
    }

    func testFixtureEvidenceInsightCompletesWhenProviderUsesScalarResearchQuestion() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp(legacyResearchQuestionString: true)
        defer { app.terminate() }
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8),
                      "本用例只能在隔离的 fixture dependency graph 中运行")
        // This focused Evidence regression owns no author-index behavior: the
        // fixture bootstraps this bounded paper locally, so selecting it
        // directly keeps the test on the exact formula-generation path.
        let paper = app.staticTexts["paperRow-1234567"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 8))
        paper.click()
        let formulaTab = app.radioButtons["公式推导"]
        if formulaTab.waitForExistence(timeout: 5) {
            formulaTab.click()
        } else {
            // AppKit has exposed this same segmented Picker as either a radio
            // button group or ordinary buttons across Xcode/macOS releases.
            let formulaButton = app.buttons["公式推导"]
            XCTAssertTrue(formulaButton.waitForExistence(timeout: 5))
            formulaButton.click()
        }
        app.buttons["downloadFullText-fixture-fulltext"].click()
        XCTAssertTrue(app.buttons["confirmFullTextDownload"].waitForExistence(timeout: 5))
        app.buttons["confirmFullTextDownload"].click()
        let generate = app.buttons["generateEvidenceInsight"]
        XCTAssertTrue(generate.waitForExistence(timeout: 8))
        generate.click()
        XCTAssertTrue(app.buttons["acceptEvidenceDisclosure"].waitForExistence(timeout: 5))
        app.buttons["acceptEvidenceDisclosure"].click()

        let status = app.staticTexts["evidenceInsightStatus"]
        XCTAssertEqual(waitForValue(of: status, expected: "已完成 · 1 次请求", timeout: 12), .completed,
                       "scalar research_question 只能降级为未锚定信息，不能使已锚定公式推导整轮失败")
        XCTAssertTrue(app.staticTexts["已验证公式推导（paper-insight-v2）"].waitForExistence(timeout: 5),
                      "完成后必须显示已验证的 v2 artifact，而不是仅停留在状态栏")
        XCTAssertTrue(app.staticTexts["原文公式（直接支持）"].waitForExistence(timeout: 5),
                      "已锚定的公式卡片必须仍然在真实 Evidence UI 中可见")
        #endif
    }

    func testFixtureCompareCreatesExtractsAndJumpsToExactSharedPDFAnchor() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp(initialWorkbenchTab: "compare")
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let firstPaper = selectFixturePaper(in: app)
        firstPaper.click()
        app.radioButtons["证据"].click()
        app.buttons["downloadFullText-fixture-fulltext"].click()
        XCTAssertTrue(app.buttons["confirmFullTextDownload"].waitForExistence(timeout: 5))
        app.buttons["confirmFullTextDownload"].click()
        XCTAssertEqual(waitForValue(of: app.staticTexts["fullTextStatus"], expected: "全文已提取为页级 evidence anchors。", timeout: 8), .completed)

        let secondPaper = app.staticTexts["paperRow-1234568"].firstMatch
        XCTAssertTrue(secondPaper.waitForExistence(timeout: 5))
        secondPaper.click()
        XCTAssertTrue(app.radioButtons["证据"].waitForExistence(timeout: 5))
        app.radioButtons["证据"].click()
        let secondDownload = app.buttons["downloadFullText-fixture-fulltext-1234568"]
        XCTAssertTrue(secondDownload.waitForExistence(timeout: 5),
                      "第二篇 fixture paper 必须显式提供同一 content-addressed PDF 的本地下载动作")
        secondDownload.click()
        XCTAssertTrue(app.buttons["confirmFullTextDownload"].waitForExistence(timeout: 5))
        app.buttons["confirmFullTextDownload"].click()
        XCTAssertEqual(waitForValue(of: app.staticTexts["fullTextStatus"], expected: "全文已提取为页级 evidence anchors。", timeout: 8), .completed)

        app.buttons["workbenchButton"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Fixture lattice observable"].waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Fixture lattice renormalization"].waitForExistence(timeout: 5))
        let firstToggle = sheet.buttons["toggleComparePaper-1234567"]
        let secondToggle = sheet.buttons["toggleComparePaper-1234568"]
        XCTAssertTrue(firstToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(secondToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(firstToggle.value as? String, "unselected")
        XCTAssertEqual(secondToggle.value as? String, "unselected")
        let create = sheet.buttons["createCompareWorkspace"]
        XCTAssertTrue(create.waitForExistence(timeout: 5),
                      "Compare 工作台必须提供受控的 workspace 创建动作")
        XCTAssertFalse(create.isEnabled,
                       "未选择至少两篇论文时不得创建 Compare workspace；2–6 的上界由本地 contract tests 覆盖")
        firstToggle.click()
        secondToggle.click()
        XCTAssertEqual(firstToggle.value as? String, "selected")
        XCTAssertEqual(secondToggle.value as? String, "selected")
        XCTAssertTrue(create.isEnabled)
        create.click()
        let extract = sheet.buttons["extractLocalCompare"]
        XCTAssertTrue(extract.waitForExistence(timeout: 8),
                      "创建的 workspace 必须暴露 deterministic local extractor")
        extract.click()
        XCTAssertEqual(waitForValue(of: sheet.staticTexts["compareExtractionStatus"],
                                    expected: "已从本地 evidence anchors 提取 26 个 Compare cells。", timeout: 8), .completed)
        let spacingCell = sheet.buttons["physicsCell-lattice_spacing-1234568"]
        XCTAssertTrue(spacingCell.waitForExistence(timeout: 8))
        XCTAssertTrue(spacingCell.label.contains("0.09 fm") && spacingCell.label.contains("direct"),
                      "matrix 必须向用户显示同 paper PDF anchor 证明的 0.09 fm direct cell")
        app.activate()
        spacingCell.click()
        XCTAssertTrue(app.staticTexts["physicsCellInspectorSelection"].waitForExistence(timeout: 5),
                      "点击 direct matrix cell 必须选择该 cell 并打开 evidence inspector")
        // The anchor button is the actionable evidence chip. Its appearance
        // proves that the inspector opened without coupling the test to a
        // sheet/root accessibility container.
        let anchor = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "physicsCellAnchor-1234568-lattice_spacing-"
        )).firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 5), "direct cell 必须暴露可回查的具体 anchor")
        app.activate()
        anchor.click()
        XCTAssertTrue(app.staticTexts["pdfAnchorPreviewPageTitle-1"].waitForExistence(timeout: 8),
                      "Compare anchor 跳转必须打开第二篇论文的本地 PDF 第 1 页，而不是只切换 paper metadata")
        #endif
    }

    func testFixtureModelDiscoveryUsesInProcessSubstitute() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        // Resolve the action beneath the presented Settings sheet rather
        // than re-querying the complete application tree between the
        // existence check and click.  AppKit may briefly rebuild toolbar
        // descendants while a sheet gains focus, even though the sheet's
        // own controls are already stable.
        let settingsSheet = app.sheets.firstMatch
        XCTAssertTrue(settingsSheet.waitForExistence(timeout: 5))
        let discover = settingsSheet.descendants(matching: .any)["discoverModels"].firstMatch
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        XCTAssertEqual(waitForHittability(of: discover, expected: true, timeout: 5), .completed)
        discover.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "发现 1 个模型")).firstMatch.waitForExistence(timeout: 5))
        #endif
    }

    func testFixtureGlobalSearchAndSmartFilterAreAccessibleControls() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("XCUIApplication 测试仅通过 LatticeLens.xcodeproj 的 UI-test target 运行。")
        #else
        let app = launchFixtureApp()
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8))
        _ = selectFixturePaper(in: app)
        XCTAssertTrue(app.textFields["globalPaperSearch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["paperFilter"].waitForExistence(timeout: 5),
                      "Papers / Updates / Favorites / Needs Review filter 必须有稳定可访问入口")
        #endif
    }

    private func selectFixturePaper(in app: XCUIApplication) -> XCUIElement {
        let buildIndex = app.links["buildAuthorIndex"]
        XCTAssertTrue(buildIndex.waitForExistence(timeout: 8))
        buildIndex.tap()
        let zed = app.staticTexts["authorRow-77"].firstMatch
        XCTAssertTrue(zed.waitForExistence(timeout: 8))
        zed.click()
        let paper = app.staticTexts["paperRow-1234567"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 8))
        return paper
    }

    private func fixtureModeIndicator(in app: XCUIApplication) -> XCUIElement {
        // Toolbar statuses are deliberately exposed as standalone generic AX
        // elements.  Querying the complete descendant tree avoids assuming
        // AppKit will bridge a SwiftUI status `Text` as a StaticText.
        app.descendants(matching: .any)["fixtureModeIndicator"].firstMatch
    }

    private func largeFixtureModeIndicator(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["largeFixtureModeIndicator"].firstMatch
    }

    private func assertLargeFixtureReady(in app: XCUIApplication) {
        XCTAssertTrue(fixtureModeIndicator(in: app).waitForExistence(timeout: 8),
                      "large UI case 必须先确认隔离的 fixture dependency graph")
        XCTAssertTrue(largeFixtureModeIndicator(in: app).waitForExistence(timeout: 12),
                      "large UI case 必须等待所有 process-local rows 及首个本地 projection 完成")
    }

    private func selectWorkbenchTab(_ title: String, in sheet: XCUIElement) {
        let radio = sheet.radioButtons[title]
        if radio.waitForExistence(timeout: 3) {
            radio.click()
        } else {
            let button = sheet.buttons[title]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.click()
        }
    }

    private func waitForInsightStatus(_ expected: String, in app: XCUIApplication, timeout: TimeInterval) -> XCTWaiter.Result {
        let status = app.staticTexts["insightStatus"]
        guard status.waitForExistence(timeout: timeout) else { return .timedOut }
        let predicate = NSPredicate(format: "value == %@", expected)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: status)], timeout: timeout)
    }

    private func waitForExistence(of element: XCUIElement, expected: Bool, timeout: TimeInterval) -> XCTWaiter.Result {
        let predicate = NSPredicate(format: "exists == %@", NSNumber(value: expected))
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
    }

    private func waitForValue(of element: XCUIElement, expected: String, timeout: TimeInterval) -> XCTWaiter.Result {
        let predicate = NSPredicate(format: "value == %@", expected)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
    }

    private func waitForHittability(of element: XCUIElement, expected: Bool, timeout: TimeInterval) -> XCTWaiter.Result {
        let predicate = NSPredicate(format: "isHittable == %@", NSNumber(value: expected))
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
    }
}
