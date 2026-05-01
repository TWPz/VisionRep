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
    private var lastThreeDimensionalFrame: PoseFrame?
    private var lastThreeDimensionalTimestamp: TimeInterval = -.infinity
    private var bodyRegionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let minimumFrameInterval: TimeInterval
    private let targetThreeDimensionalFramesPerSecond: Double = 15
    private let minimum3DFrameInterval: TimeInterval
    private let maximumDepthReuseInterval: TimeInterval = 0.18
    private let minimumJointConfidence: VNConfidence = 0.12
    private let fullFrameRegionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let minimumRegionJointCount = 8
    private let minimumRequiredRegionJointRatio = 0.7
    private let minimumRegionWidth: CGFloat = 0.58
    private let minimumRegionHeight: CGFloat = 0.76
    private let regionSmoothingFactor: CGFloat = 0.72

    init(targetFramesPerSecond: Double = 30) {
        minimumFrameInterval = 1 / targetFramesPerSecond
        minimum3DFrameInterval = 1 / min(targetFramesPerSecond, targetThreeDimensionalFramesPerSecond)
    }

    func process(_ sampleBuffer: CMSampleBuffer) -> PoseProcessingResult {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp - lastProcessedTimestamp >= minimumFrameInterval else {
            return .skipped
        }
        lastProcessedTimestamp = timestamp

        let observation: VNHumanBodyPoseObservation?
        do {
            observation = try performTwoDimensionalPoseRequest(on: sampleBuffer)
        } catch {
            poseSmoother.reset()
            lastThreeDimensionalFrame = nil
            resetRegionOfInterest()
            return .failed(error.localizedDescription)
        }

        guard let observation else {
            poseSmoother.reset()
            lastThreeDimensionalFrame = nil
            resetRegionOfInterest()
            return .noPose(timestamp)
        }

        do {
            let twoDimensionalFrame = try makeFrame(from: observation, timestamp: timestamp)
            updateRegionOfInterest(from: twoDimensionalFrame)
            refreshThreeDimensionalPoseIfNeeded(
                on: sampleBuffer,
                fallbackObservation: observation,
                timestamp: timestamp
            )
            let fusedFrame = mergeDepth(from: lastThreeDimensionalFrame, into: twoDimensionalFrame, timestamp: timestamp)
            return makePoseResult(from: fusedFrame)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func performTwoDimensionalPoseRequest(on sampleBuffer: CMSampleBuffer) throws -> VNHumanBodyPoseObservation? {
        bodyPose2DRequest.regionOfInterest = bodyRegionOfInterest
        try sequenceHandler.perform(
            [bodyPose2DRequest],
            on: sampleBuffer,
            orientation: .upMirrored
        )
        return bodyPose2DRequest.results?.max(by: { area(of: $0) < area(of: $1) })
    }

    private func performThreeDimensionalPoseRequest(on sampleBuffer: CMSampleBuffer) throws -> VNHumanBodyPose3DObservation? {
        bodyPose3DRequest.regionOfInterest = bodyRegionOfInterest
        try sequenceHandler.perform(
            [bodyPose3DRequest],
            on: sampleBuffer,
            orientation: .upMirrored
        )
        return bodyPose3DRequest.results?.max(by: { $0.confidence < $1.confidence })
    }

    private func shouldRefreshThreeDimensionalPose(at timestamp: TimeInterval) -> Bool {
        timestamp - lastThreeDimensionalTimestamp >= minimum3DFrameInterval
    }

    private func refreshThreeDimensionalPoseIfNeeded(
        on sampleBuffer: CMSampleBuffer,
        fallbackObservation: VNHumanBodyPoseObservation,
        timestamp: TimeInterval
    ) {
        guard shouldRefreshThreeDimensionalPose(at: timestamp) else {
            return
        }

        lastThreeDimensionalTimestamp = timestamp
        guard let observation = try? performThreeDimensionalPoseRequest(on: sampleBuffer),
              let frame = makeThreeDimensionalFrame(
                from: observation,
                fallbackObservation: fallbackObservation,
                timestamp: timestamp
              )
        else {
            return
        }

        lastThreeDimensionalFrame = frame
    }

    private func updateRegionOfInterest(from frame: PoseFrame) {
        guard let targetRegion = regionOfInterest(for: frame) else {
            resetRegionOfInterest()
            return
        }

        bodyRegionOfInterest = smoothedRegionOfInterest(from: targetRegion)
    }

    private func resetRegionOfInterest() {
        bodyRegionOfInterest = fullFrameRegionOfInterest
    }

    private func regionOfInterest(for frame: PoseFrame) -> CGRect? {
        let joints = frame.joints.values.filter { $0.confidence >= Double(minimumJointConfidence) }
        guard joints.count >= minimumRegionJointCount else {
            return nil
        }
        let requiredJointCount = PoseFrameFactory.requiredJoints.filter { jointName in
            (frame.joint(jointName)?.confidence ?? 0) >= Double(minimumJointConfidence)
        }.count
        let requiredJointRatio = Double(requiredJointCount) / Double(PoseFrameFactory.requiredJoints.count)
        guard requiredJointRatio >= minimumRequiredRegionJointRatio else {
            return nil
        }

        let xs = joints.map { CGFloat($0.x) }
        let ys = joints.map { CGFloat($0.y) }
        guard let minX = xs.min(),
              let maxX = xs.max(),
              let minY = ys.min(),
              let maxY = ys.max()
        else {
            return nil
        }

        let bodyBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard bodyBounds.width > 0.04, bodyBounds.height > 0.04 else {
            return nil
        }

        return expandedRegionOfInterest(from: bodyBounds)
    }

    private func expandedRegionOfInterest(from bodyBounds: CGRect) -> CGRect {
        let horizontalPadding = max(bodyBounds.width * 0.55, CGFloat(0.16))
        let verticalPadding = max(bodyBounds.height * 0.35, CGFloat(0.12))
        var expanded = bodyBounds.insetBy(dx: -horizontalPadding, dy: -verticalPadding)

        if expanded.width < minimumRegionWidth {
            let delta = minimumRegionWidth - expanded.width
            expanded = expanded.insetBy(dx: -(delta / 2), dy: 0)
        }

        if expanded.height < minimumRegionHeight {
            let delta = minimumRegionHeight - expanded.height
            expanded = expanded.insetBy(dx: 0, dy: -(delta / 2))
        }

        return clampedUnitRect(expanded)
    }

    private func smoothedRegionOfInterest(from target: CGRect) -> CGRect {
        guard bodyRegionOfInterest != fullFrameRegionOfInterest else {
            return target
        }

        let current = bodyRegionOfInterest
        let alpha = regionSmoothingFactor
        let smoothed = CGRect(
            x: (current.origin.x * alpha) + (target.origin.x * (1 - alpha)),
            y: (current.origin.y * alpha) + (target.origin.y * (1 - alpha)),
            width: (current.width * alpha) + (target.width * (1 - alpha)),
            height: (current.height * alpha) + (target.height * (1 - alpha))
        )

        return clampedUnitRect(smoothed)
    }

    private func clampedUnitRect(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, 0.05), 1)
        let height = min(max(rect.height, 0.05), 1)
        let x = min(max(rect.origin.x, 0), 1 - width)
        let y = min(max(rect.origin.y, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func mergeDepth(from depthFrame: PoseFrame?, into twoDimensionalFrame: PoseFrame, timestamp: TimeInterval) -> PoseFrame {
        guard let depthFrame, timestamp - depthFrame.timestamp <= maximumDepthReuseInterval else {
            return twoDimensionalFrame
        }

        var joints = twoDimensionalFrame.joints
        for (name, depthJoint) in depthFrame.joints {
            guard let depth = depthJoint.z, var joint = joints[name] else {
                continue
            }

            joint.z = depth
            joint.confidence = max(joint.confidence, min(depthJoint.confidence, 1))
            joints[name] = joint
        }

        return PoseFrame(timestamp: twoDimensionalFrame.timestamp, joints: joints)
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
            let usableFallbackPoint = fallbackPoint.flatMap { point -> VNRecognizedPoint? in
                point.confidence >= minimumJointConfidence ? point : nil
            }
            let x = usableFallbackPoint.map { Double($0.location.x) } ?? projectedPoint?.x
            let y = usableFallbackPoint.map { Double($0.location.y) } ?? projectedPoint?.y
            guard let x, let y
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
