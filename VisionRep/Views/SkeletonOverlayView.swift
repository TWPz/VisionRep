import SwiftUI

struct SkeletonOverlayView: View {
    var pose: PoseFrame?
    var sourceAspectRatio: CGFloat = 9.0 / 16.0
    var rotatesLandscapeSourceToPortrait = true
    var mirrorsFrontCameraPreview = true

    private let minimumJointConfidence = 0.12

    var body: some View {
        Canvas { context, size in
            guard let pose else { return }
            let layout = AspectFillLayout(size: size, sourceAspectRatio: sourceAspectRatio)

            for connection in SkeletonConnection.all {
                guard let start = pose.joint(connection.start),
                      let end = pose.joint(connection.end),
                      start.confidence >= minimumJointConfidence,
                      end.confidence >= minimumJointConfidence
                else {
                    continue
                }

                let startPoint = layout.point(for: start, rotation: rotatesLandscapeSourceToPortrait, mirrored: mirrorsFrontCameraPreview)
                let endPoint = layout.point(for: end, rotation: rotatesLandscapeSourceToPortrait, mirrored: mirrorsFrontCameraPreview)
                guard isDrawable(startPoint, in: size), isDrawable(endPoint, in: size) else {
                    continue
                }

                var path = Path()
                path.move(to: startPoint)
                path.addLine(to: endPoint)
                context.stroke(
                    path,
                    with: .color(connection.group.color.opacity(0.82)),
                    style: StrokeStyle(lineWidth: lineWidth(in: size), lineCap: .round, lineJoin: .round)
                )
            }

            for (jointName, joint) in pose.joints where joint.confidence >= minimumJointConfidence {
                let point = layout.point(for: joint, rotation: rotatesLandscapeSourceToPortrait, mirrored: mirrorsFrontCameraPreview)
                guard isDrawable(point, in: size) else { continue }

                let radius = jointRadius(in: size, confidence: joint.confidence)
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(SkeletonConnection.group(for: jointName).color.opacity(0.9)))
                context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.35)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct AspectFillLayout {
        let usesHeightConstraint: Bool
        let drawnDimension: CGFloat
        let xOffset: CGFloat
        let yOffset: CGFloat
        let size: CGSize

        init(size: CGSize, sourceAspectRatio: CGFloat) {
            self.size = size
            let viewAspectRatio = size.width / size.height
            if viewAspectRatio > sourceAspectRatio {
                usesHeightConstraint = true
                drawnDimension = size.width / sourceAspectRatio
                xOffset = 0
                yOffset = (size.height - drawnDimension) / 2
            } else {
                usesHeightConstraint = false
                drawnDimension = size.height * sourceAspectRatio
                xOffset = (size.width - drawnDimension) / 2
                yOffset = 0
            }
        }

        func point(for joint: PoseJoint, rotation: Bool, mirrored: Bool) -> CGPoint {
            var previewX: CGFloat
            var previewY: CGFloat
            if rotation {
                (previewX, previewY) = (1 - CGFloat(joint.y), CGFloat(joint.x))
            } else {
                (previewX, previewY) = (CGFloat(joint.x), CGFloat(joint.y))
            }
            if mirrored {
                previewX = 1 - previewX
            }

            let normalizedX = previewX
            let normalizedY = 1 - previewY
            if usesHeightConstraint {
                return CGPoint(x: normalizedX * size.width, y: yOffset + normalizedY * drawnDimension)
            } else {
                return CGPoint(x: xOffset + normalizedX * drawnDimension, y: normalizedY * size.height)
            }
        }
    }

    private func isDrawable(_ point: CGPoint, in size: CGSize) -> Bool {
        let padding = max(lineWidth(in: size) * 3, 18)
        return point.x >= -padding
            && point.x <= size.width + padding
            && point.y >= -padding
            && point.y <= size.height + padding
    }

    private func lineWidth(in size: CGSize) -> CGFloat {
        max(2.5, min(5, size.width * 0.008))
    }

    private func jointRadius(in size: CGSize, confidence: Double) -> CGFloat {
        let baseRadius = max(3.5, min(7, size.width * 0.012))
        return baseRadius * max(0.75, min(1.25, CGFloat(confidence) + 0.25))
    }
}

private struct SkeletonConnection {
    var start: PoseJointName
    var end: PoseJointName
    var group: SkeletonGroup

    static let all: [SkeletonConnection] = [
        SkeletonConnection(start: .nose, end: .neck, group: .head),
        SkeletonConnection(start: .neck, end: .leftShoulder, group: .torso),
        SkeletonConnection(start: .neck, end: .rightShoulder, group: .torso),
        SkeletonConnection(start: .leftShoulder, end: .rightShoulder, group: .torso),
        SkeletonConnection(start: .leftShoulder, end: .leftHip, group: .torso),
        SkeletonConnection(start: .rightShoulder, end: .rightHip, group: .torso),
        SkeletonConnection(start: .leftHip, end: .rightHip, group: .torso),
        SkeletonConnection(start: .leftShoulder, end: .leftElbow, group: .arms),
        SkeletonConnection(start: .leftElbow, end: .leftWrist, group: .arms),
        SkeletonConnection(start: .rightShoulder, end: .rightElbow, group: .arms),
        SkeletonConnection(start: .rightElbow, end: .rightWrist, group: .arms),
        SkeletonConnection(start: .leftHip, end: .leftKnee, group: .legs),
        SkeletonConnection(start: .leftKnee, end: .leftAnkle, group: .legs),
        SkeletonConnection(start: .rightHip, end: .rightKnee, group: .legs),
        SkeletonConnection(start: .rightKnee, end: .rightAnkle, group: .legs)
    ]

    static func group(for joint: PoseJointName) -> SkeletonGroup {
        switch joint {
        case .nose, .neck:
            .head
        case .leftShoulder, .rightShoulder, .leftHip, .rightHip, .root:
            .torso
        case .leftElbow, .rightElbow, .leftWrist, .rightWrist:
            .arms
        case .leftKnee, .rightKnee, .leftAnkle, .rightAnkle:
            .legs
        }
    }
}

private enum SkeletonGroup {
    case head, torso, arms, legs

    var color: Color {
        switch self {
        case .head:
            Color(red: 0.22, green: 0.56, blue: 1.0)
        case .torso:
            Color(red: 1.0, green: 0.64, blue: 0.24)
        case .arms:
            Color(red: 0.22, green: 0.86, blue: 0.52)
        case .legs:
            Color(red: 1.0, green: 0.36, blue: 0.62)
        }
    }
}
