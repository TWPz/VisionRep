@preconcurrency import AVFoundation
import Foundation
import ImageIO
import simd
@preconcurrency import Vision

nonisolated enum PoseProcessingResult: Sendable {
    case pose(displayFrame: PoseFrame, normalizedFrame: PoseFrame, quality: PoseQuality)
    case noPose(TimeInterval)
    case skipped
    case failed(String)
}

nonisolated final class PoseFrameProcessor {
    private let bodyPose2DRequest = VNDetectHumanBodyPoseRequest()
    private let bodyPose3DRequest = VNDetectHumanBodyPose3DRequest()
    private let sequenceHandler = VNSequenceRequestHandler()
    private let poseSmoother = PoseSmoother()
    private var lastProcessedTimestamp: TimeInterval = 0
    private let minimumFrameInterval: TimeInterval
    private let minimumJointConfidence: VNConfidence = 0.12

    init(targetFramesPerSecond: Double = 30) {
        minimumFrameInterval = 1 / targetFramesPerSecond
    }

    func process(_ sampleBuffer: CMSampleBuffer) -> PoseProcessingResult {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp - lastProcessedTimestamp >= minimumFrameInterval else {
            return .skipped
        }
        lastProcessedTimestamp = timestamp

        do {
            try sequenceHandler.perform(
                [bodyPose3DRequest, bodyPose2DRequest],
                on: sampleBuffer,
                orientation: .upMirrored
            )

            let twoDimensionalObservation = bodyPose2DRequest.results?.max(by: { area(of: $0) < area(of: $1) })

            if let threeDimensionalObservation = bodyPose3DRequest.results?.max(by: { $0.confidence < $1.confidence }),
               let frame = makeThreeDimensionalFrame(
                from: threeDimensionalObservation,
                fallbackObservation: twoDimensionalObservation,
                timestamp: timestamp
               ) {
                return makePoseResult(from: frame)
            }

            guard let observation = twoDimensionalObservation else {
                poseSmoother.reset()
                return .noPose(timestamp)
            }

            let frame = try makeFrame(from: observation, timestamp: timestamp)
            return makePoseResult(from: frame)
        } catch {
            return processTwoDimensionalFallback(sampleBuffer, timestamp: timestamp)
        }
    }

    private func makePoseResult(from rawFrame: PoseFrame) -> PoseProcessingResult {
        let refinedFrame = poseSmoother.refine(rawFrame)
        let normalized = PoseFrameFactory.normalized(refinedFrame)
        let quality = PoseFrameFactory.quality(for: refinedFrame)
        return .pose(displayFrame: refinedFrame, normalizedFrame: normalized, quality: quality)
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

    private func makeThreeDimensionalFrame(
        from observation: VNHumanBodyPose3DObservation,
        fallbackObservation: VNHumanBodyPoseObservation?,
        timestamp: TimeInterval
    ) -> PoseFrame? {
        let fallbackPoints = (try? fallbackObservation?.recognizedPoints(.all)) ?? [:]
        var joints: [PoseJointName: PoseJoint] = [:]

        for name in PoseJointName.allCases {
            guard let threeDimensionalName = name.vision3DJointName,
                  let point3D = try? observation.recognizedPoint(threeDimensionalName)
            else {
                if let point2D = fallbackPoints[name.visionJointName], point2D.confidence >= minimumJointConfidence {
                    joints[name] = PoseJoint(
                        x: point2D.location.x,
                        y: point2D.location.y,
                        confidence: Double(point2D.confidence)
                    )
                }
                continue
            }

            let projectedPoint = try? observation.pointInImage(threeDimensionalName)
            let fallbackPoint = fallbackPoints[name.visionJointName]
            let fallbackX = fallbackPoint.map { Double($0.location.x) }
            let fallbackY = fallbackPoint.map { Double($0.location.y) }
            guard let x = projectedPoint?.x ?? fallbackX,
                  let y = projectedPoint?.y ?? fallbackY
            else {
                continue
            }

            let confidence = max(
                Double(fallbackPoint?.confidence ?? 0),
                Double(observation.confidence) * 0.72
            )

            guard confidence >= Double(minimumJointConfidence) else {
                continue
            }

            let modelPosition = point3D.position.columns.3
            joints[name] = PoseJoint(
                x: x,
                y: y,
                confidence: confidence,
                z: Double(modelPosition.z)
            )
        }

        guard !joints.isEmpty else { return nil }
        return PoseFrame(timestamp: timestamp, joints: joints)
    }

    private func processTwoDimensionalFallback(
        _ sampleBuffer: CMSampleBuffer,
        timestamp: TimeInterval
    ) -> PoseProcessingResult {
        do {
            let handler = VNImageRequestHandler(
                cmSampleBuffer: sampleBuffer,
                orientation: .upMirrored,
                options: [:]
            )
            try handler.perform([bodyPose2DRequest])

            guard let observation = bodyPose2DRequest.results?.max(by: { area(of: $0) < area(of: $1) }) else {
                poseSmoother.reset()
                return .noPose(timestamp)
            }

            let frame = try makeFrame(from: observation, timestamp: timestamp)
            return makePoseResult(from: frame)
        } catch {
            return .failed(error.localizedDescription)
        }
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

    nonisolated var vision3DJointName: VNHumanBodyPose3DObservation.JointName? {
        switch self {
        case .nose:
            .centerHead
        case .neck:
            .centerShoulder
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
