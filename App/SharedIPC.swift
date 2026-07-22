import Foundation

/// The on-device protocol between the containing app and keyboard extension.
/// The two targets intentionally compile their own copy of this file so the
/// keyboard never links the app's speech-model dependencies.
enum OBIPC {
    static let protocolVersion = 4
    static let appGroup = "group.com.openblabber.app"
    static let commandFilename = "ob3-command.json"
    static let stateFilename = "ob3-state.json"
    static let leaseFilename = "ob3-lease.json"
    static let resultFilename = "ob3-result.json"
    static let receiptFilename = "ob3-result-receipt.json"
    static let commandNotification = "com.openblabber.ob3.command"
    static let stateNotification = "com.openblabber.ob3.state"

    static let commandMaxAge: TimeInterval = 5
    static let resultTTL: TimeInterval = 2 * 60
    static let recordingWatchdog: TimeInterval = 3
    static let keyboardPresenceGrace: TimeInterval = 3
    static let launchReturnGrace: TimeInterval = 30
    static let maximumRecordingDuration: TimeInterval = 2 * 60
    static let publicationGrace: TimeInterval = 2
    static let maximumPartialCharacters = 256

    private static let smallMailboxLimit = 64 * 1_024
    private static let resultMailboxLimit = 512 * 1_024

    static func mayAutomaticallyInsert(
        resultRequestID: String?,
        activeRequestID: String?,
        keyboardIsVisible: Bool,
        sameViewGeneration: Bool,
        sameDocument: Bool,
        sameTextRevision: Bool,
        sameCaret: Bool
    ) -> Bool {
        guard let resultRequestID, let activeRequestID else { return false }
        return resultRequestID == activeRequestID
            && keyboardIsVisible
            && sameViewGeneration
            && sameDocument
            && sameTextRevision
            && sameCaret
    }

    enum CommandAction: String, Codable, Sendable {
        case ping
        case start
        case stop
        case cancel
        case ackResult
        case endSession
        case shutdown
    }

    enum LeaseKind: String, Codable, Sendable {
        case keyboardPresence
        case recording
    }

    struct LeaseEnvelope: Codable, Equatable, Sendable {
        let version: Int
        let sessionToken: String
        let requestID: String?
        let kind: LeaseKind
        let uptime: TimeInterval

        init(
            sessionToken: String,
            requestID: String? = nil,
            kind: LeaseKind,
            uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) {
            version = OBIPC.protocolVersion
            self.sessionToken = sessionToken
            self.requestID = requestID
            self.kind = kind
            self.uptime = uptime
        }

        func isFresh(
            maximumAge: TimeInterval,
            nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) -> Bool {
            version == OBIPC.protocolVersion
                && uptime <= nowUptime + 1
                && nowUptime - uptime <= maximumAge
        }
    }

    enum EngineState: String, Codable, Sendable {
        case off
        case preparingModel
        case modelReady
        case arming
        case armed
        case recording
        case transcribing
        case result
        case error
        case interrupted
    }

    struct CommandEnvelope: Codable, Equatable, Sendable {
        let version: Int
        let sequence: UInt64
        let sessionToken: String
        let requestID: String?
        let action: CommandAction
        let createdAt: TimeInterval

        init(
            sequence: UInt64,
            sessionToken: String,
            requestID: String? = nil,
            action: CommandAction,
            createdAt: TimeInterval = Date().timeIntervalSince1970
        ) {
            self.version = OBIPC.protocolVersion
            self.sequence = sequence
            self.sessionToken = sessionToken
            self.requestID = requestID
            self.action = action
            self.createdAt = createdAt
        }

        func isFresh(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
            version == OBIPC.protocolVersion
                && createdAt <= now + 1
                && now - createdAt <= OBIPC.commandMaxAge
        }
    }

    struct EngineSnapshot: Codable, Equatable, Sendable {
        let version: Int
        let engineEpoch: String
        let sessionToken: String
        let acknowledgedSequence: UInt64
        let state: EngineState
        let reason: String?
        let updatedAt: TimeInterval
        let leaseExpiresAt: TimeInterval?
        let requestID: String?
        let resultExpiresAt: TimeInterval?
        let progress: String?
        let recordingStartedAt: TimeInterval?
        let partialText: String?
        let inputLevel: Float?

        init(
            engineEpoch: String,
            sessionToken: String,
            acknowledgedSequence: UInt64,
            state: EngineState,
            reason: String? = nil,
            updatedAt: TimeInterval = Date().timeIntervalSince1970,
            leaseExpiresAt: TimeInterval? = nil,
            requestID: String? = nil,
            resultExpiresAt: TimeInterval? = nil,
            progress: String? = nil,
            recordingStartedAt: TimeInterval? = nil,
            partialText: String? = nil,
            inputLevel: Float? = nil
        ) {
            self.version = OBIPC.protocolVersion
            self.engineEpoch = engineEpoch
            self.sessionToken = sessionToken
            self.acknowledgedSequence = acknowledgedSequence
            self.state = state
            self.reason = reason
            self.updatedAt = updatedAt
            self.leaseExpiresAt = leaseExpiresAt
            self.requestID = requestID
            self.resultExpiresAt = resultExpiresAt
            self.progress = progress
            self.recordingStartedAt = recordingStartedAt
            self.partialText = partialText.map {
                String($0.suffix(OBIPC.maximumPartialCharacters))
            }
            self.inputLevel = inputLevel.map { min(max($0, 0), 1) }
        }

    }

