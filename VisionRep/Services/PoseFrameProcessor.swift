@preconcurrency import AVFoundation
import Foundation

nonisolated enum PoseProcessingResult: Sendable {
    case pose(displayFrame: PoseFrame, normalizedFrame: PoseFrame, quality: PoseQuality)
    case noPose(TimeInterval)
    case skipped
    case failed(String)
}

nonisolated final class PoseFrameProcessor: @unchecked Sendable {
    var onTargetFramesPerSecondChange: ((Double) -> Void)?

    private let poseEstimator: (any PoseEstimating)?
    private let poseSmoother = PoseSmoother()
    private var nextProcessingTimestamp: TimeInterval?
    private var performanceController: PoseProcessingPerformanceController
    private var consecutiveNoPoseFrameCount = 0
    private let smootherResetThreshold = 3
    private let frameIntervalTolerance: TimeInterval = 0.002
    private let startupError: String?

    init(
        targetFramesPerSecond: Double = 24,
        poseEstimator: (any PoseEstimating)? = nil
    ) {
        performanceController = PoseProcessingPerformanceController(
            initialTargetFramesPerSecond: targetFramesPerSecond
        )

        if let poseEstimator {
            self.poseEstimator = poseEstimator
            startupError = nil
            return
        }

        do {
            self.poseEstimator = try YoloCoreMLPoseEstimator()
            startupError = nil
        } catch {
            self.poseEstimator = nil
            startupError = error.localizedDescription
        }
    }

    func process(_ sampleBuffer: CMSampleBuffer) -> PoseProcessingResult {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard shouldProcessFrame(at: timestamp) else {
            return .skipped
        }

        if let startupError {
            recordPoseDropout()
            return .failed(startupError)
        }

        guard let poseEstimator else {
            recordPoseDropout()
            return .failed("YOLO pose estimator is unavailable.")
        }

        do {
            let processingStart = DispatchTime.now().uptimeNanoseconds
            defer {
                recordProcessingDuration(since: processingStart)
            }

            guard let rawFrame = try poseEstimator.estimatePose(in: sampleBuffer, timestamp: timestamp) else {
                recordPoseDropout()
                return .noPose(timestamp)
            }

            consecutiveNoPoseFrameCount = 0
            return makePoseResult(from: rawFrame)
        } catch {
            recordPoseDropout()
            return .failed(error.localizedDescription)
        }
    }

    func setTargetFramesPerSecond(_ targetFramesPerSecond: Double) {
        let previousFramesPerSecond = performanceController.targetFramesPerSecond
        performanceController.setTargetFramesPerSecond(targetFramesPerSecond)
        nextProcessingTimestamp = nil
        notifyTargetFramesPerSecondIfNeeded(previousFramesPerSecond)
    }

    private func shouldProcessFrame(at timestamp: TimeInterval) -> Bool {
        let frameInterval = performanceController.minimumFrameInterval
        guard let scheduledTimestamp = nextProcessingTimestamp else {
            nextProcessingTimestamp = timestamp + frameInterval
            return true
        }

        guard timestamp + frameIntervalTolerance >= scheduledTimestamp else {
            return false
        }

        nextProcessingTimestamp = nextScheduledTimestamp(
            after: scheduledTimestamp,
            interval: frameInterval,
            observedTimestamp: timestamp
        )
        return true
    }

    private func nextScheduledTimestamp(
        after scheduledTimestamp: TimeInterval,
        interval: TimeInterval,
        observedTimestamp: TimeInterval
    ) -> TimeInterval {
        var nextTimestamp = scheduledTimestamp + interval
        while nextTimestamp <= observedTimestamp {
            nextTimestamp += interval
        }
        return nextTimestamp
    }

    private func recordProcessingDuration(since startTime: UInt64) {
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startTime
        let elapsedSeconds = TimeInterval(elapsedNanoseconds) / 1_000_000_000
        let previousFramesPerSecond = performanceController.targetFramesPerSecond
        performanceController.recordProcessingDuration(elapsedSeconds)
        notifyTargetFramesPerSecondIfNeeded(previousFramesPerSecond)
    }

    private func notifyTargetFramesPerSecondIfNeeded(_ previousFramesPerSecond: Double) {
        let currentFramesPerSecond = performanceController.targetFramesPerSecond
        guard currentFramesPerSecond != previousFramesPerSecond else { return }
        onTargetFramesPerSecondChange?(currentFramesPerSecond)
    }

    private func recordPoseDropout() {
        consecutiveNoPoseFrameCount += 1
        if consecutiveNoPoseFrameCount >= smootherResetThreshold {
            poseSmoother.reset()
        }
    }

    private func makePoseResult(from rawFrame: PoseFrame) -> PoseProcessingResult {
        let refinedFrame = poseSmoother.refine(rawFrame)
        let normalized = PoseFrameFactory.normalized(refinedFrame)
        let quality = PoseFrameFactory.quality(for: refinedFrame)
        return .pose(displayFrame: refinedFrame, normalizedFrame: normalized, quality: quality)
    }
}

