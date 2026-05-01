@preconcurrency import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class WorkoutSessionModel {
    enum Mode: Equatable {
        case setup
        case cameraReady
        case recordingTemplate(Int)
        case templatesReady
        case counting
    }

    let camera = CameraFrameSource()

    var cameraState: CameraState = .idle
    var mode: Mode = .setup
    var latestPose: PoseFrame?
    var poseQuality = PoseQuality(trackedJointRatio: 0, requiredJointRatio: 0, averageConfidence: 0)
    var templates: [MovementTemplate] = []
    var activeCaptureFrameCount = 0
    var repetitionCount = 0
    var matchConfidence = 0.0
    var latestMatcherScore = Double.infinity
    var trainingCountdownRemaining: Int?
    var countingCountdownRemaining: Int?
    var voiceCommandStatus = ""
    var statusMessage = "Start the camera and keep your full body in frame."
    var cameraFramingMode: CameraFramingMode = .widestView

    @ObservationIgnored private let frameBridge = PoseProcessingBridge()
    @ObservationIgnored private let templateBuilder = FewShotRepetitionCounter()
    @ObservationIgnored private let liveRepetitionCounter = LiveRepetitionCounterBridge()
    @ObservationIgnored private let profileStore = ExerciseProfileStore()
    @ObservationIgnored private let voiceCommandListener = VoiceCommandListener()
    @ObservationIgnored private var activeCaptureFrames: [PoseFrame] = []
    @ObservationIgnored private var activeCaptureQualityScores: [Double] = []
    @ObservationIgnored private var trainingCountdownTask: Task<Void, Never>?
    @ObservationIgnored private var countingCountdownTask: Task<Void, Never>?
    @ObservationIgnored private var isTemplateCaptureActive = false
    @ObservationIgnored private var isLiveCountingActive = false

    init() {
        templates = profileStore.loadTemplates()
        templateBuilder.load(templates: templates)
        liveRepetitionCounter.load(templates: templates)
        if !templates.isEmpty {
            statusMessage = "Loaded \(templates.count) local templates. Start the camera to count live."
        }

        frameBridge.onResult = { [weak self] result in
            self?.handle(result)
        }
        liveRepetitionCounter.onUpdate = { [weak self] update, quality in
            self?.handleLiveCountUpdate(update, quality: quality)
        }
        camera.frameHandler = { [frameBridge] sampleBuffer in
            frameBridge.process(sampleBuffer)
        }
    }

    var captureSession: AVCaptureSession {
        camera.session
    }

    var canRecordTemplate: Bool {
        switch mode {
        case .cameraReady, .templatesReady:
            // poseQuality.score >= 0.58 // blocked for initial run low accuracy needed
            poseQuality.score >= 0.47
        default:
            false
        }
    }

    var canStartCounting: Bool {
        templates.count >= 3
    }

    var primaryActionTitle: String {
        switch mode {
        case .setup:
            "Start Camera"
        case .cameraReady, .templatesReady:
            templates.count >= 5 ? "Count Live" : "Record Rep"
        case .recordingTemplate:
            if let trainingCountdownRemaining {
                "Starting in \(trainingCountdownRemaining)"
            } else {
                "Finish Rep"
            }
        case .counting:
            if let countingCountdownRemaining {
                "Starting in \(countingCountdownRemaining)"
            } else {
                "Pause"
            }
        }
    }

    func performPrimaryAction() {
        switch mode {
        case .setup:
            startCamera()
        case .cameraReady, .templatesReady:
            if templates.count >= 5 {
                startCounting()
            } else {
                beginTemplateRecording()
            }
        case .recordingTemplate:
            finishTemplateRecording()
        case .counting:
            pauseCounting()
        }
    }

    func startCamera() {
        camera.requestAccessAndConfigure { [weak self] state in
            Task { @MainActor in
                self?.applyCameraState(state)
            }
        }
    }

    func toggleCameraFramingMode() {
        let nextMode: CameraFramingMode = cameraFramingMode == .centerStageTracking ? .widestView : .centerStageTracking
        cameraFramingMode = nextMode
        statusMessage = "Switching camera framing..."

        camera.setFramingMode(nextMode) { [weak self] state in
            Task { @MainActor in
                self?.applyCameraFramingState(state, mode: nextMode)
            }
        }
    }

    func beginTemplateRecording() {
        guard cameraState == .running else {
            statusMessage = "Start the camera before recording a training rep."
            return
        }

        activeCaptureFrames.removeAll(keepingCapacity: true)
        activeCaptureQualityScores.removeAll(keepingCapacity: true)
        activeCaptureFrameCount = 0
        isTemplateCaptureActive = false
        stopCountingCountdown()
        isLiveCountingActive = false
        mode = .recordingTemplate(templates.count + 1)
        startVoiceCommands(listeningFor: [.stop])
        startTrainingCountdown()
    }

    func finishTemplateRecording() {
        guard case .recordingTemplate(let index) = mode else { return }
        stopTrainingCountdown()
        stopVoiceCommands()
        isTemplateCaptureActive = false

        let averageQuality = activeCaptureQualityScores.average
        guard let template = templateBuilder.makeTemplate(
            index: index,
            frames: activeCaptureFrames,
            averageQuality: averageQuality
        ) else {
            activeCaptureFrames.removeAll(keepingCapacity: true)
            activeCaptureQualityScores.removeAll(keepingCapacity: true)
            activeCaptureFrameCount = 0
            mode = templates.isEmpty ? .cameraReady : .templatesReady
            statusMessage = "That rep was too short or unclear. Try one slower, full-body rep."
            refreshVoiceCommandsForCurrentMode()
            return
        }

        templates.append(template)
        profileStore.save(templates)
        activeCaptureFrames.removeAll(keepingCapacity: true)
        activeCaptureQualityScores.removeAll(keepingCapacity: true)
        activeCaptureFrameCount = 0
        templateBuilder.load(templates: templates)
        liveRepetitionCounter.load(templates: templates)
        trainingCountdownRemaining = nil

        mode = templates.count >= 3 ? .templatesReady : .cameraReady
        statusMessage = trainingProgressMessage
        refreshVoiceCommandsForCurrentMode()
    }

    func recordAdditionalTemplate() {
        guard templates.count < 5, mode == .templatesReady else { return }
        beginTemplateRecording()
    }

    func startCountingFromTemplates() {
        startCounting()
    }

    func startCounting() {
        guard templates.count >= 3 else {
            statusMessage = "Record at least 3 templates before live counting."
            return
        }

        liveRepetitionCounter.load(templates: templates)
        repetitionCount = 0
        matchConfidence = 0
        latestMatcherScore = .infinity
        stopTrainingCountdown()
        stopVoiceCommands()
        isLiveCountingActive = false
        mode = .counting
        startCountingCountdown()
    }

    func pauseCounting() {
        stopCountingCountdown()
        isLiveCountingActive = false
        liveRepetitionCounter.clearOnlineTemplates()
        mode = .templatesReady
        statusMessage = "Counting paused. Templates remain on this device."
        refreshVoiceCommandsForCurrentMode()
    }

    func resetCalibration() {
        templates.removeAll()
        profileStore.deleteTemplates()
        stopTrainingCountdown()
        stopCountingCountdown()
        stopVoiceCommands()
        isTemplateCaptureActive = false
        isLiveCountingActive = false
        activeCaptureFrames.removeAll()
        activeCaptureQualityScores.removeAll()
        activeCaptureFrameCount = 0
        liveRepetitionCounter.clearOnlineTemplates()
        templateBuilder.load(templates: [])
        liveRepetitionCounter.load(templates: [])
        repetitionCount = 0
        matchConfidence = 0
        latestMatcherScore = .infinity
        trainingCountdownRemaining = nil
        countingCountdownRemaining = nil
        mode = cameraState == .running ? .cameraReady : .setup
        statusMessage = "Calibration reset. Record 3 to 5 clean reps."
        refreshVoiceCommandsForCurrentMode()
    }

    private func handle(_ result: PoseProcessingResult) {
        switch result {
        case .pose(let displayFrame, let normalizedFrame, let quality):
            latestPose = displayFrame
            poseQuality = quality
            ingest(normalizedFrame, quality: quality)
        case .noPose:
            latestPose = nil
            poseQuality = PoseQuality(trackedJointRatio: 0, requiredJointRatio: 0, averageConfidence: 0)
            if trainingCountdownRemaining == nil, countingCountdownRemaining == nil {
                updateStatus("No body detected. Step into frame.")
            }
        case .skipped:
            break
        case .failed(let message):
            updateStatus("Pose detection failed: \(message)")
        }
    }

    private func updateStatus(_ message: String) {
        guard statusMessage != message else { return }
        statusMessage = message
    }

    private func applyCameraState(_ state: CameraState) {
        cameraState = state

        switch state {
        case .idle:
            camera.start()
            cameraState = .running
            mode = templates.isEmpty ? .cameraReady : .templatesReady
            statusMessage = "Camera is live. Record 3 to 5 clean full-body reps."
        case .configuring:
            statusMessage = "Preparing the camera..."
        case .needsPermission:
            statusMessage = "Camera permission is required for on-device rep counting."
        case .failed(let message):
            statusMessage = message
        case .running:
            statusMessage = "Camera is live."
        }

        refreshVoiceCommandsForCurrentMode()
    }

    private func applyCameraFramingState(_ state: CameraState, mode: CameraFramingMode) {
        cameraState = state

        switch state {
        case .configuring:
            statusMessage = "Switching camera framing..."
        case .idle:
            statusMessage = mode.readyMessage
        case .running:
            statusMessage = mode.readyMessage
        case .needsPermission:
            statusMessage = "Camera permission is required for on-device rep counting."
        case .failed(let message):
            statusMessage = message
        }
    }

    private func ingest(_ frame: PoseFrame, quality: PoseQuality) {
        switch mode {
        case .recordingTemplate:
            guard isTemplateCaptureActive else {
                return
            }
            guard quality.score >= 0.48 else {
                updateStatus(quality.guidance)
                return
            }
            activeCaptureFrames.append(frame)
            activeCaptureQualityScores.append(quality.score)
            activeCaptureFrameCount = activeCaptureFrames.count
        case .counting:
            guard isLiveCountingActive else {
                return
            }
            liveRepetitionCounter.submit(frame, quality: quality)
        default:
            if quality.score < 0.58 {
                updateStatus(quality.guidance)
            }
        }
    }

    private func handleLiveCountUpdate(_ update: CountUpdate, quality: PoseQuality) {
        guard mode == .counting, isLiveCountingActive else {
            return
        }

        repetitionCount = update.repetitions
        matchConfidence = update.confidence
        latestMatcherScore = update.bestScore
        if update.confidence > 0.72 {
            updateStatus("Movement matched template \(update.matchedTemplateIndex ?? 0).")
        } else if quality.score < 0.58 {
            updateStatus(quality.guidance)
        } else {
            updateStatus("Track the full recorded movement path.")
        }
    }

    private func startTrainingCountdown() {
        stopTrainingCountdown()
        trainingCountdownTask = Task { @MainActor [weak self] in
            for remaining in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.trainingCountdownRemaining = remaining
                self.statusMessage = "Get ready. Recording starts in \(remaining)."
                try? await Task.sleep(for: .seconds(1))
            }

            guard let self, !Task.isCancelled else { return }
            self.trainingCountdownRemaining = nil
            self.isTemplateCaptureActive = true
            self.activeCaptureFrameCount = 0
            self.statusMessage = "Recording now. Say stop or tap Finish Rep."
        }
    }

    private func stopTrainingCountdown() {
        trainingCountdownTask?.cancel()
        trainingCountdownTask = nil
        trainingCountdownRemaining = nil
    }

    private func startCountingCountdown() {
        stopCountingCountdown()
        countingCountdownTask = Task { @MainActor [weak self] in
            for remaining in stride(from: 5, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.countingCountdownRemaining = remaining
                self.statusMessage = "Get ready. Counting starts in \(remaining)."
                try? await Task.sleep(for: .seconds(1))
            }

            guard let self, !Task.isCancelled else { return }
            self.countingCountdownRemaining = nil
            self.isLiveCountingActive = true
            self.liveRepetitionCounter.resetCount()
            self.repetitionCount = 0
            self.matchConfidence = 0
            self.latestMatcherScore = .infinity
            self.statusMessage = "Counting live. Complete the same movement path you recorded."
        }
    }

    private func stopCountingCountdown() {
        countingCountdownTask?.cancel()
        countingCountdownTask = nil
        countingCountdownRemaining = nil
    }

    private func startVoiceCommands(listeningFor allowedCommands: Set<VoiceCommandListener.Command>) {
        voiceCommandStatus = "Voice preparing"
        voiceCommandListener.start(listeningFor: allowedCommands) { [weak self] command in
            self?.handleVoiceCommand(command)
        } onStatus: { [weak self] status in
            self?.voiceCommandStatus = status
        }
    }

    private func stopVoiceCommands() {
        voiceCommandListener.stop()
        voiceCommandStatus = ""
    }

    private func refreshVoiceCommandsForCurrentMode() {
        guard cameraState == .running else {
            stopVoiceCommands()
            return
        }

        switch mode {
        case .cameraReady where templates.count < 5,
             .templatesReady where templates.count < 5:
            startVoiceCommands(listeningFor: [.action])
        case .recordingTemplate:
            startVoiceCommands(listeningFor: [.stop])
        case .setup, .cameraReady, .templatesReady, .counting:
            stopVoiceCommands()
        }
    }

    private func handleVoiceCommand(_ command: VoiceCommandListener.Command) {
        switch command {
        case .action:
            guard templates.count < 5 else {
                voiceCommandStatus = "Action ignored"
                return
            }

            switch mode {
            case .cameraReady, .templatesReady:
                beginTemplateRecording()
            case .setup, .recordingTemplate, .counting:
                voiceCommandStatus = "Action ignored"
            }
        case .stop:
            guard case .recordingTemplate = mode else {
                voiceCommandStatus = "Stop ignored"
                refreshVoiceCommandsForCurrentMode()
                return
            }
            guard isTemplateCaptureActive else {
                voiceCommandStatus = "Stop ignored until recording"
                return
            }
            finishTemplateRecording()
        }
    }

    private var trainingProgressMessage: String {
        switch templates.count {
        case 0..<3:
            "Template saved. Record \(3 - templates.count) more."
        case 3..<5:
            "Template saved. Continue to 5 reps or start counting live."
        default:
            "All 5 templates captured. Start counting live."
        }
    }
}

private nonisolated final class PoseProcessingBridge: @unchecked Sendable {
    var onResult: ((PoseProcessingResult) -> Void)?

    private let processor = PoseFrameProcessor()

    func process(_ sampleBuffer: CMSampleBuffer) {
        let result = processor.process(sampleBuffer)
        guard case .skipped = result else {
            DispatchQueue.main.async { [weak self] in
                self?.onResult?(result)
            }
            return
        }
    }
}

private extension Array where Element == Double {
    var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}

private extension CameraFramingMode {
    var readyMessage: String {
        switch self {
        case .centerStageTracking:
            "Center Stage tracking is on. Use it when you want the camera to follow you."
        case .widestView:
            "Wide view is on. Use it when you need the maximum front camera field of view."
        }
    }
}
