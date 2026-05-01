import Foundation

nonisolated final class PoseSmoother {
    private let lowConfidenceThreshold = 0.5
    private let maxRecentFrameCount = 3
    private var filters: [PoseJointName: JointFilter] = [:]
    private var recentFrames: [PoseFrame] = []

    func refine(_ frame: PoseFrame) -> PoseFrame {
        let repairedFrame = repairLowConfidenceJoints(in: frame)
        var smoothedJoints: [PoseJointName: PoseJoint] = [:]

        for (name, joint) in repairedFrame.joints {
            var filter = filters[name] ?? JointFilter()
            smoothedJoints[name] = filter.filter(joint, timestamp: frame.timestamp)
            filters[name] = filter
        }

        let smoothedFrame = PoseFrame(timestamp: frame.timestamp, joints: smoothedJoints)
        recentFrames.append(smoothedFrame)
        if recentFrames.count > maxRecentFrameCount {
            recentFrames.removeFirst(recentFrames.count - maxRecentFrameCount)
        }
        return smoothedFrame
    }

    func reset() {
        filters.removeAll(keepingCapacity: true)
        recentFrames.removeAll(keepingCapacity: true)
    }

    private func repairLowConfidenceJoints(in frame: PoseFrame) -> PoseFrame {
        guard !recentFrames.isEmpty else { return frame }

        var joints = frame.joints
        let repairFrames = recentFrames.reversed()
        for name in PoseJointName.allCases {
            let currentJoint = joints[name]
            guard currentJoint?.confidence ?? 0 < lowConfidenceThreshold,
                  let repairedJoint = repairedJoint(name, currentJoint: currentJoint, repairFrames: repairFrames)
            else {
                continue
            }

            joints[name] = repairedJoint
        }

        return PoseFrame(timestamp: frame.timestamp, joints: joints)
    }

    private func repairedJoint(
        _ name: PoseJointName,
        currentJoint: PoseJoint?,
        repairFrames: ReversedCollection<[PoseFrame]>
    ) -> PoseJoint? {
        var weightedX = 0.0
        var weightedY = 0.0
        var weightedZ = 0.0
        var totalWeight = 0.0
        var totalDepthWeight = 0.0
        var bestConfidence = currentJoint?.confidence ?? 0

        if let currentJoint {
            let currentWeight = max(currentJoint.confidence, 0.05)
            weightedX += currentJoint.x * currentWeight
            weightedY += currentJoint.y * currentWeight
            totalWeight += currentWeight

            if let currentDepth = currentJoint.z {
                weightedZ += currentDepth * currentWeight
                totalDepthWeight += currentWeight
            }
        }

        var offset = 0
        for frame in repairFrames {
            defer { offset += 1 }
            guard let previousJoint = frame.joint(name) else { continue }

            let decay = pow(0.9, Double(offset + 1))
            let weight = previousJoint.confidence * decay
            guard weight > bestConfidence else { continue }

            bestConfidence = max(bestConfidence, weight)
            weightedX += previousJoint.x * weight
            weightedY += previousJoint.y * weight
            totalWeight += weight

            if let previousDepth = previousJoint.z {
                weightedZ += previousDepth * weight
                totalDepthWeight += weight
            }
        }

        let currentConfidence = currentJoint?.confidence ?? 0
        guard totalWeight > 0, bestConfidence > currentConfidence else {
            return currentJoint
        }

        return PoseJoint(
            x: weightedX / totalWeight,
            y: weightedY / totalWeight,
            confidence: min(bestConfidence, 1),
            z: totalDepthWeight > 0 ? weightedZ / totalDepthWeight : nil
        )
    }
}

private nonisolated struct JointFilter {
    private var xFilter = OneEuroFilter()
    private var yFilter = OneEuroFilter()
    private var zFilter = OneEuroFilter(minCutoff: 0.7, beta: 0.55)

    mutating func filter(_ joint: PoseJoint, timestamp: TimeInterval) -> PoseJoint {
        PoseJoint(
            x: xFilter.filter(joint.x, timestamp: timestamp),
            y: yFilter.filter(joint.y, timestamp: timestamp),
            confidence: joint.confidence,
            z: joint.z.map { zFilter.filter($0, timestamp: timestamp) }
        )
    }
}

private nonisolated struct OneEuroFilter {
    private let minCutoff: Double
    private let beta: Double
    private let derivativeCutoff: Double
    private var previousValue: Double?
    private var previousDerivative: Double = 0
    private var previousTimestamp: TimeInterval?

    init(minCutoff: Double = 0.8, beta: Double = 0.8, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func filter(_ value: Double, timestamp: TimeInterval) -> Double {
        guard let previousValue, let previousTimestamp else {
            self.previousValue = value
            self.previousTimestamp = timestamp
            return value
        }

        let elapsed = max(min(timestamp - previousTimestamp, 0.25), 1.0 / 240.0)
        let frequency = 1.0 / elapsed
        let derivative = (value - previousValue) * frequency
        let smoothedDerivative = lowPass(
            current: derivative,
            previous: previousDerivative,
            alpha: alpha(cutoff: derivativeCutoff, frequency: frequency)
        )
        let cutoff = minCutoff + (beta * abs(smoothedDerivative))
        let smoothedValue = lowPass(
            current: value,
            previous: previousValue,
            alpha: alpha(cutoff: cutoff, frequency: frequency)
        )

        self.previousValue = smoothedValue
        self.previousDerivative = smoothedDerivative
        self.previousTimestamp = timestamp
        return smoothedValue
    }

    private func lowPass(current: Double, previous: Double, alpha: Double) -> Double {
        (alpha * current) + ((1 - alpha) * previous)
    }

    private func alpha(cutoff: Double, frequency: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        let te = 1.0 / frequency
        return 1.0 / (1.0 + (tau / te))
    }
}
