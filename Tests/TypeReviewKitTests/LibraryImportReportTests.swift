import XCTest

@testable import TypeReviewKit

/// The Library's status line, which is where cleaning reports what it removed.
final class LibraryImportReportTests: XCTestCase {
    func testABatchWithAFailureStillSaysWhatWasAddedAndWhatCleaningRemoved() {
        let status = LibraryImportReport.batchStatus(
            added: 2, truncated: false, dropped: 3,
            failures: ["b.txt: no typeable text left after cleaning"], libraryCount: 5)
        XCTAssertEqual(
            status,
            "added 2 (3 unusable characters removed) · 5 in library · b.txt: no typeable text left after cleaning")
    }

    func testABatchThatOnlyFailedNamesEachFailure() {
        let status = LibraryImportReport.batchStatus(
            added: 0, truncated: false, dropped: 0,
            failures: ["a.txt: not readable as UTF-8", "library is full (200)"], libraryCount: 200)
        XCTAssertEqual(status, "a.txt: not readable as UTF-8 · library is full (200)")
    }

    func testABatchThatDidNothingSaysNothing() {
        XCTAssertNil(
            LibraryImportReport.batchStatus(
                added: 0, truncated: true, dropped: 4, failures: [], libraryCount: 0))
    }

    func testTheNoteNamesTheCapSanitizeEnforces() {
        XCTAssertEqual(LibraryImportReport.cleaningNote(truncated: false, dropped: 0), "")
        XCTAssertEqual(
            LibraryImportReport.cleaningNote(truncated: true, dropped: 1),
            " (truncated to the \(maxPassageChars)-character cap, 1 unusable characters removed)")
    }
}
