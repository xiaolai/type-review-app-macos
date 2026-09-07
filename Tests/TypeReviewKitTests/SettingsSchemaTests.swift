import XCTest

@testable import TypeReviewKit

/// The settings surface against the website's.
///
/// Everything else in this suite checks behaviour; this checks *agreement*.
/// The two implementations describe the same settings from separate
/// repositories, so nothing but a test stops one of them quietly offering a
/// range the other rejects.
final class SettingsSchemaTests: XCTestCase {
    struct Vector: Decodable {
        struct Bound: Decodable {
            let lo: Double
            let hi: Double
            let integer: Bool
        }
        struct Bounds: Decodable {
            let targetWpm: Bound
            let wordCount: Bound
            let testDurationSec: Bound
            let minAlphabetSize: Bound
            let alphabetExpansion: Bound
        }
        struct Defaults: Decodable {
            let mode: String
            let targetWpm: Double
            let wordCount: Double
            let testMode: String
            let testDurationSec: Double
            let stopOnError: Bool
            let noBackspace: Bool
            let passageLength: String
            let includeNumbers: Bool
            let includePunctuation: Bool
            let adaptive: Adaptive
            struct Adaptive: Decodable {
                let minAlphabetSize: Double
                let alphabetExpansion: Double
            }
        }
        struct Domains: Decodable {
            let mode: [String]
            let testMode: [String]
            let passageLength: [String]
        }
        struct Presets: Decodable {
            let wordCount: [Double]
            let testDurationSec: [Double]
        }
        let defaults: Defaults
        let uiBounds: Bounds
        let engineBounds: Bounds
        let domains: Domains
        let presets: Presets
    }

    private func vector() throws -> Vector {
        guard let url = Bundle.module.url(
            forResource: "Vectors/settings-schema", withExtension: "json")
        else { throw XCTSkip("Vectors/settings-schema.json missing — see ARCHITECTURE.md — Regenerating a vector") }
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    func testDefaultsMatchTheWebsite() throws {
        let expected = try vector().defaults
        let actual = ProfileSettings.default
        XCTAssertEqual(actual.mode.rawValue, expected.mode)
        XCTAssertEqual(actual.targetWpm, expected.targetWpm)
        XCTAssertEqual(actual.wordCount, expected.wordCount)
        XCTAssertEqual(actual.testMode.rawValue, expected.testMode)
        XCTAssertEqual(actual.testDurationSec, expected.testDurationSec)
        XCTAssertEqual(actual.stopOnError, expected.stopOnError)
        XCTAssertEqual(actual.noBackspace, expected.noBackspace)
        XCTAssertEqual(actual.passageLength.rawValue, expected.passageLength)
        XCTAssertEqual(actual.includeNumbers, expected.includeNumbers)
        XCTAssertEqual(actual.includePunctuation, expected.includePunctuation)
        XCTAssertEqual(actual.adaptive.minAlphabetSize, expected.adaptive.minAlphabetSize)
        XCTAssertEqual(actual.adaptive.alphabetExpansion, expected.adaptive.alphabetExpansion)
    }

    func testStorageBoundsMatchTheWebsite() throws {
        // These are what the validator enforces on the way in from disk, so a
        // divergence means a profile that loads on one side and not the other.
        let expected = try vector().engineBounds
        XCTAssertEqual(SettingsBounds.targetWpm.lo, expected.targetWpm.lo)
        XCTAssertEqual(SettingsBounds.targetWpm.hi, expected.targetWpm.hi)
        XCTAssertEqual(SettingsBounds.wordCount.lo, expected.wordCount.lo)
        XCTAssertEqual(SettingsBounds.wordCount.hi, expected.wordCount.hi)
        XCTAssertEqual(SettingsBounds.testDurationSec.lo, expected.testDurationSec.lo)
        XCTAssertEqual(SettingsBounds.testDurationSec.hi, expected.testDurationSec.hi)
        XCTAssertEqual(SettingsBounds.minAlphabetSize.hi, expected.minAlphabetSize.hi)
        XCTAssertEqual(SettingsBounds.alphabetExpansion.hi, expected.alphabetExpansion.hi)
    }

    func testControlRangesAndPresetsMatchTheWebsite() throws {
        let vector = try vector()
        XCTAssertEqual(SettingsSchema.UIBounds.targetWpm.lo, vector.uiBounds.targetWpm.lo)
        XCTAssertEqual(SettingsSchema.UIBounds.targetWpm.hi, vector.uiBounds.targetWpm.hi)
        XCTAssertEqual(SettingsSchema.UIBounds.wordCount.hi, vector.uiBounds.wordCount.hi)
        XCTAssertEqual(
            SettingsSchema.UIBounds.testDurationSec.hi, vector.uiBounds.testDurationSec.hi)
        XCTAssertEqual(SettingsSchema.wordCountPresets, vector.presets.wordCount)
        XCTAssertEqual(SettingsSchema.durationPresets, vector.presets.testDurationSec)
        XCTAssertEqual(SettingsSchema.modes.map(\.rawValue), vector.domains.mode)
        XCTAssertEqual(SettingsSchema.testModes.map(\.rawValue), vector.domains.testMode)
        XCTAssertEqual(
            SettingsSchema.passageLengths.map(\.rawValue), vector.domains.passageLength)
    }

    func testWhatAControlCanProduceIsAlwaysAcceptedByStorage() throws {
        // The invariant the two bound tables exist to hold: UI_BOUNDS is a
        // subset of SETTINGS_BOUNDS, so the Settings window can never emit a
        // value the profile validator would refuse.
        let ui = try vector().uiBounds
        let engine = try vector().engineBounds
        for (name, control, storage) in [
            ("targetWpm", ui.targetWpm, engine.targetWpm),
            ("wordCount", ui.wordCount, engine.wordCount),
            ("testDurationSec", ui.testDurationSec, engine.testDurationSec),
        ] {
            XCTAssertGreaterThanOrEqual(control.lo, storage.lo, "\(name) low end")
            XCTAssertLessThanOrEqual(control.hi, storage.hi, "\(name) high end")
        }
    }
}
