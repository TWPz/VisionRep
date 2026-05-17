import AudioToolbox
import SwiftUI
import UIKit

struct WorkoutDashboardView: View {
    @Bindable var model: WorkoutSessionModel

    var body: some View {
        ZStack {
            cameraLayer

            SkeletonOverlayLayer(model: model)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Spacer(minLength: 20)

                if shouldShowCenterReadout {
                    centerReadout
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 18)

                controlDock
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }

            countdownOverlay
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .task {
            LiveCountButtonFeedback.prepare()
            if case .setup = model.mode {
                model.startCamera()
            }
        }
    }

    private var cameraLayer: some View {
        Group {
            switch model.cameraState {
            case .running, .idle, .configuring:
                CameraPreview(session: model.captureSession)
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(model.cameraState == .running ? 0.05 : 0.6))
            case .needsPermission:
                PermissionPlaceholderView()
            case .failed:
                PermissionPlaceholderView(systemImage: "video.slash", title: "Camera Unavailable")
            }
        }
    }

    @ViewBuilder
    private var topBar: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                topBarContent
            }
        } else {
            topBarContent
        }
    }

    private var topBarContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MPiPE")
                        .font(.title3.weight(.semibold))
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    QualityBadge(quality: model.poseQuality)
                    HeatWatchBadge(status: model.heatStatus)
                    FPSDebugBadge(
                        cameraFramesPerSecond: model.debugCameraFramesPerSecond,
                        poseFramesPerSecond: model.debugPoseFramesPerSecond,
                        uiFramesPerSecond: model.debugUIDeliveryFramesPerSecond,
                        repetitionFramesPerSecond: model.debugRepetitionFramesPerSecond
                    )
                }
            }

            if shouldShowTrainingStatus {
                SlimTrainingStatus(
                    completedCount: model.templates.count,
                    activeFrameCount: model.activeCaptureFrameCount,
                    isRecording: isRecordingTemplate,
                    voiceCommandStatus: model.voiceCommandStatus
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .visionGlassPanel(cornerRadius: 24, tint: .white.opacity(0.08))
    }

    private var centerReadout: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(model.displayedRepetitionCount)")
                    .font(.system(size: 112, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .opacity(model.isRepetitionConfirmationPending ? 0.72 : 1)
                Text("reps")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            PhasePathProgressBar(
                phasePathProgress: model.movementPhaseProgress,
                matchConfidence: model.matchConfidence,
                isPendingCompletion: model.isRepetitionConfirmationPending
            )
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 24)
        .visionGlassPanel(cornerRadius: 28, tint: .black.opacity(0.08))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live count \(model.displayedRepetitionCount) reps, confidence \(Int(model.matchConfidence * 100)) percent, phase \(Int(model.movementPhaseProgress * 100)) percent")
    }

    private var shouldShowCenterReadout: Bool {
        model.mode == .counting && model.templates.count >= 3 && model.countingCountdownRemaining == nil
    }

    private var shouldShowTrainingStatus: Bool {
        switch model.mode {
        case .recordingTemplate:
            model.trainingCountdownRemaining == nil
        case .cameraReady:
            model.templates.count < 5
        case .templatesReady:
            model.templates.count < 5
        case .setup, .counting:
            false
        }
    }

    @ViewBuilder
    private var countdownOverlay: some View {
        if let countdownRemaining {
            CenterTrainingCountdownView(remaining: countdownRemaining)
                .padding(.horizontal, 32)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                .animation(.snappy(duration: 0.22), value: countdownRemaining)
                .accessibilitySortPriority(10)
        }
    }

    private var countdownRemaining: Int? {
        model.countingCountdownRemaining ?? model.trainingCountdownRemaining
    }

    private var isRecordingTemplate: Bool {
        if case .recordingTemplate = model.mode {
            return true
        }
        return false
    }

    private var controlDock: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                GlassActionButton(
                    title: model.primaryActionTitle,
                    systemImage: primaryActionIcon,
                    isProminent: true
                ) {
                    performPrimaryAction()
                }
                .disabled(!primaryActionEnabled)

                Button {
                    model.resetCalibration()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title3.weight(.semibold))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Reset calibration")
            }

            if model.templates.count >= 3 && model.templates.count < 5 && model.mode == .templatesReady {
                LiveCountButton {
                    model.startCountingFromTemplates()
                }
            }

            TemplateStrip(templates: model.templates, activeFrameCount: model.activeCaptureFrameCount, mode: model.mode)
        }
        .padding(14)
        .visionGlassPanel(cornerRadius: 28, tint: .white.opacity(0.08), interactive: true)
    }

    private func performPrimaryAction() {
        if model.primaryActionTitle == "Count Live" {
            LiveCountButtonFeedback.play()
        }
        model.performPrimaryAction()
    }

    private var primaryActionIcon: String {
        switch model.mode {
        case .setup:
            "camera.fill"
        case .recordingTemplate:
            "checkmark.circle.fill"
        case .counting:
            "pause.fill"
        case .cameraReady, .templatesReady:
            model.templates.count >= 5 ? "play.fill" : "record.circle"
        }
    }

    private var primaryActionEnabled: Bool {
        switch model.mode {
        case .setup, .counting:
            model.countingCountdownRemaining == nil
        case .recordingTemplate:
            model.trainingCountdownRemaining == nil
        case .cameraReady, .templatesReady:
            true
        }
    }
}

