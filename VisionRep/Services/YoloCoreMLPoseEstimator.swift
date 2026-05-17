@preconcurrency import AVFoundation
import CoreML
import Foundation
import Vision

nonisolated enum YoloCoreMLPoseEstimatorError: LocalizedError, Sendable {
    case missingModel(String)
    case invalidModel(URL)
    case missingOutput(String)
    case invalidOutputShape([NSNumber])
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .missingModel(let name):
            "Missing YOLO pose model: \(name)."
        case .invalidModel(let url):
            "YOLO pose model could not be loaded from \(url.lastPathComponent)."
        case .missingOutput(let name):
            "YOLO pose model did not return output \(name)."
        case .invalidOutputShape(let shape):
            "YOLO pose model returned an unsupported output shape: \(shape)."
        case .emptyResult:
            "YOLO pose model did not return a confident pose."
        }
    }
}

nonisolated final class YoloCoreMLPoseEstimator: PoseEstimating, @unchecked Sendable {
    static let modelResourceName = "yolo26n-pose"
    static let modelExtension = "mlpackage"

    private let request: VNCoreMLRequest
    private let decoder = YoloPoseDecoder()
    private let outputName = "var_1566"

    init(bundle: Bundle = .main) throws {
        let modelURL = try Self.preferredModelURL(in: bundle)
        let mlModel = try Self.loadModel(from: modelURL)
        let visionModel = try VNCoreMLModel(for: mlModel)
        request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
    }

    func estimatePose(in sampleBuffer: CMSampleBuffer, timestamp: TimeInterval) throws -> PoseFrame? {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.compactMap({ $0 as? VNCoreMLFeatureValueObservation })
            .first(where: { $0.featureName == outputName }),
              let multiArray = observation.featureValue.multiArrayValue
        else {
            throw YoloCoreMLPoseEstimatorError.missingOutput(outputName)
        }

        return try decoder.makeFrame(from: multiArray, timestamp: timestamp)
    }

    private static func preferredModelURL(in bundle: Bundle) throws -> URL {
        let subdirectories = ["Resources/Models", "Models", nil]
        let extensions = ["mlmodelc", modelExtension]

        for subdirectory in subdirectories {
            for modelExtension in extensions {
                if let url = bundle.url(
                    forResource: modelResourceName,
                    withExtension: modelExtension,
                    subdirectory: subdirectory
                ) {
                    return url
                }
            }
        }

        throw YoloCoreMLPoseEstimatorError.missingModel("\(modelResourceName).\(modelExtension)")
    }

    private static func loadModel(from url: URL) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        do {
            if url.pathExtension == "mlmodelc" {
                return try MLModel(contentsOf: url, configuration: configuration)
            }

            let compiledURL = try MLModel.compileModel(at: url)
            return try MLModel(contentsOf: compiledURL, configuration: configuration)
        } catch {
            throw YoloCoreMLPoseEstimatorError.invalidModel(url)
        }
    }
}

nonisolated struct YoloPoseDecoder: Sendable {
    private static let modelInputSize: Double = 640
    private static let minimumPoseConfidence: Float = 0.35
    private static let minimumKeypointConfidence: Float = 0.25
    private static let detectionCount = 300
    private static let detectionWidth = 57
    private static let keypointStartIndex = 6
    private static let keypointValueCount = 3

    private static let keypointIndexByJoint: [PoseJointName: Int] = [
        .nose: 0,
        .leftShoulder: 5,
        .rightShoulder: 6,
        .leftElbow: 7,
        .rightElbow: 8,
        .leftWrist: 9,
        .rightWrist: 10,
        .leftHip: 11,
        .rightHip: 12,
        .leftKnee: 13,
        .rightKnee: 14,
        .leftAnkle: 15,
        .rightAnkle: 16
    ]

    func makeFrame(from output: MLMultiArray, timestamp: TimeInterval) throws -> PoseFrame? {
        try validateShape(output.shape)

        guard let detectionOffset = bestDetectionOffset(in: output) else {
            return nil
        }

        var joints: [PoseJointName: PoseJoint] = [:]
        for (jointName, keypointIndex) in Self.keypointIndexByJoint {
            let keypointOffset = detectionOffset
                + Self.keypointStartIndex
                + (keypointIndex * Self.keypointValueCount)
            let x = output.floatValue(at: keypointOffset)
            let y = output.floatValue(at: keypointOffset + 1)
            let confidence = output.floatValue(at: keypointOffset + 2)

            guard confidence >= Self.minimumKeypointConfidence else {
                continue
            }

            joints[jointName] = PoseJoint(
                x: normalizedCoordinate(x),
                y: normalizedCoordinate(y),
                confidence: Double(confidence),
                z: nil
            )
        }

        deriveJoint(.neck, from: .leftShoulder, and: .rightShoulder, in: &joints)
        deriveJoint(.root, from: .leftHip, and: .rightHip, in: &joints)

        guard !joints.isEmpty else {
            return nil
        }

        return PoseFrame(timestamp: timestamp, joints: joints)
    }

    private func validateShape(_ shape: [NSNumber]) throws {
        let dimensions = shape.map(\.intValue)
        guard dimensions == [1, Self.detectionCount, Self.detectionWidth] else {
            throw YoloCoreMLPoseEstimatorError.invalidOutputShape(shape)
        }
    }

    private func bestDetectionOffset(in output: MLMultiArray) -> Int? {
        var bestOffset: Int?
        var bestConfidence = Self.minimumPoseConfidence

        for detectionIndex in 0..<Self.detectionCount {
            let offset = detectionIndex * Self.detectionWidth
            let confidence = output.floatValue(at: offset + 4)
            if confidence > bestConfidence {
                bestConfidence = confidence
                bestOffset = offset
            }
        }

        return bestOffset
    }

    private func normalizedCoordinate(_ value: Float) -> Double {
        let raw = Double(value)
        let normalized = raw > 1 ? raw / Self.modelInputSize : raw
        return min(max(normalized, 0), 1)
    }

    private func deriveJoint(
        _ target: PoseJointName,
        from firstName: PoseJointName,
        and secondName: PoseJointName,
        in joints: inout [PoseJointName: PoseJoint]
    ) {
        guard let first = joints[firstName], let second = joints[secondName] else {
            return
        }

        joints[target] = PoseJoint(
            x: (first.x + second.x) / 2,
            y: (first.y + second.y) / 2,
            confidence: min(first.confidence, second.confidence),
            z: nil
        )
    }
}

private extension MLMultiArray {
    func floatValue(at contiguousIndex: Int) -> Float {
        Float(truncating: self[contiguousIndex])
    }
}
