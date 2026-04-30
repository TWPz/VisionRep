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
    private var pendingCompletion: PendingCompletion?
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
        var template: MovementTemplate
        var acceptanceThreshold: Double
        var segment: [PoseFrame]
        var vectors: [PoseFeatureVector]
        var anchorScore: Double
        var averageQuality: Double
    }

    private struct PendingCompletion {
        var candidate: Candidate
        var expiresAt: TimeInterval
    }

    private struct ScalarFeature {
        var value: Double
        var weight: Double
    }

    var hasTemplates: Bool {
        !templates.isEmpty
    }

    var onlineTemplateCount: Int {
        onlineTemplates.count
    }

    func resetCount() {
        buffer.removeAll(keepingCapacity: true)
        pendingCompletion = nil
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
        let rawVectors = Self.featureVectors(from: frames)
        let normalized = resample(rawVectors, targetCount: sampleCount)
        guard normalized.count == sampleCount else { return nil }

        let weighted = Self.applyFeatureVarianceWeights(normalized)

        let duration = max((frames.last?.timestamp ?? 0) - (frames.first?.timestamp ?? 0), 0.1)
        return MovementTemplate(
            index: index,
            capturedAt: Date(),
            sourceFrameCount: frames.count,
            duration: duration,
            qualityScore: averageQuality,
            vectors: weighted
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
        expirePendingCompletion(now: frame.timestamp)

        let candidate = bestCandidate()
        bestScore = candidate?.score ?? .infinity
        confidence = confidence(for: candidate)

        let cooldownElapsed = frame.timestamp - lastCountTimestamp > completionCooldown
        if let candidate, candidate.score <= candidate.acceptanceThreshold, cooldownElapsed {
            rememberPendingCompletion(candidate, now: frame.timestamp)
        }

        let completedCandidate = completedPendingCandidate(with: frame)
        if let completedCandidate, cooldownElapsed {
            repetitions += 1
            lastCountTimestamp = frame.timestamp
            promoteOnlineTemplate(from: completedCandidate)
            pendingCompletion = nil
            buffer.removeAll(keepingCapacity: true)
        }

        let displayedCandidate = completedCandidate ?? candidate
        return CountUpdate(
            repetitions: repetitions,
            confidence: confidence,
            bestScore: bestScore,
            matchedTemplateIndex: displayedCandidate?.templateIndex,
            matchedTemplateSource: displayedCandidate?.source,
            onlineTemplateCount: onlineTemplateCount
        )
    }

    private func trimBuffer(now: TimeInterval) {
        let longestTemplate = matchingTemplates.map(\.template.duration).max() ?? 4
        let window = max(10, longestTemplate * 2.4)
        buffer.removeAll { now - $0.timestamp > window }
    }

    private func bestCandidate() -> Candidate? {
        guard buffer.count >= 18 else {
            return nil
        }

        var best: Candidate?

        for record in matchingTemplates {
            let template = record.template
            guard let lengthRange = strictLengthRange(for: template, availableCount: buffer.count) else {
                continue
            }

            var candidateLengths = Array(stride(from: lengthRange.lowerBound, through: lengthRange.upperBound, by: 4))
            if candidateLengths.last != lengthRange.upperBound {
                candidateLengths.append(lengthRange.upperBound)
            }

            for length in candidateLengths {
                let segment = Array(buffer.suffix(length))
                guard segmentDuration(segment) >= minimumCandidateDuration(for: template) else {
                    continue
                }
                let vectors = resample(Self.featureVectors(from: segment), targetCount: sampleCount)
                let candidateMovement = Self.movementMagnitude(vectors)
                guard candidateMovement >= minimumCandidateMovement(for: template) else {
                    continue
                }
                let candidateThreshold = acceptanceThreshold(for: record.source)
                guard phaseGatePasses(vectors, template: template, acceptanceThreshold: candidateThreshold) else {
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
                let candidateRank = score / max(candidateThreshold, 0.001)
                let bestRank = best.map { $0.score / max($0.acceptanceThreshold, 0.001) } ?? .infinity

                if candidateRank < bestRank {
                    best = Candidate(
                        score: score,
                        templateIndex: template.index,
                        source: record.source,
                        template: template,
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
        let ratio = candidate.score / max(candidate.acceptanceThreshold, 0.001)
        return max(0, min(1, 1 - pow(ratio, 1.7)))
    }

    private func strictLengthRange(for template: MovementTemplate, availableCount: Int) -> ClosedRange<Int>? {
        completeLengthRange(for: template, availableCount: availableCount)
    }

    private func completeLengthRange(for template: MovementTemplate, availableCount: Int) -> ClosedRange<Int>? {
        let expectedFrames = max(template.sourceFrameCount, 20)
        let lowerBound = max(Int((Double(expectedFrames) * 0.68).rounded(.down)), 20)
        let upperBound = min(Int((Double(expectedFrames) * 1.85).rounded(.up)), availableCount)

        guard lowerBound <= upperBound else {
            return nil
        }
        return lowerBound...upperBound
    }

    private func minimumCandidateDuration(for template: MovementTemplate) -> TimeInterval {
        max(template.duration * 0.68, 0.55)
    }

    private func segmentDuration(_ segment: [PoseFrame]) -> TimeInterval {
        guard let first = segment.first, let last = segment.last else {
            return 0
        }
        return max(last.timestamp - first.timestamp, 0)
    }

    private func minimumCandidateMovement(for template: MovementTemplate) -> Double {
        max(Self.movementMagnitude(template.vectors) * 0.35, 0.006)
    }

    private func anchorCorroborates(_ anchorScore: Double) -> Bool {
        anchorScore <= min(max(anchorThreshold * 1.35, anchorThreshold + 0.04), 0.42)
    }

    private func rememberPendingCompletion(_ candidate: Candidate, now: TimeInterval) {
        guard completionCandidateHasEnoughCoverage(candidate) else {
            return
        }

        let expiresAt = now + max(0.75, candidate.template.duration * 0.35)
        guard let pendingCompletion else {
            self.pendingCompletion = PendingCompletion(candidate: candidate, expiresAt: expiresAt)
            return
        }

        let existingRank = pendingCompletion.candidate.score / max(pendingCompletion.candidate.acceptanceThreshold, 0.001)
        let newRank = candidate.score / max(candidate.acceptanceThreshold, 0.001)
        if newRank <= existingRank {
            self.pendingCompletion = PendingCompletion(candidate: candidate, expiresAt: expiresAt)
        } else {
            self.pendingCompletion?.expiresAt = max(pendingCompletion.expiresAt, expiresAt)
        }
    }

    private func completedPendingCandidate(with frame: PoseFrame) -> Candidate? {
        guard let pendingCompletion else { return nil }
        guard completionPoseMatches(frame, candidate: pendingCompletion.candidate) else { return nil }
        guard completionPoseIsStable() else { return nil }
        return pendingCompletion.candidate
    }

    private func expirePendingCompletion(now: TimeInterval) {
        guard let pendingCompletion, now > pendingCompletion.expiresAt else { return }
        self.pendingCompletion = nil
    }

    private func completionCandidateHasEnoughCoverage(_ candidate: Candidate) -> Bool {
        segmentDuration(candidate.segment) >= max(candidate.template.duration * 0.74, 0.65)
    }

    private func completionPoseMatches(_ frame: PoseFrame, candidate: Candidate) -> Bool {
        guard let endVector = candidate.template.vectors.last else { return false }
        let recentFrames = Array((buffer + [frame]).suffix(2))
        let currentVector = Self.featureVectors(from: recentFrames).last ?? Self.vector(from: frame)
        let endPoseDistance = currentVector.distance(to: endVector, limitedTo: Self.poseFeatureValueCount)
        return endPoseDistance <= completionPoseThreshold(for: candidate.template)
    }

    private func completionPoseIsStable() -> Bool {
        let recentFrames = Array(buffer.suffix(3))
        guard recentFrames.count >= 2 else { return false }

        let vectors = recentFrames.map(Self.vector)
        let largestStep = zip(vectors, vectors.dropFirst()).map { pair in
            pair.0.distance(to: pair.1, limitedTo: Self.poseFeatureValueCount)
        }.max() ?? .infinity

        return largestStep <= max(anchorThreshold * 0.12, 0.025)
    }

    private func completionPoseThreshold(for template: MovementTemplate) -> Double {
        let endpointDrift = template.vectors.first.map { firstVector in
            firstVector.distance(to: template.vectors.last ?? firstVector, limitedTo: Self.poseFeatureValueCount)
        } ?? 0
        return max(min(anchorThreshold * 1.2, 0.24), endpointDrift + 0.08)
    }

    private func phaseGatePasses(
        _ vectors: [PoseFeatureVector],
        template: MovementTemplate,
        acceptanceThreshold: Double
    ) -> Bool {
        guard vectors.count == template.vectors.count, vectors.count >= 5 else {
            return false
        }

        let checkpoints = [
            0,
            vectors.count / 4,
            vectors.count / 2,
            (vectors.count * 3) / 4,
            vectors.count - 1
        ]

        let poseThreshold = max(min(acceptanceThreshold * 1.55, 0.34), 0.14)
        let middleThreshold = max(min(acceptanceThreshold * 1.9, 0.42), 0.18)
        let startDistance = vectors[checkpoints[0]].distance(
            to: template.vectors[checkpoints[0]],
            limitedTo: Self.poseFeatureValueCount
        )
        let endDistance = vectors[checkpoints[4]].distance(
            to: template.vectors[checkpoints[4]],
            limitedTo: Self.poseFeatureValueCount
        )

        guard startDistance <= poseThreshold, endDistance <= poseThreshold else {
            return false
        }

        let middlePassCount = checkpoints[1...3].filter { checkpoint in
            vectors[checkpoint].distance(
                to: template.vectors[checkpoint],
                limitedTo: Self.poseFeatureValueCount
            ) <= middleThreshold
        }.count

        guard middlePassCount >= 2 else {
            return false
        }

        let velocityDistance = Self.distance(vectors, template.vectors)
        return velocityDistance <= max(acceptanceThreshold * 1.25, acceptanceThreshold + 0.05)
    }

    private func closestAnchorScore(
        to vectors: [PoseFeatureVector],
        duration: TimeInterval,
        movement: Double
    ) -> Double {
        var closest = Double.infinity

        for template in templates {
            let durationRatio = duration / max(template.duration, 0.1)
            guard (0.62...1.85).contains(durationRatio) else {
                continue
            }

            let templateMovement = Self.movementMagnitude(template.vectors)
            guard movement >= max(templateMovement * 0.35, 0.006) else {
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

    private static func applyFeatureVarianceWeights(_ vectors: [PoseFeatureVector], boost: Double = 1.5) -> [PoseFeatureVector] {
        guard vectors.count > 1,
              let featureCount = vectors.first?.values.count,
              featureCount > 0
        else {
            return vectors
        }

        var means = Array(repeating: 0.0, count: featureCount)
        for v in vectors {
            for i in 0..<featureCount {
                means[i] += v.values[i]
            }
        }
        for i in 0..<featureCount {
            means[i] /= Double(vectors.count)
        }

        var stds = Array(repeating: 0.0, count: featureCount)
        for v in vectors {
            for i in 0..<featureCount {
                let diff = v.values[i] - means[i]
                stds[i] += diff * diff
            }
        }
        for i in 0..<featureCount {
            stds[i] = sqrt(stds[i] / Double(vectors.count))
        }

        guard let maxStd = stds.max(), maxStd > 0.001 else {
            return vectors
        }

        let varianceWeights: [Double] = stds.map { std in
            1.0 + boost * (std / maxStd)
        }

        return vectors.map { v in
            var boosted = v
            for i in 0..<featureCount {
                boosted.weights[i] *= varianceWeights[i]
            }
            return boosted
        }
    }

    private static let jointOrder: [PoseJointName] = [
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

    private static let angleTriples: [(PoseJointName, PoseJointName, PoseJointName)] = [
        (.leftShoulder, .leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow, .rightWrist),
        (.leftHip, .leftKnee, .leftAnkle),
        (.rightHip, .rightKnee, .rightAnkle),
        (.leftShoulder, .leftHip, .leftKnee),
        (.rightShoulder, .rightHip, .rightKnee),
        (.leftHip, .leftShoulder, .leftWrist),
        (.rightHip, .rightShoulder, .rightWrist)
    ]

    private static let leftArmLimbDirectionPairs: [(proximal: PoseJointName, distal: PoseJointName)] = [
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist)
    ]

    private static let rightArmLimbDirectionPairs: [(proximal: PoseJointName, distal: PoseJointName)] = [
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist)
    ]

    private static var limbDirectionFeatureCount: Int {
        leftArmLimbDirectionPairs.count + rightArmLimbDirectionPairs.count
    }

    private static var poseFeatureValueCount: Int {
        (jointOrder.count * 3) + angleTriples.count + limbDirectionFeatureCount
    }

    private static func featureVectors(from frames: [PoseFrame]) -> [PoseFeatureVector] {
        var previousPoseVector: PoseFeatureVector?

        return frames.map { frame in
            let poseVector = vector(from: frame)
            let velocity = previousPoseVector.map { previous in
                velocityFeatures(from: previous, to: poseVector)
            } ?? zeroVelocityFeatures()
            previousPoseVector = poseVector
            return poseVector.appending(velocity)
        }
    }

    private static func vector(from frame: PoseFrame) -> PoseFeatureVector {
        var values: [Double] = []
        var weights: [Double] = []

        for jointName in jointOrder {
            if let joint = frame.joint(jointName) {
                values.append(joint.x)
                values.append(joint.y)
                values.append(joint.z ?? 0)
                weights.append(joint.confidence)
                weights.append(joint.confidence)
                weights.append(joint.z == nil ? 0 : joint.confidence * 0.35)
            } else {
                values.append(0)
                values.append(0)
                values.append(0)
                weights.append(0)
                weights.append(0)
                weights.append(0)
            }
        }

        for feature in angleFeatures(in: frame) {
            values.append(feature.value)
            weights.append(feature.weight)
        }

        for feature in limbDirectionFeatures(in: frame) {
            values.append(feature.value)
            weights.append(feature.weight)
        }

        return PoseFeatureVector(values: values, weights: weights)
    }

    private static func limbDirectionFeatures(in frame: PoseFrame) -> [ScalarFeature] {
        var features: [ScalarFeature] = []

        for pair in leftArmLimbDirectionPairs + rightArmLimbDirectionPairs {
            guard let proximal = frame.joint(pair.proximal),
                  let distal = frame.joint(pair.distal)
            else {
                features.append(ScalarFeature(value: 0, weight: 0))
                continue
            }

            let verticalOffset = distal.y - proximal.y
            let weight = min(proximal.confidence, distal.confidence) * 0.75

            features.append(ScalarFeature(value: verticalOffset, weight: weight))
        }

        return features
    }

    private static func angleFeatures(in frame: PoseFrame) -> [ScalarFeature] {
        angleTriples.map { first, middle, last in
            guard let firstJoint = frame.joint(first),
                  let middleJoint = frame.joint(middle),
                  let lastJoint = frame.joint(last)
            else {
                return ScalarFeature(value: 0, weight: 0)
            }

            let firstVector = vector(from: middleJoint, to: firstJoint)
            let secondVector = vector(from: middleJoint, to: lastJoint)
            let firstMagnitude = magnitude(firstVector)
            let secondMagnitude = magnitude(secondVector)
            guard firstMagnitude > 0.0001, secondMagnitude > 0.0001 else {
                return ScalarFeature(value: 0, weight: 0)
            }

            let cosine = max(-1, min(1, dot(firstVector, secondVector) / (firstMagnitude * secondMagnitude)))
            return ScalarFeature(
                value: acos(cosine) / .pi,
                weight: min(firstJoint.confidence, middleJoint.confidence, lastJoint.confidence) * 0.8
            )
        }
    }

    private static func vector(from origin: PoseJoint, to target: PoseJoint) -> (x: Double, y: Double, z: Double) {
        (
            target.x - origin.x,
            target.y - origin.y,
            (target.z ?? 0) - (origin.z ?? 0)
        )
    }

    private static func dot(
        _ left: (x: Double, y: Double, z: Double),
        _ right: (x: Double, y: Double, z: Double)
    ) -> Double {
        (left.x * right.x) + (left.y * right.y) + (left.z * right.z)
    }

    private static func magnitude(_ value: (x: Double, y: Double, z: Double)) -> Double {
        sqrt((value.x * value.x) + (value.y * value.y) + (value.z * value.z))
    }

    private static func zeroVelocityFeatures() -> PoseFeatureVector {
        PoseFeatureVector(
            values: Array(repeating: 0, count: poseFeatureValueCount),
            weights: Array(repeating: 0, count: poseFeatureValueCount)
        )
    }

    private static func velocityFeatures(
        from previous: PoseFeatureVector,
        to current: PoseFeatureVector
    ) -> PoseFeatureVector {
        let valueCount = min(poseFeatureValueCount, previous.values.count, current.values.count)
        guard valueCount > 0 else {
            return zeroVelocityFeatures()
        }

        var values: [Double] = []
        var weights: [Double] = []
        values.reserveCapacity(poseFeatureValueCount)
        weights.reserveCapacity(poseFeatureValueCount)

        for index in 0..<valueCount {
            values.append(current.values[index] - previous.values[index])
            weights.append(min(previous.weights[index], current.weights[index]) * 0.55)
        }

        while values.count < poseFeatureValueCount {
            values.append(0)
            weights.append(0)
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

    func distance(to other: PoseFeatureVector, limitedTo valueLimit: Int? = nil) -> Double {
        let comparedCount: Int
        if let valueLimit {
            comparedCount = min(valueLimit, values.count, other.values.count, weights.count, other.weights.count)
        } else {
            guard values.count == other.values.count, weights.count == other.weights.count else {
                return .infinity
            }
            comparedCount = values.count
        }

        guard comparedCount > 0 else {
            return .infinity
        }

        var weightedSum = 0.0
        var totalWeight = 0.0

        for index in 0..<comparedCount {
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

    func appending(_ other: PoseFeatureVector) -> PoseFeatureVector {
        PoseFeatureVector(
            values: values + other.values,
            weights: weights + other.weights
        )
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
