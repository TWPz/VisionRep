import SwiftUI

struct WorkoutDashboardView: View {
    @Bindable var model: WorkoutSessionModel

    var body: some View {
        ZStack {
            cameraLayer

            SkeletonOverlayView(pose: model.latestPose)
                .ignoresSafeArea()

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
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("VisionRep (Codex)")
                        .font(.title3.weight(.semibold))
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    QualityBadge(quality: model.poseQuality)

                    CameraFramingToggleButton(mode: model.cameraFramingMode) {
                        model.toggleCameraFramingMode()
                    }
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
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(model.repetitionCount)")
                    .font(.system(size: 112, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("reps")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Confidence \(model.matchConfidence, format: .percent.precision(.fractionLength(0)))")
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 24)
        .visionGlassPanel(cornerRadius: 28, tint: .black.opacity(0.08))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live count \(model.repetitionCount) reps, confidence \(Int(model.matchConfidence * 100)) percent")
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
                    model.performPrimaryAction()
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
        GlassActionButton(title: "Count Live", systemImage: "play.fill", action: action)
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

private struct CameraFramingToggleButton: View {
    var mode: CameraFramingMode
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: mode.systemImage)
                    .font(.subheadline.weight(.bold))
                Text(mode.shortTitle)
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(width: 54, height: 48)
            .visionGlassPanel(cornerRadius: 16, tint: .white.opacity(0.1), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.accessibilityLabel)
        .accessibilityHint("Switch camera framing")
    }
}

private struct QualityBadge: View {
    var quality: PoseQuality

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(quality.label)
                .font(.subheadline.weight(.bold))
            Text(quality.score.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
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

private extension CameraFramingMode {
    var shortTitle: String {
        switch self {
        case .centerStageTracking:
            "Track"
        case .widestView:
            "Wide"
        }
    }

    var systemImage: String {
        switch self {
        case .centerStageTracking:
            "dot.viewfinder"
        case .widestView:
            "arrow.up.left.and.arrow.down.right"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .centerStageTracking:
            "Center Stage tracking on"
        case .widestView:
            "Widest camera view on"
        }
    }
}

private struct MetricChip: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .visionGlassPanel(cornerRadius: 18, tint: .white.opacity(0.05))
        .accessibilityElement(children: .combine)
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
                    .font(.title2.weight(.semibold))
                Text("All pose estimation runs on this device. Video frames are used only for live tracking.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .padding(24)
            .visionGlassPanel(cornerRadius: 28)
        }
    }
}
