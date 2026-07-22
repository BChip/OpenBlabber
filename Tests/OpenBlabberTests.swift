import AVFoundation
import XCTest
@testable import OpenBlabber

final class OpenBlabberTests: XCTestCase {
    func testCommandEnvelopeRoundTripsWithoutLosingCorrelation() throws {
        let command = OBIPC.CommandEnvelope(
            sequence: 42,
            sessionToken: "session-token",
            requestID: "request-id",
            action: .start,
            createdAt: 1_000
        )

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(OBIPC.CommandEnvelope.self, from: data)

        XCTAssertEqual(decoded, command)
        XCTAssertEqual(decoded.version, OBIPC.protocolVersion)
    }

    func testCommandFreshnessRejectsReplayAndFutureTimestamp() {
        let fresh = OBIPC.CommandEnvelope(
            sequence: 1,
            sessionToken: "token",
            action: .ping,
            createdAt: 100
        )
        let stale = OBIPC.CommandEnvelope(
            sequence: 2,
            sessionToken: "token",
            action: .ping,
            createdAt: 90
        )
        let future = OBIPC.CommandEnvelope(
            sequence: 3,
            sessionToken: "token",
            action: .ping,
            createdAt: 102
        )

        XCTAssertTrue(fresh.isFresh(at: 104))
        XCTAssertFalse(stale.isFresh(at: 100))
        XCTAssertFalse(future.isFresh(at: 100))
    }

    func testShutdownCommandRoundTrips() throws {
        let command = OBIPC.CommandEnvelope(
            sequence: 9,
            sessionToken: "token",
            action: .shutdown,
            createdAt: 100
        )

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(OBIPC.CommandEnvelope.self, from: data)

        XCTAssertEqual(decoded.action, .shutdown)
        XCTAssertEqual(decoded, command)
    }

    func testKeyboardLifecycleUsesShortHeartbeatAndLongerReturnGrace() {
        XCTAssertEqual(OBIPC.recordingWatchdog, 3)
        XCTAssertEqual(OBIPC.keyboardPresenceGrace, 3)
        XCTAssertEqual(OBIPC.launchReturnGrace, 30)
    }

    func testForegroundAppRejectsKeyboardPresence() {
        XCTAssertFalse(
            DictationLifecyclePolicy.acceptsKeyboardPresence(appIsBackground: false)
        )
        XCTAssertTrue(
            DictationLifecyclePolicy.acceptsKeyboardPresence(appIsBackground: true)
        )
    }

    func testLifecycleDeadlineCannotExpireWhileAppIsForeground() {
        XCTAssertFalse(
            DictationLifecyclePolicy.shouldExpireResources(
                appIsBackground: false,
                ownsResources: true,
                deadlineUptime: 100,
                nowUptime: 101
            )
        )
        XCTAssertTrue(
            DictationLifecyclePolicy.shouldExpireResources(
                appIsBackground: true,
                ownsResources: true,
                deadlineUptime: 100,
                nowUptime: 101
            )
        )
    }

    func testPreparationStallWatchdogUsesMonotonicActivity() {
        XCTAssertFalse(
            DictationLifecyclePolicy.preparationHasStalled(
                lastActivityUptime: 100,
                nowUptime: 399
            )
        )
        XCTAssertTrue(
            DictationLifecyclePolicy.preparationHasStalled(
                lastActivityUptime: 100,
                nowUptime: 401
            )
        )
    }

    func testOnlyRecentForegroundLaunchRecoversFromShutdown() {
        XCTAssertTrue(
            DictationLifecyclePolicy.shouldRestartAfterShutdown(
                appIsBackground: false,
                recoveryDeadlineUptime: 106,
                nowUptime: 105
            )
        )
        XCTAssertFalse(
            DictationLifecyclePolicy.shouldRestartAfterShutdown(
                appIsBackground: true,
                recoveryDeadlineUptime: 106,
                nowUptime: 105
            )
        )
        XCTAssertFalse(
            DictationLifecyclePolicy.shouldRestartAfterShutdown(
                appIsBackground: false,
                recoveryDeadlineUptime: 104,
                nowUptime: 105
            )
        )
    }

