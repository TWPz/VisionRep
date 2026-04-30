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
    var matchedTemplateSource: TemplateMatchSource?
    var onlineTemplateCount = 0
}

nonisolated enum TemplateMatchSource: String, Equatable, Sendable {
    case anchor
    case online
}

nonisolated final class FewShotRepetitionCounter {
    private let sampleCount = 48
    private let maxOnlineTemplateCount = 4
    private let onlinePromotionConfidenceThreshold = 0.85
    private var templates: [MovementTemplate] = []
    private var onlineTemplates: [OnlineTemplateRecord] = []
    private var anchorThreshold: Double = 0.22
    private var buffer: [PoseFrame] = []
    private var lastCountTimestamp: TimeInterval = -.infinity
    private(set) var repetitions = 0
    private(set) var confidence = 0.0
    private(set) var bestScore = Double.infinity

    private struct OnlineTemplateRecord {
        var template: MovementTemplate
        var promotionConfidence: Double
        var anchorScore: Double

        func trustScore(anchorThreshold: Double) -> Double {
            let closeness = max(0, min(1, 1 - (anchorScore / max(anchorThreshold, 0.001))))
            return (promotionConfidence * 0.45) + (template.qualityScore * 0.35) + (closeness * 0.2)
        }
    }

    private struct TemplateRecord {
        var template: MovementTemplate
        var source: TemplateMatchSource
    }

    private struct Candidate {
        var score: Double
        var templateIndex: Int
        var source: TemplateMatchSource
        var acceptanceThreshold: Double
        var segment: [PoseFrame]
        var vectors: [PoseFeatureVector]
        var anchorScore: Double
        var averageQuality: Double
    }

    var hasTemplates: Bool {
        !templates.isEmpty
    }

    var onlineTemplateCount: Int {
        onlineTemplates.count
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
        onlineTemplates.removeAll(keepingCapacity: true)
        anchorThreshold = Self.learnThreshold(from: templates)
        resetCount()
    }

    func clearOnlineTemplates() {
        onlineTemplates.removeAll(keepingCapacity: true)
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
            return CountUpdate(
                repetitions: repetitions,
                confidence: 0,
                bestScore: .infinity,
                matchedTemplateIndex: nil,
                matchedTemplateSource: nil,
                onlineTemplateCount: onlineTemplateCount
            )
        }

        buffer.append(frame)
        trimBuffer(now: frame.timestamp)

        let candidate = bestCandidate()
        bestScore = candidate?.score ?? .infinity
        confidence = confidence(for: candidate)

        let cooldownElapsed = frame.timestamp - lastCountTimestamp > completionCooldown
        if let candidate, candidate.score <= candidate.acceptanceThreshold, cooldownElapsed {
            repetitions += 1
            lastCountTimestamp = frame.timestamp
            promoteOnlineTemplate(from: candidate)
            buffer.removeAll(keepingCapacity: true)
        }

        return CountUpdate(
            repetitions: repetitions,
            confidence: confidence,
            bestScore: bestScore,
            matchedTemplateIndex: candidate?.templateIndex,
            matchedTemplateSource: candidate?.source,
            onlineTemplateCount: onlineTemplateCount
        )
    }

    private func trimBuffer(now: TimeInterval) {
        let longestTemplate = matchingTemplates.map(\.template.duration).max() ?? 4
        let window = max(8, longestTemplate * 1.7)
        buffer.removeAll { now - $0.timestamp > window }
    }

    private func bestCandidate() -> Candidate? {
        guard buffer.count >= 18 else {
            return nil
        }

        var best: Candidate?

        for record in matchingTemplates {
            let template = record.template
            guard let strictLengthRange = strictLengthRange(for: template, availableCount: buffer.count) else {
                continue
            }

            for length in stride(from: strictLengthRange.lowerBound, through: strictLengthRange.upperBound, by: 4) {
                let segment = Array(buffer.suffix(length))
                guard segmentDuration(segment) >= minimumCandidateDuration(for: template) else {
                    continue
                }
                let vectors = resample(segment.map(Self.vector), targetCount: sampleCount)
                let candidateMovement = Self.movementMagnitude(vectors)
                guard candidateMovement >= minimumCandidateMovement(for: template) else {
                    continue
                }

                let anchorScore = closestAnchorScore(
                    to: vectors,
                    duration: segmentDuration(segment),
                    movement: candidateMovement
                )

                guard record.source == .anchor || anchorCorroborates(anchorScore) else {
                    continue
                }

                let score = Self.distance(vectors, template.vectors)
                let candidateThreshold = acceptanceThreshold(for: record.source)
                let candidateRank = score / max(candidateThreshold, 0.001)
                let bestRank = best.map { $0.score / max($0.acceptanceThreshold, 0.001) } ?? .infinity

                if candidateRank < bestRank {
                    best = Candidate(
                        score: score,
                        templateIndex: template.index,
                        source: record.source,
                        acceptanceThreshold: candidateThreshold,
                        segment: segment,
                        vectors: vectors,
                        anchorScore: anchorScore,
                        averageQuality: Self.averageJointConfidence(in: segment)
                    )
                }
            }
        }

        return best
    }

    private var matchingTemplates: [TemplateRecord] {
        templates.map { TemplateRecord(template: $0, source: .anchor) }
            + onlineTemplates.map { TemplateRecord(template: $0.template, source: .online) }
    }

    private var completionCooldown: TimeInterval {
        let shortestTemplate = templates.map(\.duration).min() ?? 1.6
        return max(1.1, shortestTemplate * 0.72)
    }

    private func acceptanceThreshold(for source: TemplateMatchSource) -> Double {
        switch source {
        case .anchor:
            anchorThreshold
        case .online:
            onlineAcceptanceThreshold
        }
    }

    private var onlineAcceptanceThreshold: Double {
        max(0.12, anchorThreshold * 0.88)
    }

    private func confidence(for candidate: Candidate?) -> Double {
        guard let candidate else { return 0 }
        return max(0, min(1, 1 - (candidate.score / max(candidate.acceptanceThreshold, 0.001))))
    }

    private func strictLengthRange(for template: MovementTemplate, availableCount: Int) -> ClosedRange<Int>? {
        let expectedFrames = max(template.sourceFrameCount, 20)
        let lowerBound = max(Int((Double(expectedFrames) * 0.92).rounded(.down)), 20)
        let upperBound = min(Int((Double(expectedFrames) * 1.28).rounded(.up)), availableCount)

        guard lowerBound <= upperBound else {
            return nil
        }
        return lowerBound...upperBound
    }

    private func minimumCandidateDuration(for template: MovementTemplate) -> TimeInterval {
        max(template.duration * 0.82, 0.8)
    }

    private func segmentDuration(_ segment: [PoseFrame]) -> TimeInterval {
        guard let first = segment.first, let last = segment.last else {
            return 0
        }
        return max(last.timestamp - first.timestamp, 0)
    }

    private func minimumCandidateMovement(for template: MovementTemplate) -> Double {
        max(Self.movementMagnitude(template.vectors) * 0.45, 0.025)
    }

    private func anchorCorroborates(_ anchorScore: Double) -> Bool {
        anchorScore <= min(max(anchorThreshold * 1.35, anchorThreshold + 0.04), 0.42)
    }

    private func closestAnchorScore(
        to vectors: [PoseFeatureVector],
        duration: TimeInterval,
        movement: Double
    ) -> Double {
        var closest = Double.infinity

        for template in templates {
            let durationRatio = duration / max(template.duration, 0.1)
            guard (0.72...1.42).contains(durationRatio) else {
                continue
            }

            let templateMovement = Self.movementMagnitude(template.vectors)
            guard movement >= max(templateMovement * 0.42, 0.02) else {
                continue
            }

            closest = min(closest, Self.distance(vectors, template.vectors))
        }

        return closest
    }

    private func promoteOnlineTemplate(from candidate: Candidate) {
        let promotionConfidence = confidence(for: candidate)
        guard promotionConfidence >= onlinePromotionConfidenceThreshold else {
            return
        }
        guard anchorCorroborates(candidate.anchorScore) else {
            return
        }
        guard !isDuplicateOnlineTemplate(candidate.vectors) else {
            return
        }
        guard let template = makeTemplate(
            index: nextOnlineTemplateIndex,
            frames: candidate.segment,
            averageQuality: candidate.averageQuality
        ) else {
            return
        }

        onlineTemplates.append(
            OnlineTemplateRecord(
                template: template,
                promotionConfidence: promotionConfidence,
                anchorScore: candidate.anchorScore
            )
        )
        evictWeakOnlineTemplatesIfNeeded()
    }

    private var nextOnlineTemplateIndex: Int {
        let highestAnchorIndex = templates.map(\.index).max() ?? 0
        let highestOnlineIndex = onlineTemplates.map(\.template.index).max() ?? highestAnchorIndex
        return max(highestAnchorIndex, highestOnlineIndex) + 1
    }

    private func isDuplicateOnlineTemplate(_ vectors: [PoseFeatureVector]) -> Bool {
        let duplicateDistance = max(anchorThreshold * 0.12, 0.018)
        return onlineTemplates.contains { record in
            Self.distance(vectors, record.template.vectors) <= duplicateDistance
        }
    }

    private func evictWeakOnlineTemplatesIfNeeded() {
        while onlineTemplates.count > maxOnlineTemplateCount {
            guard let weakestIndex = onlineTemplates.indices.min(by: { left, right in
                let leftRecord = onlineTemplates[left]
                let rightRecord = onlineTemplates[right]
                let leftTrust = leftRecord.trustScore(anchorThreshold: anchorThreshold)
                let rightTrust = rightRecord.trustScore(anchorThreshold: anchorThreshold)

                if leftTrust == rightTrust {
                    return leftRecord.template.capturedAt < rightRecord.template.capturedAt
                }
                return leftTrust < rightTrust
            }) else {
                return
            }
            onlineTemplates.remove(at: weakestIndex)
        }
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

    private static func movementMagnitude(_ vectors: [PoseFeatureVector]) -> Double {
        guard vectors.count > 1 else { return 0 }
        let total = zip(vectors, vectors.dropFirst()).reduce(0) { partial, pair in
            partial + pair.0.distance(to: pair.1)
        }
        return total / Double(vectors.count - 1)
    }

    private static func averageJointConfidence(in segment: [PoseFrame]) -> Double {
        let confidences = segment.flatMap { frame in
            frame.joints.values.map(\.confidence)
        }
        guard !confidences.isEmpty else { return 0 }
        return confidences.reduce(0, +) / Double(confidences.count)
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
