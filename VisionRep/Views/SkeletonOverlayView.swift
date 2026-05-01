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

            for connection in SkeletonConnection.all {
                guard let start = pose.joint(connection.start),
                      let end = pose.joint(connection.end),
                      start.confidence >= minimumJointConfidence,
                      end.confidence >= minimumJointConfidence
                else {
                    continue
                }

                let startPoint = aspectFillPoint(start, in: size)
                let endPoint = aspectFillPoint(end, in: size)
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
                let point = aspectFillPoint(joint, in: size)
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

    private func aspectFillPoint(_ joint: PoseJoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0, sourceAspectRatio > 0 else {
            return .zero
        }

        let previewPoint = previewNormalizedPoint(from: joint)
        let normalizedX = CGFloat(previewPoint.x)
        let normalizedY = CGFloat(1 - previewPoint.y)
        let viewAspectRatio = size.width / size.height

        if viewAspectRatio > sourceAspectRatio {
            let drawnHeight = size.width / sourceAspectRatio
            let yOffset = (size.height - drawnHeight) / 2
            return CGPoint(x: normalizedX * size.width, y: yOffset + (normalizedY * drawnHeight))
        } else {
            let drawnWidth = size.height * sourceAspectRatio
            let xOffset = (size.width - drawnWidth) / 2
            return CGPoint(x: xOffset + (normalizedX * drawnWidth), y: normalizedY * size.height)
        }
    }

    private func previewNormalizedPoint(from joint: PoseJoint) -> CGPoint {
        let rotatedPoint: CGPoint
        if rotatesLandscapeSourceToPortrait {
            rotatedPoint = CGPoint(x: 1 - joint.y, y: joint.x)
        } else {
            rotatedPoint = CGPoint(x: joint.x, y: joint.y)
        }

        guard mirrorsFrontCameraPreview else { return rotatedPoint }
        return CGPoint(x: 1 - rotatedPoint.x, y: rotatedPoint.y)
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
