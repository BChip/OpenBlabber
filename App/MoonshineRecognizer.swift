//
//  MoonshineRecognizer.swift
//  Open Blabber
//
//  App-only Moonshine Tiny Streaming integration. The keyboard extension must
//  never link this file or MoonshineVoice; it receives transcript text through
//  the existing App Group IPC instead.
//

@preconcurrency import AVFoundation
import Foundation
import MoonshineVoice

/// Incrementally assembles Moonshine's revisable transcript lines.
///
/// Moonshine can update a line several times before completing it. Keeping one
/// entry per stable `lineID` prevents duplicate words when partial hypotheses
/// are revised. The separate order array preserves spoken order even if IDs are
/// not contiguous.
struct MoonshineTranscriptAssembler: Sendable {
    private struct Entry: Sendable, Equatable {
        var text: String
        var isComplete: Bool
    }

    private var order: [UInt64] = []
    private var entries: [UInt64: Entry] = [:]

    var text: String {
        order.compactMap { entries[$0]?.text }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var isEmpty: Bool {
        text.isEmpty
    }

    /// Returns `true` only when the user-visible transcript changed.
    @discardableResult
    mutating func apply(lineID: UInt64, text: String, isComplete: Bool) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = entries[lineID]

        if previous == nil {
            order.append(lineID)
        }
        entries[lineID] = Entry(text: normalized, isComplete: isComplete)

        return previous?.text != normalized
    }

    mutating func reset() {
        order.removeAll(keepingCapacity: true)
        entries.removeAll(keepingCapacity: true)
    }
}

enum MoonshineRecognizerError: LocalizedError, Equatable, Sendable {
    case modelDirectoryMissing(String)
    case modelAlreadyPrepared
    case modelNotPrepared
    case sessionAlreadyActive
    case sessionNotActive
    case invalidAudioFormat
    case audioBacklogExceeded
    case moonshine(String)

    var errorDescription: String? {
        switch self {
        case .modelDirectoryMissing(let path):
            return "The bundled Moonshine model is missing at \(path)."
        case .modelAlreadyPrepared:
            return "A different Moonshine model is already prepared."
        case .modelNotPrepared:
            return "The Moonshine model is not prepared."
        case .sessionAlreadyActive:
            return "A Moonshine transcription session is already active."
        case .sessionNotActive:
            return "There is no active Moonshine transcription session."
        case .invalidAudioFormat:
            return "Moonshine requires 16 kHz mono Float32 PCM audio."
        case .audioBacklogExceeded:
            return "Transcription could not keep up with the microphone audio."
        case .moonshine(let message):
            return "Moonshine transcription failed: \(message)"
        }
    }
}

/// A fixed-capacity FIFO used to move PCM off the real-time audio callback.
///
/// Storage is allocated once. `append` only copies into the ring; Moonshine
/// inference and the temporary `[Float]` allocation used by its Swift API both
/// happen later on `MoonshineRecognizer.workerQueue`.
private struct BoundedPCMQueue {
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private(set) var queuedCount = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: max(1, capacity))
    }

    mutating func append(_ source: UnsafePointer<Float>, count: Int) -> Bool {
        let capacity = storage.count
        guard count > 0,
              count <= capacity - queuedCount else { return false }

        let destinationIndex = writeIndex
        storage.withUnsafeMutableBufferPointer { destination in
            guard let baseAddress = destination.baseAddress else { return }
            let firstCount = min(count, capacity - destinationIndex)
            baseAddress.advanced(by: destinationIndex).update(
                from: source,
                count: firstCount
            )
            let remaining = count - firstCount
            if remaining > 0 {
                baseAddress.update(from: source.advanced(by: firstCount), count: remaining)
            }
        }

        writeIndex = (destinationIndex + count) % capacity
        queuedCount += count
        return true
    }

    mutating func drain(maximumCount: Int) -> [Float] {
        let count = min(maximumCount, queuedCount)
        guard count > 0 else { return [] }

        let capacity = storage.count
        let sourceIndex = readIndex
        var result = [Float](repeating: 0, count: count)
        storage.withUnsafeMutableBufferPointer { source in
            result.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                let firstCount = min(count, capacity - sourceIndex)
                destinationBase.update(
                    from: sourceBase.advanced(by: sourceIndex),
                    count: firstCount
                )
                sourceBase.advanced(by: sourceIndex).update(
                    repeating: 0,
                    count: firstCount
                )

                let remaining = count - firstCount
                if remaining > 0 {
                    destinationBase.advanced(by: firstCount).update(
                        from: sourceBase,
                        count: remaining
                    )
                    sourceBase.update(repeating: 0, count: remaining)
                }
            }
        }

        readIndex = (sourceIndex + count) % capacity
        queuedCount -= count
        return result
    }

    mutating func reset() {
        storage.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.update(repeating: 0, count: buffer.count)
        }
        readIndex = 0
        writeIndex = 0
        queuedCount = 0
    }
}

