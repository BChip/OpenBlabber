//
//  OpenBlabberApp.swift
//  Open Blabber — private, on-device dictation for a custom keyboard.
//
//  iOS keyboard extensions cannot record audio. The containing app owns the
//  microphone and local speech model while the keyboard is present. The
//  extension stays small and exchanges commands/results through protected,
//  versioned App Group mailboxes. Darwin notifications are only doorbells.
//

@preconcurrency import AVFoundation
import Observation
import SwiftUI
import UIKit

private let localCommandNotification = Notification.Name("OpenBlabber.CommandDoorbell")

private func commandDarwinCallback(
    _: CFNotificationCenter?,
    _: UnsafeMutableRawPointer?,
    _: CFNotificationName?,
    _: UnsafeRawPointer?,
    _: CFDictionary?
) {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: localCommandNotification, object: nil)
    }
}

@main
struct OpenBlabberApp: App {
    @State private var engine = DictationEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
        }
    }
}

// MARK: - Streaming microphone metering

/// Tracks recording duration, speech activity, and the keyboard waveform
/// without retaining the user's audio. Moonshine consumes each converted PCM
/// chunk incrementally, so the former two-minute in-memory recording copy is
/// unnecessary.
final class StreamingAudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleRate: Int
    private let maximumSampleCount: Int
    private var sampleCount = 0
    private var capturing = false
    private var detectedSpeech = false
    private var smoothedInputLevel: Float = 0

    init(
        sampleRate: Int = 16_000,
        maximumDuration: TimeInterval = OBIPC.maximumRecordingDuration
    ) {
        self.sampleRate = sampleRate
        maximumSampleCount = sampleRate * Int(maximumDuration)
    }

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capturing && sampleCount < maximumSampleCount
    }

    var isFull: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sampleCount >= maximumSampleCount
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return TimeInterval(sampleCount) / TimeInterval(sampleRate)
    }

    var hasDetectedSpeech: Bool {
        lock.lock()
        defer { lock.unlock() }
        return detectedSpeech
    }

    var inputLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return smoothedInputLevel
    }

    func begin() {
        lock.lock()
        sampleCount = 0
        detectedSpeech = false
        smoothedInputLevel = 0
        capturing = true
        lock.unlock()
    }

    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }

        lock.lock()
        defer { lock.unlock() }
        guard capturing, sampleCount < maximumSampleCount else { return false }

        let requestedCount = Int(buffer.frameLength)
        guard requestedCount > 0 else { return false }
        let available = maximumSampleCount - sampleCount
        guard requestedCount <= available else {
            sampleCount = maximumSampleCount
            capturing = false
            return false
        }

        var peak: Float = 0
        for index in 0..<requestedCount {
            peak = max(peak, abs(channels[0][index]))
        }
        let normalized = min(max((peak - 0.008) / 0.18, 0), 1)
        smoothedInputLevel = (smoothedInputLevel * 0.55) + (normalized * 0.45)
        // This only avoids finalizing obvious silence, not quiet speakers.
        detectedSpeech = detectedSpeech || peak >= 0.012

        sampleCount += requestedCount
        if sampleCount >= maximumSampleCount {
            capturing = false
        }
        return true
    }

    func end() -> (sampleCount: Int, hadSpeech: Bool) {
        lock.lock()
        capturing = false
        let usedCount = sampleCount
        let speech = detectedSpeech
        sampleCount = 0
        detectedSpeech = false
        smoothedInputLevel = 0
        lock.unlock()
        return (usedCount, speech)
    }

    func cancel() {
        lock.lock()
        capturing = false
        sampleCount = 0
        detectedSpeech = false
        smoothedInputLevel = 0
        lock.unlock()
    }
}

/// Isolates AVFoundation's non-Sendable converter objects to the audio tap.
private final class AudioConversionContext: @unchecked Sendable {
    let converter: AVAudioConverter
    let targetFormat: AVAudioFormat
    let sourceSampleRate: Double
    private let outputBuffer: AVAudioPCMBuffer
    private let maximumInputFrames: AVAudioFrameCount
    private var currentInput: AVAudioPCMBuffer?
    private var suppliedInput = false

    init?(
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        sourceSampleRate: Double,
        maximumInputFrames: AVAudioFrameCount
    ) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.sourceSampleRate = sourceSampleRate
        self.maximumInputFrames = maximumInputFrames
        let ratio = targetFormat.sampleRate / sourceSampleRate
        let capacity = AVAudioFrameCount(
            (Double(maximumInputFrames) * ratio).rounded(.up)
        ) + 16
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else { return nil }
        self.outputBuffer = outputBuffer
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.frameLength <= maximumInputFrames else { return nil }
        currentInput = input
        suppliedInput = false
        outputBuffer.frameLength = 0
        defer { currentInput = nil }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { [self] _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return currentInput
        }

        guard conversionError == nil,
              status != .error,
              outputBuffer.frameLength > 0 else {
            return nil
        }
        return outputBuffer
    }
}

// MARK: - Dictation engine

enum DictationLifecyclePolicy {
    static let preparationStallTimeout: TimeInterval = 5 * 60

    static func acceptsKeyboardPresence(appIsBackground: Bool) -> Bool {
        appIsBackground
    }

    static func shouldExpireResources(
        appIsBackground: Bool,
        ownsResources: Bool,
        deadlineUptime: TimeInterval?,
        nowUptime: TimeInterval
    ) -> Bool {
        guard appIsBackground, ownsResources, let deadlineUptime else { return false }
        return deadlineUptime <= nowUptime
    }

    static func preparationHasStalled(
        lastActivityUptime: TimeInterval?,
        nowUptime: TimeInterval,
        timeout: TimeInterval = preparationStallTimeout
    ) -> Bool {
        guard let lastActivityUptime else { return false }
        return nowUptime - lastActivityUptime > timeout
    }

    static func shouldRestartAfterShutdown(
        appIsBackground: Bool,
        recoveryDeadlineUptime: TimeInterval?,
        nowUptime: TimeInterval
    ) -> Bool {
        guard !appIsBackground, let recoveryDeadlineUptime else { return false }
        return recoveryDeadlineUptime > nowUptime
    }
}

