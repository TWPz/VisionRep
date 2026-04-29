import SwiftUI

struct SkeletonOverlayView: View {
    var pose: PoseFrame?

    var body: some View {
        Canvas { context, size in
            guard let pose else { return }

            for connection in SkeletonConnection.all {
                guard let start = pose.joint(connection.start), let end = pose.joint(connection.end) else {
                    continue
                }

                var path = Path()
                path.move(to: displayPoint(start, in: size))
                path.addLine(to: displayPoint(end, in: size))
                context.stroke(
                    path,
                    with: .color(.mint.opacity(0.78)),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
            }

            for joint in pose.joints.values {
                let point = displayPoint(joint, in: size)
                let radius = CGFloat(max(4, min(8, joint.confidence * 8)))
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)))
                context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.35)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func displayPoint(_ joint: PoseJoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: joint.x * size.width,
            y: (1 - joint.y) * size.height
        )
    }
}

private struct SkeletonConnection {
    var start: PoseJointName
    var end: PoseJointName

    static let all: [SkeletonConnection] = [
        SkeletonConnection(start: .leftShoulder, end: .rightShoulder),
        SkeletonConnection(start: .leftShoulder, end: .leftElbow),
        SkeletonConnection(start: .leftElbow, end: .leftWrist),
        SkeletonConnection(start: .rightShoulder, end: .rightElbow),
        SkeletonConnection(start: .rightElbow, end: .rightWrist),
        SkeletonConnection(start: .leftShoulder, end: .leftHip),
        SkeletonConnection(start: .rightShoulder, end: .rightHip),
        SkeletonConnection(start: .leftHip, end: .rightHip),
        SkeletonConnection(start: .leftHip, end: .leftKnee),
        SkeletonConnection(start: .leftKnee, end: .leftAnkle),
        SkeletonConnection(start: .rightHip, end: .rightKnee),
        SkeletonConnection(start: .rightKnee, end: .rightAnkle),
        SkeletonConnection(start: .nose, end: .neck),
        SkeletonConnection(start: .neck, end: .leftShoulder),
        SkeletonConnection(start: .neck, end: .rightShoulder)
    ]
}