    struct ResultEnvelope: Codable, Equatable, Sendable {
        let version: Int
        let engineEpoch: String
        let sessionToken: String
        let requestID: String
        let text: String
        let createdAt: TimeInterval
        let expiresAt: TimeInterval

        init(
            engineEpoch: String,
            sessionToken: String,
            requestID: String,
            text: String,
            createdAt: TimeInterval = Date().timeIntervalSince1970,
            expiresAt: TimeInterval
        ) {
            version = OBIPC.protocolVersion
            self.engineEpoch = engineEpoch
            self.sessionToken = sessionToken
            self.requestID = requestID
            self.text = text
            self.createdAt = createdAt
            self.expiresAt = expiresAt
        }

        func isLive(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
            version == OBIPC.protocolVersion && !text.isEmpty && expiresAt > now
        }
    }

    enum ResultDisposition: String, Codable, Sendable {
        case inserting
        case inserted
        case discarded
    }

    struct HandledResultReceipt: Codable, Equatable, Sendable {
        let version: Int
        let requestID: String
        let ownerToken: String
        let disposition: ResultDisposition
        let expiresAt: TimeInterval

        init(
            requestID: String,
            ownerToken: String,
            disposition: ResultDisposition,
            expiresAt: TimeInterval
        ) {
            version = OBIPC.protocolVersion
            self.requestID = requestID
            self.ownerToken = ownerToken
            self.disposition = disposition
            self.expiresAt = expiresAt
        }

        func isLive(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
            version == OBIPC.protocolVersion && expiresAt > now
        }
    }

    struct Mailbox {
        let commandURL: URL
        let stateURL: URL
        let leaseURL: URL
        let resultURL: URL
        let receiptURL: URL

        init?(fileManager: FileManager = .default) {
            guard let container = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: OBIPC.appGroup
            ) else { return nil }
            commandURL = container.appendingPathComponent(OBIPC.commandFilename, isDirectory: false)
            stateURL = container.appendingPathComponent(OBIPC.stateFilename, isDirectory: false)
            leaseURL = container.appendingPathComponent(OBIPC.leaseFilename, isDirectory: false)
            resultURL = container.appendingPathComponent(OBIPC.resultFilename, isDirectory: false)
            receiptURL = container.appendingPathComponent(OBIPC.receiptFilename, isDirectory: false)
        }

        func readCommand() -> CommandEnvelope? {
            read(CommandEnvelope.self, from: commandURL, maximumBytes: OBIPC.smallMailboxLimit)
        }

        func readState() -> EngineSnapshot? {
            read(EngineSnapshot.self, from: stateURL, maximumBytes: OBIPC.smallMailboxLimit)
        }

        func readLease() -> LeaseEnvelope? {
            read(LeaseEnvelope.self, from: leaseURL, maximumBytes: OBIPC.smallMailboxLimit)
        }

        func readResult() -> ResultEnvelope? {
            read(ResultEnvelope.self, from: resultURL, maximumBytes: OBIPC.resultMailboxLimit)
        }

        func readReceipt() -> HandledResultReceipt? {
            read(HandledResultReceipt.self, from: receiptURL, maximumBytes: OBIPC.smallMailboxLimit)
        }

        func writeCommand(_ command: CommandEnvelope) throws {
            try write(command, to: commandURL)
        }

        func writeState(_ state: EngineSnapshot) throws {
            try write(state, to: stateURL)
        }

        func writeLease(_ lease: LeaseEnvelope) throws {
            try write(lease, to: leaseURL)
        }

        func writeResult(_ result: ResultEnvelope) throws {
            try write(result, to: resultURL)
        }

        func writeReceipt(_ receipt: HandledResultReceipt) throws {
            try write(receipt, to: receiptURL)
        }

        func claimReceipt(_ receipt: HandledResultReceipt) throws {
            let data = try encoded(receipt)
            try data.write(
                to: receiptURL,
                options: [.withoutOverwriting, .completeFileProtection]
            )
            excludeFromBackup(receiptURL)
        }

        @discardableResult
        func deleteResult() -> Bool {
            delete(resultURL)
        }

        @discardableResult
        func deleteReceipt() -> Bool {
            delete(receiptURL)
        }

        @discardableResult
        func deleteLease() -> Bool {
            delete(leaseURL)
        }

        private func read<Value: Decodable>(
            _ type: Value.Type,
            from url: URL,
            maximumBytes: Int
        ) -> Value? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.intValue <= maximumBytes else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }

        private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
            let data = try encoded(value)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            excludeFromBackup(url)
        }

        private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        }

        private func excludeFromBackup(_ url: URL) {
            // Atomic replacement creates a new file, so reapply this flag on
            // every write. The mailbox is transient and never belongs in backup.
            var resourceURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? resourceURL.setResourceValues(values)
        }

        private func delete(_ url: URL) -> Bool {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return true
            } catch {
                return false
            }
        }
    }
}
