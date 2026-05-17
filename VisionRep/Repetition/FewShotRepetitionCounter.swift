import Foundation

nonisolated struct MovementTemplate: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var index: Int
    var capturedAt: Date
    var sourceFrameCount: Int
    var duration: TimeInterval
    var qualityScore: Double
    var vectors: [PoseFeatureVector]
    var depthCoverage: Double
    var phaseProfile: MovementPhaseProfile

    private enum CodingKeys: String, CodingKey {
        case id
        case index
        case capturedAt
        case sourceFrameCount
        case duration
        case qualityScore
        case vectors
        case depthCoverage
        case phaseProfile
    }

    init(
        id: UUID = UUID(),
        index: Int,
        capturedAt: Date,
        sourceFrameCount: Int,
        duration: TimeInterval,
        qualityScore: Double,
        vectors: [PoseFeatureVector],
        depthCoverage: Double = 0,
        phaseProfile: MovementPhaseProfile = MovementPhaseProfile()
    ) {
        self.id = id
        self.index = index
        self.capturedAt = capturedAt
        self.sourceFrameCount = sourceFrameCount
        self.duration = duration
        self.qualityScore = qualityScore
        self.vectors = vectors
        self.depthCoverage = depthCoverage
        self.phaseProfile = phaseProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        index = try container.decode(Int.self, forKey: .index)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        sourceFrameCount = try container.decode(Int.self, forKey: .sourceFrameCount)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        qualityScore = try container.decode(Double.self, forKey: .qualityScore)
        vectors = try container.decode([PoseFeatureVector].self, forKey: .vectors)
        depthCoverage = try container.decodeIfPresent(Double.self, forKey: .depthCoverage) ?? 0
        phaseProfile = try container.decodeIfPresent(MovementPhaseProfile.self, forKey: .phaseProfile) ?? MovementPhaseProfile()
    }
}

nonisolated enum MovementComplexity: String, Codable, Equatable, Sendable {
    case simple
    case medium
    case complex
}

nonisolated struct MovementPhaseProfile: Codable, Equatable, Sendable {
    var checkpointIndices: [Int]
    var complexity: MovementComplexity

    private enum CodingKeys: String, CodingKey {
        case checkpointIndices
        case complexity
    }

    init(checkpointIndices: [Int] = [], complexity: MovementComplexity = .complex) {
        self.checkpointIndices = checkpointIndices
        self.complexity = complexity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checkpointIndices = try container.decodeIfPresent([Int].self, forKey: .checkpointIndices) ?? []
        complexity = try container.decodeIfPresent(MovementComplexity.self, forKey: .complexity) ?? .complex
    }
}

nonisolated struct CountUpdate: Equatable, Sendable {
    var repetitions: Int
    var confidence: Double
    var bestScore: Double
    var matchedTemplateIndex: Int?
    var matchedTemplateSource: TemplateMatchSource?
    var onlineTemplateCount = 0
    var phaseProgress = 0.0
    var pendingRepetition = false
    var didCalibrateView = false
}

nonisolated enum TemplateMatchSource: String, Equatable, Sendable {
    case anchor
    case online
    case calibration
}