/// Owns Moonshine's model and explicit streaming session, but never the mic.
///
/// Lifecycle calls are asynchronous barriers on a private serial queue:
///
/// 1. Await `prepare(modelDirectory:)` once.
/// 2. Await `begin(...)` before installing/enabling the microphone capture gate.
/// 3. Call `append(_:)` from the audio tap. It only copies into a bounded FIFO.
/// 4. Await `finish()` for final text, or `cancel()` to discard without a final pass.
/// 5. Await `unload()` when the keyboard lifecycle releases model resources.
///
/// Moonshine objects are touched only by `workerQueue`, because the upstream
/// Swift wrapper is mutable and does not declare thread-safety.
final class MoonshineRecognizer: @unchecked Sendable {
    typealias PartialHandler = @MainActor @Sendable (String) -> Void
    typealias FailureHandler = @MainActor @Sendable (MoonshineRecognizerError) -> Void

    private enum Lifecycle: Equatable {
        case unloaded
        case preparing
        case ready
        case starting
        case streaming
        case finishing
        case cancelling
        case unloading
    }

    static let sampleRate = 16_000

    private let stateLock = NSLock()
    private let workerQueue = DispatchQueue(
        label: "com.openblabber.moonshine-recognizer",
        qos: .userInitiated
    )
    private let drainSampleCount = 16_000

    // Protected by stateLock.
    private var lifecycle: Lifecycle = .unloaded
    private var generation: UInt64 = 0
    private var preparedModelDirectory: URL?
    private var acceptsAudio = false
    private var drainIsScheduled = false
    private var audioQueue: BoundedPCMQueue
    private var sessionFailure: MoonshineRecognizerError?
    private var partialHandler: PartialHandler?
    private var failureHandler: FailureHandler?
    private var callbackGeneration: UInt64?

    // Worker-queue confined.
    private var transcriber: Transcriber?
    private var stream: MoonshineVoice.Stream?
    private var streamGeneration: UInt64?
    private var transcript = MoonshineTranscriptAssembler()

    init(maximumQueuedAudioDuration: TimeInterval = 8) {
        let capacity = Int(
            (maximumQueuedAudioDuration * Double(Self.sampleRate)).rounded(.up)
        )
        audioQueue = BoundedPCMQueue(capacity: capacity)
    }

