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

                centerContent
                    .padding(.horizontal, 20)

                Spacer(minLength: 18)

                controlDock
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("VisionRep")
                    .font(.title3.weight(.semibold))
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 12)

            QualityBadge(quality: model.poseQuality)
        }
        .padding(14)
        .visionGlassPanel(cornerRadius: 24, tint: .white.opacity(0.08))
    }

    private var centerReadout: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(model.repetitionCount)")
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("reps")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                MetricChip(title: "Templates", value: "\(model.templates.count)/5", systemImage: "figure.run")
                MetricChip(title: "Match", value: model.matchConfidence.formatted(.percent.precision(.fractionLength(0))), systemImage: "waveform.path.ecg")
                MetricChip(title: "Frames", value: "\(model.activeCaptureFrameCount)", systemImage: "timer")
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .visionGlassPanel(cornerRadius: 28, tint: .black.opacity(0.08))
    }

    @ViewBuilder
    private var centerContent: some View {
        if shouldShowCenterReadout {
            centerReadout
        } else {
            trainingReadout
        }
    }

    private var shouldShowCenterReadout: Bool {
        model.mode == .counting && model.templates.count >= 3
    }

    private var trainingReadout: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.mixed.cardio")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.mint)

            Text("Train Movement")
                .font(.title2.weight(.semibold))

            Text("\(min(model.templates.count, 3)) of 3 successful reps")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)

            ProgressView(value: Double(min(model.templates.count, 3)), total: 3)
                .tint(.mint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .visionGlassPanel(cornerRadius: 28, tint: .black.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Train movement, \(min(model.templates.count, 3)) of 3 successful reps")
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

            if model.mode == .templatesReady, model.templates.count < 5 {
                GlassActionButton(title: "Record Another Template", systemImage: "plus.circle") {
                    model.recordAdditionalTemplate()
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
            model.templates.count >= 3 ? "play.fill" : "record.circle"
        }
    }

    private var primaryActionEnabled: Bool {
        switch model.mode {
        case .setup, .recordingTemplate, .counting:
            true
        case .cameraReady:
            model.canRecordTemplate
        case .templatesReady:
            model.templates.count >= 3 || model.canRecordTemplate
        }
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