private struct SlimTrainingStatus: View {
    var completedCount: Int
    var activeFrameCount: Int
    var isRecording: Bool
    var voiceCommandStatus: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.caption.weight(.bold))
                .foregroundStyle(iconColor)
                .frame(width: 18)

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            ProgressView(value: Double(completedCount), total: 5)
                .tint(.mint)
                .frame(maxWidth: 96)

            Text(statusText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Train movement, \(completedCount) of 5 successful reps")
    }

    private var iconName: String {
        if isRecording {
            "record.circle.fill"
        } else {
            "figure.mixed.cardio"
        }
    }

    private var iconColor: Color {
        if isRecording {
            .red
        } else {
            .mint
        }
    }

    private var title: String {
        "Train Movement"
    }

    private var statusText: String {
        if isRecording {
            let voiceText = voiceCommandStatus.isEmpty ? "say stop" : voiceCommandStatus.lowercased()
            return "\(activeFrameCount) frames - \(voiceText)"
        } else {
            let voiceText = voiceCommandStatus.isEmpty ? "say action" : voiceCommandStatus.lowercased()
            return "\(completedCount)/5 reps - \(voiceText)"
        }
    }
}

private struct LiveCountButton: View {
    var action: () -> Void

    var body: some View {
        GlassActionButton(title: "Count Live", systemImage: "play.fill", action: performAction)
    }

    private func performAction() {
        LiveCountButtonFeedback.play()
        action()
    }
}

private enum LiveCountButtonFeedback {
    private static let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let startSoundID: SystemSoundID = 1104

    static func prepare() {
        impactGenerator.prepare()
    }

    static func play() {
        impactGenerator.impactOccurred(intensity: 0.85)
        AudioServicesPlaySystemSound(LiveCountButtonFeedback.startSoundID)
        impactGenerator.prepare()
    }
}

private struct CenterTrainingCountdownView: View {
    var remaining: Int