    var isPrepared: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lifecycle == .ready
    }

    /// Loads the bundled English Tiny Streaming model without opening the mic.
    func prepare(modelDirectory: URL) async throws {
        let standardizedDirectory = modelDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: standardizedDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw MoonshineRecognizerError.modelDirectoryMissing(
                standardizedDirectory.path
            )
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateLock.lock()

            if lifecycle == .ready,
               preparedModelDirectory == standardizedDirectory {
                stateLock.unlock()
                continuation.resume()
                return
            }
            guard lifecycle == .unloaded else {
                stateLock.unlock()
                continuation.resume(throwing: MoonshineRecognizerError.modelAlreadyPrepared)
                return
            }

            generation &+= 1
            let operationGeneration = generation
            lifecycle = .preparing
            preparedModelDirectory = standardizedDirectory

            workerQueue.async { [self] in
                do {
                    let loaded = try Transcriber(
                        modelPath: standardizedDirectory.path,
                        modelArch: .tinyStreaming,
                        options: [
                            TranscriberOption(
                                name: "return_audio_data",
                                value: "false"
                            )
                        ]
                    )

                    stateLock.lock()
                    let isCurrent = generation == operationGeneration
                        && lifecycle == .preparing
                    if isCurrent {
                        transcriber = loaded
                        lifecycle = .ready
                    }
                    stateLock.unlock()

                    guard isCurrent else {
                        // `loaded` is released here on the worker queue.
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume()
                } catch {
                    stateLock.lock()
                    let isCurrent = generation == operationGeneration
                        && lifecycle == .preparing
                    if isCurrent {
                        lifecycle = .unloaded
                        preparedModelDirectory = nil
                    }
                    stateLock.unlock()

                    if isCurrent {
                        continuation.resume(
                            throwing: MoonshineRecognizerError.moonshine(
                                error.localizedDescription
                            )
                        )
                    } else {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
            stateLock.unlock()
        }
    }

    /// Creates and starts a fresh explicit Moonshine stream.
    ///
    /// Await this method before allowing the audio tap to call `append(_:)`.
    /// Appends made while the stream is still starting are rejected.
    func begin(
        onPartial: @escaping PartialHandler,
        onFailure: @escaping FailureHandler = { _ in }
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateLock.lock()
            guard lifecycle == .ready else {
                let error: MoonshineRecognizerError = lifecycle == .unloaded
                    ? .modelNotPrepared
                    : .sessionAlreadyActive
                stateLock.unlock()
                continuation.resume(throwing: error)
                return
            }

            generation &+= 1
            let operationGeneration = generation
            lifecycle = .starting
            acceptsAudio = false
            drainIsScheduled = false
            audioQueue.reset()
            sessionFailure = nil
            partialHandler = onPartial
            failureHandler = onFailure
            callbackGeneration = operationGeneration

            workerQueue.async { [self] in
                do {
                    guard let transcriber else {
                        throw MoonshineRecognizerError.modelNotPrepared
                    }

                    transcript.reset()
                    let newStream = try transcriber.createStream(updateInterval: 0.5)
                    newStream.addListener { [weak self] event in
                        self?.handle(event, generation: operationGeneration)
                    }
                    try newStream.start()

                    stateLock.lock()
                    let isCurrent = generation == operationGeneration
                        && lifecycle == .starting
                    if isCurrent {
                        stream = newStream
                        streamGeneration = operationGeneration
                        lifecycle = .streaming
                        acceptsAudio = true
                    }
                    stateLock.unlock()

                    guard isCurrent else {
                        newStream.removeAllListeners()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume()
                } catch {
                    let recognizedError = Self.recognizerError(from: error)
                    stateLock.lock()
                    let isCurrent = generation == operationGeneration
                        && lifecycle == .starting
                    if isCurrent {
                        lifecycle = transcriber == nil ? .unloaded : .ready
                        acceptsAudio = false
                        partialHandler = nil
                        failureHandler = nil
                        callbackGeneration = nil
                    }
                    stateLock.unlock()

                    continuation.resume(
                        throwing: isCurrent ? recognizedError : CancellationError()
                    )
                }
            }
            stateLock.unlock()
        }
    }

    /// Enqueues converted 16 kHz mono Float32 PCM without running inference.
    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount == 1,
              abs(buffer.format.sampleRate - Double(Self.sampleRate)) < 0.5,
              let channel = buffer.floatChannelData?.pointee else {
            failCurrentSession(with: .invalidAudioFormat)
            return false
        }
        return append(channel, count: Int(buffer.frameLength))
    }

    /// Convenience entry point for already-converted PCM. Prefer the buffer
    /// overload in the audio tap so callers do not allocate a second array.
    @discardableResult
    func append(
        samples: [Float],
        sampleRate: Int = MoonshineRecognizer.sampleRate
    ) -> Bool {
        guard sampleRate == Self.sampleRate else {
            failCurrentSession(with: .invalidAudioFormat)
            return false
        }
        return samples.withUnsafeBufferPointer { samples in
            guard let baseAddress = samples.baseAddress else { return true }
            return append(baseAddress, count: samples.count)
        }
    }

    /// Stops the stream, forces Moonshine's trailing update, and returns the
    /// line-ID-assembled final transcript. The transcriber remains loaded.
    func finish() async throws -> String {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, Error>) in
            stateLock.lock()
            guard lifecycle == .streaming else {
                stateLock.unlock()
                continuation.resume(throwing: MoonshineRecognizerError.sessionNotActive)
                return
            }

            let operationGeneration = generation
            lifecycle = .finishing
            acceptsAudio = false

            // Enqueue while holding stateLock so this barrier cannot overtake a
            // drain that an audio callback committed immediately before it.
            workerQueue.async { [self] in
                var result = ""
                var resultError: MoonshineRecognizerError?

                stateLock.lock()
                let shouldFinish = generation == operationGeneration
                    && lifecycle == .finishing
                resultError = sessionFailure
                stateLock.unlock()

                guard shouldFinish else {
                    // A queued unload invalidated this final pass before it
                    // started. That later worker barrier owns stream teardown.
                    continuation.resume(throwing: CancellationError())
                    return
                }

                if resultError == nil {
                    do {
                        guard streamGeneration == operationGeneration,
                              let stream else {
                            throw MoonshineRecognizerError.sessionNotActive
                        }
                        try stream.stop()

                        stateLock.lock()
                        resultError = sessionFailure
                        stateLock.unlock()
                        result = transcript.text
                    } catch {
                        resultError = Self.recognizerError(from: error)
                    }
                }

                discardWorkerStream()

                stateLock.lock()
                let isCurrent = generation == operationGeneration
                    && lifecycle == .finishing
                if isCurrent {
                    lifecycle = .ready
                    acceptsAudio = false
                    drainIsScheduled = false
                    audioQueue.reset()
                    sessionFailure = nil
                    partialHandler = nil
                    failureHandler = nil
                    callbackGeneration = nil
                }
                stateLock.unlock()

                guard isCurrent else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let resultError {
                    continuation.resume(throwing: resultError)
                } else {
                    continuation.resume(returning: result)
                }
            }
            stateLock.unlock()
        }
    }

    /// Discards the current stream without forcing final inference. This keeps
    /// the loaded model ready for another dictation.
    func cancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateLock.lock()
            guard lifecycle == .streaming || lifecycle == .starting else {
                if lifecycle == .cancelling {
                    workerQueue.async { continuation.resume() }
                } else {
                    continuation.resume()
                }
                stateLock.unlock()
                return
            }

            generation &+= 1
            let operationGeneration = generation
            lifecycle = .cancelling
            acceptsAudio = false
            drainIsScheduled = false
            audioQueue.reset()
            sessionFailure = nil
            partialHandler = nil
            failureHandler = nil
            callbackGeneration = nil

            workerQueue.async { [self] in
                discardWorkerStream()

                stateLock.lock()
                if generation == operationGeneration,
                   lifecycle == .cancelling {
                    lifecycle = transcriber == nil ? .unloaded : .ready
                }
                stateLock.unlock()
                continuation.resume()
            }
            stateLock.unlock()
        }
    }

    /// Releases the stream and model on the serialized worker queue.
    func unload() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateLock.lock()
            generation &+= 1
            let operationGeneration = generation
            lifecycle = .unloading
            acceptsAudio = false
            drainIsScheduled = false
            audioQueue.reset()
            sessionFailure = nil
            partialHandler = nil
            failureHandler = nil
            callbackGeneration = nil

            workerQueue.async { [self] in
                discardWorkerStream()
                // Do not call `close()` explicitly: Moonshine's Swift wrapper
                // closes again in deinit. Releasing on this queue performs one
                // serialized native teardown.
                transcriber = nil
                transcript.reset()

                stateLock.lock()
                if generation == operationGeneration,
                   lifecycle == .unloading {
                    lifecycle = .unloaded
                    preparedModelDirectory = nil
                }
                stateLock.unlock()
                continuation.resume()
            }
            stateLock.unlock()
        }
    }

    // MARK: - Audio queue

    private func append(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return true }

        var failureToPublish: MoonshineRecognizerError?
        stateLock.lock()
        guard lifecycle == .streaming,
              acceptsAudio,
              sessionFailure == nil else {
            stateLock.unlock()
            return false
        }

        let operationGeneration = generation
        guard audioQueue.append(samples, count: count) else {
            sessionFailure = .audioBacklogExceeded
            acceptsAudio = false
            failureToPublish = .audioBacklogExceeded
            stateLock.unlock()
            publishFailure(failureToPublish!, generation: operationGeneration)
            return false
        }

        if !drainIsScheduled {
            drainIsScheduled = true
            // Scheduling while locked preserves ordering with finish/cancel.
            workerQueue.async { [weak self] in
                self?.drainAudio(generation: operationGeneration)
            }
        }
        stateLock.unlock()
        return true
    }

    private func drainAudio(generation operationGeneration: UInt64) {
        while true {
            stateLock.lock()
            guard generation == operationGeneration,
                  lifecycle == .streaming || lifecycle == .finishing,
                  sessionFailure == nil else {
                drainIsScheduled = false
                stateLock.unlock()
                return
            }

            var samples = audioQueue.drain(maximumCount: drainSampleCount)
            if samples.isEmpty {
                drainIsScheduled = false
                stateLock.unlock()
                return
            }
            stateLock.unlock()

            defer {
                samples.withUnsafeMutableBufferPointer { buffer in
                    buffer.baseAddress?.update(repeating: 0, count: buffer.count)
                }
            }

            do {
                guard streamGeneration == operationGeneration,
                      let stream else {
                    throw MoonshineRecognizerError.sessionNotActive
                }
                try stream.addAudio(samples, sampleRate: Int32(Self.sampleRate))
            } catch {
                let recognizedError = Self.recognizerError(from: error)
                failCurrentSession(
                    with: recognizedError,
                    generation: operationGeneration
                )
                return
            }
        }
    }

    // MARK: - Transcript events

    private func handle(_ event: TranscriptEvent, generation operationGeneration: UInt64) {
        guard streamGeneration == operationGeneration else { return }

        if let event = event as? TranscriptError {
            failCurrentSession(
                with: Self.recognizerError(from: event.error),
                generation: operationGeneration
            )
            return
        }

        let line = event.line
        guard transcript.apply(
            lineID: line.lineId,
            text: line.text,
            isComplete: line.isComplete
        ) else { return }

        publishPartial(transcript.text, generation: operationGeneration)
    }

    private func publishPartial(_ text: String, generation operationGeneration: UInt64) {
        stateLock.lock()
        let handler = callbackGeneration == operationGeneration
            ? partialHandler
            : nil
        stateLock.unlock()
        guard let handler else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  self.callbackIsCurrent(operationGeneration) else { return }
            handler(text)
        }
    }

    private func publishFailure(
        _ error: MoonshineRecognizerError,
        generation operationGeneration: UInt64
    ) {
        stateLock.lock()
        let handler = callbackGeneration == operationGeneration
            ? failureHandler
            : nil
        stateLock.unlock()
        guard let handler else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  self.callbackIsCurrent(operationGeneration) else { return }
            handler(error)
        }
    }

    private func callbackIsCurrent(_ operationGeneration: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == operationGeneration
            && callbackGeneration == operationGeneration
            && (lifecycle == .streaming || lifecycle == .finishing)
    }

    private func failCurrentSession(with error: MoonshineRecognizerError) {
        stateLock.lock()
        let operationGeneration = generation
        let shouldFail = lifecycle == .streaming && sessionFailure == nil
        if shouldFail {
            sessionFailure = error
            acceptsAudio = false
        }
        stateLock.unlock()

        if shouldFail {
            publishFailure(error, generation: operationGeneration)
        }
    }

    private func failCurrentSession(
        with error: MoonshineRecognizerError,
        generation operationGeneration: UInt64
    ) {
        stateLock.lock()
        let shouldFail = generation == operationGeneration
            && (lifecycle == .streaming || lifecycle == .finishing)
            && sessionFailure == nil
        if shouldFail {
            sessionFailure = error
            acceptsAudio = false
            audioQueue.reset()
            drainIsScheduled = false
        }
        stateLock.unlock()

        if shouldFail {
            publishFailure(error, generation: operationGeneration)
        }
    }

    /// Worker-queue only. Releasing the Stream invokes its native close without
    /// `stop()`, which is exactly what cancellation and unload require.
    private func discardWorkerStream() {
        stream?.removeAllListeners()
        stream = nil
        streamGeneration = nil
        transcript.reset()
    }

    private static func recognizerError(from error: Error) -> MoonshineRecognizerError {
        if let error = error as? MoonshineRecognizerError {
            return error
        }
        return .moonshine(error.localizedDescription)
    }
}
