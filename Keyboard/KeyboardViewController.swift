//
//  KeyboardViewController.swift
//  Open Blabber keyboard extension.
//
//  The extension owns only a small UIKit surface and protected App Group IPC.
//  Audio capture and the on-device speech model remain in the containing app.
//

@preconcurrency import UIKit

private let localStateNotification = Notification.Name("OpenBlabber.StateDoorbell")

private func stateDarwinCallback(
    _: CFNotificationCenter?,
    _: UnsafeMutableRawPointer?,
    _: CFNotificationName?,
    _: UnsafeRawPointer?,
    _: CFDictionary?
) {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: localStateNotification, object: nil)
    }
}

@MainActor
private final class VoiceActivityView: UIView {
    private let bars: [UIView]
    private var heightConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        bars = (0..<7).map { _ in
            let bar = UIView()
            bar.backgroundColor = .systemRed
            bar.layer.cornerRadius = 2
            bar.translatesAutoresizingMaskIntoConstraints = false
            return bar
        }
        super.init(frame: frame)

        isAccessibilityElement = false
        accessibilityElementsHidden = true

        let stack = UIStackView(arrangedSubviews: bars)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fillEqually
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 88),
            heightAnchor.constraint(equalToConstant: 32)
        ])

        for bar in bars {
            let height = bar.heightAnchor.constraint(equalToConstant: 4)
            height.isActive = true
            heightConstraints.append(height)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setLevel(_ rawLevel: Float) {
        let level = CGFloat(min(max(rawLevel, 0), 1))
        let shapes: [CGFloat] = [0.42, 0.68, 0.88, 1, 0.88, 0.68, 0.42]
        for (constraint, shape) in zip(heightConstraints, shapes) {
            constraint.constant = 4 + (24 * max(0.08, level * shape))
        }

        let updates = { self.layoutIfNeeded() }
        if UIAccessibility.isReduceMotionEnabled {
            updates()
        } else {
            UIView.animate(
                withDuration: 0.14,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
                animations: updates
            )
        }
    }
}