    var body: some View {
        VStack(spacing: 8) {
            Text("\(remaining)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text("Get ready")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 190, height: 190)
        .visionGlassPanel(cornerRadius: 32, tint: .black.opacity(0.16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording starts in \(remaining)")
    }
}

private struct PhasePathProgressBar: View {
    var phasePathProgress: Double
    var matchConfidence: Double
    var isPendingCompletion: Bool

    private var clampedProgress: Double {
        min(max(phasePathProgress, 0), 1)
    }

    private var clampedConfidence: Double {
        min(max(matchConfidence, 0), 1)
    }

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.16))

                    Capsule()
                        .fill(progressTint)
                        .frame(width: max(8, width * clampedProgress))

                    HStack(spacing: 0) {
                        ForEach(1..<4, id: \.self) { index in
                            Spacer()
                            Rectangle()
                                .fill(.black.opacity(0.28))
                                .frame(width: 1, height: 18)
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .frame(width: 184, height: 18)
            .animation(.snappy(duration: 0.18), value: clampedProgress)

            HStack(spacing: 12) {
                Text("Rep path \(clampedProgress, format: .percent.precision(.fractionLength(0)))")
                Text("Match \(clampedConfidence, format: .percent.precision(.fractionLength(0)))")
            }
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rep path \(Int(clampedProgress * 100)) percent, match \(Int(clampedConfidence * 100)) percent")
    }

    private var progressTint: Color {
        if isPendingCompletion || clampedProgress >= 0.9 {
            return .mint
        }
        if clampedProgress >= 0.5 {
            return .cyan
        }
        return .white.opacity(0.72)
    }
}

private struct QualityBadge: View {
    var quality: PoseQuality

    var body: some View {
        VStack(spacing: 4) {
            Text(quality.label)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(quality.score.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 66, height: 62)
        .visionGlassPanel(cornerRadius: 18, tint: badgeColor.opacity(0.2))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pose quality \(quality.label), \(Int(quality.score * 100)) percent")
    }

    private var badgeColor: Color {
        switch quality.score {
        case 0.78...:
            .green
        case 0.58..<0.78:
            .yellow
        default:
            .red
        }
    }
}

private struct HeatWatchBadge: View {
    var status: HeatStatus

    var body: some View {
        VStack(spacing: 4) {
            Text("Heat")
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(status.stateLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(width: 66, height: 62)
        .visionGlassPanel(cornerRadius: 18, tint: tint.opacity(0.22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thermal state \(status.stateLabel)")
    }

    private var tint: Color {
        switch status.thermalState {
        case .nominal:
            .green
        case .fair:
            .yellow
        case .serious:
            .orange
        case .critical:
            .red
        @unknown default:
            .gray
        }
    }
}

private struct FPSDebugBadge: View {
    var cameraFramesPerSecond: Double
    var poseFramesPerSecond: Double
    var uiFramesPerSecond: Double
    var repetitionFramesPerSecond: Double

    var body: some View {
        let cameraFPS = Int(cameraFramesPerSecond.rounded())
        let poseFPS = Int(poseFramesPerSecond.rounded())
        let uiFPS = Int(uiFramesPerSecond.rounded())
        let repetitionFPS = Int(repetitionFramesPerSecond.rounded())
        let cameraText = cameraFPS > 0 ? "\(cameraFPS)" : "--"
        let poseText = poseFPS > 0 ? "\(poseFPS)" : "--"
        let uiText = uiFPS > 0 ? "\(uiFPS)" : "--"
        let repetitionText = repetitionFPS > 0 ? "\(repetitionFPS)" : "--"

        VStack(spacing: 4) {
            Text("FPS")
                .font(.subheadline.weight(.bold))
            Text("C\(cameraText) P\(poseText)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Text("U\(uiText) R\(repetitionText)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 104, height: 62)
        .visionGlassPanel(cornerRadius: 18, tint: Color.cyan.opacity(0.22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Actual camera \(cameraText) frames per second, pose \(poseText) frames per second, UI \(uiText) frames per second, repetition counter \(repetitionText) frames per second")
    }
}

private struct SkeletonOverlayLayer: View {
    @Bindable var model: WorkoutSessionModel
    private static let skeletonOverlayFramesPerSecond: Double = 12

    var body: some View {
        SkeletonOverlayView(
            pose: model.latestPose,
            sourceAspectRatio: 3.0 / 4.0,
            renderFramesPerSecond: Self.skeletonOverlayFramesPerSecond
        )
        .ignoresSafeArea()
    }
}

private struct TemplateStrip: View {
    var templates: [MovementTemplate]
    var activeFrameCount: Int
    var mode: WorkoutSessionModel.Mode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { index in
                TemplateDot(
                    index: index,
                    state: state(for: index)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Templates recorded \(templates.count) of 5")
    }

    private func state(for index: Int) -> TemplateDot.State {
        if case .recordingTemplate(let activeIndex) = mode, activeIndex == index {
            return .recording(activeFrameCount)
        }
        return templates.contains { $0.index == index } ? .complete : .empty
    }
}

private struct TemplateDot: View {
    enum State: Equatable {
        case empty
        case recording(Int)
        case complete
    }

    var index: Int
    var state: State

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(fill)
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)

            Text(label)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var fill: Color {
        switch state {
        case .complete:
            .green.opacity(0.82)
        case .recording:
            .red.opacity(0.86)
        case .empty:
            .white.opacity(0.16)
        }
    }

    private var symbol: String {
        switch state {
        case .complete:
            "checkmark"
        case .recording:
            "record.circle"
        case .empty:
            "\(index).circle"
        }
    }

    private var label: String {
        switch state {
        case .recording(let frames):
            "\(frames)"
        default:
            "Rep \(index)"
        }
    }
}

private struct PermissionPlaceholderView: View {
    var systemImage = "camera.fill"
    var title = "Camera Needed"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}
