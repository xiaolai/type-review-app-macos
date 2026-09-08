import XCTest

@testable import TypeReviewKit

/// Whether a passage is prose, decided by where it came from rather than by
/// looking up its words.
///
/// The measurement that produced this rule is in the plan: `NSSpellChecker`
/// accepts `123` and `42nd`, and `DCSCopyTextDefinition` accepted a quarter of
/// a generated drill. Neither is a membership test, so the gate is provenance.
/// These assert the two facts that gate depends on — that a session says which
/// passage it is serving, and that the ids it reports really are prefixed the
/// way the rule assumes.
final class SpeechProvenanceTests: XCTestCase {
    // MARK: - The one API addition

    /// The app cannot apply a provenance gate to a passage it cannot name.
    func testTheSnapshotCarriesThePassageId() throws {
        var settings = ProfileSettings.default
        settings.mode = .adaptive
        let session = try Session(
            profile: Profile(settings: settings),
            now: { 1_700_000_000_000 },
            rng: Mulberry32(seed: 7))

        let snapshot = try session.snapshot()
        XCTAssertTrue(
            snapshot.passageId.hasPrefix("pseudo:"),
            "an adaptive run with no corpus source generates pseudo-words: \(snapshot.passageId)")
    }

    /// The picker reports what it chose, so the snapshot can be checked against
    /// the actual entry rather than against the shape of an id.
    private final class PickedID: @unchecked Sendable {
        var value: String?
    }

    /// Not "an id that looks like a quote" — *the* passage that was picked.
    ///
    /// A prefix assertion holds for a snapshot that returns any plausible id,
    /// and for one that keeps reporting the previous run's. Both would leave
    /// the provenance gate deciding about a passage nobody is typing, so the
    /// check is identity, and it is repeated after a second run.
    func testTheSnapshotNamesTheExactPassageThatWasPicked() throws {
        var settings = ProfileSettings.default
        settings.mode = .adaptive
        let picked = PickedID()
        let adapter = CorpusAdapter(channel: .quotes) { entry in picked.value = entry?.id }
        let session = try Session(
            profile: Profile(settings: settings),
            now: { 1_700_000_000_000 },
            rng: Mulberry32(seed: 7),
            adaptiveSource: { filter, wordCount, passageLength, rng in
                try adapter.adaptiveSource(
                    filter: filter, wordCount: wordCount, passageLength: passageLength, rng: &rng)
            })

        let first = try XCTUnwrap(picked.value)
        XCTAssertTrue(first.hasPrefix("q-"), "the quotes channel serves a quote: \(first)")
        XCTAssertEqual(try session.snapshot().passageId, first)

        // And it follows the run rather than being captured once.
        var seen: Set<String> = [first]
        for _ in 0..<8 {
            try session.start()
            let next = try XCTUnwrap(picked.value)
            XCTAssertEqual(try session.snapshot().passageId, next)
            seen.insert(next)
        }
        XCTAssertGreaterThan(
            seen.count, 1, "nine runs all reported the same passage id")
    }

    /// A benchmark run with no corpus source falls back to the plain-word
    /// generator, and that fallback has to be nameable too — it is the one the
    /// `auto` channel reaches when nothing in the corpus fits.
    func testAGeneratedBenchmarkIsNamedPlain() throws {
        var settings = ProfileSettings.default
        settings.mode = .benchmark
        let session = try Session(
            profile: Profile(settings: settings),
            now: { 1_700_000_000_000 },
            rng: Mulberry32(seed: 7))

        XCTAssertTrue(
            try session.snapshot().passageId.hasPrefix("plain:"),
            "a benchmark with no source generates plain words")
    }

    // MARK: - The prefixes the gate reads

    /// §5 left one question open: what a code passage's id looks like, so that
    /// `auto` serving a code snippet is excluded by the same test rather than
    /// by the channel alone. It is `code-`, and this is what keeps that true.
    func testEveryBundledCodePassageIdIsPrefixed() {
        XCTAssertFalse(BundledCorpus.code.entries.isEmpty, "no code entries to check")
        for entry in BundledCorpus.code.entries {
            XCTAssertTrue(
                entry.id.hasPrefix("code-"),
                "\(entry.id) would be read aloud as prose by the auto channel")
        }
    }

    func testEveryBundledQuoteIdIsPrefixed() {
        XCTAssertGreaterThan(BundledCorpus.quotes.entries.count, 100)
        for entry in BundledCorpus.quotes.entries {
            XCTAssertTrue(entry.id.hasPrefix("q-"), "\(entry.id) is not shaped like a quote id")
        }
    }

    // MARK: - The gate

    func testProseChannelsSpeakAndTheOthersDoNot() {
        XCTAssertTrue(passageMayBeSpoken(channel: .quotes, passageId: "q-twain-travel"))
        XCTAssertTrue(passageMayBeSpoken(channel: .user, passageId: "0F2C-…"))
        XCTAssertTrue(passageMayBeSpoken(channel: .auto, passageId: "q-twain-travel"))
        XCTAssertFalse(passageMayBeSpoken(channel: .code, passageId: "code-fizzbuzz-py"))
        XCTAssertFalse(passageMayBeSpoken(channel: .generated, passageId: "pseudo:aa bb"))
    }

    /// The two halves of the gate are independent, and both have to hold.
    ///
    /// Tested across every prose channel rather than only `auto`. `auto` asks
    /// the corpus first and generates when it cannot answer — an early alphabet
    /// cannot answer at all — but `quotes` and `user` fall back to the
    /// generator too, and a gate that only checked ids under `auto` would speak
    /// a drill in the other two.
    func testEveryProseChannelStillRefusesAGeneratedOrCodeId() {
        for channel in [CorpusChannel.quotes, .user, .auto] {
            XCTAssertFalse(
                passageMayBeSpoken(channel: channel, passageId: "pseudo:etaoin shrdlu"),
                "\(channel.rawValue) spoke a pseudo-word drill")
            XCTAssertFalse(
                passageMayBeSpoken(channel: channel, passageId: "plain:the be to of"),
                "\(channel.rawValue) spoke a plain-word drill")
            XCTAssertFalse(
                passageMayBeSpoken(channel: channel, passageId: "code-fizzbuzz-py"),
                "\(channel.rawValue) read a code snippet aloud")
            XCTAssertFalse(
                passageMayBeSpoken(channel: channel, passageId: ""),
                "\(channel.rawValue) spoke a passage it could not name")
        }
    }

    /// And the other half: a prose-shaped id does not rescue a refused channel.
    ///
    /// Without this, dropping the channel test entirely would still pass every
    /// other case here, because the ids those cases use are the refused ones.
    func testARefusedChannelStillRefusesAProseId() {
        for channel in [CorpusChannel.code, .generated] {
            XCTAssertFalse(
                passageMayBeSpoken(channel: channel, passageId: "q-twain-travel"),
                "\(channel.rawValue) spoke a quote")
            XCTAssertFalse(
                passageMayBeSpoken(channel: channel, passageId: "custom:1700000000000"),
                "\(channel.rawValue) spoke custom text")
        }
    }

    /// Inline custom text is the user's own prose, typed on purpose.
    func testCustomTextIsProse() {
        XCTAssertTrue(passageMayBeSpoken(channel: .auto, passageId: "custom:1700000000000"))
    }
}
