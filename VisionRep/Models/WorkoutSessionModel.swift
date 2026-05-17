@preconcurrency import AVFoundation
import Foundation
import Observation

nonisolated struct HeatStatus: Equatable, Sendable {
    var thermalState: ProcessInfo.ThermalState

    static func current() -> HeatStatus {
        HeatStatus(thermalState: ProcessInfo.processInfo.thermalState)
    }

    var stateLabel: String {
        switch thermalState {
        case .nominal:
            "Normal"
        case .fair:
            "Fair"
        case .serious:
            "Hot"
        case .critical:
            "Critical"
        @unknown default:
            "Unknown"
        }
    }
}

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

    private enum PoseRuntimeProfile {
        case ready
        case active

        var poseFramesPerSecond: Double {
            switch self {
            case .ready:
                8
            case .active:
                24
            }
        }

        var cameraFramesPerSecond: Double {
            switch self {
            case .ready:
                12
            case .active:
                24
            }
        }

        var cameraCaptureProfile: CameraCaptureProfile {
            switch self {
            case .ready:
                .ready
            case .active:
                .active
            }
        }
    }

    let camera = CameraFrameSource()

    var cameraState: CameraState = .idle
    var mode: Mode = .setup
    var latestPose: PoseFrame?
    var poseQuality = PoseQuality(trackedJointRatio: 0, requiredJointRatio: 0, averageConfidence: 0)
    var templates: [MovementTemplate] = []
    var activeCaptureFrameCount = 0
    var repetitionCount = 0
    var displayedRepetitionCount = 0
    var isRepetitionConfirmationPending = false
    var movementPhaseProgress = 0.0
    var matchConfidence = 0.0
    var trainingCountdownRemaining: Int?
    var countingCountdownRemaining: Int?
    var voiceCommandStatus = ""
    var statusMessage = "Start the camera and keep your full body in frame."
    var heatStatus = HeatStatus.current()
    var debugCameraFramesPerSecond = 0.0
    var debugPoseFramesPerSecond = 0.0
    var debugUIDeliveryFramesPerSecond = 0.0
    var debugRepetitionFramesPerSecond = 0.0

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
    @ObservationIgnored private var lastLiveViewPoseUpdateTime: TimeInterval = -.infinity
    @ObservationIgnored private var lastPoseQualityUpdateTime: TimeInterval = -.infinity
    @ObservationIgnored private var lastActiveCaptureFrameCountUpdateTime: TimeInterval = -.infinity
    @ObservationIgnored private var lastLiveCountStatusUpdateTime: TimeInterval = -.infinity
    @ObservationIgnored private var liveViewFrameRateWindowStartTime: TimeInterval?
    @ObservationIgnored private var liveViewFrameRateWindowFrameCount = 0
    @ObservationIgnored private var latestMatcherScore = Double.infinity

    private var liveViewPoseUpdateInterval: TimeInterval {
        targetLiveViewPoseUpdateInterval
    }

    private var targetLiveViewPoseUpdateInterval: TimeInterval {
        switch mode {
        case .recordingTemplate, .counting:
            1.0 / 12.0
        case .setup, .cameraReady, .templatesReady:
            1.0 / 8.0
        }
    }
    private let poseQualityUpdateInterval: TimeInterval = 1.0 / 4.0
    private let activeCaptureFrameCountDisplayInterval: TimeInterval = 1.0 / 4.0
    private let liveCountStatusUpdateInterval: TimeInterval = 1.0 / 2.0
    private let minimumTrainingFrameQuality = 0.30
    private let idealTrainingFrameQuality = 0.58
    private let minimumTemplateFrameCount = 20

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
        frameBridge.onTargetFramesPerSecondChange = { [weak self] framesPerSecond in
            self?.handlePoseFrameRateChange(framesPerSecond)
        }
        frameBridge.onActualFramesPerSecondChange = { [weak self] framesPerSecond in
            self?.handleActualPoseFrameRateChange(framesPerSecond)
        }
        liveRepetitionCounter.onUpdate = { [weak self] update, quality in
            self?.handleLiveCountUpdate(update, quality: quality)
        }
        liveRepetitionCounter.onActualFramesPerSecondChange = { [weak self] framesPerSecond in
            DispatchQueue.main.async {
                self?.handleActualRepetitionFrameRateChange(framesPerSecond)
            }
        }
        camera.onThermalStateChange = { [weak self] thermalState in
            DispatchQueue.main.async {
                self?.updateHeatStatus(thermalState)
            }
        }
        camera.onActualFramesPerSecondChange = { [weak self] framesPerSecond in
            DispatchQueue.main.async {
                self?.handleActualCameraFrameRateChange(framesPerSecond)
            }
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
        applyRuntimeProfile(.ready)
        camera.requestAccessAndConfigure { [weak self] state in
            Task { @MainActor in
                self?.applyCameraState(state)
            }
        }
    }

    func beginTemplateRecording() {
        guard cameraState == .running else {
            statusMessage = "Start the camera before recording a training rep."
            return
        }

        applyRuntimeProfile(.active)
        activeCaptureFrames.removeAll(keepingCapacity: true)
        activeCaptureQualityScores.removeAll(keepingCapacity: true)
        activeCaptureFrameCount = 0
        lastActiveCaptureFrameCountUpdateTime = -.infinity
        isTemplateCaptureActive = false
        stopCountingCountdown()
        isLiveCountingActive = false
        debugRepetitionFramesPerSecond = 0
        mode = .recordingTemplate(templates.count + 1)
        startVoiceCommands(listeningFor: [.stop])
        startTrainingCountdown()
    }

    func finishTemplateRecording(triggeredByVoice: Bool = false) {
        guard case .recordingTemplate(let index) = mode else { return }
        if triggeredByVoice, activeCaptureFrames.count < minimumTemplateFrameCount {
            voiceCommandStatus = "Keep recording - finish the full rep"
            startVoiceCommands(listeningFor: [.stop])
            return
        }

        stopTrainingCountdown()
        stopVoiceCommands()
        isTemplateCaptureActive = false

        let averageQuality = activeCaptureQualityScores.average
        guard activeCaptureFrames.count >= minimumTemplateFrameCount,
              let template = templateBuilder.makeTemplate(
                  index: index,
                  frames: activeCaptureFrames,
                  averageQuality: averageQuality
              )
        else {
            activeCaptureFrames.removeAll(keepingCapacity: true)
            activeCaptureQualityScores.removeAll(keepingCapacity: true)
            activeCaptureFrameCount = 0
            lastActiveCaptureFrameCountUpdateTime = -.infinity
            mode = templates.isEmpty ? .cameraReady : .templatesReady
            applyRuntimeProfile(.ready)
            statusMessage = "That rep was too short or unclear. Try one slower, full-body rep."
            refreshVoiceCommandsForCurrentMode()
            return
        }

        templates.append(template)
        let didSaveTemplates = profileStore.save(templates)
        activeCaptureFrames.removeAll(keepingCapacity: true)
        activeCaptureQualityScores.removeAll(keepingCapacity: true)
        activeCaptureFrameCount = 0
        lastActiveCaptureFrameCountUpdateTime = -.infinity
        templateBuilder.load(templates: templates)
        liveRepetitionCounter.load(templates: templates)
        trainingCountdownRemaining = nil

        mode = templates.count >= 3 ? .templatesReady : .cameraReady
        applyRuntimeProfile(.ready)
        statusMessage = didSaveTemplates ? trainingProgressMessage : "Template save failed - check device storage."
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

        applyRuntimeProfile(.active)
        liveRepetitionCounter.load(templates: templates)
        repetitionCount = 0
        displayedRepetitionCount = 0
        isRepetitionConfirmationPending = false
        movementPhaseProgress = 0
        matchConfidence = 0
        latestMatcherScore = .infinity
        lastLiveCountStatusUpdateTime = -.infinity
        resetLiveViewFrameRateWindow()
        debugRepetitionFramesPerSecond = 0
        stopTrainingCountdown()
        stopVoiceCommands()
        isLiveCountingActive = false
        mode = .counting
        startCountingCountdown()
    }

    func pauseCounting() {
        stopCountingCountdown()
        isLiveCountingActive = false
        debugRepetitionFramesPerSecond = 0
        liveRepetitionCounter.clearOnlineTemplates()
        mode = .templatesReady
        applyRuntimeProfile(.ready)
        isRepetitionConfirmationPending = false
        movementPhaseProgress = 0
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
        lastActiveCaptureFrameCountUpdateTime = -.infinity
        liveRepetitionCounter.clearOnlineTemplates()
        templateBuilder.load(templates: [])
        liveRepetitionCounter.load(templates: [])
        repetitionCount = 0
        displayedRepetitionCount = 0
        isRepetitionConfirmationPending = false
        movementPhaseProgress = 0
        matchConfidence = 0
        latestMatcherScore = .infinity
        resetDebugFrameRates()
        trainingCountdownRemaining = nil
        countingCountdownRemaining = nil
        mode = cameraState == .running ? .cameraReady : .setup
        applyRuntimeProfile(.ready)
        statusMessage = "Calibration reset. Record 3 to 5 clean reps."
        refreshVoiceCommandsForCurrentMode()
    }

    private func handle(_ result: PoseProcessingResult) {
        switch result {
        case .pose(let displayFrame, let normalizedFrame, let quality):
            updateLiveViewPose(displayFrame, quality: quality)
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

    private func updateLiveViewPose(_ pose: PoseFrame, quality: PoseQuality) {
        let now = Date().timeIntervalSince1970
        if now - lastLiveViewPoseUpdateTime >= liveViewPoseUpdateInterval {
            lastLiveViewPoseUpdateTime = now
            latestPose = pose
            recordLiveViewFrameRate(now: now)
        }

        updateDisplayedPoseQuality(quality, now: now)
    }

    private func updateDisplayedPoseQuality(_ quality: PoseQuality, now: TimeInterval) {
        guard now - lastPoseQualityUpdateTime >= poseQualityUpdateInterval || quality.label != poseQuality.label else {
            return
        }

        lastPoseQualityUpdateTime = now
        poseQuality = quality
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
            applyRuntimeProfile(.ready)
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

    private func ingest(_ frame: PoseFrame, quality: PoseQuality) {
        switch mode {
        case .recordingTemplate:
            guard isTemplateCaptureActive else {
                return
            }
            guard quality.score >= minimumTrainingFrameQuality else {
                updateStatus(quality.guidance)
                return
            }
            activeCaptureFrames.append(frame)
            activeCaptureQualityScores.append(quality.score)
            updateDisplayedActiveCaptureFrameCount(frameCount: activeCaptureFrames.count, timestamp: frame.timestamp)
            if quality.score < idealTrainingFrameQuality {
                updateStatus(quality.guidance)
            }
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

        let didCountNewRepetition = updateLiveCountDisplay(update)
        updateLiveCountStatus(update, quality: quality, force: didCountNewRepetition)
    }

    private func updateLiveCountDisplay(_ update: CountUpdate) -> Bool {
        let previousRepetitionCount = repetitionCount
        let nextDisplayedRepetitionCount = update.repetitions
        let roundedProgress = (update.phaseProgress * 100).rounded() / 100

        if repetitionCount != update.repetitions {
            repetitionCount = update.repetitions
        }
        if displayedRepetitionCount != nextDisplayedRepetitionCount {
            displayedRepetitionCount = nextDisplayedRepetitionCount
        }
        if isRepetitionConfirmationPending != update.pendingRepetition {
            isRepetitionConfirmationPending = update.pendingRepetition
        }
        if abs(movementPhaseProgress - roundedProgress) >= 0.01 {
            movementPhaseProgress = roundedProgress
        }
        if abs(matchConfidence - update.confidence) >= 0.01 {
            matchConfidence = update.confidence
        }
        if latestMatcherScore != update.bestScore {
            latestMatcherScore = update.bestScore
        }

        return update.repetitions > previousRepetitionCount
    }

    private func updateLiveCountStatus(_ update: CountUpdate, quality: PoseQuality, force: Bool) {
        let now = Date().timeIntervalSince1970
        guard force || now - lastLiveCountStatusUpdateTime >= liveCountStatusUpdateInterval else {
            return
        }

        lastLiveCountStatusUpdateTime = now
        if update.didCalibrateView {
            updateStatus("View calibrated. Keep the camera placement steady.")
        } else if update.confidence > 0.72 {
            updateStatus("Movement matched template \(update.matchedTemplateIndex ?? 0).")
        } else if quality.score < 0.58 {
            updateStatus(quality.guidance)
        } else {
            updateStatus("Track the full recorded movement path.")
        }
    }

    private func updateDisplayedActiveCaptureFrameCount(frameCount: Int, timestamp: TimeInterval) {
        let shouldUpdate = timestamp - lastActiveCaptureFrameCountUpdateTime >= activeCaptureFrameCountDisplayInterval
        let displayedCount = shouldUpdate ? frameCount : activeCaptureFrameCount
        guard activeCaptureFrameCount != displayedCount else { return }

        activeCaptureFrameCount = displayedCount
        if shouldUpdate {
            lastActiveCaptureFrameCountUpdateTime = timestamp
        }
    }

    private func applyRuntimeProfile(_ profile: PoseRuntimeProfile) {
        let poseFramesPerSecond = effectivePoseFramesPerSecond(for: profile)
        let cameraFramesPerSecond = effectiveCameraFramesPerSecond(
            for: profile,
            poseFramesPerSecond: poseFramesPerSecond
        )

        camera.setCaptureProfile(.adaptive(cameraFramesPerSecond))
        frameBridge.setTargetFramesPerSecond(poseFramesPerSecond)
    }

    private func effectivePoseFramesPerSecond(for profile: PoseRuntimeProfile) -> Double {
        switch heatStatus.thermalState {
        case .nominal:
            return profile.poseFramesPerSecond
        case .fair:
            return min(profile.poseFramesPerSecond, 20)
        case .serious:
            return min(profile.poseFramesPerSecond, 15)
        case .critical:
            return min(profile.poseFramesPerSecond, 8)
        @unknown default:
            return min(profile.poseFramesPerSecond, 12)
        }
    }

    private func effectiveCameraFramesPerSecond(
        for profile: PoseRuntimeProfile,
        poseFramesPerSecond: Double
    ) -> Double {
        switch profile {
        case .ready:
            return min(profile.cameraFramesPerSecond, max(poseFramesPerSecond, 12))
        case .active:
            return poseFramesPerSecond
        }
    }

    private func currentRuntimeProfile() -> PoseRuntimeProfile {
        switch mode {
        case .recordingTemplate, .counting:
            .active
        case .setup, .cameraReady, .templatesReady:
            .ready
        }
    }

    private func reapplyRuntimeProfileForThermalState() {
        applyRuntimeProfile(currentRuntimeProfile())
    }

    private func handlePoseFrameRateChange(_ framesPerSecond: Double) {
        switch mode {
        case .recordingTemplate, .counting:
            break
        case .setup, .cameraReady, .templatesReady:
            return
        }

        camera.setCaptureProfile(.adaptive(framesPerSecond))
    }

    private func handleActualCameraFrameRateChange(_ framesPerSecond: Double) {
        debugCameraFramesPerSecond = framesPerSecond
    }

    private func handleActualPoseFrameRateChange(_ framesPerSecond: Double) {
        debugPoseFramesPerSecond = framesPerSecond
    }

    private func handleActualRepetitionFrameRateChange(_ framesPerSecond: Double) {
        guard mode == .counting, isLiveCountingActive else {
            debugRepetitionFramesPerSecond = 0
            return
        }
        debugRepetitionFramesPerSecond = framesPerSecond
    }

    private func resetDebugFrameRates() {
        debugCameraFramesPerSecond = 0
        debugPoseFramesPerSecond = 0
        debugUIDeliveryFramesPerSecond = 0
        debugRepetitionFramesPerSecond = 0
        resetLiveViewFrameRateWindow()
    }

    private func resetLiveViewFrameRateWindow() {
        liveViewFrameRateWindowStartTime = nil
        liveViewFrameRateWindowFrameCount = 0
    }

    private func recordLiveViewFrameRate(now: TimeInterval) {
        guard let windowStartTime = liveViewFrameRateWindowStartTime else {
            liveViewFrameRateWindowStartTime = now
            liveViewFrameRateWindowFrameCount = 0
            return
        }

        liveViewFrameRateWindowFrameCount += 1
        let elapsed = now - windowStartTime
        guard elapsed >= 1 else { return }

        debugUIDeliveryFramesPerSecond = Double(liveViewFrameRateWindowFrameCount) / elapsed
        liveViewFrameRateWindowStartTime = now
        liveViewFrameRateWindowFrameCount = 0
    }

    private func updateHeatStatus(_ thermalState: ProcessInfo.ThermalState) {
        let nextStatus = HeatStatus(thermalState: thermalState)
        guard heatStatus != nextStatus else { return }
        heatStatus = nextStatus
        reapplyRuntimeProfileForThermalState()
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
            self.lastActiveCaptureFrameCountUpdateTime = -.infinity
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
            self.displayedRepetitionCount = 0
            self.isRepetitionConfirmationPending = false
            self.movementPhaseProgress = 0
            self.matchConfidence = 0
            self.latestMatcherScore = .infinity
            self.lastLiveCountStatusUpdateTime = -.infinity
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
            finishTemplateRecording(triggeredByVoice: true)
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
    var onTargetFramesPerSecondChange: ((Double) -> Void)?
    var onActualFramesPerSecondChange: ((Double) -> Void)?

    private let processingQueue = DispatchQueue(label: "com.visionrep.pose.processing", qos: .userInitiated)
    private let stateLock = NSLock()
    private var processor: PoseFrameProcessor?
    private var latestSampleBuffer: CMSampleBuffer?
    private var isProcessing = false
    private var targetFramesPerSecond: Double = 8
    private var actualFrameRateWindowStartTime: TimeInterval?
    private var actualFrameRateWindowFrameCount = 0

    init() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            let processor = PoseFrameProcessor(targetFramesPerSecond: targetFramesPerSecond)
            processor.onTargetFramesPerSecondChange = { [weak self] framesPerSecond in
                DispatchQueue.main.async {
                    self?.onTargetFramesPerSecondChange?(framesPerSecond)
                }
            }
            self.stateLock.lock()
            self.processor = processor
            self.stateLock.unlock()
        }
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        latestSampleBuffer = sampleBuffer
        guard !isProcessing else {
            stateLock.unlock()
            return
        }
        isProcessing = true
        stateLock.unlock()

        processingQueue.async { [weak self] in
            self?.processLatestFrames()
        }
    }

    func setTargetFramesPerSecond(_ targetFramesPerSecond: Double) {
        stateLock.lock()
        self.targetFramesPerSecond = targetFramesPerSecond
        resetActualFrameRateWindow()
        stateLock.unlock()

        processingQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let processor = self.processor
            self.stateLock.unlock()
            processor?.setTargetFramesPerSecond(targetFramesPerSecond)
        }
    }

    private func resetActualFrameRateWindow() {
        actualFrameRateWindowStartTime = nil
        actualFrameRateWindowFrameCount = 0
        DispatchQueue.main.async { [weak self] in
            self?.onActualFramesPerSecondChange?(0)
        }
    }

    private func processLatestFrames() {
        stateLock.lock()
        guard let sampleBuffer = latestSampleBuffer else {
            isProcessing = false
            stateLock.unlock()
            return
        }
        latestSampleBuffer = nil
        let processor = processor
        stateLock.unlock()

        guard let processor else {
            stateLock.lock()
            isProcessing = false
            stateLock.unlock()
            return
        }

        let result = processor.process(sampleBuffer)
        if case .skipped = result {
            stateLock.lock()
            latestSampleBuffer = nil
            isProcessing = false
            stateLock.unlock()
            return
        }

        recordActualPoseFrameRate()
        DispatchQueue.main.async { [weak self] in
            self?.onResult?(result)
        }

        processLatestFrames()
    }

    private func recordActualPoseFrameRate() {
        let now = Date().timeIntervalSince1970
        guard let windowStartTime = actualFrameRateWindowStartTime else {
            actualFrameRateWindowStartTime = now
            actualFrameRateWindowFrameCount = 0
            return
        }

        actualFrameRateWindowFrameCount += 1
        let elapsed = now - windowStartTime
        guard elapsed >= 1 else { return }

        let framesPerSecond = Double(actualFrameRateWindowFrameCount) / elapsed
        actualFrameRateWindowStartTime = now
        actualFrameRateWindowFrameCount = 0
        DispatchQueue.main.async { [weak self] in
            self?.onActualFramesPerSecondChange?(framesPerSecond)
        }
    }
}

private extension Array where Element == Double {
    var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
