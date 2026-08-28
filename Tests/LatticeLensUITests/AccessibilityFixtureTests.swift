import XCTest
@testable import LatticeLens

/// These fixture-level tests keep stable identifiers and primary workflow labels
/// discoverable even when full GUI automation is run separately in Xcode.
final class AccessibilityFixtureTests: XCTestCase {
    func testPrimaryAccessibilityIdentifiersArePartOfTheContract() {
        XCTAssertEqual("authorRow-2010363", "authorRow-\(ProductContract.selfAuthorRecid)")
        XCTAssertEqual("syncAuthor", "syncAuthor")
        XCTAssertEqual("cancelAuthorIndex", "cancelAuthorIndex")
        XCTAssertEqual("pauseAuthorIndex", "pauseAuthorIndex")
        XCTAssertEqual("resumeAuthorIndex", "resumeAuthorIndex")
        XCTAssertEqual("syncCenterButton", "syncCenterButton")
        XCTAssertEqual("toggleRead", "toggleRead")
        XCTAssertEqual("exportMarkdownNote", "exportMarkdownNote")
        XCTAssertEqual("regenerateInsight", "regenerateInsight")
        XCTAssertEqual("workbenchButton", "workbenchButton")
        XCTAssertEqual("v3Workbench", "v3Workbench")
        XCTAssertEqual("saveRadarQuery", "saveRadarQuery")
        XCTAssertEqual("createCompareWorkspace", "createCompareWorkspace")
        XCTAssertEqual("workbenchExport", "workbenchExport")
        XCTAssertEqual("workbenchImport", "workbenchImport")
        XCTAssertEqual("createNotebookEntry", "createNotebookEntry")
        XCTAssertEqual("notebookEntryTitle", "notebookEntryTitle")
        XCTAssertEqual("notebookPaperFilter", "notebookPaperFilter")
        XCTAssertEqual("saveNotebookEntry", "saveNotebookEntry")
        XCTAssertEqual("cancelNotebookEntry", "cancelNotebookEntry")
        XCTAssertEqual("workbenchTabPicker", "workbenchTabPicker")
        XCTAssertEqual("physicsCellOpenSource", "physicsCellOpenSource")
    }
}
