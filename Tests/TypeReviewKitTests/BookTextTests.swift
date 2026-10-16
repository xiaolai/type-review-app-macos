import XCTest

@testable import TypeReviewKit

/// The shared pipeline every book format goes through: blocks in, typeable
/// units out.
final class BookTextTests: XCTestCase {
    /// The invariant every unit must hold, whatever the input.
    private func assertTypeable(_ split: SentenceSplit, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(split.truncatedPieces, 0, "sanitize truncated a piece", file: file, line: line)
        for sentence in split.sentences {
            XCTAssertFalse(sentence.isEmpty, "an empty unit", file: file, line: line)
            XCTAssertLessThanOrEqual(
                sentence.utf16.count, maxBookSentenceChars, "over the cap: \(sentence.prefix(40))",
                file: file, line: line)
            XCTAssertTrue(
                sentence.unicodeScalars.allSatisfy { $0.isASCII }, "not ASCII: \(sentence)", file: file,
                line: line)
            XCTAssertTrue(
                sentence.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) },
                "nothing to type: \(sentence)", file: file, line: line)
        }
    }

    func testAParagraphSplitsIntoItsSentences() {
        let split = splitIntoSentences([
            .paragraph("Dorothy lived in the midst of the great Kansas prairies. Her house was small.")
        ])
        XCTAssertEqual(
            split.sentences,
            ["Dorothy lived in the midst of the great Kansas prairies.", "Her house was small."])
        assertTypeable(split)
    }

    func testHeadingsAndSceneBreaksAreNeverTyped() {
        let split = splitIntoSentences([
            .heading("Chapter I. The Cyclone"), .paragraph("The wind blew."), .sceneBreak,
            .paragraph("Then it stopped."),
        ])
        XCTAssertEqual(split.sentences, ["The wind blew.", "Then it stopped."])
    }

    func testVerseKeepsEachLineAsAUnit() {
        let split = splitIntoSentences([
            BookBlock(kind: .verse, lines: ["Twinkle, twinkle, little bat!", "How I wonder what you're at!"])
        ])
        XCTAssertEqual(split.sentences, ["Twinkle, twinkle, little bat!", "How I wonder what you're at!"])
    }

    func testSoftHyphensAreRemovedAndNotCountedAsLost() {
        let split = splitIntoSentences([.paragraph("Extra\u{00AD}ordinary\u{200B} things hap\u{00AD}pened.")])
        XCTAssertEqual(split.sentences, ["Extraordinary things happened."])
        XCTAssertEqual(split.droppedChars, 0, "an invisible character is not a lost one")
        XCTAssertEqual(split.invisibleRemoved, 3)
    }

    func testCurlyQuotesAndDashesFoldToTheKeysThatTypeThem() {
        let split = splitIntoSentences([.paragraph("\u{201C}Don\u{2019}t go\u{2014}please.\u{201D}")])
        XCTAssertEqual(split.sentences, ["\"Don't go-please.\""])
    }

    func testALowerCasePieceJoinsTheQuotationBeforeIt() {
        let split = splitIntoSentences([.paragraph("\u{201C}Is it far?\u{201D} asked Dorothy.")])
        XCTAssertEqual(split.sentences, ["\"Is it far?\" asked Dorothy."])
    }

    func testADialogueTagJoinsItsQuotation() {
        // NLTokenizer ends a sentence after `?"`, and the tag starts with a
        // capital, so only the speech verb tells it apart from a sentence.
        let split = splitIntoSentences([.paragraph("\u{201C}Owen?\u{201D} I say. Nobody answers.")])
        XCTAssertEqual(split.sentences, ["\"Owen?\" I say.", "Nobody answers."])
    }

    func testATitleAtTheEndOfAPieceRunsOn() {
        XCTAssertEqual(mergeSentencePieces(["It was Mr.", "Dursley again."]), ["It was Mr. Dursley again."])
    }

    func testAnOpenQuotationJoinsTheNextPieceWhileItFits() {
        XCTAssertEqual(
            mergeSentencePieces(["\u{201C}They don\u{2019}t know.", "I\u{2019}m going to have fun.\u{201D}"]),
            ["\u{201C}They don\u{2019}t know. I\u{2019}m going to have fun.\u{201D}"])
        // Not when the result would not fit in one unit.
        let long = String(repeating: "word ", count: 70)
        XCTAssertEqual(mergeSentencePieces(["\u{201C}" + long, "More."]).count, 2)
    }

    func testALongSentenceSplitsAtItsStrongestBreak() {
        let clause = String(repeating: "the wind howled over the prairie ", count: 5)
        let sentence = clause + "; " + clause + ", and " + clause + "."
        let pieces = splitLongSentence(sentence.trimmingCharacters(in: .whitespaces))
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces[0].hasSuffix(";"), "the semicolon is the strongest break: \(pieces[0])")
        for piece in pieces { XCTAssertLessThanOrEqual(piece.utf16.count, maxBookSentenceChars) }
        XCTAssertEqual(
            pieces.joined(separator: " ").replacingOccurrences(of: "  ", with: " "),
            sentence.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " "),
            "splitting loses nothing")
    }

    func testTextWithNoSpacesIsCutHard() {
        let pieces = splitLongSentence(String(repeating: "a", count: 1_000))
        XCTAssertEqual(pieces.joined(), String(repeating: "a", count: 1_000))
        for piece in pieces { XCTAssertLessThanOrEqual(piece.utf16.count, maxBookSentenceChars) }
    }

    func testAParagraphFarOverTheSanitizeCapLosesNothing() {
        // No sentence end in 30,000 characters: sanitize would cut this at
        // 5,000 and throw the rest away.
        let paragraph = String(repeating: "and then the river ran on ", count: 1_200)
        let split = splitIntoSentences([.paragraph(paragraph)])
        assertTypeable(split)
        let typed = split.sentences.joined(separator: " ")
        XCTAssertEqual(
            typed.filter { $0 != " " }.count,
            paragraph.filter { $0 != " " }.count, "every letter survives")
    }

    func testAUnitWithOnlyPunctuationLeftIsDroppedAndCounted() {
        let split = splitIntoSentences([.paragraph("The end."), .paragraph("\u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}\u{3002}")])
        XCTAssertEqual(split.sentences, ["The end."])
        XCTAssertEqual(split.punctuationOnlyDropped, 1)
        XCTAssertGreaterThan(split.droppedChars, 0)
    }

    func testACutNeverLeavesAUnitOfOnlyPunctuation() {
        let line = String(repeating: "a", count: 299) + String(repeating: "!", count: 20)
        let split = splitIntoSentences([BookBlock(kind: .verse, lines: [line])])
        XCTAssertFalse(split.sentences.isEmpty)
        for sentence in split.sentences {
            XCTAssertTrue(sentence.contains { $0.isLetter || $0.isNumber }, sentence)
        }
    }

    func testALineInAnotherScriptIsCountedAsLeftOut() {
        let split = splitIntoSentences([.paragraph("\u{4F60}\u{597D}")])
        XCTAssertEqual(split.sentences, [])
        XCTAssertEqual(split.punctuationOnlyDropped, 1)
    }

    func testLowerCasePiecesMergeIntoOneUnit() {
        XCTAssertEqual(
            mergeSentencePieces(["it began", "and went on", "and on."]), ["it began and went on and on."])
    }

    func testTextThatGrowsWhenCleanedIsNeverCut() {
        // "€" folds to "EUR": 3,949 units become 7,899, past sanitize's
        // 5,000-character cap, though they are under cutForCleaning's 4,000.
        let paragraph = Array(repeating: "\u{20AC}\u{20AC}\u{20AC}x", count: 790).joined(separator: " ")
        XCTAssertLessThan(paragraph.utf16.count, 4_000)
        XCTAssertTrue(sanitize(paragraph).truncated, "the case this guards against")
        let split = splitIntoSentences([.paragraph(paragraph)])
        XCTAssertEqual(split.truncatedPieces, 0)
        assertTypeable(split)
        XCTAssertEqual(
            split.sentences.joined(separator: " ").components(separatedBy: "EUREUREURx").count - 1, 790,
            "every group survives")
    }

    func testAnOrnamentIsDroppedWithoutCountingAsLost() {
        let split = splitIntoSentences([
            .paragraph("The end."), .paragraph("*      *      *      *"), .paragraph("...\""),
        ])
        XCTAssertEqual(split.sentences, ["The end."])
        XCTAssertEqual(split.punctuationOnlyDropped, 0, "no letters were there to lose")
        XCTAssertEqual(split.droppedChars, 0)
    }

    func testTheSameInputAlwaysGivesTheSameSplit() {
        let blocks: [BookBlock] = [
            .paragraph("\u{201C}Where are we?\u{201D} Sam asked. It was late; the moon was up. Mr. Brown slept."),
            .paragraph(String(repeating: "On and on it went, ", count: 40) + "until morning."),
        ]
        let first = splitIntoSentences(blocks)
        for _ in 0..<5 { XCTAssertEqual(splitIntoSentences(blocks), first) }
        assertTypeable(first)
    }

    func testStrippingInvisibleFormattingCounts() {
        let (text, removed) = stripInvisibleFormatting("a\u{FEFF}b\u{200D}c\u{2060}")
        XCTAssertEqual(text, "abc")
        XCTAssertEqual(removed, 3)
    }
}

