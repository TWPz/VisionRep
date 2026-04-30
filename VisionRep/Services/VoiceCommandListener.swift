import AVFoundation
import Speech

@MainActor
final class VoiceCommandListener {
    enum Command {
        case stop
    }

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isTapInstalled = false
    private var didHandleStop = false

    func start(
        onCommand: @escaping (Command) -> Void,
        onStatus: @escaping (String) -> Void
    ) {
        stop()
        didHandleStop = false
        onStatus("Voice preparing")

        Task { [weak self] in
            guard let self else { return }

            guard await Self.requestSpeechAuthorization() else {
                onStatus("Speech denied; tap Finish")
                return
            }

            guard await Self.requestMicrophoneAuthorization() else {
                onStatus("Mic denied; tap Finish")
                return
            }

            self.startRecognition(onCommand: onCommand, onStatus: onStatus)
        }
    }

    func stop() {
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
        onCommand: @escaping (Command) -> Void,
        onStatus: @escaping (String) -> Void
    ) {
        guard let recognizer else {
            onStatus("Voice unavailable; tap Finish")
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
                        onCommand: onCommand,
                        onStatus: onStatus
                    )
                }
            }

            onStatus("Say stop")
        } catch {
            stop()
            onStatus("Voice failed; tap Finish")
        }
    }

    private func handleRecognitionResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?,
        onCommand: @escaping (Command) -> Void,
        onStatus: @escaping (String) -> Void
    ) {
        if let result {
            let transcript = result.bestTranscription.formattedString
            if Self.containsStopCommand(in: transcript), !didHandleStop {
                didHandleStop = true
                onStatus("Stop heard")
                onCommand(.stop)
                stop()
                return
            }
        }

        if error != nil, !didHandleStop {
            stop()
            onStatus("Voice paused; tap Finish")
        }
    }

    private static func containsStopCommand(in transcript: String) -> Bool {
        let words = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
        return words.contains("stop")
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