@MainActor
final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    private struct RequestContext {
        let requestID: String
        let documentID: UUID
        let viewGeneration: UInt64
        let textRevision: UInt64
        let caretFingerprint: Int
    }

    private struct PendingCommand {
        let sequence: UInt64
        let action: OBIPC.CommandAction
        let requestID: String?
        let deadline: Date
    }

    private let sessionURL = URL(string: "openblabber://session")!
    private let mailbox = OBIPC.Mailbox()
    private let instanceToken = UUID().uuidString

    private let transcriptLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let activityView = VoiceActivityView()
    private var preferredHeightConstraint: NSLayoutConstraint?

    private var pollTimer: Timer?
    private var deleteDelayTimer: Timer?
    private var deleteRepeatTimer: Timer?
    private var stateObserver: NSObjectProtocol?
    private var snapshot: OBIPC.EngineSnapshot?
    private var commandSequence: UInt64 = 0
    private var pendingCommand: PendingCommand?
    private var requestContext: RequestContext?
    private var pendingResult: OBIPC.ResultEnvelope?
    private var insertionRecoveryRequired = false
    private var locallyHandledResultID: String?
    private var stopRequested = false
    private var connectionFailed = false
    private var isOpeningContainer = false

    private var viewGeneration: UInt64 = 0
    private var textRevision: UInt64 = 0
    private var isKeyboardVisible = false
    private var lastEngineEpoch: String?
    private var lastAnnouncementKey: String?
    private var lastLeaseUptime: TimeInterval = 0

    var enableInputClicksWhenVisible: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        hasDictationKey = true
        configureInterface()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (self: KeyboardViewController, _: UITraitCollection) in
            self.updatePreferredHeight()
        }
        installStateObserver()
        startPolling()
        refreshState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewGeneration &+= 1
        isKeyboardVisible = true
        isOpeningContainer = false
        connectionFailed = false
        globeButton.isHidden = !needsInputModeSwitchKey

        if stateObserver == nil {
            installStateObserver()
        }
        if pollTimer == nil {
            startPolling()
        }
        refreshState()
        sendPresenceIfNeeded(force: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        isKeyboardVisible = false
        viewGeneration &+= 1
        stopRepeatingDelete()
        mailbox?.deleteLease()

        if !isOpeningContainer {
            pendingCommand = nil
            _ = sendCommand(.shutdown, requestID: nil, expectsAcknowledgement: false)
        }

        super.viewWillDisappear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        stopRepeatingDelete()
        requestContext = nil
        pendingResult = nil
        insertionRecoveryRequired = false
        activityView.setLevel(0)

        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
            self.stateObserver = nil
        }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(OBIPC.stateNotification as CFString),
            nil
        )
        super.viewDidDisappear(animated)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        textRevision &+= 1
        super.textDidChange(textInput)
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        textRevision &+= 1
        super.selectionDidChange(textInput)
    }

    private func configureInterface() {
        view.backgroundColor = .clear

        transcriptLabel.font = .preferredFont(forTextStyle: .body)
        transcriptLabel.textColor = .label
        transcriptLabel.textAlignment = .center
        transcriptLabel.numberOfLines = 3
        transcriptLabel.adjustsFontForContentSizeCategory = true
        transcriptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        transcriptLabel.accessibilityTraits = .staticText

        var micConfiguration = UIButton.Configuration.filled()
        micConfiguration.image = UIImage(systemName: "mic.fill")
        micConfiguration.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        micConfiguration.baseBackgroundColor = .systemBlue
        micConfiguration.baseForegroundColor = .white
        micConfiguration.cornerStyle = .capsule
        micButton.configuration = micConfiguration
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.accessibilityLabel = "Dictate"
        micButton.accessibilityHint = "Starts private on-device dictation"

        var globeConfiguration = UIButton.Configuration.plain()
        globeConfiguration.image = UIImage(systemName: "globe")
        globeConfiguration.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        globeConfiguration.baseForegroundColor = .label
        globeButton.configuration = globeConfiguration
        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.accessibilityHint = "Touch and hold to choose another keyboard"
        globeButton.addTarget(
            self,
            action: #selector(globeTapped(_:forEvent:)),
            for: .allTouchEvents
        )

        var deleteConfiguration = UIButton.Configuration.plain()
        deleteConfiguration.image = UIImage(systemName: "delete.left")
        deleteConfiguration.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        deleteConfiguration.baseForegroundColor = .label
        deleteButton.configuration = deleteConfiguration
        deleteButton.accessibilityLabel = "Delete"
        deleteButton.accessibilityHint =
            "Deletes the previous character. Touch and hold to delete continuously."
        deleteButton.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
        deleteButton.addTarget(
            self,
            action: #selector(deleteTouchEnded),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )

        let micRow = UIStackView(arrangedSubviews: [UIView(), micButton, UIView()])
        micRow.axis = .horizontal
        micRow.alignment = .center
        micRow.distribution = .equalCentering

        let root = UIStackView(arrangedSubviews: [
            transcriptLabel,
            micRow,
            activityView
        ])
        root.axis = .vertical
        root.alignment = .fill
        root.distribution = .fill
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        globeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(globeButton)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            root.bottomAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -10
            ),
            transcriptLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            micButton.widthAnchor.constraint(equalToConstant: 76),
            micButton.heightAnchor.constraint(equalToConstant: 64),
            globeButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            globeButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -8
            ),
            globeButton.widthAnchor.constraint(equalToConstant: 44),
            globeButton.heightAnchor.constraint(equalToConstant: 44),
            deleteButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            deleteButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -8
            ),
            deleteButton.widthAnchor.constraint(equalToConstant: 44),
            deleteButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        let preferredHeight = view.heightAnchor.constraint(equalToConstant: 216)
        preferredHeight.priority = .defaultHigh
        preferredHeight.isActive = true
        preferredHeightConstraint = preferredHeight
        updatePreferredHeight()

        activityView.isHidden = true
        updateAccessibilityOrder()
    }

    private func updatePreferredHeight() {
        preferredHeightConstraint?.constant =
            traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 252 : 216
    }

    private func installStateObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            stateDarwinCallback,
            OBIPC.stateNotification as CFString,
            nil,
            .deliverImmediately
        )
        stateObserver = NotificationCenter.default.addObserver(
            forName: localStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshState()
            }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollTick()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollTick() {
        if let pendingCommand,
           pendingCommand.deadline > Date(),
           mailbox?.readCommand()?.sequence == pendingCommand.sequence {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(OBIPC.commandNotification as CFString),
                nil,
                nil,
                true
            )
        }

        if let pendingCommand, pendingCommand.deadline <= Date() {
            self.pendingCommand = nil
            if pendingCommand.action != .ackResult {
                if pendingCommand.action == .start {
                    // Supersede a delayed start before opening the app so it
                    // cannot become a ghost recording without a keyboard.
                    _ = sendCommand(
                        .shutdown,
                        requestID: nil,
                        expectsAcknowledgement: false
                    )
                }
                connectionFailed = true
                stopRequested = false
                if pendingCommand.action == .start {
                    openContainerApp()
                }
            }
        }

        refreshState()
        sendPresenceIfNeeded(force: false)
    }

    private func sendPresenceIfNeeded(force: Bool) {
        guard isKeyboardVisible,
              !connectionFailed,
              let state = snapshot,
              [
                OBIPC.EngineState.preparingModel,
                .arming,
                OBIPC.EngineState.armed,
                .recording,
                .transcribing,
                .result
              ].contains(state.state) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let interval: TimeInterval = state.state == .recording ? 0.45 : 0.75
        guard force || now - lastLeaseUptime >= interval else { return }

        do {
            try mailbox?.writeLease(
                OBIPC.LeaseEnvelope(
                    sessionToken: state.sessionToken,
                    requestID: state.requestID,
                    kind: state.state == .recording ? .recording : .keyboardPresence
                )
            )
            lastLeaseUptime = now
        } catch {
            connectionFailed = true
            setTranscript("Connection lost")
        }
    }

    private func refreshState() {
        guard hasFullAccess else {
            snapshot = nil
            pendingCommand = nil
            requestContext = nil
            pendingResult = nil
            stopRequested = false
            renderNoFullAccess()
            return
        }

        guard let mailbox,
              let newSnapshot = mailbox.readState(),
              newSnapshot.version == OBIPC.protocolVersion else {
            snapshot = nil
            renderUnavailable()
            return
        }

        if lastEngineEpoch != newSnapshot.engineEpoch {
            lastEngineEpoch = newSnapshot.engineEpoch
            pendingCommand = nil
            requestContext = nil
            pendingResult = nil
            insertionRecoveryRequired = false
            locallyHandledResultID = nil
            stopRequested = false
            connectionFailed = false
            lastLeaseUptime = 0
        }

        commandSequence = max(
            commandSequence,
            max(newSnapshot.acknowledgedSequence, mailbox.readCommand()?.sequence ?? 0)
        )

        if let pendingCommand,
           newSnapshot.acknowledgedSequence >= pendingCommand.sequence {
            if !pendingTransitionSucceeded(pendingCommand, in: newSnapshot) {
                connectionFailed = true
            }
            self.pendingCommand = nil
        }

        snapshot = newSnapshot
        if newSnapshot.state == .result {
            handleResult(newSnapshot)
        } else {
            pendingResult = nil
            insertionRecoveryRequired = false
            if let result = mailbox.readResult(),
               !result.isLive()
                || result.createdAt + OBIPC.publicationGrace
                    <= Date().timeIntervalSince1970 {
                mailbox.deleteResult()
            }
            if let receipt = mailbox.readReceipt(), !receipt.isLive() {
                mailbox.deleteReceipt()
            }
        }

        render(newSnapshot)
    }

    private func pendingTransitionSucceeded(
        _ command: PendingCommand,
        in state: OBIPC.EngineSnapshot
    ) -> Bool {
        switch command.action {
        case .start:
            state.requestID == command.requestID
                && [.recording, .transcribing, .result].contains(state.state)
        case .stop:
            state.state != .recording
        case .ackResult:
            state.state != .result || state.requestID != command.requestID
        case .ping, .cancel, .endSession, .shutdown:
            true
        }
    }

    private func renderNoFullAccess() {
        setTranscript("Allow Full Access to use private dictation")
        activityView.isHidden = true
        micButton.isEnabled = false
        setMic(
            symbol: "lock.slash",
            color: .systemGray,
            label: "Dictation requires Full Access"
        )
    }

    private func renderUnavailable() {
        setTranscript(connectionFailed ? "Open Blabber stopped responding" : nil)
        activityView.isHidden = true
        micButton.isEnabled = true
        setMic(
            symbol: "arrow.up.forward.app",
            color: .systemBlue,
            label: "Open Open Blabber",
            hint: "Opens the app to start on-device dictation"
        )
    }

    private func render(_ state: OBIPC.EngineSnapshot) {
        if connectionFailed {
            renderUnavailable()
            return
        }

        switch state.state {
        case .off, .modelReady:
            setTranscript(nil)
            activityView.isHidden = true
            micButton.isEnabled = true
            setMic(
                symbol: "arrow.up.forward.app",
                color: .systemBlue,
                label: "Open Open Blabber",
                hint: "Opens the app to start on-device dictation"
            )

        case .preparingModel, .arming:
            setTranscript("Getting ready…")
            activityView.isHidden = true
            micButton.isEnabled = true
            setMic(
                symbol: "arrow.up.forward.app",
                color: .systemBlue,
                label: "Open Open Blabber",
                hint: "Opens the app to continue getting ready"
            )

        case .armed:
            setTranscript(nil)
            activityView.isHidden = true
            micButton.isEnabled = pendingCommand == nil
            setMic(
                symbol: "mic.fill",
                color: .systemBlue,
                label: "Dictate",
                hint: "Starts private on-device dictation"
            )
            announceOnce(key: "armed-\(state.engineEpoch)", message: "Dictation ready.")

        case .recording:
            setTranscript(state.partialText)
            activityView.isHidden = false
            activityView.setLevel(state.inputLevel ?? 0)
            micButton.isEnabled = pendingCommand == nil && !stopRequested
            setMic(
                symbol: "stop.fill",
                color: .systemRed,
                label: "Stop dictation",
                hint: "Stops listening and inserts the transcription"
            )
            micButton.accessibilityValue = "Listening"
            announceOnce(
                key: "recording-\(state.requestID ?? "")",
                message: "Listening."
            )

        case .transcribing:
            setTranscript(state.partialText)
            activityView.setLevel(0)
            activityView.isHidden = true
            micButton.isEnabled = true
            setMic(
                symbol: "arrow.up.forward.app",
                color: .systemBlue,
                label: "Open Open Blabber",
                hint: "Opens the app to finish dictation"
            )

        case .result:
            activityView.isHidden = true
            activityView.setLevel(0)
            if let pendingResult {
                setTranscript(
                    insertionRecoveryRequired
                        ? "Check the field, then tap to insert again"
                        : pendingResult.text
                )
                micButton.isEnabled = true
                setMic(
                    symbol: "text.badge.plus",
                    color: .systemBlue,
                    label: "Insert transcription",
                    hint: "Inserts the displayed transcription in this field"
                )
            } else if locallyHandledResultID == state.requestID {
                setTranscript(nil)
                micButton.isEnabled = true
                setMic(
                    symbol: "checkmark",
                    color: .systemBlue,
                    label: "Transcription inserted",
                    hint: "Opens Open Blabber if dictation does not become ready"
                )
            } else {
                setTranscript("Open Blabber needs to recover this transcription")
                micButton.isEnabled = true
                setMic(
                    symbol: "arrow.up.forward.app",
                    color: .systemBlue,
                    label: "Open Open Blabber",
                    hint: "Opens the app to recover dictation"
                )
            }

        case .error, .interrupted:
            setTranscript(state.reason ?? "Open Blabber needs attention")
            activityView.isHidden = true
            micButton.isEnabled = true
            setMic(
                symbol: "arrow.up.forward.app",
                color: .systemOrange,
                label: "Open Open Blabber"
            )
        }

        if let pendingCommand {
            switch pendingCommand.action {
            case .start, .stop:
                micButton.isEnabled = false
            case .ping, .cancel, .ackResult, .endSession, .shutdown:
                break
            }
        }
        updateAccessibilityOrder()
    }

    private func setTranscript(_ text: String?) {
        let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptLabel.text = clean?.isEmpty == false ? clean : " "
        transcriptLabel.alpha = clean?.isEmpty == false ? 1 : 0
        transcriptLabel.accessibilityLabel = clean
    }

    private func setMic(
        symbol: String,
        color: UIColor,
        label: String,
        hint: String? = nil
    ) {
        var configuration = micButton.configuration ?? .filled()
        configuration.image = UIImage(systemName: symbol)
        configuration.baseBackgroundColor = color
        configuration.baseForegroundColor = .white
        micButton.configuration = configuration
        micButton.accessibilityLabel = label
        micButton.accessibilityHint = hint
        micButton.accessibilityValue = nil
    }

    private func updateAccessibilityOrder() {
        var elements: [Any] = []
        if transcriptLabel.alpha > 0 {
            elements.append(transcriptLabel)
        }
        elements.append(micButton)
        if !globeButton.isHidden {
            elements.append(globeButton)
        }
        elements.append(deleteButton)
        view.accessibilityElements = elements
    }

    private func handleResult(_ state: OBIPC.EngineSnapshot) {
        let now = Date().timeIntervalSince1970
        guard let mailbox,
              let requestID = state.requestID,
              (state.resultExpiresAt ?? 0) > now else {
            pendingResult = nil
            insertionRecoveryRequired = false
            return
        }

        if let receipt = mailbox.readReceipt() {
            if !receipt.isLive(at: now) || receipt.requestID != requestID {
                mailbox.deleteReceipt()
            } else {
                switch receipt.disposition {
                case .inserting:
                    pendingResult = matchingResult(in: mailbox, state: state, now: now)
                    insertionRecoveryRequired = pendingResult != nil
                    return
                case .inserted, .discarded:
                    locallyHandledResultID = requestID
                    pendingResult = nil
                    mailbox.deleteResult()
                    retryResultAcknowledgement(requestID: requestID)
                    return
                }
            }
        }

        if locallyHandledResultID == requestID {
            pendingResult = nil
            retryResultAcknowledgement(requestID: requestID)
            return
        }

        guard let result = matchingResult(in: mailbox, state: state, now: now) else {
            pendingResult = nil
            return
        }

        let canInsert = OBIPC.mayAutomaticallyInsert(
            resultRequestID: requestID,
            activeRequestID: requestContext?.requestID,
            keyboardIsVisible: isKeyboardVisible,
            sameViewGeneration: requestContext?.viewGeneration == viewGeneration,
            sameDocument: requestContext?.documentID == textDocumentProxy.documentIdentifier,
            sameTextRevision: requestContext?.textRevision == textRevision,
            sameCaret: requestContext?.caretFingerprint == caretFingerprint()
        )

        if canInsert {
            _ = consume(result, insertingAgain: false)
        } else {
            pendingResult = result
            insertionRecoveryRequired = false
            announceOnce(
                key: "pending-\(requestID)",
                message: "Transcription ready. Tap the center button to insert it."
            )
        }
    }

    @discardableResult
    private func consume(
        _ result: OBIPC.ResultEnvelope,
        insertingAgain: Bool
    ) -> Bool {
        let now = Date().timeIntervalSince1970
        guard let mailbox,
              result.isLive(at: now),
              let state = mailbox.readState(),
              state.state == .result,
              state.engineEpoch == result.engineEpoch,
              state.sessionToken == result.sessionToken,
              state.requestID == result.requestID,
              matchingResult(in: mailbox, state: state, now: now) == result else {
            pendingResult = nil
            insertionRecoveryRequired = false
            setTranscript("That transcription is no longer available")
            return false
        }

        if insertingAgain,
           let receipt = mailbox.readReceipt(),
           receipt.requestID == result.requestID,
           receipt.disposition == .inserting,
           !mailbox.deleteReceipt() {
            setTranscript("Check the field before trying again")
            return false
        }

        let claim = OBIPC.HandledResultReceipt(
            requestID: result.requestID,
            ownerToken: instanceToken,
            disposition: .inserting,
            expiresAt: result.expiresAt
        )
        do {
            try mailbox.claimReceipt(claim)
        } catch {
            setTranscript("Check the field before trying again")
            return false
        }

        guard let persisted = mailbox.readReceipt(),
              persisted.ownerToken == instanceToken,
              persisted.disposition == .inserting else {
            return false
        }

        insert(text: result.text)

        do {
            try mailbox.writeReceipt(
                OBIPC.HandledResultReceipt(
                    requestID: result.requestID,
                    ownerToken: instanceToken,
                    disposition: .inserted,
                    expiresAt: result.expiresAt
                )
            )
        } catch {
            pendingResult = result
            insertionRecoveryRequired = true
            setTranscript("Check the field, then tap to insert again")
            return false
        }

        mailbox.deleteResult()
        locallyHandledResultID = result.requestID
        pendingResult = nil
        insertionRecoveryRequired = false
        requestContext = nil
        retryResultAcknowledgement(requestID: result.requestID)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        announceOnce(key: "inserted-\(result.requestID)", message: "Transcription inserted.")
        return true
    }

    private func matchingResult(
        in mailbox: OBIPC.Mailbox,
        state: OBIPC.EngineSnapshot,
        now: TimeInterval
    ) -> OBIPC.ResultEnvelope? {
        guard let result = mailbox.readResult(),
              result.isLive(at: now),
              result.engineEpoch == state.engineEpoch,
              result.sessionToken == state.sessionToken,
              result.requestID == state.requestID else { return nil }
        return result
    }

    private func retryResultAcknowledgement(requestID: String) {
        guard pendingCommand == nil else { return }
        _ = sendCommand(.ackResult, requestID: requestID, expectsAcknowledgement: true)
    }

    private func caretFingerprint() -> Int {
        var hasher = Hasher()
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        let selected = textDocumentProxy.selectedText ?? ""
        hasher.combine(String(before.suffix(24)))
        hasher.combine(String(after.prefix(24)))
        hasher.combine(selected.count)
        hasher.combine(String(selected.prefix(24)))
        return hasher.finalize()
    }

    private func insert(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var insertion = trimmed
        if let before = textDocumentProxy.documentContextBeforeInput?.last,
           !before.isWhitespace,
           !before.isNewline,
           let first = trimmed.first,
           first.isLetter || first.isNumber {
            insertion = " " + insertion
        }
        if let after = textDocumentProxy.documentContextAfterInput?.first,
           !after.isWhitespace,
           !after.isNewline,
           let last = insertion.last,
           (last.isLetter || last.isNumber),
           (after.isLetter || after.isNumber) {
            insertion += " "
        }

        textRevision &+= 1
        textDocumentProxy.insertText(insertion)
    }

    @discardableResult
    private func sendCommand(
        _ action: OBIPC.CommandAction,
        requestID: String?,
        expectsAcknowledgement: Bool
    ) -> Bool {
        guard hasFullAccess,
              let mailbox,
              let state = snapshot ?? mailbox.readState(),
              state.version == OBIPC.protocolVersion else {
            return false
        }

        commandSequence = max(
            commandSequence,
            max(state.acknowledgedSequence, mailbox.readCommand()?.sequence ?? 0)
        )
        commandSequence &+= 1

        do {
            let command = OBIPC.CommandEnvelope(
                sequence: commandSequence,
                sessionToken: state.sessionToken,
                requestID: requestID,
                action: action
            )
            try mailbox.writeCommand(command)
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(OBIPC.commandNotification as CFString),
                nil,
                nil,
                true
            )
            if expectsAcknowledgement {
                pendingCommand = PendingCommand(
                    sequence: command.sequence,
                    action: action,
                    requestID: requestID,
                    deadline: Date().addingTimeInterval(2)
                )
            }
            return true
        } catch {
            connectionFailed = true
            setTranscript("Couldn’t reach Open Blabber")
            return false
        }
    }

    @objc private func micTapped() {
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.prepare()
        feedback.impactOccurred()

        guard hasFullAccess else { return }

        if connectionFailed {
            openContainerApp()
            return
        }

        guard let state = snapshot else {
            openContainerApp()
            return
        }

        switch state.state {
        case .armed:
            let context = RequestContext(
                requestID: UUID().uuidString,
                documentID: textDocumentProxy.documentIdentifier,
                viewGeneration: viewGeneration,
                textRevision: textRevision,
                caretFingerprint: caretFingerprint()
            )
            requestContext = context
            locallyHandledResultID = nil
            stopRequested = false
            if sendCommand(.start, requestID: context.requestID, expectsAcknowledgement: true) {
                micButton.isEnabled = false
            }

        case .recording:
            guard !stopRequested else { return }
            stopRequested = true
            if !sendCommand(
                .stop,
                requestID: requestContext?.requestID ?? state.requestID,
                expectsAcknowledgement: true
            ) {
                stopRequested = false
            }

        case .result:
            if let pendingResult {
                _ = consume(pendingResult, insertingAgain: insertionRecoveryRequired)
            } else {
                openContainerApp()
            }

        case .off, .modelReady, .error, .interrupted:
            openContainerApp()

        case .preparingModel, .arming, .transcribing:
            openContainerApp()
        }
    }

    @objc private func globeTapped(_ sender: UIButton, forEvent event: UIEvent) {
        handleInputModeList(from: sender, with: event)
    }

    @objc private func deleteTouchDown() {
        stopRepeatingDelete()
        deletePreviousCharacter()

        let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startRepeatingDelete()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deleteDelayTimer = timer
    }

    @objc private func deleteTouchEnded() {
        stopRepeatingDelete()
    }

    private func startRepeatingDelete() {
        deleteDelayTimer = nil
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deletePreviousCharacter()
            }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        deleteRepeatTimer = timer
    }

    private func stopRepeatingDelete() {
        deleteDelayTimer?.invalidate()
        deleteDelayTimer = nil
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
    }

    private func deletePreviousCharacter() {
        textRevision &+= 1
        textDocumentProxy.deleteBackward()
        UIDevice.current.playInputClick()
    }

    private func openContainerApp() {
        setTranscript("Opening Open Blabber…")
        isOpeningContainer = true
        isKeyboardVisible = false
        mailbox?.deleteLease()

        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(sessionURL, options: [:]) { [weak self] opened in
                    guard !opened else { return }
                    Task { @MainActor in
                        self?.openThroughExtensionContext()
                    }
                }
                return
            }
            responder = current.next
        }

        openThroughExtensionContext()
    }

    private func openThroughExtensionContext() {
        guard let extensionContext else {
            isOpeningContainer = false
            isKeyboardVisible = true
            setTranscript("Open Open Blabber from the Home Screen")
            sendPresenceIfNeeded(force: true)
            return
        }
        extensionContext.open(sessionURL) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                self?.isOpeningContainer = false
                self?.isKeyboardVisible = true
                self?.setTranscript("Open Open Blabber from the Home Screen")
                self?.sendPresenceIfNeeded(force: true)
            }
        }
    }

    private func announceOnce(key: String, message: String) {
        guard key != lastAnnouncementKey else { return }
        lastAnnouncementKey = key
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
