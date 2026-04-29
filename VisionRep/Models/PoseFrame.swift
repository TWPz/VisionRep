import CoreGraphics
import Foundation

nonisolated enum PoseJointName: String, CaseIterable, Identifiable, Codable, Sendable {
    case nose
    case neck
    case root
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle

    var id: String { rawValue }
}

nonisolated struct PoseJoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var confidence: Double

    var point: CGPoint {
        CGPoint(x: x, y: y)
    }
}

nonisolated struct PoseFrame: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var timestamp: TimeInterval
    var joints: [PoseJointName: PoseJoint]

    var trackedJointRatio: Double {
        guard !PoseJointName.allCases.isEmpty else { return 0 }
        return Double(joints.count) / Double(PoseJointName.allCases.count)
    }

    func joint(_ name: PoseJointName) -> PoseJoint? {
        joints[name]
    }
}

nonisolated struct PoseQuality: Equatable, Sendable {
    var trackedJointRatio: Double
    var requiredJointRatio: Double
    var averageConfidence: Double

    var score: Double {
        (trackedJointRatio * 0.3) + (requiredJointRatio * 0.5) + (averageConfidence * 0.2)
    }

    var label: String {
        switch score {
        case 0.78...:
            "Ready"
        case 0.58..<0.78:
            "Adjust"
        default:
            "Poor"
        }
    }

    var guidance: String {
        switch score {
        case 0.78...:
            "Full body visible"
        case 0.58..<0.78:
            "Keep wrists, hips, knees, and ankles visible"
        default:
            "Step back and improve lighting"
        }
    }
}

nonisolated enum PoseFrameFactory {
    static let requiredJoints: Set<PoseJointName> = [
        .leftShoulder,
        .rightShoulder,
        .leftWrist,
        .rightWrist,
        .leftHip,
        .rightHip,
        .leftKnee,
        .rightKnee,
        .leftAnkle,
        .rightAnkle
    ]

    static func quality(for frame: PoseFrame?) -> PoseQuality {
        guard let frame else {
            return PoseQuality(trackedJointRatio: 0, requiredJointRatio: 0, averageConfidence: 0)
        }

        let requiredCount = requiredJoints.filter { frame.joints[$0] != nil }.count
        let requiredRatio = Double(requiredCount) / Double(requiredJoints.count)
        let confidence = frame.joints.values.map(\.confidence).average

        return PoseQuality(
            trackedJointRatio: frame.trackedJointRatio,
            requiredJointRatio: requiredRatio,
            averageConfidence: confidence
        )
    }

    static func normalized(_ frame: PoseFrame) -> PoseFrame {
        let leftHip = frame.joint(.leftHip)
        let rightHip = frame.joint(.rightHip)
        let root = frame.joint(.root)

        let centerX = root?.x ?? [leftHip?.x, rightHip?.x].compactMap { $0 }.average
        let centerY = root?.y ?? [leftHip?.y, rightHip?.y].compactMap { $0 }.average

        let shoulderWidth = distance(frame.joint(.leftShoulder), frame.joint(.rightShoulder))
        let hipWidth = distance(leftHip, rightHip)
        let torsoHeight = distance(average(frame.joint(.leftShoulder), frame.joint(.rightShoulder)), average(leftHip, rightHip))
        let scale = max(shoulderWidth, hipWidth, torsoHeight, 0.12)

        let joints = frame.joints.mapValues { joint in
            PoseJoint(
                x: (joint.x - centerX) / scale,
                y: (joint.y - centerY) / scale,
                confidence: joint.confidence
            )
        }

        return PoseFrame(timestamp: frame.timestamp, joints: joints)
    }

    private static func distance(_ first: PoseJoint?, _ second: PoseJoint?) -> Double {
        guard let first, let second else { return 0 }
        return hypot(first.x - second.x, first.y - second.y)
    }

    private static func average(_ first: PoseJoint?, _ second: PoseJoint?) -> PoseJoint? {
        guard let first, let second else { return first ?? second }
        return PoseJoint(
            x: (first.x + second.x) / 2,
            y: (first.y + second.y) / 2,
            confidence: min(first.confidence, second.confidence)
        )
    }
}

private extension Array where Element == Double {
    nonisolated var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