private nonisolated struct PoseProcessingPerformanceController {
    private static let frameRateTiers: [Double] = [24, 20, 18, 15, 12, 10, 8]
    private let downgradePressureFrameCount = 12
    private let upgradeRecoveryFrameCount = 120
    private let downgradeLoadThreshold = 0.90
    private let upgradeLoadThreshold = 0.45
    private let smoothingFactor = 0.25
    private var targetFrameRateIndex: Int
    private var minimumFramesPerSecond: Double
    private var maximumFramesPerSecond: Double
    private var smoothedProcessingDuration: TimeInterval?
    private var pressureFrameCount = 0
    private var recoveryFrameCount = 0

    init(initialTargetFramesPerSecond: Double) {
        minimumFramesPerSecond = initialTargetFramesPerSecond >= 20 ? 12 : 8
        maximumFramesPerSecond = initialTargetFramesPerSecond
        targetFrameRateIndex = Self.frameRateTiers.indices.min { lhs, rhs in
            abs(Self.frameRateTiers[lhs] - initialTargetFramesPerSecond)
                < abs(Self.frameRateTiers[rhs] - initialTargetFramesPerSecond)
        } ?? 0
    }

    var targetFramesPerSecond: Double {
        Self.frameRateTiers[targetFrameRateIndex]
    }

    var minimumFrameInterval: TimeInterval {
        1 / targetFramesPerSecond
    }

    mutating func recordProcessingDuration(_ duration: TimeInterval) {
        if let smoothedProcessingDuration {
            self.smoothedProcessingDuration = (smoothingFactor * duration)
                + ((1 - smoothingFactor) * smoothedProcessingDuration)
        } else {
            smoothedProcessingDuration = duration
        }

        guard let smoothedProcessingDuration else { return }

        if smoothedProcessingDuration > minimumFrameInterval * downgradeLoadThreshold {
            pressureFrameCount += 1
            recoveryFrameCount = 0
            downgradeIfNeeded()
        } else if smoothedProcessingDuration < minimumFrameInterval * upgradeLoadThreshold {
            recoveryFrameCount += 1
            pressureFrameCount = 0
            upgradeIfNeeded()
        } else {
            pressureFrameCount = 0
            recoveryFrameCount = 0
        }
    }

    mutating func setTargetFramesPerSecond(_ targetFramesPerSecond: Double) {
        minimumFramesPerSecond = targetFramesPerSecond >= 20 ? 12 : 8
        maximumFramesPerSecond = targetFramesPerSecond
        targetFrameRateIndex = Self.frameRateTiers.indices.min { lhs, rhs in
            abs(Self.frameRateTiers[lhs] - targetFramesPerSecond)
                < abs(Self.frameRateTiers[rhs] - targetFramesPerSecond)
        } ?? targetFrameRateIndex
    }

    private mutating func downgradeIfNeeded() {
        guard pressureFrameCount >= downgradePressureFrameCount,
              targetFrameRateIndex < Self.frameRateTiers.count - 1,
              Self.frameRateTiers[targetFrameRateIndex + 1] >= minimumFramesPerSecond
        else {
            return
        }

        targetFrameRateIndex += 1
        pressureFrameCount = 0
        recoveryFrameCount = 0
    }

    private mutating func upgradeIfNeeded() {
        guard recoveryFrameCount >= upgradeRecoveryFrameCount,
              targetFrameRateIndex > 0,
              Self.frameRateTiers[targetFrameRateIndex - 1] <= maximumFramesPerSecond
        else {
            return
        }

        targetFrameRateIndex -= 1
        pressureFrameCount = 0
        recoveryFrameCount = 0
    }
}
