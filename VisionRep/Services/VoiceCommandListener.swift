import AVFoundation
import Foundation
import Speech

@MainActor
final class VoiceCommandListener {
    enum Command: Hashable {
        case action
        case stop
    }

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isTapInstalled = false
    private var didHandleCommand = false
    private let recognitionTimeoutSeconds: Int64 = 15
    private var timeoutTask: Task<Void, Never>?
    private var voiceSessionID = UUID()

    func start(
        listeningFor allowedCommands: Set<Command>,
        onCommand: @escaping (Command) -> Void,
        onStatus: @escaping (String) -> Void
    ) {
        stop()
        voiceSessionID = UUID()
        let sessionID = voiceSessionID
        didHandleCommand = false

        guard !allowedCommands.isEmpty else {
            onStatus("")
            return
        }

        onStatus("Voice preparing")

        Task { [weak self] in
            guard let self else { return }

            let speechAuthorized = await Self.requestSpeechAuthorization()
            guard self.voiceSessionID == sessionID else { return }
            guard speechAuthorized else {
                onStatus("Speech denied; tap Finish")
                return
            }

            let microphoneAuthorized = await Self.requestMicrophoneAuthorization()
            guard self.voiceSessionID == sessionID else { return }
            guard microphoneAuthorized else {
                onStatus("Mic denied; tap Finish")
                return
            }

            self.startRecognition(
                sessionID: sessionID,
                listeningFor: allowedCommands,
                onCommand: onCommand,
                onStatus: onStatus
            )
        }
    }

    func stop() {
        voiceSessionID = UUID()
        timeoutTask?.cancel()
        timeoutTask = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startRecognition(
        sessionID: UUID,
        listeningFor allowedCommands: Set<Command>,
        onCommand: @escaping (Command) -> Void,
        onStatus: @escaping (String) -> Void
    ) {
        guard voiceSessionID == sessionID else { return }

        guard let recognizer else {
            onStatus("Voice unavailable")
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            onStatus("On-device voice unavailable")
            return
        }

        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            recognitionRequest = request

            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            isTapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    self?.handleRecognitionResult(
                        result,
                        error: error,
                        sessionID: sessionID,
                        listeningFor: allowedCommands,
                        onCommand: onCommand,
                        onStatus: onStatus
                    )
                }
            }

            scheduleRecognitionTimeout(sessionID: sessionID, onStatus: onStatus)
            onStatus(Self.statusText(for: allowedCommands))
        } catch {
            stop()
            onStatus("Voice failed; use button")
        }
    }

    private func scheduleRecognitionTimeout(
        sessionID: UUID,
        onStatus: @escaping (String) -> Void
    ) {
        timeoutTask?.cancel()
        let timeoutSeconds = recognitionTimeoutSeconds
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard let self, self.voiceSessionID == sessionID, !self.didHandleCommand else {
                return
            }
            self.stop()
            onStatus("Voice timed out - use button")
        }
    }

    private func handleRecognitionResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?,
        sessionID: UUID,
        listeningFor allowedCommands: Set<Command>,
        onCommand: @escaping (Command) -> Void,
        onStatus: @escaping (String) -> Void
    ) {
        guard voiceSessionID == sessionID else { return }

        if let result {
            let transcript = result.bestTranscription.formattedString
            if let command = Self.command(in: transcript, allowedCommands: allowedCommands), !didHandleCommand {
                didHandleCommand = true
                onStatus(Self.heardText(for: command))
                stop()
                onCommand(command)
                return
            }
        }

        if error != nil, !didHandleCommand {
            stop()
            onStatus("Voice paused; use button")
        }
    }

    private static func command(in transcript: String, allowedCommands: Set<Command>) -> Command? {
        if allowedCommands.contains(.action), containsActionCommand(in: transcript) {
            return .action
        }

        if allowedCommands.contains(.stop), containsStopCommand(in: transcript) {
            return .stop
        }

        return nil
    }

    private static func containsActionCommand(in transcript: String) -> Bool {
        commandWords(in: transcript).contains("action")
    }

    private static func containsStopCommand(in transcript: String) -> Bool {
        commandWords(in: transcript).contains("stop")
    }

    private static func commandWords(in transcript: String) -> [String] {
        let words = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
        return words
    }

    private static func statusText(for commands: Set<Command>) -> String {
        if commands == [.action] {
            return "Say action"
        }

        if commands == [.stop] {
            return "Say stop"
        }

        return "Say action or stop"
    }

    private static func heardText(for command: Command) -> String {
        switch command {
        case .action:
            "Action heard"
        case .stop:
            "Stop heard"
        }
    }

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
