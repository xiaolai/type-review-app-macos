import Foundation
import XCTest

/// Thrown when a golden vector cannot be found or read.
///
/// A thrown error, not `XCTSkip`. The vectors are committed, so a missing one
/// is a broken checkout or a deleted file — never a legitimate configuration.
/// Skipping made that state green, which is the failure mode these tests exist
/// to prevent: a suite that passes because it did not run the part that
/// matters. A skipped conformance test and a passing one look identical in
/// aggregate output.
struct VectorUnavailable: LocalizedError {
    let reason: String
    var errorDescription: String? {
        "\(reason) — see ARCHITECTURE.md — Regenerating a vector"
    }
}

/// That every vector in the bundle is actually read by something.
///
/// `Package.swift` copies the whole `Vectors/` directory, so a file added
/// there ships whether or not a test names it. The names are hand-written at a
/// dozen call sites, which means the failure is silent in the worst direction:
/// an unread vector is bytes on disk that look exactly like coverage, and the
/// suite goes green having never opened it.
///
/// The list below is the declared contract. Both directions fail — a file with
/// no reader, and a reader whose file is gone — so neither can drift quietly.
final class VectorCoverageTests: XCTestCase {
    /// Every vector this suite reads. Add a file to `Vectors/`, add it here,
    /// and assert against it somewhere — in that order.
    private static let consumed: Set<String> = [
        "aggregations", "aggregations-dst", "corpus", "deserialize", "generators",
        "histogram", "library", "math", "metrics", "planner", "planner-synthetic",
        "profile", "rng", "settings-schema",
    ]

    func testEveryBundledVectorIsRead() throws {
        let urls =
            Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Vectors") ?? []
        let onDisk = Set(urls.map { $0.deletingPathExtension().lastPathComponent })
        // First, because an empty bundle would otherwise report as fourteen
        // missing files and read like fourteen problems instead of one.
        XCTAssertFalse(
            onDisk.isEmpty,
            "no vectors found in the test bundle — check the resources rule in Package.swift")
        XCTAssertEqual(
            onDisk.subtracting(Self.consumed), [],
            "bundled but never read — add a test, or delete the file")
        XCTAssertEqual(
            Self.consumed.subtracting(onDisk), [],
            "listed as read but not in the bundle")
    }

    /// That no vector holds an invisible or combining character raw.
    ///
    /// Written raw, a combining accent is one editor's Unicode normalisation away
    /// from being a different string: the corpus case proving that a decomposed
    /// `cafe\u0301` folds like the composed `caf\u00e9` would quietly become the
    /// composed one, and keep passing, having stopped testing anything. `JSON.stringify` writes
    /// these characters raw. That is how three reached `histogram.json`, and how
    /// regenerating `corpus.json` once wrote eight more. As `\u0301` the file is
    /// plain ASCII at that point, and nothing rewrites it.
    func testNoVectorHoldsAnInvisibleOrCombiningCharacterRaw() throws {
        let urls =
            Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Vectors") ?? []
        XCTAssertFalse(urls.isEmpty, "no vectors found in the test bundle")
        let invisible: Set<Unicode.GeneralCategory> = [
            .nonspacingMark, .spacingMark, .enclosingMark, .spaceSeparator, .lineSeparator,
            .paragraphSeparator, .format, .control,
        ]
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            let raw = text.unicodeScalars.filter {
                $0.value > 0x7E && invisible.contains($0.properties.generalCategory)
            }
            XCTAssertEqual(
                raw.map { String(format: "U+%04X", $0.value) }, [],
                "\(url.lastPathComponent) holds these raw; write each as a \\u escape")
        }
    }
}