    func testAutomaticInsertionRequiresEveryContextSignal() {
        XCTAssertTrue(
            OBIPC.mayAutomaticallyInsert(
                resultRequestID: "same",
                activeRequestID: "same",
                keyboardIsVisible: true,
                sameViewGeneration: true,
                sameDocument: true,
                sameTextRevision: true,
                sameCaret: true
            )
        )
        XCTAssertFalse(
            OBIPC.mayAutomaticallyInsert(
                resultRequestID: "same",
                activeRequestID: "same",
                keyboardIsVisible: true,
                sameViewGeneration: true,
                sameDocument: false,
                sameTextRevision: true,
                sameCaret: true
            )
        )
        XCTAssertFalse(
            OBIPC.mayAutomaticallyInsert(
                resultRequestID: "old",
                activeRequestID: "new",
                keyboardIsVisible: true,
                sameViewGeneration: true,
                sameDocument: true,
                sameTextRevision: true,
                sameCaret: true
            )
        )
        XCTAssertFalse(
            OBIPC.mayAutomaticallyInsert(
                resultRequestID: "same",
                activeRequestID: "same",
                keyboardIsVisible: false,
                sameViewGeneration: true,
                sameDocument: true,
                sameTextRevision: true,
                sameCaret: true
            )
        )
        XCTAssertFalse(
            OBIPC.mayAutomaticallyInsert(
                resultRequestID: "same",
                activeRequestID: "same",
                keyboardIsVisible: true,
                sameViewGeneration: true,
                sameDocument: true,
                sameTextRevision: false,
                sameCaret: true
            )
        )
        XCTAssertFalse(
            OBIPC.mayAutomaticallyInsert(
                resultRequestID: "same",
                activeRequestID: "same",
                keyboardIsVisible: true,
                sameViewGeneration: true,
                sameDocument: true,
                sameTextRevision: true,
                sameCaret: false
            )
        )
    }

    func testResultIsUsableOnlyBeforeItsTTL() {
        let result = OBIPC.ResultEnvelope(
            engineEpoch: "epoch",
            sessionToken: "token",
            requestID: "request",
            text: "private transcript",
            createdAt: 100,
            expiresAt: 200
        )

        XCTAssertTrue(result.isLive(at: 199.999))
        XCTAssertFalse(result.isLive(at: 200))
        XCTAssertFalse(result.isLive(at: 201))
    }

    func testHandledResultReceiptExpires() {
        let receipt = OBIPC.HandledResultReceipt(
            requestID: "request",
            ownerToken: "keyboard-instance",
            disposition: .inserted,
            expiresAt: 200
        )
        XCTAssertTrue(receipt.isLive(at: 199.999))
        XCTAssertFalse(receipt.isLive(at: 200))
    }

    func testLeaseFreshnessUsesMonotonicUptime() {
        let lease = OBIPC.LeaseEnvelope(
            sessionToken: "session",
            requestID: "request",
            kind: .recording,
            uptime: 100
        )
        XCTAssertTrue(lease.isFresh(maximumAge: 3, nowUptime: 102.9))
        XCTAssertFalse(lease.isFresh(maximumAge: 3, nowUptime: 103.1))
        XCTAssertFalse(lease.isFresh(maximumAge: 3, nowUptime: 98))
    }

    func testLiveFeedbackIsBoundedForTheKeyboard() {
        let snapshot = OBIPC.EngineSnapshot(
            engineEpoch: "epoch",
            sessionToken: "token",
            acknowledgedSequence: 0,
            state: .recording,
            partialText: String(repeating: "a", count: 400),
            inputLevel: 2
        )

        XCTAssertEqual(snapshot.partialText?.count, OBIPC.maximumPartialCharacters)
        XCTAssertEqual(snapshot.inputLevel, 1)
    }

    func testStreamingMeterDoesNotAcceptAudioOutsideExplicitRecording() {
        let meter = StreamingAudioMeter(sampleRate: 10, maximumDuration: 1)
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 10,
            channels: 1
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4

        XCTAssertFalse(meter.isCapturing)
        XCTAssertFalse(meter.append(buffer))
        meter.begin()
        XCTAssertTrue(meter.isCapturing)
        XCTAssertTrue(meter.append(buffer))
        meter.cancel()
        XCTAssertFalse(meter.isCapturing)
        XCTAssertFalse(meter.append(buffer))
        XCTAssertEqual(meter.duration, 0)
    }

    func testStreamingMeterRejectsChunkThatWouldCrossDurationLimit() {
        let meter = StreamingAudioMeter(sampleRate: 10, maximumDuration: 1)
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 10,
            channels: 1
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6)!
        buffer.frameLength = 6

        meter.begin()
        XCTAssertTrue(meter.append(buffer))
        XCTAssertFalse(meter.append(buffer))
        XCTAssertTrue(meter.isFull)
        XCTAssertFalse(meter.isCapturing)
    }
}
