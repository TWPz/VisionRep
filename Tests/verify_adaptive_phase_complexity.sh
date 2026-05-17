#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"

rg -q 'enum MovementComplexity: String, Codable, Equatable, Sendable' "$counter_file"
rg -q 'var complexity: MovementComplexity' "$counter_file"
rg -q 'learnedPhaseProfile' "$counter_file"
rg -q 'movementComplexity\(for vectors:' "$counter_file"
rg -q 'case \.simple:' "$counter_file"
rg -q 'return \[0, vectors.count / 2, vectors.count - 1\]' "$counter_file"

tmp_file="$(mktemp /tmp/mpipe-adaptive-phase-complexity-XXXXXX.swift)"
trap 'rm -f "$tmp_file"' EXIT

cat "$repo_root/VisionRep/Models/PoseFrame.swift" "$counter_file" > "$tmp_file"
cat >> "$tmp_file" <<'SWIFT'

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func joint(_ x: Double, _ y: Double, _ z: Double = 0, confidence: Double = 0.96) -> PoseJoint {
    PoseJoint(x: x, y: y, confidence: confidence, z: z)
}

func makeArmsUpRep(start: TimeInterval, frameCount: Int = 42, amplitude: Double = 1.0) -> [PoseFrame] {
    (0..<frameCount).map { index in
        let progress = Double(index) / Double(frameCount - 1)
        let raise = sin(progress * .pi)
        let wristY = -0.08 - (raise * 0.72 * amplitude)
        let elbowY = -0.24 - (raise * 0.42 * amplitude)
        let t = start + (Double(index) * 0.05)

        return PoseFrame(timestamp: t, joints: [
            .leftShoulder: joint(-0.26, -0.58),
            .rightShoulder: joint(0.26, -0.58),
            .leftElbow: joint(-0.36, elbowY),
            .rightElbow: joint(0.36, elbowY),
            .leftWrist: joint(-0.44, wristY),
            .rightWrist: joint(0.44, wristY),
            .leftHip: joint(-0.18, 0.04),
            .rightHip: joint(0.18, 0.04),
            .leftKnee: joint(-0.18, 0.52),
            .rightKnee: joint(0.18, 0.52),
            .leftAnkle: joint(-0.18, 1.0),
            .rightAnkle: joint(0.18, 1.0)
        ])
    }
}

func holdEndPose(after rep: [PoseFrame], count: Int) -> [PoseFrame] {
    guard let last = rep.last else { return [] }
    return (1...count).map { offset in
        PoseFrame(timestamp: last.timestamp + (Double(offset) * 0.05), joints: last.joints)
    }
}

func makeBurpeeLikeRep(start: TimeInterval, frameCount: Int = 72, amplitude: Double = 1.0, skipExtension: Bool = false) -> [PoseFrame] {
    (0..<frameCount).map { index in
        let progress = Double(index) / Double(frameCount - 1)
        let drop = sin(min(progress, 0.38) / 0.38 * .pi / 2)
        let extensionRaw = sin(max(0, min((progress - 0.24) / 0.34, 1)) * .pi)
        let plankReach = skipExtension ? 0 : extensionRaw
        let recover = min(1, max(0, (progress - 0.66) / 0.34))
        let hipY = 0.00 + (drop * 0.70 * amplitude) - (recover * 0.70 * amplitude)
        let shoulderY = -0.62 + (drop * 0.48 * amplitude) + (plankReach * 0.18 * amplitude) - (recover * 0.48 * amplitude)
        let wristY = -0.22 + (drop * 0.82 * amplitude) - (recover * 0.35 * amplitude)
        let ankleX = 0.24 + (plankReach * 0.68 * amplitude)
        let t = start + (Double(index) * 0.05)

        return PoseFrame(timestamp: t, joints: [
            .leftShoulder: joint(-0.26, shoulderY, -plankReach * 0.12),
            .rightShoulder: joint(0.26, shoulderY, -plankReach * 0.12),
            .leftElbow: joint(-0.40 - plankReach * 0.18, wristY - 0.18, -plankReach * 0.20),
            .rightElbow: joint(0.40 + plankReach * 0.18, wristY - 0.18, -plankReach * 0.20),
            .leftWrist: joint(-0.48 - plankReach * 0.28, wristY, -plankReach * 0.26),
            .rightWrist: joint(0.48 + plankReach * 0.28, wristY, -plankReach * 0.26),
            .leftHip: joint(-0.18, hipY, plankReach * 0.05),
            .rightHip: joint(0.18, hipY, plankReach * 0.05),
            .leftKnee: joint(-0.20 - plankReach * 0.24, 0.50 + drop * 0.22, plankReach * 0.10),
            .rightKnee: joint(0.20 + plankReach * 0.24, 0.50 + drop * 0.22, plankReach * 0.10),
            .leftAnkle: joint(-ankleX, 0.98 + plankReach * 0.12, plankReach * 0.20),
            .rightAnkle: joint(ankleX, 0.98 + plankReach * 0.12, plankReach * 0.20)
        ])
    }
}