/// The per-file repairs, each found on real books.
final class BookRepairTests: XCTestCase {
    func testMojibakeIsRepairedOneRunAtATime() {
        // A genuine curly quote beside broken ones: a whole-paragraph round
        // trip would fail on it.
        XCTAssertEqual(repairMojibake("Henryâ€™s daughter \u{2019}"), "Henry\u{2019}s daughter \u{2019}")
        XCTAssertEqual(repairMojibake("cafÃ©"), "caf\u{00E9}")
        XCTAssertNil(repairMojibake("plain text"))
    }

    func testAnOrphanMojibakeQuoteIsAClosingQuote() {
        XCTAssertEqual(repairMojibake("â€œYesâ€ he said"), "\u{201C}Yes\u{201D} he said")
    }

    func testAPrintedLinePerParagraphIsJoined() {
        let lines = [
            "Mr. and Mrs. Dursley, of number four, Privet Drive,", "were proud to say that they were perfectly",
            "normal, thank you very much. They were the last", "people you'd expect to be involved in anything",
            "strange or mysterious, because they just didn't", "hold with such nonsense.",
            "Mr. Dursley was the director of a firm called", "Grunnings, which made drills. He was a big,",
            "beefy man with hardly any neck, although he did", "have a very large mustache.",
        ]
        let (blocks, report) = repairBlocks(lines.map(BookBlock.paragraph))
        XCTAssertTrue(report.lineMode)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks[1].lines[0].hasPrefix("Mr. Dursley was the director of a firm called Grunnings"))
    }

    func testALowerCaseParagraphContinuesTheOneBefore() {
        let (blocks, _) = repairBlocks([.paragraph("It was a dark and"), .paragraph("stormy night.")])
        XCTAssertEqual(blocks, [.paragraph("It was a dark and stormy night.")])
    }

    func testAWordBrokenAcrossLinesKeepsItsHyphenAndLosesTheSpace() {
        let (blocks, _) = repairBlocks([.paragraph("a well-"), .paragraph("known story.")])
        XCTAssertEqual(blocks, [.paragraph("a well-known story.")])
    }

    func testATitleAtALineEndJoinsTheName() {
        let (blocks, _) = repairBlocks([.paragraph("It was a few seconds before Mr."), .paragraph("Dursley noticed.")])
        XCTAssertEqual(blocks, [.paragraph("It was a few seconds before Mr. Dursley noticed.")])
    }

    func testALabelParagraphBecomesAHeading() {
        let (blocks, report) = repairBlocks(
            [.paragraph("Chapter 1"), .paragraph("THE BOY WHO LIVED"), .paragraph("Mr. Dursley was proud.")])
        XCTAssertEqual(blocks.prefix(2).map(\.kind), [.heading, .heading])
        XCTAssertEqual(report.labelsMadeHeadings, 2)
        XCTAssertEqual(splitIntoSentences(blocks).sentences, ["Mr. Dursley was proud."])
    }

    func testTheTableOfContentsNameForAFileIsItsTitle() {
        let (blocks, _) = repairBlocks([.paragraph("The Vanishing Glass"), .paragraph("Nearly ten years had passed.")], label: "The Vanishing Glass")
        XCTAssertEqual(blocks.first?.kind, .heading)
    }

    func testNumberOnlyParagraphsAreDropped() {
        let (blocks, report) = repairBlocks([.paragraph("It rained."), .paragraph("23"), .paragraph("[24]")])
        XCTAssertEqual(blocks, [.paragraph("It rained.")])
        XCTAssertEqual(report.numberParagraphsDropped, 2)
    }

    func testGutenbergMarkersInsideAFileAreCut() {
        let (blocks, report) = repairBlocks([
            .paragraph("The Project Gutenberg eBook of Peter Pan"),
            .paragraph("*** START OF THE PROJECT GUTENBERG EBOOK PETER PAN ***"),
            .paragraph("All children, except one, grow up."),
            .paragraph("*** END OF THE PROJECT GUTENBERG EBOOK PETER PAN ***"),
            .paragraph("Updated editions will replace the previous one."),
        ])
        XCTAssertEqual(blocks, [.paragraph("All children, except one, grow up.")])
        XCTAssertEqual(report.gutenbergCuts, 2)
    }

    func testMojibakeIsRepairedWhateverItsLeadByte() {
        XCTAssertEqual(repairMojibake("Å“uvre"), "\u{0153}uvre")
        XCTAssertEqual(repairMojibake("5 â‚¬"), "5 \u{20AC}")
    }

    func testProseAtTheTopOfAFileIsNotTakenForALabel() {
        for line in ["Part of me wanted to leave.", "HELP!", "Book one was the best."] {
            let (blocks, report) = repairBlocks([.paragraph(line), .paragraph("Then it rained.")])
            XCTAssertEqual(blocks.first?.kind, .paragraph, line)
            XCTAssertEqual(report.labelsMadeHeadings, 0, line)
        }
    }

    func testAPrintedLineThatContinuesIsNotALabel() {
        let (blocks, report) = repairBlocks([.paragraph("Book One Was the Best"), .paragraph("of all the summers.")])
        XCTAssertEqual(blocks, [.paragraph("Book One Was the Best of all the summers.")])
        XCTAssertEqual(report.labelsMadeHeadings, 0)
    }

    func testOnlyTheNextBlockCanContinueALabel() {
        let (blocks, _) = repairBlocks([
            .paragraph("THE TITLE"), .heading("Chapter 1"), .paragraph("once upon a time there was a fox."),
        ])
        XCTAssertEqual(blocks.first, .heading("THE TITLE"))
    }

    func testEveryGutenbergEndMarkerIsCut() {
        for marker in ["END OF PROJECT GUTENBERG'S THE BOAT", "End of the Project Gutenberg EBook of The Boat"] {
            let (blocks, _) = repairBlocks([.paragraph("The river ran fast."), .paragraph(marker), .paragraph("License.")])
            XCTAssertEqual(blocks, [.paragraph("The river ran fast.")], marker)
        }
    }

    func testAChapterNumberStaysALabelWhateverFollows() {
        let (blocks, _) = repairBlocks([.paragraph("Chapter 1"), .paragraph("once upon a time there was a fox.")])
        XCTAssertEqual(blocks, [.heading("Chapter 1"), .paragraph("once upon a time there was a fox.")])
    }

    func testALongRunOfFragmentsJoinsIntoOneParagraph() {
        let fragments = (0..<5_000).map { BookBlock.paragraph("word\($0)") }
        let (blocks, report) = repairBlocks([.paragraph("It began")] + fragments)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(report.joinedParagraphs, 5_000)
        XCTAssertTrue(blocks[0].lines[0].hasSuffix("word4998 word4999"))
    }

    func testOrdinaryProseIsLeftAlone() {
        let input: [BookBlock] = [
            .paragraph("Alice was beginning to get very tired."), .paragraph("So she was considering."),
        ]
        let (blocks, report) = repairBlocks(input)
        XCTAssertEqual(blocks, input)
        XCTAssertFalse(report.lineMode)
        XCTAssertEqual(report.joinedParagraphs, 0)
    }
}
