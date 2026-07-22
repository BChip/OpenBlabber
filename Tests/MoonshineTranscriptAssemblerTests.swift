import XCTest
@testable import OpenBlabber

final class MoonshineTranscriptAssemblerTests: XCTestCase {
    func testBundledEnglishModelPreparesAndUnloads() async throws {
        let modelDirectory = try XCTUnwrap(
            Bundle.main.url(
                forResource: "tiny-streaming-en",
                withExtension: nil
            )
        )
        let recognizer = MoonshineRecognizer()

        try await recognizer.prepare(modelDirectory: modelDirectory)
        XCTAssertTrue(recognizer.isPrepared)
        await recognizer.unload()
        XCTAssertFalse(recognizer.isPrepared)
    }

    func testRevisingLineReplacesPartialInsteadOfDuplicatingIt() {
        var transcript = MoonshineTranscriptAssembler()

        XCTAssertTrue(
            transcript.apply(lineID: 7, text: "hello wor", isComplete: false)
        )
        XCTAssertTrue(
            transcript.apply(lineID: 7, text: "hello world", isComplete: false)
        )

        XCTAssertEqual(transcript.text, "hello world")
    }

    func testLineCompletionWithoutTextChangeDoesNotRepublishPartial() {
        var transcript = MoonshineTranscriptAssembler()

        XCTAssertTrue(
            transcript.apply(lineID: 1, text: "fast blabbers", isComplete: false)
        )
        XCTAssertFalse(
            transcript.apply(lineID: 1, text: "fast blabbers", isComplete: true)
        )

        XCTAssertEqual(transcript.text, "fast blabbers")
    }

    func testLinesRemainInFirstSeenSpeechOrderWhenEarlierLineIsRevised() {
        var transcript = MoonshineTranscriptAssembler()

        transcript.apply(lineID: 42, text: "first phrase", isComplete: true)
        transcript.apply(lineID: 3, text: "second phrase", isComplete: false)
        transcript.apply(lineID: 42, text: "revised first phrase", isComplete: true)

        XCTAssertEqual(
            transcript.text,
            "revised first phrase second phrase"
        )
    }

    func testEmptyRevisionRemovesOnlyThatLinesVisibleText() {
        var transcript = MoonshineTranscriptAssembler()

        transcript.apply(lineID: 1, text: "discard me", isComplete: false)
        transcript.apply(lineID: 2, text: "keep me", isComplete: false)
        transcript.apply(lineID: 1, text: "   ", isComplete: false)

        XCTAssertEqual(transcript.text, "keep me")
    }

    func testResetRemovesEveryLine() {
        var transcript = MoonshineTranscriptAssembler()
        transcript.apply(lineID: 1, text: "private words", isComplete: false)

        transcript.reset()

        XCTAssertTrue(transcript.isEmpty)
        XCTAssertEqual(transcript.text, "")
    }
}