let trainer = FewShotRepetitionCounter()
let simpleTemplates = [
    trainer.makeTemplate(index: 1, frames: makeArmsUpRep(start: 0, amplitude: 1.00), averageQuality: 0.96),
    trainer.makeTemplate(index: 2, frames: makeArmsUpRep(start: 10, amplitude: 1.04), averageQuality: 0.96),
    trainer.makeTemplate(index: 3, frames: makeArmsUpRep(start: 20, amplitude: 0.96), averageQuality: 0.96)
].compactMap { $0 }

expect(simpleTemplates.count == 3, "simple templates should be created")
expect(simpleTemplates.allSatisfy { $0.phaseProfile.complexity == .simple }, "arms up/down should learn simple complexity")
expect(simpleTemplates.allSatisfy { $0.phaseProfile.checkpointIndices.count == 3 }, "simple motion should use start/peak/return checkpoints")

let simpleCounter = FewShotRepetitionCounter()
simpleCounter.load(templates: simpleTemplates)
var simpleUpdate = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
let simpleRep = makeArmsUpRep(start: 40, amplitude: 1.0)
let simpleMidpoint = simpleRep.count / 2
for frame in simpleRep.prefix(simpleMidpoint) {
    simpleUpdate = simpleCounter.update(with: frame)
}
let midpointProgress = simpleUpdate.phaseProgress
for frame in simpleRep.suffix(simpleRep.count - simpleMidpoint) + holdEndPose(after: simpleRep, count: 4) {
    simpleUpdate = simpleCounter.update(with: frame)
}
expect(simpleUpdate.phaseProgress >= midpointProgress, "arms up/down progress should not go backward on the return-to-down phase")
expect(simpleUpdate.repetitions == 1, "simple arms up/down rep should count with adaptive 3-phase profile")

let complexTemplates = [
    trainer.makeTemplate(index: 1, frames: makeBurpeeLikeRep(start: 100), averageQuality: 0.96),
    trainer.makeTemplate(index: 2, frames: makeBurpeeLikeRep(start: 110, amplitude: 1.04), averageQuality: 0.96),
    trainer.makeTemplate(index: 3, frames: makeBurpeeLikeRep(start: 120, amplitude: 0.96), averageQuality: 0.96)
].compactMap { $0 }

expect(complexTemplates.count == 3, "complex templates should be created")
expect(complexTemplates.allSatisfy { $0.phaseProfile.complexity == .complex }, "burpee-like motion should learn complex complexity")
expect(complexTemplates.allSatisfy { $0.phaseProfile.checkpointIndices.count == 7 }, "complex motion should keep seven ordered checkpoints")

let complexCounter = FewShotRepetitionCounter()
complexCounter.load(templates: complexTemplates)
var skipped = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
for frame in makeBurpeeLikeRep(start: 200, skipExtension: true) {
    skipped = complexCounter.update(with: frame)
}
expect(skipped.repetitions == 0, "complex motion that skips the extension phase should not count")

print("adaptive phase complexity verified")
SWIFT

swift "$tmp_file"
