@preconcurrency import AVFoundation
import Foundation

nonisolated protocol PoseEstimating: Sendable {
    func estimatePose(in sampleBuffer: CMSampleBuffer, timestamp: TimeInterval) throws -> PoseFrame?
}
