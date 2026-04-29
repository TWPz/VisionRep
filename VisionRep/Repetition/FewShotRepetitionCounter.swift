import Foundation

nonisolated struct MovementTemplate: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var index: Int
    var capturedAt: Date
    var sourceFrameCount: Int
    var duration: TimeInterval
    var qualityScore: Double
    var vectors: [PoseFeatureVector]
}

nonisolated struct CountUpdate: Equatable, Sendable {
    var repetitions: Int
    var confidence: Double
    var bestScore: Double
    var matchedTemplateIndex: Int?
}

nonisolated final class FewShotRepetitionCounter {
    private let sampleCount = 48
    private var templates: [MovementTemplate] = []
    private var threshold: Double = 0.22
    private var buffer: [PoseFrame] = []
    private var lastCountTimestamp: TimeInterval = -.infinity
    private(set) var repetitions = 0
    private(set) var confidence = 0.0
    private(set) var bestScore = Double.infinity

    var hasTemplates: Bool {
        !templates.isEmpty
    }

    func resetCount() {
        buffer.removeAll(keepingCapacity: true)
        lastCountTimestamp = -.infinity
        repetitions = 0
        confidence = 0
        bestScore = .infinity
    }

    func load(templates: [MovementTemplate]) {
        self.templates = templates
        threshold = Self.learnThreshold(from: templates)
        resetCount()
    }

    func makeTemplate(index: Int, frames: [PoseFrame], averageQuality: Double) -> MovementTemplate? {
        guard frames.count >= 20 else { return nil }
        let normalized = resample(frames.map(Self.vector), targetCount: sampleCount)
        guard normalized.count == sampleCount else { return nil }

        let duration = max((frames.last?.timestamp ?? 0) - (frames.first?.timestamp ?? 0), 0.1)
        return MovementTemplate(
            index: index,
            capturedAt: Date(),
            sourceFrameCount: frames.count,
            duration: duration,
            qualityScore: averageQuality,
            vectors: normalized
        )
    }

    func update(with frame: PoseFrame) -> CountUpdate {
        guard !templates.isEmpty else {
            return CountUpdate(repetitions: repetitions, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
        }

        buffer.append(frame)
        trimBuffer(now: frame.timestamp)

        let candidate = bestCandidate()
        bestScore = candidate.score
        confidence = max(0, min(1, 1 - (candidate.score / threshold)))

        let cooldownElapsed = frame.timestamp - lastCountTimestamp > 1.1
        if candidate.score <= threshold, cooldownElapsed {
            repetitions += 1
            lastCountTimestamp = frame.timestamp
            buffer.removeAll(keepingCapacity: true)
        }

        return CountUpdate(
            repetitions: repetitions,
            confidence: confidence,
            bestScore: candidate.score,
            matchedTemplateIndex: candidate.templateIndex
        )
    }

    private func trimBuffer(now: TimeInterval) {
        let longestTemplate = templates.map(\.duration).max() ?? 4
        let window = max(8, longestTemplate * 1.7)
        buffer.removeAll { now - $0.timestamp > window }
    }

    private func bestCandidate() -> (score: Double, templateIndex: Int?) {
        guard buffer.count >= 18 else {
            return (.infinity, nil)
        }

        var best = (score: Double.infinity, templateIndex: Optional<Int>.none)

        for template in templates {
            let expectedFrames = max(template.sourceFrameCount, 20)
            let possibleLengths = stride(
                from: max(Int(Double(expectedFrames) * 0.72), 18),
                through: min(Int(Double(expectedFrames) * 1.45), buffer.count),
                by: 4
            )

            for length in possibleLengths {
                let segment = Array(buffer.suffix(length))
                let vectors = resample(segment.map(Self.vector), targetCount: sampleCount)
                let score = Self.distance(vectors, template.vectors)
                if score < best.score {
                    best = (score, template.index)
                }
            }
        }

        return best
    }

    private static func learnThreshold(from templates: [MovementTemplate]) -> Double {
        guard templates.count > 1 else { return 0.22 }
        var scores: [Double] = []

        for leftIndex in templates.indices {
            for rightIndex in templates.indices where leftIndex < rightIndex {
                scores.append(distance(templates[leftIndex].vectors, templates[rightIndex].vectors))
            }
        }

        guard !scores.isEmpty else { return 0.22 }
        scores.sort()
        let median = scores[scores.count / 2]
        return min(max(median + 0.08, 0.16), 0.34)
    }

    private func resample(_ values: [PoseFeatureVector], targetCount: Int) -> [PoseFeatureVector] {
        Self.resample(values, targetCount: targetCount)
    }

    private static func resample(_ values: [PoseFeatureVector], targetCount: Int) -> [PoseFeatureVector] {
        guard values.count > 1, targetCount > 1 else { return values }
        let lastIndex = Double(values.count - 1)

        return (0..<targetCount).map { index in
            let position = Double(index) * lastIndex / Double(targetCount - 1)
            let lower = Int(floor(position))
            let upper = min(lower + 1, values.count - 1)
            let blend = position - Double(lower)
            return PoseFeatureVector.interpolate(values[lower], values[upper], blend: blend)
        }
    }

    private static func vector(from frame: PoseFrame) -> PoseFeatureVector {
        let jointOrder: [PoseJointName] = [
            .leftShoulder,
            .rightShoulder,
            .leftElbow,
            .rightElbow,
            .leftWrist,
            .rightWrist,
            .leftHip,
            .rightHip,
            .leftKnee,
            .rightKnee,
            .leftAnkle,
            .rightAnkle
        ]

        var values: [Double] = []
        var weights: [Double] = []

        for jointName in jointOrder {
            if let joint = frame.joint(jointName) {
                values.append(joint.x)
                values.append(joint.y)
                weights.append(joint.confidence)
                weights.append(joint.confidence)
            } else {
                values.append(0)
                values.append(0)
                weights.append(0)
                weights.append(0)
            }
        }

        return PoseFeatureVector(values: values, weights: weights)
    }

    private static func distance(_ left: [PoseFeatureVector], _ right: [PoseFeatureVector]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return .infinity }
        let total = zip(left, right).reduce(0) { partial, pair in
            partial + pair.0.distance(to: pair.1)
        }
        return total / Double(left.count)
    }
}

nonisolated struct PoseFeatureVector: Codable, Equatable, Sendable {
    var values: [Double]
    var weights: [Double]

    func distance(to other: PoseFeatureVector) -> Double {
        guard values.count == other.values.count, weights.count == other.weights.count else {
            return .infinity
        }

        var weightedSum = 0.0
        var totalWeight = 0.0

        for index in values.indices {
            let weight = min(weights[index], other.weights[index])
            if weight > 0.08 {
                weightedSum += abs(values[index] - other.values[index]) * weight
                totalWeight += weight
            } else if max(weights[index], other.weights[index]) > 0.4 {
                weightedSum += 0.35
                totalWeight += 1
            }
        }

        guard totalWeight > 0 else { return .infinity }
        return weightedSum / totalWeight
    }

    static func interpolate(_ left: PoseFeatureVector, _ right: PoseFeatureVector, blend: Double) -> PoseFeatureVector {
        let values = zip(left.values, right.values).map { leftValue, rightValue in
            leftValue + ((rightValue - leftValue) * blend)
        }
        let weights = zip(left.weights, right.weights).map { leftValue, rightValue in
            leftValue + ((rightValue - leftValue) * blend)
        }
        return PoseFeatureVector(values: values, weights: weights)
    }
}