@MainActor
@Observable
final class DictationEngine {
    enum Phase: Equatable {
        case off
        case preparing(String, Double?)
        case modelReady
        case arming
        case armed
        case recording
        case transcribing
        case result
        case interrupted(String)
        case failed(String)
    }

    private(set) var phase: Phase = .off
    private(set) var leaseExpiresAt: Date?
    private(set) var recordingStartedAt: Date?
    private(set) var liveTranscript = ""
    private(set) var inputLevel: Float = 0
    private(set) var notice: String?
    private(set) var failureRequiresSettings = false

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath")
    }

    private var audioEngine = AVAudioEngine()
    private let audioMeter = StreamingAudioMeter()
    private let mailbox = OBIPC.Mailbox()
    private let engineEpoch = UUID().uuidString
    private let sessionToken = UUID().uuidString

    private var recognizer: MoonshineRecognizer?
    private var tapInstalled = false
    private var isReconfiguringAudio = false
    private var lastAudioConfigurationUptime: TimeInterval = 0
    private var lifecycleTimer: Timer?
    private var levelTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var backgroundHold: UIBackgroundTaskIdentifier = .invalid

    private var activationTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var sessionStartTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var releaseAfterTranscription = false
    private var automaticallyActivateWhenPrepared = false
    private var keyboardHasConnected = false

    private var acknowledgedSequence: UInt64 = 0
    private var activeRequestID: String?
    private var leaseDeadlineUptime: TimeInterval?
    private var lastRecordingLeaseUptime: TimeInterval?
    private var lastKeyboardPresenceUptime: TimeInterval?
    private var resultExpiresAt: Date?
    private var interruptedLeaseExpiresAt: Date?
    private var interruptedLeaseDeadlineUptime: TimeInterval?
    private var lastPreparationActivityUptime: TimeInterval?
    private var foregroundLaunchRecoveryDeadlineUptime: TimeInterval?
    private var backgroundHandoffArmed = false

    init() {
        clearLegacyIPC()
        mailbox?.deleteResult()
        mailbox?.deleteReceipt()
        mailbox?.deleteLease()
        installObservers()
        publishSnapshot()
        startLifecycleTimer()
    }

    // MARK: Public lifecycle

    func startAutomatically() {
        guard !Self.isRunningUnderXCTest else { return }
        automaticallyActivateWhenPrepared = true
        notice = nil
        failureRequiresSettings = false
        beginLaunchAttempt()

        if recognizer == nil {
            prepareModelIfNeeded()
        } else {
            armForKeyboardReturn()
        }
    }

    private func beginLaunchAttempt() {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        keyboardHasConnected = false
        lastKeyboardPresenceUptime = nowUptime
        if audioEngine.isRunning {
            leaseExpiresAt = Date().addingTimeInterval(OBIPC.launchReturnGrace)
            leaseDeadlineUptime = nowUptime + OBIPC.launchReturnGrace
        } else {
            leaseExpiresAt = nil
            leaseDeadlineUptime = nil
        }
    }

    private func armForKeyboardReturn() {
        guard recognizer != nil else {
            automaticallyActivateWhenPrepared = true
            prepareModelIfNeeded()
            return
        }
        switch phase {
        case .modelReady, .failed, .interrupted:
            break
        default:
            return
        }

        if audioEngine.isRunning {
            let grace = keyboardHasConnected
                ? OBIPC.keyboardPresenceGrace
                : OBIPC.launchReturnGrace
            leaseExpiresAt = Date().addingTimeInterval(grace)
            leaseDeadlineUptime = ProcessInfo.processInfo.systemUptime + grace
            phase = .armed
            publishSnapshot()
            announce("Dictation ready.")
            return
        }

        notice = nil
        failureRequiresSettings = false
        generation &+= 1
        let operationGeneration = generation
        activationTask?.cancel()
        phase = .arming
        publishSnapshot(progress: "Activating the microphone…")

        activationTask = Task { [weak self] in
            guard let self else { return }
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard self.generation == operationGeneration,
                  self.phase == .arming,
                  !Task.isCancelled else { return }
            self.activationTask = nil
            guard allowed else {
                self.failureRequiresSettings = true
                self.phase = .failed(
                    "Microphone access is off. Enable it in Settings → Apps → Open Blabber."
                )
                self.publishSnapshot(reason: "Microphone permission is off.")
                self.announce("Microphone access is off.")
                return
            }

            do {
                try self.startAudioEngine()
                let grace = self.keyboardHasConnected
                    ? OBIPC.keyboardPresenceGrace
                    : OBIPC.launchReturnGrace
                let nowUptime = ProcessInfo.processInfo.systemUptime
                self.leaseExpiresAt = Date().addingTimeInterval(grace)
                self.leaseDeadlineUptime = nowUptime + grace
                self.lastKeyboardPresenceUptime = nowUptime
                self.phase = .armed
                self.publishSnapshot()
                self.announce("Dictation ready.")
            } catch {
                self.stopAudioHardware()
                self.phase = .failed("Couldn’t start the microphone: \(error.localizedDescription)")
                self.publishSnapshot(reason: error.localizedDescription)
            }
        }
    }

    func refreshAuthorizationAfterSettings() {
        guard failureRequiresSettings,
              AVAudioApplication.shared.recordPermission == .granted else { return }
        failureRequiresSettings = false
        notice = nil
        phase = recognizer == nil ? .off : .modelReady
        publishSnapshot()
        startAutomatically()
    }

    func noteKeyboardLaunch() {
        noteAppBecameActive()
    }

    func noteAppBecameActive() {
        backgroundHandoffArmed = false
        foregroundLaunchRecoveryDeadlineUptime =
            ProcessInfo.processInfo.systemUptime + OBIPC.commandMaxAge + 1
        startAutomatically()
    }

    func noteAppEnteredBackground() {
        guard ownsLifecycleResources, !backgroundHandoffArmed else { return }
        let nowUptime = ProcessInfo.processInfo.systemUptime
        keyboardHasConnected = false
        lastKeyboardPresenceUptime = nowUptime
        leaseDeadlineUptime = nowUptime + OBIPC.launchReturnGrace
        leaseExpiresAt = Date().addingTimeInterval(OBIPC.launchReturnGrace)
        backgroundHandoffArmed = true
        publishSnapshot()
    }

    func unloadModel() {
        guard !audioEngine.isRunning,
              phase != .recording,
              phase != .transcribing else { return }
        shutdownAndUnload(reason: nil)
    }

    private func shutdownAndUnload(reason: String?) {
        generation &+= 1
        automaticallyActivateWhenPrepared = false
        keyboardHasConnected = false
        interruptedLeaseExpiresAt = nil
        interruptedLeaseDeadlineUptime = nil
        releaseAfterTranscription = false
        let cancelledActivation = activationTask
        cancelledActivation?.cancel()
        activationTask = nil
        let cancelledPreparation = preparationTask
        cancelledPreparation?.cancel()
        preparationTask = nil
        let cancelledSessionStart = sessionStartTask
        cancelledSessionStart?.cancel()
        sessionStartTask = nil
        let cancelledTranscription = transcriptionTask
        cancelledTranscription?.cancel()
        transcriptionTask = nil
        stopLevelUpdates(clear: true)
        audioMeter.cancel()
        stopAudioHardware()
        releaseBackgroundHold()
        recordingStartedAt = nil
        leaseExpiresAt = nil
        leaseDeadlineUptime = nil
        lastRecordingLeaseUptime = nil
        lastKeyboardPresenceUptime = nil
        lastPreparationActivityUptime = nil
        foregroundLaunchRecoveryDeadlineUptime = nil
        backgroundHandoffArmed = false
        let loadedRecognizer = recognizer
        let unloadTask = loadedRecognizer.map { recognizer in
            Task { await recognizer.unload() }
        }
        let previousCleanup = cleanupTask
        if previousCleanup != nil
            || cancelledActivation != nil
            || cancelledPreparation != nil
            || cancelledSessionStart != nil
            || cancelledTranscription != nil
            || loadedRecognizer != nil {
            cleanupTask = Task {
                // Invalidate Moonshine before awaiting cancelled continuations,
                // so queued final inference is skipped during keyboard teardown.
                await unloadTask?.value
                await previousCleanup?.value
                await cancelledActivation?.value
                await cancelledPreparation?.value
                await cancelledSessionStart?.value
                await cancelledTranscription?.value
            }
        }
        recognizer = nil
        activeRequestID = nil
        resultExpiresAt = nil
        mailbox?.deleteResult()
        mailbox?.deleteReceipt()
        notice = reason
        phase = .off
        publishSnapshot(reason: reason)
    }

    // MARK: Model preparation

    private func prepareModelIfNeeded() {
        if recognizer != nil {
            phase = .modelReady
            publishSnapshot()
            if automaticallyActivateWhenPrepared {
                armForKeyboardReturn()
            }
            return
        }
        guard preparationTask == nil else { return }
        guard let modelDirectory = Bundle.main.url(
            forResource: "tiny-streaming-en",
            withExtension: nil
        ) else {
            let message = "The bundled English speech model is missing. Reinstall Open Blabber."
            phase = .failed(message)
            publishSnapshot(reason: message)
            return
        }

        generation &+= 1
        let operationGeneration = generation
        failureRequiresSettings = false
        notice = nil
        beginBackgroundHold(named: "Prepare speech model")

        setPreparing(
            "Loading the bundled English speech model…",
            fraction: nil
        )

        let pendingCleanup = cleanupTask
        let loadingRecognizer = MoonshineRecognizer()
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                await pendingCleanup?.value
                try Task.checkCancellation()
                self.setPreparing("Warming up the local model…", fraction: nil)
                try await loadingRecognizer.prepare(modelDirectory: modelDirectory)

                guard self.generation == operationGeneration,
                      !Task.isCancelled else {
                    await loadingRecognizer.unload()
                    return
                }

                self.recognizer = loadingRecognizer
                self.preparationTask = nil
                self.lastPreparationActivityUptime = nil
                self.releaseBackgroundHold()
                self.phase = .modelReady
                self.publishSnapshot()
                self.announce("Speech model ready.")
                if self.automaticallyActivateWhenPrepared {
                    self.armForKeyboardReturn()
                }
            } catch is CancellationError {
                await loadingRecognizer.unload()
                guard self.generation == operationGeneration else { return }
                self.preparationTask = nil
                self.lastPreparationActivityUptime = nil
                self.releaseBackgroundHold()
                self.phase = .off
                self.publishSnapshot()
            } catch {
                await loadingRecognizer.unload()
                guard self.generation == operationGeneration else { return }
                self.preparationTask = nil
                self.lastPreparationActivityUptime = nil
                self.releaseBackgroundHold()
                self.phase = .failed("Couldn’t prepare the model: \(error.localizedDescription)")
                self.publishSnapshot(reason: error.localizedDescription)
            }
        }
    }

    private func setPreparing(_ text: String, fraction: Double?) {
        lastPreparationActivityUptime = ProcessInfo.processInfo.systemUptime
        phase = .preparing(text, fraction)
        publishSnapshot(progress: text)
    }

    // MARK: Audio session

    private func startAudioEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .allowBluetoothHFP]
        )
        try? session.setPreferredSampleRate(16_000)
        try? session.setPreferredIOBufferDuration(0.08)
        try session.setActive(true)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw engineError(1, "Couldn’t create the speech-model audio format.")
        }

        let input = audioEngine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0,
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw engineError(2, "The selected microphone is unavailable.")
        }

        guard let conversion = AudioConversionContext(
            converter: converter,
            targetFormat: targetFormat,
            sourceSampleRate: sourceFormat.sampleRate,
            maximumInputFrames: 8192
        ) else {
            throw engineError(3, "Couldn’t allocate the audio conversion buffer.")
        }
        let meter = audioMeter
        let recognizer = recognizer
        input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { inputBuffer, _ in
            // This gate is intentionally before allocation and resampling.
            guard meter.isCapturing,
                  let converted = conversion.convert(inputBuffer) else { return }
            guard meter.append(converted) else { return }
            recognizer?.append(converted)
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        lastAudioConfigurationUptime = ProcessInfo.processInfo.systemUptime
    }

    private func stopAudioHardware() {
        audioMeter.cancel()
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        mailbox?.deleteLease()
        leaseExpiresAt = nil
        leaseDeadlineUptime = nil
        recordingStartedAt = nil
        lastRecordingLeaseUptime = nil
        lastKeyboardPresenceUptime = nil
    }

    private func restartAudioEngine() {
        guard !isReconfiguringAudio,
              ProcessInfo.processInfo.systemUptime - lastAudioConfigurationUptime >= 0.25 else {
            return
        }
        guard let expiry = leaseExpiresAt,
              let deadline = leaseDeadlineUptime,
              deadline > ProcessInfo.processInfo.systemUptime else { return }

        isReconfiguringAudio = true
        defer { isReconfiguringAudio = false }

        let wasRecording = phase == .recording
        if wasRecording {
            finishRecording()
        }

        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        do {
            try startAudioEngine()
            if phase != .transcribing, phase != .result {
                leaseExpiresAt = expiry
                leaseDeadlineUptime = deadline
                phase = .armed
                publishSnapshot()
            }
        } catch {
            releaseMicrophonePreservingWork(
                reason: "The audio route changed and could not recover."
            )
        }
    }

    private func handleMediaServicesReset() {
        guard !isReconfiguringAudio else { return }
        isReconfiguringAudio = true
        defer { isReconfiguringAudio = false }

        let priorExpiry = leaseExpiresAt
        let priorDeadline = leaseDeadlineUptime
        let priorPhase = phase

        if priorPhase == .recording {
            finishRecording(releaseSessionAfterward: true)
            audioEngine = AVAudioEngine()
            tapInstalled = false
            return
        }

        audioEngine = AVAudioEngine()
        tapInstalled = false

        guard let priorExpiry,
              let priorDeadline,
              priorDeadline > ProcessInfo.processInfo.systemUptime else {
            if priorPhase != .transcribing, priorPhase != .result {
                phase = recognizer == nil ? .off : .modelReady
                publishSnapshot(reason: "Audio services restarted. Microphone off.")
            }
            return
        }

        guard [.armed, .transcribing, .result].contains(priorPhase) else { return }
        do {
            try startAudioEngine()
            leaseExpiresAt = priorExpiry
            leaseDeadlineUptime = priorDeadline
            phase = priorPhase
            publishSnapshot(reason: "Audio services recovered.")
        } catch {
            releaseMicrophonePreservingWork(
                reason: "Audio services restarted and could not recover."
            )
        }
    }

    // MARK: Recording and ASR

    private func beginRecording(requestID: String) {
        guard phase == .armed,
              audioEngine.isRunning,
              leaseDeadlineUptime.map({ $0 > ProcessInfo.processInfo.systemUptime }) == true,
              sessionStartTask == nil,
              let recognizer else {
            publishSnapshot(reason: "Dictation is not ready.")
            return
        }

        notice = nil
        resultExpiresAt = nil
        mailbox?.deleteResult()
        mailbox?.deleteReceipt()
        liveTranscript = ""
        inputLevel = 0
        generation &+= 1
        let operationGeneration = generation

        sessionStartTask = Task { [weak self, recognizer] in
            guard let self else { return }
            do {
                try await recognizer.begin(
                    onPartial: { [weak self] text in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.generation == operationGeneration,
                                  self.phase == .recording,
                                  self.activeRequestID == requestID else { return }
                            let bounded = String(
                                text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .suffix(OBIPC.maximumPartialCharacters)
                            )
                            guard !bounded.isEmpty,
                                  bounded != self.liveTranscript else { return }
                            self.liveTranscript = bounded
                            self.publishSnapshot()
                        }
                    },
                    onFailure: { [weak self] error in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.generation == operationGeneration,
                                  self.phase == .recording,
                                  self.activeRequestID == requestID else { return }
                            self.notice = error.localizedDescription
                            self.finishRecording()
                        }
                    }
                )
                try Task.checkCancellation()
                guard self.generation == operationGeneration,
                      self.phase == .armed else {
                    throw CancellationError()
                }

                self.sessionStartTask = nil
                self.activeRequestID = requestID
                self.recordingStartedAt = Date()
                let nowUptime = ProcessInfo.processInfo.systemUptime
                self.lastRecordingLeaseUptime = nowUptime
                self.lastKeyboardPresenceUptime = nowUptime
                self.audioMeter.begin()
                self.phase = .recording
                self.publishSnapshot()
                self.startLevelUpdates(requestID: requestID)
                self.announce("Listening.")
            } catch is CancellationError {
                guard self.generation == operationGeneration else { return }
                self.sessionStartTask = nil
                await recognizer.cancel()
            } catch {
                guard self.generation == operationGeneration else { return }
                self.sessionStartTask = nil
                await recognizer.cancel()
                let message = "Couldn’t start English transcription: \(error.localizedDescription)"
                self.stopAudioHardware()
                self.notice = message
                self.phase = .failed(message)
                self.publishSnapshot(reason: message)
            }
        }
    }

    private func startLevelUpdates(requestID: String) {

        levelTimer?.invalidate()
        let level = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.phase == .recording,
                      self.activeRequestID == requestID else { return }
                let nextLevel = self.audioMeter.inputLevel
                guard abs(nextLevel - self.inputLevel) >= 0.02 else { return }
                self.inputLevel = nextLevel
                self.publishSnapshot()
            }
        }
        level.tolerance = 0.025
        RunLoop.main.add(level, forMode: .common)
        levelTimer = level
    }

    private func stopLevelUpdates(clear: Bool) {
        levelTimer?.invalidate()
        levelTimer = nil
        inputLevel = 0
        if clear {
            liveTranscript = ""
        }
    }

    private func finishRecording(releaseSessionAfterward: Bool = false) {
        guard phase == .recording,
              let requestID = activeRequestID,
              let recognizer else { return }

        stopLevelUpdates(clear: false)
        let recording = audioMeter.end()
        recordingStartedAt = nil
        lastRecordingLeaseUptime = nil
        releaseAfterTranscription = releaseSessionAfterward

        if releaseSessionAfterward {
            stopAudioHardware()
            beginBackgroundHold(named: "Finish transcription")
        }

        generation &+= 1
        let operationGeneration = generation
        phase = .transcribing
        publishSnapshot()
        announce("Finishing transcription on this device.")

        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self, recognizer] in
            guard let self else { return }

            guard recording.sampleCount >= 4_000, recording.hadSpeech else {
                await recognizer.cancel()
                guard self.generation == operationGeneration,
                      self.activeRequestID == requestID else { return }
                self.transcriptionTask = nil
                self.activeRequestID = nil
                self.notice = "No speech detected."
                let released = releaseSessionAfterward
                    || self.releaseAfterTranscription
                    || !self.audioEngine.isRunning
                self.releaseAfterTranscription = false
                self.finishWithoutResult(releasedSession: released)
                return
            }

            do {
                try Task.checkCancellation()
                let text = (try await recognizer.finish())
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard self.generation == operationGeneration,
                      !Task.isCancelled,
                      self.activeRequestID == requestID else { return }

                self.transcriptionTask = nil
                if text.isEmpty {
                    self.activeRequestID = nil
                    self.notice = "No words were recognized."
                    let sessionWasReleased = releaseSessionAfterward
                        || self.releaseAfterTranscription
                        || !self.audioEngine.isRunning
                    self.releaseAfterTranscription = false
                    self.finishWithoutResult(releasedSession: sessionWasReleased)
                    return
                }

                let expiresAt = Date().addingTimeInterval(OBIPC.resultTTL)
                guard let mailbox = self.mailbox else {
                    self.activeRequestID = nil
                    self.notice = "The protected app-to-keyboard handoff is unavailable."
                    let released = releaseSessionAfterward
                        || self.releaseAfterTranscription
                        || !self.audioEngine.isRunning
                    self.releaseAfterTranscription = false
                    self.finishWithoutResult(releasedSession: released)
                    return
                }

                do {
                    mailbox.deleteReceipt()
                    try mailbox.writeResult(
                        OBIPC.ResultEnvelope(
                            engineEpoch: self.engineEpoch,
                            sessionToken: self.sessionToken,
                            requestID: requestID,
                            text: text,
                            expiresAt: expiresAt.timeIntervalSince1970
                        )
                    )
                    self.releaseAfterTranscription = false
                    self.resultExpiresAt = expiresAt
                    self.liveTranscript = ""
                    self.phase = .result
                    self.publishSnapshot()
                    self.announce("Transcript ready.")
                    self.releaseBackgroundHold()
                } catch {
                    self.activeRequestID = nil
                    self.notice = "Couldn’t hand the transcript to the keyboard securely."
                    let released = releaseSessionAfterward
                        || self.releaseAfterTranscription
                        || !self.audioEngine.isRunning
                    self.releaseAfterTranscription = false
                    self.finishWithoutResult(releasedSession: released)
                }
            } catch is CancellationError {
                guard self.generation == operationGeneration,
                      self.activeRequestID == requestID else { return }
                self.transcriptionTask = nil
                self.activeRequestID = nil
                self.notice = "Transcription was cancelled."
                let released = releaseSessionAfterward
                    || self.releaseAfterTranscription
                    || !self.audioEngine.isRunning
                self.releaseAfterTranscription = false
                self.finishWithoutResult(releasedSession: released)
            } catch {
                guard self.generation == operationGeneration else { return }
                self.transcriptionTask = nil
                self.activeRequestID = nil
                self.notice = "Transcription failed: \(error.localizedDescription)"
                let sessionWasReleased = releaseSessionAfterward
                    || self.releaseAfterTranscription
                    || !self.audioEngine.isRunning
                self.releaseAfterTranscription = false
                self.finishWithoutResult(releasedSession: sessionWasReleased)
            }
        }
    }

    private func finishWithoutResult(releasedSession: Bool) {
        stopLevelUpdates(clear: true)
        resultExpiresAt = nil
        mailbox?.deleteResult()
        mailbox?.deleteReceipt()
        if releasedSession
            || leaseDeadlineUptime.map({
                $0 <= ProcessInfo.processInfo.systemUptime
            }) != false {
            stopAudioHardware()
            phase = recognizer == nil ? .off : .modelReady
            releaseBackgroundHold()
        } else {
            phase = .armed
        }
        publishSnapshot(reason: notice)
    }

    private func abortRecordingAfterKeyboardLoss() {
        shutdownAndUnload(reason: "Keyboard closed.")
    }

    private func acknowledgeResult(requestID: String?) {
        guard phase == .result,
              requestID == activeRequestID else {
            publishSnapshot()
            return
        }
        if let mailbox, !mailbox.deleteResult() {
            notice = "The protected transcript could not be deleted yet; cleanup will retry."
            publishSnapshot(reason: notice)
            return
        }
        activeRequestID = nil
        resultExpiresAt = nil
        liveTranscript = ""
        inputLevel = 0
        mailbox?.deleteReceipt()
        releaseBackgroundHold()

        if audioEngine.isRunning,
           leaseDeadlineUptime.map({ $0 > ProcessInfo.processInfo.systemUptime }) == true {
            phase = .armed
        } else {
            stopAudioHardware()
            phase = recognizer == nil ? .off : .modelReady
        }
        publishSnapshot()
    }

    // MARK: Keyboard lifecycle policy

    private func startLifecycleTimer() {
        lifecycleTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        lifecycleTimer = timer
    }

    private func tick() {
        // Darwin notifications are lossy/coalesced. The mailbox is the source
        // of truth, so poll it as a bounded fallback; sequence checks make this
        // idempotent.
        let now = Date()
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let appIsBackground = UIApplication.shared.applicationState == .background

        if appIsBackground, ownsLifecycleResources, !backgroundHandoffArmed {
            noteAppEnteredBackground()
        }

        consumeLatestLease()
        consumeLatestCommand()

        if case .preparing = phase,
           DictationLifecyclePolicy.preparationHasStalled(
               lastActivityUptime: lastPreparationActivityUptime,
               nowUptime: nowUptime
           ) {
            let message = "The bundled English model stopped loading. Close and reopen Open Blabber."
            shutdownAndUnload(reason: message)
            notice = message
            phase = .failed(message)
            publishSnapshot(reason: message)
            announce("Model preparation stopped responding.")
            return
        }

        if phase == .result {
            let sharedState = mailbox?.readState()
            if sharedState?.state != .result
                || sharedState?.requestID != activeRequestID
                || sharedState?.engineEpoch != engineEpoch {
                publishSnapshot()
            }
        }

        if phase == .result,
           let requestID = activeRequestID,
           let receipt = mailbox?.readReceipt() {
            if receipt.isLive(at: now.timeIntervalSince1970),
               receipt.requestID == requestID,
               receipt.disposition != .inserting {
                acknowledgeResult(requestID: requestID)
                return
            }
            if !receipt.isLive(at: now.timeIntervalSince1970) {
                mailbox?.deleteReceipt()
            }
        }

        if phase == .recording {
            let leaseAge = nowUptime - (lastRecordingLeaseUptime ?? 0)
            if leaseAge > OBIPC.recordingWatchdog {
                abortRecordingAfterKeyboardLoss()
                return
            }
            if audioMeter.isFull {
                notice = "Two-minute recording limit reached."
                finishRecording()
                return
            }
            if audioMeter.duration >= 10, !audioMeter.hasDetectedSpeech {
                notice = "No speech detected."
                finishRecording()
                return
            }
        }

        let presenceGrace = keyboardHasConnected
            ? OBIPC.keyboardPresenceGrace
            : OBIPC.launchReturnGrace
        if ownsLifecycleResources,
           appIsBackground,
           nowUptime - (lastKeyboardPresenceUptime ?? 0) > presenceGrace {
            shutdownAndUnload(reason: "Keyboard closed.")
            announce("Keyboard closed. Dictation stopped.")
            return
        }

        if let expiry = resultExpiresAt, expiry <= now {
            acknowledgeResult(requestID: activeRequestID)
            return
        }

        guard DictationLifecyclePolicy.shouldExpireResources(
            appIsBackground: appIsBackground,
            ownsResources: ownsLifecycleResources,
            deadlineUptime: leaseDeadlineUptime,
            nowUptime: nowUptime
        ) else { return }
        expireSession()
    }

    private var ownsLifecycleResources: Bool {
        audioEngine.isRunning
            || recognizer != nil
            || activationTask != nil
            || preparationTask != nil
            || sessionStartTask != nil
            || transcriptionTask != nil
    }

    private func expireSession() {
        shutdownAndUnload(reason: "Keyboard closed.")
    }

    private func releaseMicrophonePreservingWork(reason: String?) {
        notice = reason
        switch phase {
        case .recording:
            finishRecording(releaseSessionAfterward: true)
        case .transcribing:
            releaseAfterTranscription = true
            stopAudioHardware()
            beginBackgroundHold(named: "Finish transcription")
            publishSnapshot(reason: reason)
        case .result:
            stopAudioHardware()
            publishSnapshot(reason: reason)
        default:
            terminateSession(reason: reason)
        }
    }

    private func terminateSession(reason: String?) {
        shutdownAndUnload(reason: reason)
    }

    // MARK: Versioned command handling

    private func consumeLatestCommand() {
        guard let command = mailbox?.readCommand(),
              command.isFresh(),
              command.sessionToken == sessionToken,
              command.sequence > acknowledgedSequence else { return }

        acknowledgedSequence = command.sequence
        switch command.action {
        case .ping:
            publishSnapshot()

        case .start:
            guard let requestID = command.requestID else {
                publishSnapshot(reason: "Missing request identifier.")
                return
            }
            beginRecording(requestID: requestID)

        case .stop:
            guard command.requestID == activeRequestID else {
                publishSnapshot(reason: "That dictation is no longer active.")
                return
            }
            finishRecording()

        case .cancel:
            shutdownAndUnload(reason: "Keyboard closed.")

        case .ackResult:
            acknowledgeResult(requestID: command.requestID)

        case .endSession:
            shutdownAndUnload(reason: "Keyboard closed.")

        case .shutdown:
            if hasFreshKeyboardLease() {
                consumeLatestLease()
                publishSnapshot()
                return
            }

            let nowUptime = ProcessInfo.processInfo.systemUptime
            let appIsBackground = UIApplication.shared.applicationState == .background
            let shouldRestart = DictationLifecyclePolicy.shouldRestartAfterShutdown(
                appIsBackground: appIsBackground,
                recoveryDeadlineUptime: foregroundLaunchRecoveryDeadlineUptime,
                nowUptime: nowUptime
            )
            shutdownAndUnload(reason: appIsBackground ? "Keyboard closed." : nil)
            if shouldRestart {
                startAutomatically()
            }
        }
    }

    private func consumeLatestLease() {
        let appIsBackground = UIApplication.shared.applicationState == .background
        guard DictationLifecyclePolicy.acceptsKeyboardPresence(
            appIsBackground: appIsBackground
        ) else { return }

        guard let lease = mailbox?.readLease(),
              lease.sessionToken == sessionToken else { return }

        let nowUptime = ProcessInfo.processInfo.systemUptime
        switch lease.kind {
        case .recording:
            guard phase == .recording,
                  lease.requestID == activeRequestID,
                  lease.isFresh(
                    maximumAge: OBIPC.recordingWatchdog,
                    nowUptime: nowUptime
                  ) else { return }
            lastRecordingLeaseUptime = max(lastRecordingLeaseUptime ?? 0, lease.uptime)
            lastKeyboardPresenceUptime = max(lastKeyboardPresenceUptime ?? 0, lease.uptime)
            keyboardHasConnected = true
            extendPresenceLease(from: lease.uptime, nowUptime: nowUptime)

        case .keyboardPresence:
            guard lease.isFresh(
                      maximumAge: OBIPC.keyboardPresenceGrace,
                      nowUptime: nowUptime
                  ) else { return }
            switch phase {
            case .off, .failed:
                return
            case .preparing, .modelReady, .arming, .armed, .recording,
                 .transcribing, .result, .interrupted:
                break
            }
            lastKeyboardPresenceUptime = max(lastKeyboardPresenceUptime ?? 0, lease.uptime)
            keyboardHasConnected = true
            extendPresenceLease(from: lease.uptime, nowUptime: nowUptime)
        }
    }

    private func hasFreshKeyboardLease(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard let lease = mailbox?.readLease(),
              lease.sessionToken == sessionToken else { return false }

        switch lease.kind {
        case .keyboardPresence:
            return lease.isFresh(
                maximumAge: OBIPC.keyboardPresenceGrace,
                nowUptime: nowUptime
            )
        case .recording:
            return lease.requestID == activeRequestID
                && lease.isFresh(
                    maximumAge: OBIPC.recordingWatchdog,
                    nowUptime: nowUptime
                )
        }
    }

    private func extendPresenceLease(from heartbeatUptime: TimeInterval, nowUptime: TimeInterval) {
        let deadline = heartbeatUptime + OBIPC.keyboardPresenceGrace
        leaseDeadlineUptime = deadline
        leaseExpiresAt = Date().addingTimeInterval(max(0, deadline - nowUptime))
    }

    private func publishSnapshot(reason: String? = nil, progress: String? = nil) {
        guard let mailbox else { return }

        let state: OBIPC.EngineState
        switch phase {
        case .off: state = .off
        case .preparing: state = .preparingModel
        case .modelReady: state = .modelReady
        case .arming: state = .arming
        case .armed: state = .armed
        case .recording: state = .recording
        case .transcribing: state = .transcribing
        case .result: state = .result
        case .interrupted: state = .interrupted
        case .failed: state = .error
        }

        let snapshot = OBIPC.EngineSnapshot(
            engineEpoch: engineEpoch,
            sessionToken: sessionToken,
            acknowledgedSequence: acknowledgedSequence,
            state: state,
            reason: reason ?? notice,
            leaseExpiresAt: leaseExpiresAt?.timeIntervalSince1970,
            requestID: activeRequestID,
            resultExpiresAt: state == .result ? resultExpiresAt?.timeIntervalSince1970 : nil,
            progress: progress,
            recordingStartedAt: recordingStartedAt?.timeIntervalSince1970,
            partialText: [.recording, .transcribing].contains(state) && !liveTranscript.isEmpty
                ? liveTranscript
                : nil,
            inputLevel: state == .recording ? inputLevel : nil
        )

        do {
            try mailbox.writeState(snapshot)
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(OBIPC.stateNotification as CFString),
                nil,
                nil,
                true
            )
        } catch {
            // The in-app controls still work if file protection temporarily
            // prevents a write (for example while the device is locked).
        }
    }

    private func clearLegacyIPC() {
        guard let defaults = UserDefaults(suiteName: OBIPC.appGroup) else { return }
        for key in [
            "ob2_heartbeat", "ob2_state", "ob2_partial", "ob2_progress",
            "ob2_progress_date", "ob2_final_text", "ob2_final_id",
            "ob2_final_date", "ob2_final_consumed"
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Interruptions, routes, and memory

    private func installObservers() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            commandDarwinCallback,
            OBIPC.commandNotification as CFString,
            nil,
            .deliverImmediately
        )

        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: localCommandNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.consumeLatestCommand()
                }
            }
        )

        for name in [
            UIApplication.willEnterForegroundNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification
        ] {
            notificationTokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.tick()
                    }
                }
            )
        }

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let typeRaw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?
                    .uintValue
                let optionsRaw = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?
                    .uintValue ?? 0
                MainActor.assumeIsolated {
                    self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
                }
            }
        )

        for name in [
            AVAudioSession.routeChangeNotification,
            .AVAudioEngineConfigurationChange
        ] {
            notificationTokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard self?.audioEngine.isRunning == true else { return }
                        self?.restartAudioEngine()
                    }
                }
            )
        }

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleMediaServicesReset()
                }
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          !self.audioEngine.isRunning,
                          self.phase != .transcribing else { return }
                    self.unloadModel()
                }
            }
        )
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt) {
        guard let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            switch phase {
            case .recording:
                interruptedLeaseExpiresAt = nil
                interruptedLeaseDeadlineUptime = nil
                finishRecording(releaseSessionAfterward: true)

            case .transcribing:
                interruptedLeaseExpiresAt = nil
                interruptedLeaseDeadlineUptime = nil
                releaseAfterTranscription = true
                stopAudioHardware()
                beginBackgroundHold(named: "Finish interrupted transcription")
                publishSnapshot(reason: "Microphone interrupted; finishing locally.")

            case .result:
                interruptedLeaseExpiresAt = nil
                interruptedLeaseDeadlineUptime = nil
                stopAudioHardware()
                beginBackgroundHold(named: "Expire interrupted transcript")
                publishSnapshot(reason: "Microphone interrupted; transcript preserved.")

            case .armed:
                interruptedLeaseExpiresAt = leaseExpiresAt
                interruptedLeaseDeadlineUptime = leaseDeadlineUptime
                stopAudioHardware()
                phase = .interrupted("Another audio activity needs the microphone.")
                publishSnapshot(reason: "Microphone interrupted.")

            default:
                break
            }
        case .ended:
            guard case .interrupted = phase else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            guard options.contains(.shouldResume),
                  let expiry = interruptedLeaseExpiresAt,
                  let deadline = interruptedLeaseDeadlineUptime,
                  deadline > ProcessInfo.processInfo.systemUptime else {
                interruptedLeaseExpiresAt = nil
                interruptedLeaseDeadlineUptime = nil
                releaseMicrophonePreservingWork(reason: "Audio interruption stopped dictation.")
                return
            }
            do {
                try startAudioEngine()
                interruptedLeaseExpiresAt = nil
                interruptedLeaseDeadlineUptime = nil
                leaseExpiresAt = expiry
                leaseDeadlineUptime = deadline
                lastKeyboardPresenceUptime = ProcessInfo.processInfo.systemUptime
                phase = .armed
                publishSnapshot()
            } catch {
                interruptedLeaseExpiresAt = nil
                interruptedLeaseDeadlineUptime = nil
                releaseMicrophonePreservingWork(reason: "Couldn’t resume the microphone.")
            }
        @unknown default:
            releaseMicrophonePreservingWork(reason: "Unknown audio interruption.")
        }
    }

    // MARK: Utilities

    private func beginBackgroundHold(named name: String) {
        releaseBackgroundHold()
        backgroundHold = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                switch self.phase {
                case .transcribing:
                    self.shutdownAndUnload(
                        reason: "Transcription stopped when background time expired."
                    )

                case .preparing:
                    self.shutdownAndUnload(
                        reason: "Keep Open Blabber open while preparing the model."
                    )

                default:
                    self.releaseBackgroundHold()
                }
            }
        }
    }

    private func releaseBackgroundHold() {
        guard backgroundHold != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundHold)
        backgroundHold = .invalid
    }

    private func engineError(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "OpenBlabber.Audio",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

// MARK: - App UI

struct ContentView: View {
    let engine: DictationEngine

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    setupCard
                    links
                        .padding(.top, 4)
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(wash)
            .navigationTitle("Open Blabber")
        }
        .task {
            engine.noteAppBecameActive()
        }
        .onOpenURL { url in
            guard url.scheme == "openblabber", url.host == "session" else { return }
            engine.noteKeyboardLaunch()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                engine.refreshAuthorizationAfterSettings()
                engine.noteAppBecameActive()
            case .background:
                engine.noteAppEnteredBackground()
            case .inactive:
                engine.noteAppEnteredBackground()
            @unknown default:
                break
            }
        }
    }

    private var wash: some View {
        ZStack {
            Color(.systemBackground)
            Circle()
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.14))
                .frame(width: 420, height: 420)
                .blur(radius: 110)
                .offset(x: -140, y: -240)
        }
        .ignoresSafeArea()
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            }
    }

    private var statusCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Group {
                        if showsStartupProgress {
                            ProgressView()
                                .controlSize(.large)
                                .tint(statusColor)
                                .accessibilityLabel(startupProgressLabel)
                        } else {
                            Image(systemName: statusIcon)
                                .font(.largeTitle)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(statusColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle)
                            .font(.headline)
                        Text(statusDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)

                if case .failed = engine.phase {
                    Button(engine.failureRequiresSettings ? "Open Settings" : "Try Again") {
                        if engine.failureRequiresSettings,
                           let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        } else {
                            engine.startAutomatically()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    private var showsStartupProgress: Bool {
        switch engine.phase {
        case .preparing, .arming:
            true
        default:
            false
        }
    }

    private var startupProgressLabel: String {
        switch engine.phase {
        case .preparing:
            "Loading the bundled English speech model"
        case .arming:
            "Starting the microphone"
        default:
            ""
        }
    }

    private var statusIcon: String {
        switch engine.phase {
        case .preparing, .arming:
            "waveform.circle.fill"
        case .off:
            "pause.circle.fill"
        case .modelReady:
            "checkmark.circle.fill"
        case .armed:
            "checkmark.circle.fill"
        case .recording:
            "waveform"
        case .transcribing:
            "ellipsis.circle.fill"
        case .result:
            "text.badge.checkmark"
        case .interrupted:
            "exclamationmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch engine.phase {
        case .off:
            .secondary
        case .recording:
            .red
        case .interrupted:
            .orange
        case .failed:
            .red
        default:
            .accentColor
        }
    }

    private var statusTitle: String {
        switch engine.phase {
        case .off:
            "Open Blabber is idle"
        case .preparing:
            "Loading English speech…"
        case .modelReady:
            "English model ready"
        case .arming:
            "Starting the microphone…"
        case .armed:
            "Open Blabber is ready"
        case .recording:
            "Listening…"
        case .transcribing:
            "Finishing locally…"
        case .result:
            "Text ready"
        case .interrupted:
            "Microphone interrupted"
        case .failed:
            "Needs attention"
        }
    }

    private var statusDetail: String {
        switch engine.phase {
        case .off:
            engine.notice ?? "Open the keyboard to start private English dictation."
        case .preparing(let text, _):
            text
        case .modelReady:
            "The compact on-device model is loaded. Starting the microphone next."
        case .arming:
            "This should take only a moment."
        case .armed:
            "Return to the app you were using with iOS’s Back control."
        case .recording:
            engine.liveTranscript.isEmpty ? "English speech stays on this device." : engine.liveTranscript
        case .transcribing:
            engine.liveTranscript.isEmpty ? "English speech stays on this device." : engine.liveTranscript
        case .result:
            "The keyboard is inserting your transcription."
        case .interrupted(let message), .failed(let message):
            message
        }
    }

    private var setupCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Keyboard setup")
                    .font(.headline)
                Text(
                    "In \(Text("Settings → General → Keyboard → Keyboards").bold()), add \(Text("Open Blabber").bold()) and turn on \(Text("Allow Full Access").bold()). Full Access is used only for the protected on-device connection between the keyboard and this app."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var links: some View {
        HStack(spacing: 16) {
            Link(
                "Free and open source",
                destination: URL(string: "https://github.com/BChip/OpenBlabber")!
            )
            Link(
                "Privacy Policy",
                destination: URL(string: "https://openblabber.com/#privacy")!
            )
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}
