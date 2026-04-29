@preconcurrency import AVFoundation
import Foundation
import ImageIO
@preconcurrency import Vision

nonisolated enum PoseProcessingResult: Sendable {
    case pose(displayFrame: PoseFrame, normalizedFrame: PoseFrame, quality: PoseQuality)
    case noPose(TimeInterval)
    case skipped
    case failed(String)
}

nonisolated final class PoseFrameProcessor {
    private let request = VNDetectHumanBodyPoseRequest()
    private var lastProcessedTimestamp: TimeInterval = 0
    private let minimumFrameInterval: TimeInterval
    private let minimumJointConfidence: VNConfidence = 0.12

    init(targetFramesPerSecond: Double = 15) {
        minimumFrameInterval = 1 / targetFramesPerSecond
    }

    func process(_ sampleBuffer: CMSampleBuffer) -> PoseProcessingResult {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp - lastProcessedTimestamp >= minimumFrameInterval else {
            return .skipped
        }
        lastProcessedTimestamp = timestamp

        do {
            let handler = VNImageRequestHandler(
                cmSampleBuffer: sampleBuffer,
                orientation: .upMirrored,
                options: [:]
            )
            try handler.perform([request])

            guard let observation = request.results?.max(by: { area(of: $0) < area(of: $1) }) else {
                return .noPose(timestamp)
            }

            let frame = try makeFrame(from: observation, timestamp: timestamp)
            let normalized = PoseFrameFactory.normalized(frame)
            let quality = PoseFrameFactory.quality(for: frame)
            return .pose(displayFrame: frame, normalizedFrame: normalized, quality: quality)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func makeFrame(from observation: VNHumanBodyPoseObservation, timestamp: TimeInterval) throws -> PoseFrame {
        let recognizedPoints = try observation.recognizedPoints(.all)
        var joints: [PoseJointName: PoseJoint] = [:]

        for name in PoseJointName.allCases {
            guard let point = recognizedPoints[name.visionJointName], point.confidence >= minimumJointConfidence else {
                continue
            }

            joints[name] = PoseJoint(
                x: point.location.x,
                y: point.location.y,
                confidence: Double(point.confidence)
            )
        }

        return PoseFrame(timestamp: timestamp, joints: joints)
    }

    private func area(of observation: VNHumanBodyPoseObservation) -> Double {
        guard let points = try? observation.recognizedPoints(.all).values.filter({ $0.confidence >= minimumJointConfidence }),
              !points.isEmpty
        else {
            return 0
        }

        let xs = points.map(\.location.x)
        let ys = points.map(\.location.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return 0
        }

        return Double((maxX - minX) * (maxY - minY))
    }
}

private extension PoseJointName {
    nonisolated var visionJointName: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose:
            .nose
        case .neck:
            .neck
        case .root:
            .root
        case .leftShoulder:
            .leftShoulder
        case .rightShoulder:
            .rightShoulder
        case .leftElbow:
            .leftElbow
        case .rightElbow:
            .rightElbow
        case .leftWrist:
            .leftWrist
        case .rightWrist:
            .rightWrist
        case .leftHip:
            .leftHip
        case .rightHip:
            .rightHip
        case .leftKnee:
            .leftKnee
        case .rightKnee:
            .rightKnee
        case .leftAnkle:
            .leftAnkle
        case .rightAnkle:
            .rightAnkle
        }
    }
}