nonisolated final class FewShotRepetitionCounter {
    private let sampleCount = 48
    private let maxOnlineTemplateCount = 4
    private let onlinePromotionConfidenceThreshold = 0.5
    private let minimumCompletionConfidence = 0.55
    private let conservativeCountGateRepetitionLimit = 10
    private let conservativeCompletionCoverageRatio = 0.6
    private let relaxedCompletionCoverageRatio = 0.38
    private let complexCompletionCoverageRatio = 0.2
    private static let anchorPassThroughScore = 0.0
    private var templates: [MovementTemplate] = []
    private var onlineTemplates: [OnlineTemplateRecord] = []
    private var calibrationTemplates: [MovementTemplate] = []
    private var anchorThreshold: Double = 0.22
    private var depthMatchingEnabled = true
    private var buffer: [BufferedPoseFrame] = []
    private var pendingCompletion: PendingCompletion?
    private var streamingPhaseCounter = StreamingPhaseCounter()
    private var phaseTracker = PhaseProgressTracker()
    private var lastCompletionPoseVector: PoseFeatureVector?
    private var hasExitedCompletionPoseSinceLastCount = true
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

    private struct BufferedPoseFrame {
        var frame: PoseFrame
        var poseVector: PoseFeatureVector

        var timestamp: TimeInterval {
            frame.timestamp
        }
    }

    private struct PhaseProgressTracker {
        struct Signal {
            var progress: Double
        }

        mutating func update(frameCount: Int, expectedFrameCount: Int) -> Signal {
            let expected = max(expectedFrameCount, 1)
            return Signal(progress: min(max(Double(frameCount) / Double(expected), 0), 1))
        }

        mutating func reset() {}
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

    private struct StreamingPhaseCompletion {
        var record: TemplateRecord
        var startedAt: TimeInterval
        var completedAt: TimeInterval
        var averageCheckpointScore: Double
    }

    private struct StreamingPhaseResult {
        var progress: Double
        var confidence: Double
        var bestScore: Double
        var matchedTemplateIndex: Int?
        var matchedTemplateSource: TemplateMatchSource?
        var completion: StreamingPhaseCompletion?
    }

    private struct StreamingPhaseCounter {
        private struct Track {
            var nextCheckpointCursor = 0
            var startedAt: TimeInterval?
            var lastAdvancedAt: TimeInterval?
            var completedAt: TimeInterval?
            var lastAcceptedVector: PoseFeatureVector?
            var scoreSum = 0.0
        }

        private var tracks: [UUID: Track] = [:]

        mutating func reset() {
            tracks.removeAll(keepingCapacity: true)
        }

        mutating func update(
            with poseVector: PoseFeatureVector,
            at timestamp: TimeInterval,
            records: [TemplateRecord],
            anchorThreshold: Double,
            completionGateOpen: Bool
        ) -> StreamingPhaseResult {
            let liveIDs = Set(records.map(\.template.id))
            tracks = tracks.filter { liveIDs.contains($0.key) }

            var bestProgress = 0.0
            var bestConfidence = 0.0
            var bestScore = Double.infinity
            var matchedTemplateIndex: Int?
            var matchedTemplateSource: TemplateMatchSource?
            var completion: StreamingPhaseCompletion?

            for record in records {
                let template = record.template
                let checkpoints = Self.checkpoints(for: template)
                guard checkpoints.count >= 2 else {
                    continue
                }

                var track = tracks[template.id] ?? Track()
                if let lastAdvancedAt = track.lastAdvancedAt,
                   timestamp - lastAdvancedAt > Self.timeout(for: template) {
                    track = Track()
                }

                let expectedCursor = min(track.nextCheckpointCursor, checkpoints.count - 1)
                let checkpointIndex = checkpoints[expectedCursor]
                let checkpointVector = template.vectors[checkpointIndex]
                let distance = poseVector.distance(
                    to: checkpointVector,
                    limitedTo: FewShotRepetitionCounter.poseFeatureValueCount
                )
                let threshold = Self.threshold(
                    forCursor: expectedCursor,
                    checkpointCount: checkpoints.count,
                    template: template,
                    anchorThreshold: anchorThreshold
                )

                if distance <= threshold,
                   Self.didMoveEnoughSinceLastCheckpoint(
                       poseVector,
                       track: track,
                       expectedCursor: expectedCursor,
                       checkpoints: checkpoints,
                       template: template,
                       anchorThreshold: anchorThreshold
                   ) {
                    if track.nextCheckpointCursor == 0 {
                        track.startedAt = timestamp
                        track.scoreSum = 0
                    }
                    track.scoreSum += distance
                    track.nextCheckpointCursor = min(track.nextCheckpointCursor + 1, checkpoints.count)
                    track.lastAdvancedAt = timestamp
                    track.lastAcceptedVector = poseVector

                    if track.nextCheckpointCursor >= checkpoints.count,
                       completionGateOpen,
                       let startedAt = track.startedAt {
                        track.completedAt = timestamp
                        let averageScore = track.scoreSum / Double(checkpoints.count)
                        let candidateCompletion = StreamingPhaseCompletion(
                            record: record,
                            startedAt: startedAt,
                            completedAt: timestamp,
                            averageCheckpointScore: averageScore
                        )
                        if completion == nil || averageScore < completion!.averageCheckpointScore {
                            completion = candidateCompletion
                        }
                    }
                }

                if completionGateOpen,
                   track.nextCheckpointCursor >= checkpoints.count,
                   let startedAt = track.startedAt,
                   let completedAt = track.completedAt {
                    let averageScore = track.scoreSum / Double(checkpoints.count)
                    let candidateCompletion = StreamingPhaseCompletion(
                        record: record,
                        startedAt: startedAt,
                        completedAt: completedAt,
                        averageCheckpointScore: averageScore
                    )
                    if completion == nil || averageScore < completion!.averageCheckpointScore {
                        completion = candidateCompletion
                    }
                }

                let progress = Double(track.nextCheckpointCursor) / Double(checkpoints.count)
                let confidence = Self.confidence(score: distance, threshold: threshold)
                if progress > bestProgress || (progress == bestProgress && distance < bestScore) {
                    bestProgress = progress
                    bestConfidence = confidence
                    bestScore = distance
                    matchedTemplateIndex = template.index
                    matchedTemplateSource = record.source
                }

                tracks[template.id] = track
            }

            if let completion {
                bestProgress = 1
                bestConfidence = max(bestConfidence, Self.confidence(score: completion.averageCheckpointScore, threshold: anchorThreshold))
                bestScore = min(bestScore, completion.averageCheckpointScore)
                matchedTemplateIndex = completion.record.template.index
                matchedTemplateSource = completion.record.source
            }

            return StreamingPhaseResult(
                progress: bestProgress,
                confidence: bestConfidence,
                bestScore: bestScore,
                matchedTemplateIndex: matchedTemplateIndex,
                matchedTemplateSource: matchedTemplateSource,
                completion: completion
            )
        }

        private static func checkpoints(for template: MovementTemplate) -> [Int] {
            let maximumIndex = max(template.vectors.count - 1, 0)
            let learned = template.phaseProfile.checkpointIndices
                .filter { $0 >= 0 && $0 <= maximumIndex }
            if learned.count >= 2 {
                return learned
            }
            return [0, maximumIndex]
        }

        private static func threshold(
            forCursor cursor: Int,
            checkpointCount: Int,
            template: MovementTemplate,
            anchorThreshold: Double
        ) -> Double {
            let isTerminal = cursor == checkpointCount - 1
            let isStart = cursor == 0
            if isStart || isTerminal {
                return max(min(anchorThreshold * 0.82, 0.18), 0.075)
            }

            switch template.phaseProfile.complexity {
            case .simple:
                return max(min(anchorThreshold * 1.8, 0.36), 0.16)
            case .medium:
                return max(min(anchorThreshold * 2.2, 0.46), 0.20)
            case .complex:
                return max(min(anchorThreshold * 1.15, 0.26), 0.105)
            }
        }

        private static func timeout(for template: MovementTemplate) -> TimeInterval {
            max(template.duration * 2.4, 2.5)
        }

        private static func didMoveEnoughSinceLastCheckpoint(
            _ poseVector: PoseFeatureVector,
            track: Track,
            expectedCursor: Int,
            checkpoints: [Int],
            template: MovementTemplate,
            anchorThreshold: Double
        ) -> Bool {
            guard expectedCursor > 0,
                  let lastAcceptedVector = track.lastAcceptedVector
            else {
                return true
            }

            let movementSinceLastCheckpoint = poseVector.distance(
                to: lastAcceptedVector,
                limitedTo: FewShotRepetitionCounter.poseFeatureValueCount
            )
            let requiredMovement = minimumCheckpointStepDistance(
                expectedCursor: expectedCursor,
                checkpoints: checkpoints,
                template: template,
                anchorThreshold: anchorThreshold
            )
            return movementSinceLastCheckpoint >= requiredMovement
        }

        private static func minimumCheckpointStepDistance(
            expectedCursor: Int,
            checkpoints: [Int],
            template: MovementTemplate,
            anchorThreshold: Double
        ) -> Double {
            let previousIndex = checkpoints[max(expectedCursor - 1, 0)]
            let currentIndex = checkpoints[min(expectedCursor, checkpoints.count - 1)]
            let trainedStepDistance = template.vectors[currentIndex].distance(
                to: template.vectors[previousIndex],
                limitedTo: FewShotRepetitionCounter.poseFeatureValueCount
            )
            let floor = max(min(anchorThreshold * 0.16, 0.04), 0.018)
            return max(min(trainedStepDistance * 0.28, 0.12), floor)
        }

        private static func confidence(score: Double, threshold: Double) -> Double {
            guard score.isFinite else {
                return 0
            }
            let ratio = score / max(threshold, 0.001)
            return max(0, min(1, 1 - pow(ratio, 1.35)))
        }
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

    var adaptiveCalibrationTemplateCount: Int {
        calibrationTemplates.count
    }

    func resetCount() {
        buffer.removeAll(keepingCapacity: true)
        pendingCompletion = nil
        streamingPhaseCounter.reset()
        phaseTracker.reset()
        lastCompletionPoseVector = nil
        hasExitedCompletionPoseSinceLastCount = true
        lastCountTimestamp = -.infinity
        repetitions = 0
        confidence = 0
        bestScore = .infinity
    }

    func load(templates: [MovementTemplate]) {
        let loadedTemplates = templates.map(Self.templateWithDepthCoverage)
        depthMatchingEnabled = !Self.shouldDisableDepthMatching(for: loadedTemplates)
        self.templates = depthMatchingEnabled ? loadedTemplates : loadedTemplates.map(Self.templateWithoutDepthFeatures)
        onlineTemplates.removeAll(keepingCapacity: true)
        calibrationTemplates.removeAll(keepingCapacity: true)
        anchorThreshold = Self.learnThreshold(from: self.templates)
        resetCount()
    }

    func clearOnlineTemplates() {
        onlineTemplates.removeAll(keepingCapacity: true)
        calibrationTemplates.removeAll(keepingCapacity: true)
    }

    func makeTemplate(index: Int, frames: [PoseFrame], averageQuality: Double) -> MovementTemplate? {
        guard frames.count >= 20 else { return nil }
        let normalized = resample(Self.featureVectors(from: frames), targetCount: sampleCount)
        guard normalized.count == sampleCount else { return nil }
        let weighted = Self.applyFeatureVarianceWeights(normalized)

        let duration = max((frames.last?.timestamp ?? 0) - (frames.first?.timestamp ?? 0), 0.1)
        return MovementTemplate(
            index: index,
            capturedAt: Date(),
            sourceFrameCount: frames.count,
            duration: duration,
            qualityScore: averageQuality,
            vectors: weighted,
            depthCoverage: Self.depthCoverage(in: weighted),
            phaseProfile: Self.learnedPhaseProfile(for: weighted)
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
                onlineTemplateCount: onlineTemplateCount,
                phaseProgress: 0,
                pendingRepetition: false,
                didCalibrateView: false
            )
        }

        let currentPoseVector = Self.vector(from: frame)
        buffer.append(BufferedPoseFrame(frame: frame, poseVector: currentPoseVector))
        trimBuffer(now: frame.timestamp)
        expirePendingCompletion(now: frame.timestamp)
        updateCompletionResetGate(with: currentPoseVector)

        let cooldownElapsed = frame.timestamp - lastCountTimestamp > completionCooldown
        let completionGateOpen = cooldownElapsed && hasExitedCompletionPoseSinceLastCount
        let streamingResult = streamingPhaseCounter.update(
            with: currentPoseVector,
            at: frame.timestamp,
            records: matchingTemplates,
            anchorThreshold: anchorThreshold,
            completionGateOpen: completionGateOpen
        )
        let completedCandidate = terminalCompletionCandidate(
            currentFrame: frame,
            currentPoseVector: currentPoseVector,
            completionGateOpen: completionGateOpen,
            streamingProgress: streamingResult.progress,
            streamingCompletion: streamingResult.completion
        )

        let acceptedCompletedCandidate = completedCandidate.flatMap { candidate in
            completionConfidencePasses(candidate) ? candidate : nil
        }

        var didCalibrateView = false
        let didCompleteRepetition = acceptedCompletedCandidate != nil && completionGateOpen
        if let completedCandidate = acceptedCompletedCandidate, completionGateOpen {
            repetitions += 1
            lastCountTimestamp = frame.timestamp
            lastCompletionPoseVector = currentPoseVector
            hasExitedCompletionPoseSinceLastCount = false
            didCalibrateView = promoteAdaptiveCalibrationTemplate(from: completedCandidate)
            promoteOnlineTemplate(from: completedCandidate)
            pendingCompletion = nil
            streamingPhaseCounter.reset()
            buffer.removeAll(keepingCapacity: true)
        }

        bestScore = acceptedCompletedCandidate?.score ?? streamingResult.bestScore
        confidence = acceptedCompletedCandidate.map(confidence(for:)) ?? streamingResult.confidence
        let rawPhaseProgress = streamingResult.progress
        let hasMeaningfulProgressMotion = visibleProgressMotionPasses()
        return CountUpdate(
            repetitions: repetitions,
            confidence: confidence,
            bestScore: bestScore,
            matchedTemplateIndex: acceptedCompletedCandidate?.templateIndex ?? streamingResult.matchedTemplateIndex,
            matchedTemplateSource: acceptedCompletedCandidate?.source ?? streamingResult.matchedTemplateSource,
            onlineTemplateCount: onlineTemplateCount,
            phaseProgress: displayedPhaseProgress(
                rawProgress: rawPhaseProgress,
                hasDisplayCandidate: streamingResult.progress > 0,
                hasMeaningfulMotion: hasMeaningfulProgressMotion,
                isCompletionPending: false,
                didCompleteRepetition: didCompleteRepetition,
                hasExitedCompletionPose: hasExitedCompletionPoseSinceLastCount
            ),
            pendingRepetition: false,
            didCalibrateView: didCalibrateView
        )
    }

    private func trimBuffer(now: TimeInterval) {
        let longestTemplate = matchingTemplates.map(\.template.duration).max() ?? 4
        let window = max(10, longestTemplate * 2.4)
        buffer.removeAll { now - $0.timestamp > window }
    }

    private func updatePhaseTrackers(with frame: PoseFrame) -> PhaseProgressTracker.Signal? {
        let expectedFrameCount = max(templates.map(\.sourceFrameCount).min() ?? sampleCount, 1)
        return phaseTracker.update(frameCount: buffer.count, expectedFrameCount: expectedFrameCount)
    }

    private func displayedPhaseProgress(
        rawProgress: Double,
        hasDisplayCandidate: Bool,
        hasMeaningfulMotion: Bool,
        isCompletionPending: Bool,
        didCompleteRepetition: Bool,
        hasExitedCompletionPose: Bool
    ) -> Double {
        let clampedProgress = min(max(rawProgress, 0), 1)
        if didCompleteRepetition {
            return 0
        }
        if !hasExitedCompletionPose {
            return 0
        }
        if !hasMeaningfulMotion && clampedProgress <= 0.34 {
            return 0
        }
        if isCompletionPending || hasDisplayCandidate {
            return min(clampedProgress, 0.96)
        }
        if hasMeaningfulMotion {
            return min(clampedProgress, 0.85)
        }
        return 0
    }

    private func visibleProgressMotionPasses() -> Bool {
        guard buffer.count >= 3 else {
            return false
        }

        let recentFrameCount = min(buffer.count, 24)
        let recentVectors = buffer.suffix(recentFrameCount).map(\.poseVector)
        let recentMovement = Self.movementMagnitude(recentVectors)
        let trainedMovement = templates
            .map { Self.movementMagnitude($0.vectors) }
            .min() ?? 0
        let motionThreshold = max(min(trainedMovement * 0.18, 0.035), 0.01)
        return recentMovement >= motionThreshold
    }

    private func bestCandidate(matching phaseSignal: PhaseProgressTracker.Signal?) -> Candidate? {
        guard buffer.count >= 18 else {
            return nil
        }
        if phaseSignal != nil, let pendingCompletion {
            return pendingCompletion.candidate
        }

        let bufferPoseVectors = buffer.map(\.poseVector)
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
                let segmentSlice = buffer.suffix(length)
                guard segmentDuration(segmentSlice) >= minimumCandidateDuration(for: template) else {
                    continue
                }
                let segmentVectors = Self.featureVectors(fromPoseVectors: bufferPoseVectors.suffix(length))
                let vectors = resample(segmentVectors, targetCount: sampleCount)
                let comparableVectors = depthMatchingEnabled ? vectors : Self.withoutDepthFeatures(vectors)
                let candidateMovement = Self.movementMagnitude(comparableVectors)
                guard candidateMovement >= minimumCandidateMovement(for: template) else {
                    continue
                }
                let candidateThreshold = acceptanceThreshold(for: record.source)
                guard Self.phaseGatePasses(comparableVectors, template: template, acceptanceThreshold: candidateThreshold) else {
                    continue
                }
                let score = Self.distance(comparableVectors, template.vectors)
                guard score <= max(candidateThreshold * 1.25, candidateThreshold + 0.05) else {
                    continue
                }
                let candidateRank = score / max(candidateThreshold, 0.001)
                let bestRank = best.map { $0.score / max($0.acceptanceThreshold, 0.001) } ?? .infinity
                guard candidateRank < bestRank else {
                    continue
                }

                let anchorScore = record.source == .anchor
                    ? Self.anchorPassThroughScore
                    : closestAnchorScore(
                        to: comparableVectors,
                        duration: segmentDuration(segmentSlice),
                        movement: candidateMovement
                    )

                guard record.source == .anchor || anchorCorroborates(anchorScore) else {
                    continue
                }

                if candidateRank < bestRank {
                    best = Candidate(
                        score: score,
                        templateIndex: template.index,
                        source: record.source,
                        template: template,
                        acceptanceThreshold: candidateThreshold,
                        segment: segmentSlice.map(\.frame),
                        vectors: comparableVectors,
                        anchorScore: anchorScore,
                        averageQuality: Self.averageJointConfidence(in: segmentSlice)
                    )
                }
            }
        }

        return best
    }

    private var matchingTemplates: [TemplateRecord] {
        templates.map { TemplateRecord(template: $0, source: .anchor) }
            + onlineTemplates.map { TemplateRecord(template: $0.template, source: .online) }
            + calibrationTemplates.map { TemplateRecord(template: $0, source: .calibration) }
    }

    private var completionCooldown: TimeInterval {
        let shortestTemplate = templates.map(\.duration).min() ?? 1.6
        if repetitions < conservativeCountGateRepetitionLimit {
            return max(1.1, shortestTemplate * 0.55)
        }
        return max(0.45, shortestTemplate * 0.22)
    }

    private func acceptanceThreshold(for source: TemplateMatchSource) -> Double {
        switch source {
        case .anchor:
            anchorThreshold
        case .online:
            onlineAcceptanceThreshold
        case .calibration:
            max(0.11, anchorThreshold * 0.82)
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
        let lowerBound = min(18, availableCount)
        let upperBound = availableCount

        guard lowerBound <= upperBound else {
            return nil
        }
        return lowerBound...upperBound
    }

    private func minimumCandidateDuration(for template: MovementTemplate) -> TimeInterval {
        max(min(template.duration * 0.08, 0.25), 0.05)
    }

    private func segmentDuration(_ segment: [PoseFrame]) -> TimeInterval {
        segmentDuration(segment[...])
    }

    private func segmentDuration(_ segment: [BufferedPoseFrame]) -> TimeInterval {
        segmentDuration(segment[...])
    }

    private func segmentDuration(_ segment: ArraySlice<PoseFrame>) -> TimeInterval {
        guard let first = segment.first, let last = segment.last else {
            return 0
        }
        return max(last.timestamp - first.timestamp, 0)
    }

    private func segmentDuration(_ segment: ArraySlice<BufferedPoseFrame>) -> TimeInterval {
        guard let first = segment.first, let last = segment.last else {
            return 0
        }
        return max(last.timestamp - first.timestamp, 0)
    }

    private func minimumCandidateMovement(for template: MovementTemplate) -> Double {
        let minimumFloor: Double
        switch template.phaseProfile.complexity {
        case .simple:
            minimumFloor = 0.0015
        case .medium:
            minimumFloor = 0.0035
        case .complex:
            minimumFloor = 0.006
        }
        return max(Self.movementMagnitude(template.vectors) * 0.35, minimumFloor)
    }

    private func anchorCorroborates(_ anchorScore: Double) -> Bool {
        anchorScore <= min(max(anchorThreshold * 1.35, anchorThreshold + 0.04), 0.42)
    }

    private func rememberPendingCompletion(_ candidate: Candidate, now: TimeInterval) {
        guard completionCandidateHasEnoughCoverage(candidate),
              completionConfidencePasses(candidate)
        else {
            return
        }

        let expiresAt = now + max(0.35, candidate.template.duration * 0.12)
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

    private func immediateCompletionCandidate(
        from candidate: Candidate?,
        currentFrame frame: PoseFrame,
        completionGateOpen: Bool
    ) -> Candidate? {
        guard let candidate,
              completionGateOpen,
              candidate.score <= candidate.acceptanceThreshold,
              completionCandidateHasEnoughCoverage(candidate),
              completionConfidencePasses(candidate),
              terminalCompletionPasses(candidate, with: frame, requiresCandidateEndVector: true)
        else {
            return nil
        }

        return candidate
    }

    private func updateCompletionResetGate(with currentVector: PoseFeatureVector) {
        guard !hasExitedCompletionPoseSinceLastCount,
              let lastCompletionPoseVector
        else {
            return
        }

        let exitDistance = currentVector.distance(
            to: lastCompletionPoseVector,
            limitedTo: Self.poseFeatureValueCount
        )
        if exitDistance >= completionResetThreshold {
            hasExitedCompletionPoseSinceLastCount = true
        }
    }

    private func makeStreamingCompletionCandidate(from completion: StreamingPhaseCompletion) -> Candidate? {
        var segment = buffer.filter { item in
            item.timestamp >= completion.startedAt && item.timestamp <= completion.completedAt
        }
        if segment.count < 2 {
            segment = Array(buffer.suffix(min(buffer.count, completion.record.template.sourceFrameCount)))
        }
        let template = completion.record.template
        let requiredFrameCount = Int((Double(template.sourceFrameCount) * streamingCompletionCoverageRatio(for: template)).rounded(.up))
        if segment.count < requiredFrameCount {
            segment = Array(buffer.suffix(min(buffer.count, template.sourceFrameCount)))
        }
        guard segment.count >= 2 else {
            return nil
        }

        guard segment.count >= max(requiredFrameCount, 2) else {
            return nil
        }

        let segmentPoseVectors = segment.map(\.poseVector)
        let segmentVectors = Self.featureVectors(fromPoseVectors: segmentPoseVectors[...])
        let vectors = resample(segmentVectors, targetCount: sampleCount)
        let comparableVectors = depthMatchingEnabled ? vectors : Self.withoutDepthFeatures(vectors)
        guard comparableVectors.count == sampleCount else {
            return nil
        }

        let candidateMovement = Self.movementMagnitude(comparableVectors)
        let threshold = acceptanceThreshold(for: completion.record.source)
        guard Self.phaseGatePasses(comparableVectors, template: template, acceptanceThreshold: threshold) else {
            return nil
        }
        if template.phaseProfile.complexity == .complex {
            let templateDepthMotion = Self.depthMotionMagnitude(template.vectors)
            let candidateDepthMotion = Self.depthMotionMagnitude(comparableVectors)
            if templateDepthMotion >= 0.01,
               candidateDepthMotion < templateDepthMotion * 0.7 {
                return nil
            }
        }
        let templateDistance = Self.distance(comparableVectors, template.vectors)
        let distanceLimit: Double
        if template.phaseProfile.complexity == .complex {
            distanceLimit = max(threshold * 0.42, threshold - 0.08)
        } else {
            distanceLimit = max(threshold * 1.4, threshold + 0.08)
        }
        guard templateDistance <= distanceLimit else {
            return nil
        }
        let score = templateDistance

        let anchorScore = completion.record.source == .anchor
            ? Self.anchorPassThroughScore
            : closestAnchorScore(
                to: comparableVectors,
                duration: segmentDuration(segment),
                movement: candidateMovement
            )
        return Candidate(
            score: score,
            templateIndex: template.index,
            source: completion.record.source,
            template: template,
            acceptanceThreshold: threshold,
            segment: segment.map(\.frame),
            vectors: comparableVectors,
            anchorScore: anchorScore,
            averageQuality: Self.averageJointConfidence(in: segment)
        )
    }

    private func streamingCompletionCoverageRatio(for template: MovementTemplate) -> Double {
        switch template.phaseProfile.complexity {
        case .simple:
            return 0.45
        case .medium:
            return 0.58
        case .complex:
            return 0.2
        }
    }

    private var completionResetThreshold: Double {
        max(min(anchorThreshold * 0.25, 0.08), 0.025)
    }

    private func terminalCompletionCandidate(
        currentFrame frame: PoseFrame,
        currentPoseVector: PoseFeatureVector,
        completionGateOpen: Bool,
        streamingProgress: Double,
        streamingCompletion: StreamingPhaseCompletion?
    ) -> Candidate? {
        let primaryTemplate = matchingTemplates.first?.template
        guard completionGateOpen,
              streamingProgress >= completionProgressGate(for: primaryTemplate),
              terminalPoseMatchesAnyTemplate(currentPoseVector)
        else {
            return nil
        }

        if matchingTemplates.first?.template.phaseProfile.complexity != .complex {
            if let candidate = bestCandidate(matching: nil),
               candidate.score <= candidate.acceptanceThreshold,
               completionCandidateHasEnoughCoverage(candidate),
               completionConfidencePasses(candidate),
               terminalCompletionPasses(candidate, with: frame, requiresCandidateEndVector: true) {
                return candidate
            }
        }

        let synthesizedCompletion = streamingCompletion ?? matchingTemplates.first { record in
            record.template.index == candidateMatchedTemplateIndex(fromProgress: streamingProgress)
        }.map { record in
            StreamingPhaseCompletion(
                record: record,
                startedAt: buffer.first?.timestamp ?? frame.timestamp,
                completedAt: frame.timestamp,
                averageCheckpointScore: 0
            )
        }

        guard let synthesizedCompletion,
              let streamingCandidate = makeStreamingCompletionCandidate(from: synthesizedCompletion)
        else {
            return nil
        }

        return streamingCandidate
    }

    private func completionProgressGate(for template: MovementTemplate?) -> Double {
        switch template?.phaseProfile.complexity {
        case .simple:
            return 0.95
        case .medium:
            return 0.95
        case .complex:
            return 0.98
        case nil:
            return 0.9
        }
    }

    private func candidateMatchedTemplateIndex(fromProgress progress: Double) -> Int? {
        guard progress >= 1 else {
            return nil
        }
        return matchingTemplates.first?.template.index
    }

    private func terminalPoseMatchesAnyTemplate(_ currentPoseVector: PoseFeatureVector) -> Bool {
        matchingTemplates.contains { record in
            guard let endVector = record.template.vectors.last else {
                return false
            }
            let distance = currentPoseVector.distance(
                to: endVector,
                limitedTo: Self.poseFeatureValueCount
            )
            return distance <= completionPoseThreshold(for: record.template)
        }
    }

    private func shouldRunFallbackVerifier(candidate: Candidate?) -> Bool {
        candidate == nil || pendingCompletion != nil
    }

    private func completionConfidencePasses(_ candidate: Candidate) -> Bool {
        confidence(for: candidate) >= minimumCompletionConfidence
    }

    private func completedPendingCandidate(with frame: PoseFrame) -> Candidate? {
        guard let pendingCompletion else { return nil }
        guard terminalCompletionPasses(pendingCompletion.candidate, with: frame, requiresCandidateEndVector: false) else { return nil }
        return pendingCompletion.candidate
    }

    private func terminalCompletionPasses(
        _ candidate: Candidate,
        with frame: PoseFrame,
        requiresCandidateEndVector: Bool
    ) -> Bool {
        guard completionPoseMatches(frame, candidate: candidate) else {
            return false
        }
        if requiresCandidateEndVector,
           !candidateCompletesImmediately(candidate, with: frame) {
            return false
        }
        if completionPoseIsStable() {
            return true
        }
        if candidate.template.phaseProfile.complexity == .complex {
            return true
        }
        return candidate.segment.count >= min(candidate.template.sourceFrameCount, sampleCount)
    }

    private func candidateCompletesImmediately(_ candidate: Candidate, with frame: PoseFrame) -> Bool {
        guard completionPoseMatches(frame, candidate: candidate),
              let candidateEndVector = candidate.vectors.last,
              let templateEndVector = candidate.template.vectors.last
        else {
            return false
        }

        let endPoseDistance = candidateEndVector.distance(
            to: templateEndVector,
            limitedTo: Self.poseFeatureValueCount
        )
        return endPoseDistance <= completionPoseThreshold(for: candidate.template)
    }

    private func expirePendingCompletion(now: TimeInterval) {
        guard let pendingCompletion, now > pendingCompletion.expiresAt else { return }
        self.pendingCompletion = nil
    }

    private func completionCandidateHasEnoughCoverage(_ candidate: Candidate) -> Bool {
        candidate.segment.count >= minimumTerminalCandidateFrameCount(for: candidate.template)
    }

    private func minimumTerminalCandidateFrameCount(for template: MovementTemplate) -> Int {
        let coverageRatio: Double
        if template.phaseProfile.complexity == .complex {
            coverageRatio = complexCompletionCoverageRatio
        } else if repetitions < conservativeCountGateRepetitionLimit {
            coverageRatio = conservativeCompletionCoverageRatio
        } else {
            coverageRatio = relaxedCompletionCoverageRatio
        }
        let requiredFrameCount = Int((Double(template.sourceFrameCount) * coverageRatio).rounded(.up))
        let minimumFloor = template.phaseProfile.complexity == .complex ? 18 : 24
        return min(max(requiredFrameCount, minimumFloor), sampleCount)
    }

    private func completionPoseMatches(_ frame: PoseFrame, candidate: Candidate) -> Bool {
        guard let endVector = candidate.template.vectors.last else { return false }
        let currentVector = Self.vector(from: frame)
        let endPoseDistance = currentVector.distance(to: endVector, limitedTo: Self.poseFeatureValueCount)
        return endPoseDistance <= completionPoseThreshold(for: candidate.template)
    }

    private func completionPoseIsStable() -> Bool {
        let recentFrames = Array(buffer.suffix(3))
        guard recentFrames.count >= 2 else { return false }

        let vectors = recentFrames.map(\.poseVector)
        let largestStep = zip(vectors, vectors.dropFirst()).map { pair in
            pair.0.distance(to: pair.1, limitedTo: Self.poseFeatureValueCount)
        }.max() ?? .infinity

        return largestStep <= max(anchorThreshold * 0.12, 0.025)
    }

    private func completionPoseThreshold(for template: MovementTemplate) -> Double {
        max(min(anchorThreshold * 0.85, 0.18), 0.08)
    }

    private static func phaseGatePasses(
        _ vectors: [PoseFeatureVector],
        template: MovementTemplate,
        acceptanceThreshold: Double
    ) -> Bool {
        guard vectors.count == template.vectors.count, vectors.count >= 5 else {
            return false
        }

        let checkpoints = template.phaseProfile.checkpointIndices.isEmpty
            ? Self.phaseCheckpointIndices(for: vectors)
            : template.phaseProfile.checkpointIndices

        let poseThreshold = max(min(acceptanceThreshold * 1.55, 0.34), 0.14)
        let middleThreshold = max(min(acceptanceThreshold * 1.9, 0.42), 0.18)
        let startDistance = vectors[checkpoints[0]].distance(
            to: template.vectors[checkpoints[0]],
            limitedTo: Self.poseFeatureValueCount
        )
        let endCheckpoint = checkpoints.last ?? (vectors.count - 1)
        let endDistance = vectors[endCheckpoint].distance(
            to: template.vectors[endCheckpoint],
            limitedTo: Self.poseFeatureValueCount
        )

        guard startDistance <= poseThreshold, endDistance <= poseThreshold else {
            return false
        }

        let middleCheckpoints = checkpoints.dropFirst().dropLast()
        let middlePassCount = middleCheckpoints.filter { checkpoint in
            vectors[checkpoint].distance(
                to: template.vectors[checkpoint],
                limitedTo: Self.poseFeatureValueCount
            ) <= middleThreshold
        }.count

        let requiredMiddlePassCount: Int
        if template.phaseProfile.complexity == .complex {
            requiredMiddlePassCount = max(min(middleCheckpoints.count, middleCheckpoints.count - 1), 3)
        } else {
            requiredMiddlePassCount = min(3, middleCheckpoints.count)
        }

        guard middlePassCount >= requiredMiddlePassCount else {
            return false
        }

        guard Self.depthGatePasses(vectors, template: template, acceptanceThreshold: acceptanceThreshold) else {
            return false
        }

        return true
    }

    private static func phaseCheckpointIndices(for vectors: [PoseFeatureVector]) -> [Int] {
        phaseCheckpointIndices(for: vectors, complexity: .complex)
    }

    private static func learnedPhaseProfile(for vectors: [PoseFeatureVector]) -> MovementPhaseProfile {
        let complexity = movementComplexity(for: vectors)
        return MovementPhaseProfile(
            checkpointIndices: phaseCheckpointIndices(for: vectors, complexity: complexity),
            complexity: complexity
        )
    }

    private static func phaseCheckpointIndices(
        for vectors: [PoseFeatureVector],
        complexity: MovementComplexity
    ) -> [Int] {
        guard vectors.count >= 7 else {
            return [0, max(vectors.count - 1, 0)]
        }

        switch complexity {
        case .simple:
            return [0, vectors.count / 2, vectors.count - 1]
        case .medium:
            return [
                0,
                vectors.count / 4,
                vectors.count / 2,
                (vectors.count * 3) / 4,
                vectors.count - 1
            ]
        case .complex:
            break
        }

        return [
            0,
            vectors.count / 6,
            vectors.count / 3,
            vectors.count / 2,
            (vectors.count * 2) / 3,
            (vectors.count * 5) / 6,
            vectors.count - 1
        ]
    }

    private static func movementComplexity(for vectors: [PoseFeatureVector]) -> MovementComplexity {
        let signalStats = movementSignalStats(for: vectors)
        let activeSignalCount = signalStats.filter { $0.range >= 0.05 }.count
        let highMotionSignalCount = signalStats.filter { $0.range >= 0.12 }.count
        let movingRegionCount = movingBodyRegionCount(signalStats)
        let directionChangeCount = signalStats
            .sorted { $0.range > $1.range }
            .prefix(10)
            .reduce(0) { partial, stats in
                partial + min(stats.directionChanges, 2)
            }

        if movingRegionCount <= 2,
           highMotionSignalCount <= 14,
           directionChangeCount <= 10 {
            return .simple
        }

        if movingRegionCount >= 4 || activeSignalCount >= 22 || directionChangeCount >= 13 {
            return .complex
        }

        return .medium
    }

    private struct MovementSignalStats {
        var index: Int
        var range: Double
        var directionChanges: Int
    }

    private static func movementSignalStats(for vectors: [PoseFeatureVector]) -> [MovementSignalStats] {
        guard vectors.count > 2 else { return [] }
        let featureCount = min(poseFeatureValueCount, vectors.map(\.values.count).min() ?? 0)
        guard featureCount > 0 else { return [] }

        return (0..<featureCount).compactMap { index in
            let weightedValues = vectors.compactMap { vector -> Double? in
                guard index < vector.values.count,
                      index < vector.weights.count,
                      vector.weights[index] > 0.2
                else {
                    return nil
                }
                return vector.values[index]
            }
            guard weightedValues.count >= 3,
                  let minimum = weightedValues.min(),
                  let maximum = weightedValues.max()
            else {
                return nil
            }

            return MovementSignalStats(
                index: index,
                range: maximum - minimum,
                directionChanges: directionChanges(in: weightedValues, noiseFloor: 0.015)
            )
        }
    }

    private static func directionChanges(in values: [Double], noiseFloor: Double) -> Int {
        guard values.count > 2 else { return 0 }
        var previousDirection = 0
        var changes = 0

        for (previous, current) in zip(values, values.dropFirst()) {
            let delta = current - previous
            let direction: Int
            if delta > noiseFloor {
                direction = 1
            } else if delta < -noiseFloor {
                direction = -1
            } else {
                continue
            }

            if previousDirection != 0, direction != previousDirection {
                changes += 1
            }
            previousDirection = direction
        }

        return changes
    }

    private static func movingBodyRegionCount(_ signalStats: [MovementSignalStats]) -> Int {
        var regions: Set<Int> = []
        for stats in signalStats where stats.range >= 0.08 {
            if let region = bodyRegion(forFeatureIndex: stats.index) {
                regions.insert(region)
            }
        }
        return regions.count
    }

    private static func bodyRegion(forFeatureIndex index: Int) -> Int? {
        guard index < rawPoseFeatureValueCount else {
            return nil
        }
        let jointIndex = index / 3
        switch jointOrder[jointIndex] {
        case .leftShoulder, .rightShoulder:
            return 0
        case .leftElbow, .rightElbow, .leftWrist, .rightWrist:
            return 1
        case .leftHip, .rightHip:
            return 2
        case .leftKnee, .rightKnee:
            return 3
        case .leftAnkle, .rightAnkle:
            return 4
        case .nose, .neck, .root:
            return 5
        }
    }

    private func closestAnchorScore(
        to vectors: [PoseFeatureVector],
        duration: TimeInterval,
        movement: Double
    ) -> Double {
        var closest = Double.infinity

        for template in templates {
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
        guard let template = makeOnlineTemplate(from: candidate) else {
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

    private func promoteAdaptiveCalibrationTemplate(from candidate: Candidate) -> Bool {
        guard calibrationTemplates.isEmpty else {
            return false
        }
        guard let template = makeCalibrationTemplate(from: candidate) else {
            return false
        }

        calibrationTemplates.append(template)
        return true
    }

    private func makeCalibrationTemplate(from candidate: Candidate) -> MovementTemplate? {
        guard candidate.vectors.count == sampleCount, !candidate.segment.isEmpty else {
            return nil
        }

        let weighted = Self.applyFeatureVarianceWeights(candidate.vectors)
        let vectors = depthMatchingEnabled ? weighted : Self.withoutDepthFeatures(weighted)
        let duration = segmentDuration(candidate.segment)
        return MovementTemplate(
            index: nextOnlineTemplateIndex + calibrationTemplates.count,
            capturedAt: Date(),
            sourceFrameCount: candidate.segment.count,
            duration: max(duration, 0.1),
            qualityScore: candidate.averageQuality,
            vectors: vectors,
            depthCoverage: Self.depthCoverage(in: vectors),
            phaseProfile: Self.learnedPhaseProfile(for: vectors)
        )
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

    private func makeOnlineTemplate(from candidate: Candidate) -> MovementTemplate? {
        guard candidate.vectors.count == sampleCount, !candidate.segment.isEmpty else {
            return nil
        }

        let weighted = Self.applyFeatureVarianceWeights(candidate.vectors)
        let vectors = depthMatchingEnabled ? weighted : Self.withoutDepthFeatures(weighted)
        let duration = segmentDuration(candidate.segment)
        return MovementTemplate(
            index: nextOnlineTemplateIndex,
            capturedAt: Date(),
            sourceFrameCount: candidate.segment.count,
            duration: max(duration, 0.1),
            qualityScore: candidate.averageQuality,
            vectors: vectors,
            depthCoverage: Self.depthCoverage(in: vectors),
            phaseProfile: Self.learnedPhaseProfile(for: vectors)
        )
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

    private static func templateWithDepthCoverage(_ template: MovementTemplate) -> MovementTemplate {
        var template = template
        template.depthCoverage = depthCoverage(in: template.vectors)
        return template
    }

    private static func shouldDisableDepthMatching(for templates: [MovementTemplate]) -> Bool {
        guard !templates.isEmpty else { return false }
        return templates.allSatisfy { $0.depthCoverage < 0.35 }
    }

    private static func templateWithoutDepthFeatures(_ template: MovementTemplate) -> MovementTemplate {
        let vectors = withoutDepthFeatures(template.vectors)
        var template = template
        template.vectors = vectors
        template.depthCoverage = depthCoverage(in: vectors)
        return template
    }

    private static func withoutDepthFeatures(_ vectors: [PoseFeatureVector]) -> [PoseFeatureVector] {
        vectors.map { vector in
            var weights = vector.weights
            var varianceMultipliers = vector.varianceMultipliers
            for index in allDepthSensitiveFeatureIndices where index < weights.count {
                weights[index] = 0
                if index < varianceMultipliers.count {
                    varianceMultipliers[index] = 0
                }
            }
            return PoseFeatureVector(values: vector.values, weights: weights, varianceMultipliers: varianceMultipliers)
        }
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

    private static func applyFeatureVarianceWeights(_ vectors: [PoseFeatureVector], boost: Double = 0.75) -> [PoseFeatureVector] {
        guard vectors.count > 1,
              let featureCount = vectors.first?.values.count,
              featureCount > 0
        else {
            return vectors
        }

        var means = Array(repeating: 0.0, count: featureCount)
        for vector in vectors {
            for index in 0..<min(featureCount, vector.values.count) {
                means[index] += vector.values[index]
            }
        }
        for index in 0..<featureCount {
            means[index] /= Double(vectors.count)
        }

        var standardDeviations = Array(repeating: 0.0, count: featureCount)
        for vector in vectors {
            for index in 0..<min(featureCount, vector.values.count) {
                let difference = vector.values[index] - means[index]
                standardDeviations[index] += difference * difference
            }
        }
        for index in 0..<featureCount {
            standardDeviations[index] = sqrt(standardDeviations[index] / Double(vectors.count))
        }

        guard let maxStandardDeviation = standardDeviations.max(), maxStandardDeviation > 0.001 else {
            return vectors
        }

        let multipliers = standardDeviations.map { standardDeviation in
            min(2.0, 1.0 + (boost * (standardDeviation / maxStandardDeviation)))
        }

        return vectors.map { vector in
            PoseFeatureVector(values: vector.values, weights: vector.weights, varianceMultipliers: multipliers)
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

    private static let depthRelationPairs: [(reference: PoseJointName, target: PoseJointName)] = [
        (.root, .leftElbow),
        (.root, .rightElbow),
        (.root, .leftWrist),
        (.root, .rightWrist),
        (.root, .leftKnee),
        (.root, .rightKnee),
        (.root, .leftAnkle),
        (.root, .rightAnkle)
    ]

    private static let depthDirectionPairs: [(proximal: PoseJointName, distal: PoseJointName)] = [
        (.leftShoulder, .leftElbow),
        (.rightShoulder, .rightElbow),
        (.leftElbow, .leftWrist),
        (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee),
        (.rightHip, .rightKnee),
        (.leftKnee, .leftAnkle),
        (.rightKnee, .rightAnkle)
    ]

    private static let depthAsymmetryPairs: [(left: PoseJointName, right: PoseJointName)] = [
        (.leftElbow, .rightElbow),
        (.leftWrist, .rightWrist),
        (.leftKnee, .rightKnee),
        (.leftAnkle, .rightAnkle)
    ]

    private static let rawPoseFeatureValueCount = jointOrder.count * 3
    private static let angleFeatureValueCount = angleTriples.count
    private static let depthDerivedFeatureValueCount = depthRelationPairs.count + depthDirectionPairs.count + depthAsymmetryPairs.count
    private static let depthDerivedFeatureStartIndex = rawPoseFeatureValueCount + angleFeatureValueCount
    private static let poseFeatureValueCount = rawPoseFeatureValueCount + angleFeatureValueCount + depthDerivedFeatureValueCount
    private static let depthSensitiveFeatureIndices: [Int] = {
        let rawDepthIndices = jointOrder.indices.map { ($0 * 3) + 2 }
        let derivedDepthIndices = (0..<depthDerivedFeatureValueCount).map { depthDerivedFeatureStartIndex + $0 }
        return rawDepthIndices + derivedDepthIndices
    }()
    private static let allDepthSensitiveFeatureIndices: [Int] = {
        depthSensitiveFeatureIndices + depthSensitiveFeatureIndices.map { $0 + poseFeatureValueCount }
    }()

    private static func featureVectors(from frames: [PoseFrame]) -> [PoseFeatureVector] {
        let poseVectors = frames.map { vector(from: $0) }
        return featureVectors(fromPoseVectors: poseVectors[...])
    }

    private static func featureVectors(fromPoseVectors poseVectors: ArraySlice<PoseFeatureVector>) -> [PoseFeatureVector] {
        var previousPoseVector: PoseFeatureVector?

        return poseVectors.map { poseVector in
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
                weights.append(joint.z == nil ? 0 : joint.confidence * 0.72)
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

        for feature in depthFeatures(in: frame) {
            values.append(feature.value)
            weights.append(feature.weight)
        }

        return PoseFeatureVector(values: values, weights: weights)
    }

    private static func depthFeatures(in frame: PoseFrame) -> [ScalarFeature] {
        var features: [ScalarFeature] = []
        features.reserveCapacity(depthDerivedFeatureValueCount)

        for pair in depthRelationPairs {
            guard let reference = frame.joint(pair.reference),
                  let target = frame.joint(pair.target),
                  let referenceDepth = reference.z,
                  let targetDepth = target.z
            else {
                features.append(ScalarFeature(value: 0, weight: 0))
                continue
            }

            features.append(
                ScalarFeature(
                    value: targetDepth - referenceDepth,
                    weight: min(reference.confidence, target.confidence) * 0.9
                )
            )
        }

        for pair in depthDirectionPairs {
            guard let proximal = frame.joint(pair.proximal),
                  let distal = frame.joint(pair.distal),
                  proximal.z != nil,
                  distal.z != nil
            else {
                features.append(ScalarFeature(value: 0, weight: 0))
                continue
            }

            let direction = vector(from: proximal, to: distal)
            let length = magnitude(direction)
            guard length > 0.0001 else {
                features.append(ScalarFeature(value: 0, weight: 0))
                continue
            }

            features.append(
                ScalarFeature(
                    value: direction.z / length,
                    weight: min(proximal.confidence, distal.confidence) * 0.85
                )
            )
        }

        for pair in depthAsymmetryPairs {
            guard let left = frame.joint(pair.left),
                  let right = frame.joint(pair.right),
                  let leftDepth = left.z,
                  let rightDepth = right.z
            else {
                features.append(ScalarFeature(value: 0, weight: 0))
                continue
            }

            features.append(
                ScalarFeature(
                    value: leftDepth - rightDepth,
                    weight: min(left.confidence, right.confidence) * 0.75
                )
            )
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
            weights.append(min(previous.weights[index], current.weights[index]) * 0.18)
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

    private static func depthGatePasses(
        _ vectors: [PoseFeatureVector],
        template: MovementTemplate,
        acceptanceThreshold: Double
    ) -> Bool {
        let templateCoverage = template.depthCoverage
        guard templateCoverage >= 0.42 else {
            return true
        }

        let candidateCoverage = depthCoverage(in: vectors)
        guard candidateCoverage >= max(0.35, templateCoverage * 0.65) else {
            return false
        }

        let templateMotion = depthMotionMagnitude(template.vectors)
        if templateMotion >= 0.018 {
            let candidateMotion = depthMotionMagnitude(vectors)
            guard candidateMotion >= templateMotion * 0.42 else {
                return false
            }
        }

        let averageDistance = depthDistance(vectors, template.vectors)
        guard averageDistance <= max(min(acceptanceThreshold * 1.35, 0.26), 0.08) else {
            return false
        }

        let checkpoints = [
            vectors.count / 4,
            vectors.count / 2,
            (vectors.count * 3) / 4
        ]
        let worstCheckpointDistance = checkpoints.map { checkpoint in
            depthDistance(vectors[checkpoint], template.vectors[checkpoint])
        }.max() ?? .infinity

        return worstCheckpointDistance <= max(min(acceptanceThreshold * 1.65, 0.32), 0.12)
    }

    private static func depthCoverage(in vectors: [PoseFeatureVector]) -> Double {
        guard !vectors.isEmpty else { return 0 }
        var available = 0
        var possible = 0

        for vector in vectors {
            for index in depthSensitiveFeatureIndices where index < vector.weights.count {
                possible += 1
                if vector.weights[index] > 0.45 {
                    available += 1
                }
            }
        }

        guard possible > 0 else { return 0 }
        return Double(available) / Double(possible)
    }

    private static func depthMotionMagnitude(_ vectors: [PoseFeatureVector]) -> Double {
        guard vectors.count > 1 else { return 0 }
        var total = 0.0
        var sampleCount = 0

        for (previous, current) in zip(vectors, vectors.dropFirst()) {
            for index in depthSensitiveFeatureIndices
            where index < previous.values.count &&
                index < current.values.count &&
                index < previous.weights.count &&
                index < current.weights.count {
                let weight = min(previous.weights[index], current.weights[index])
                guard weight > 0.45 else { continue }
                total += abs(current.values[index] - previous.values[index]) * weight
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return 0 }
        return total / Double(sampleCount)
    }

    private static func depthDistance(_ left: [PoseFeatureVector], _ right: [PoseFeatureVector]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return .infinity }
        var total = 0.0
        var totalWeight = 0.0

        for (leftVector, rightVector) in zip(left, right) {
            let distance = depthDistance(leftVector, rightVector)
            guard distance.isFinite else { continue }
            total += distance
            totalWeight += 1
        }

        guard totalWeight > 0 else { return .infinity }
        return total / totalWeight
    }

    private static func depthDistance(_ left: PoseFeatureVector, _ right: PoseFeatureVector) -> Double {
        let comparedCount = min(
            left.values.count,
            right.values.count,
            left.weights.count,
            right.weights.count
        )
        var total = 0.0
        var totalWeight = 0.0

        for index in depthSensitiveFeatureIndices where index < comparedCount {
            let weight = min(left.weights[index], right.weights[index])
            guard weight > 0.45 else { continue }
            total += abs(left.values[index] - right.values[index]) * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else { return .infinity }
        return total / totalWeight
    }

    private static func averageJointConfidence(in segment: [PoseFrame]) -> Double {
        averageJointConfidence(in: segment[...])
    }

    private static func averageJointConfidence(in segment: [BufferedPoseFrame]) -> Double {
        averageJointConfidence(in: segment[...])
    }

    private static func averageJointConfidence(in segment: ArraySlice<PoseFrame>) -> Double {
        let confidences = segment.flatMap { frame in
            frame.joints.values.map(\.confidence)
        }
        guard !confidences.isEmpty else { return 0 }
        return confidences.reduce(0, +) / Double(confidences.count)
    }

    private static func averageJointConfidence(in segment: ArraySlice<BufferedPoseFrame>) -> Double {
        let confidences = segment.flatMap { item in
            item.frame.joints.values.map(\.confidence)
        }
        guard !confidences.isEmpty else { return 0 }
        return confidences.reduce(0, +) / Double(confidences.count)
    }
}

nonisolated struct PoseFeatureVector: Codable, Equatable, Sendable {
    var values: [Double]
    var weights: [Double]
    var varianceMultipliers: [Double] = []

    private enum CodingKeys: String, CodingKey {
        case values
        case weights
        case varianceMultipliers
    }

    init(values: [Double], weights: [Double], varianceMultipliers: [Double] = []) {
        self.values = values
        self.weights = weights
        self.varianceMultipliers = varianceMultipliers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decode([Double].self, forKey: .values)
        weights = try container.decode([Double].self, forKey: .weights)
        varianceMultipliers = try container.decodeIfPresent([Double].self, forKey: .varianceMultipliers) ?? []
    }

    func distance(to other: PoseFeatureVector, limitedTo valueLimit: Int? = nil) -> Double {
        let comparedCount: Int
        if let valueLimit {
            comparedCount = min(valueLimit, values.count, other.values.count, weights.count, other.weights.count)
        } else {
            comparedCount = min(values.count, other.values.count, weights.count, other.weights.count)
            guard comparedCount > 0 else {
                return .infinity
            }
        }

        guard comparedCount > 0 else {
            return .infinity
        }

        var weightedSum = 0.0
        var totalWeight = 0.0

        for index in 0..<comparedCount {
            let weight = min(weights[index], other.weights[index])
            let varianceBoost = max(varianceMultiplier(at: index), other.varianceMultiplier(at: index))
            if weight > 0.08 {
                let effectiveWeight = weight * varianceBoost
                weightedSum += abs(values[index] - other.values[index]) * effectiveWeight
                totalWeight += effectiveWeight
            } else if max(weights[index], other.weights[index]) > 0.4 {
                weightedSum += 0.35 * varianceBoost
                totalWeight += varianceBoost
            }
        }

        guard totalWeight > 0 else { return .infinity }
        return weightedSum / totalWeight
    }

    func appending(_ other: PoseFeatureVector) -> PoseFeatureVector {
        PoseFeatureVector(
            values: values + other.values,
            weights: weights + other.weights,
            varianceMultipliers: mergedMultipliers(with: other)
        )
    }

    static func interpolate(_ left: PoseFeatureVector, _ right: PoseFeatureVector, blend: Double) -> PoseFeatureVector {
        let values = zip(left.values, right.values).map { leftValue, rightValue in
            leftValue + ((rightValue - leftValue) * blend)
        }
        let weights = zip(left.weights, right.weights).map { leftValue, rightValue in
            leftValue + ((rightValue - leftValue) * blend)
        }
        let multipliers: [Double]
        if left.varianceMultipliers.count == right.varianceMultipliers.count, !left.varianceMultipliers.isEmpty {
            multipliers = zip(left.varianceMultipliers, right.varianceMultipliers).map { leftValue, rightValue in
                leftValue + ((rightValue - leftValue) * blend)
            }
        } else {
            multipliers = []
        }
        return PoseFeatureVector(values: values, weights: weights, varianceMultipliers: multipliers)
    }

    private func varianceMultiplier(at index: Int) -> Double {
        guard index < varianceMultipliers.count else { return 1.0 }
        return max(0.25, varianceMultipliers[index])
    }

    private func mergedMultipliers(with other: PoseFeatureVector) -> [Double] {
        if varianceMultipliers.isEmpty, other.varianceMultipliers.isEmpty {
            return []
        }

        let leftMultipliers = varianceMultipliers.isEmpty ? Array(repeating: 1.0, count: values.count) : varianceMultipliers
        let rightMultipliers = other.varianceMultipliers.isEmpty ? Array(repeating: 1.0, count: other.values.count) : other.varianceMultipliers
        return leftMultipliers + rightMultipliers
    }
}
