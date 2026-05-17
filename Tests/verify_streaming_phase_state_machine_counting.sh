#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"

rg -q 'StreamingPhaseCounter' "$counter_file"
rg -q 'StreamingPhaseCompletion' "$counter_file"
rg -q 'makeStreamingCompletionCandidate' "$counter_file"
rg -q 'streamingPhaseCounter\.update' "$counter_file"

tmp_file="$(mktemp /tmp/mpipe-streaming-phase-state-machine-XXXXXX.swift)"
trap 'rm -f "$tmp_file"' EXIT

cat "$repo_root/VisionRep/Models/PoseFrame.swift" "$counter_file" > "$tmp_file"
cat >> "$tmp_file" <<'SWIFT'

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func joint(_ x: Double, _ y: Double, _ z: Double = 0, confidence: Double = 0.97) -> PoseJoint {
    PoseJoint(x: x, y: y, confidence: confidence, z: z)
}

func makeBurpeeLikeRep(start: TimeInterval, frameCount: Int = 84, amplitude: Double = 1.0) -> [PoseFrame] {
    (0..<frameCount).map { index in
        let progress = Double(index) / Double(frameCount - 1)
        let drop = sin(min(progress, 0.36) / 0.36 * .pi / 2)
        let plank = sin(max(0, min((progress - 0.22) / 0.34, 1)) * .pi)
        let recover = min(1, max(0, (progress - 0.64) / 0.36))
        let t = start + (Double(index) * 0.05)

        let shoulderY = -0.62 + drop * 0.52 + plank * 0.18 - recover * 0.52
        let hipY = 0.0 + drop * 0.72 - recover * 0.72
        let wristY = -0.24 + drop * 0.84 - recover * 0.42
        let ankleReach = plank * 0.66

        return PoseFrame(timestamp: t, joints: [
            .leftShoulder: joint(-0.26, shoulderY, -plank * 0.12),
            .rightShoulder: joint(0.26, shoulderY, -plank * 0.12),
            .leftElbow: joint(-0.42 - plank * 0.18, wristY - 0.18, -plank * 0.18),
            .rightElbow: joint(0.42 + plank * 0.18, wristY - 0.18, -plank * 0.18),
            .leftWrist: joint(-0.52 - plank * 0.30, wristY, -plank * 0.28),
            .rightWrist: joint(0.52 + plank * 0.30, wristY, -plank * 0.28),
            .leftHip: joint(-0.18, hipY, plank * 0.06),
            .rightHip: joint(0.18, hipY, plank * 0.06),
            .leftKnee: joint(-0.20 - ankleReach * 0.22, 0.50 + drop * 0.28, plank * 0.10),
            .rightKnee: joint(0.20 + ankleReach * 0.22, 0.50 + drop * 0.28, plank * 0.10),
            .leftAnkle: joint(-0.24 - ankleReach, 1.0 + plank * 0.12, plank * 0.18),
            .rightAnkle: joint(0.24 + ankleReach, 1.0 + plank * 0.12, plank * 0.18)
        ])
    }
}

func makeMiddleLoop(from rep: [PoseFrame], start: TimeInterval, count: Int) -> [PoseFrame] {
    let middle = Array(rep[(rep.count / 3)..<((rep.count * 2) / 3)])
    return (0..<count).map { index in
        let source = middle[index % middle.count]
        return PoseFrame(timestamp: start + Double(index) * 0.05, joints: source.joints)
    }
}

let trainer = FewShotRepetitionCounter()
let templates = [
    trainer.makeTemplate(index: 1, frames: makeBurpeeLikeRep(start: 0, frameCount: 84, amplitude: 1.00), averageQuality: 0.97),
    trainer.makeTemplate(index: 2, frames: makeBurpeeLikeRep(start: 10, frameCount: 88, amplitude: 1.03), averageQuality: 0.96),
    trainer.makeTemplate(index: 3, frames: makeBurpeeLikeRep(start: 20, frameCount: 80, amplitude: 0.97), averageQuality: 0.96)
].compactMap { $0 }

expect(templates.count == 3, "expected templates")

let midLoopCounter = FewShotRepetitionCounter()
midLoopCounter.load(templates: templates)
var midLoopUpdate = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
for frame in makeMiddleLoop(from: makeBurpeeLikeRep(start: 40), start: 100, count: 140) {
    midLoopUpdate = midLoopCounter.update(with: frame)
}
expect(midLoopUpdate.repetitions == 0, "looping only the middle of an action must never increment the count")
expect(midLoopUpdate.phaseProgress < 1.0, "middle-only motion must not present completed progress")

let staticStartCounter = FewShotRepetitionCounter()
staticStartCounter.load(templates: templates)
var staticStartUpdate = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
let startPose = makeBurpeeLikeRep(start: 160).first!
for index in 0..<96 {
    staticStartUpdate = staticStartCounter.update(
        with: PoseFrame(timestamp: 160 + Double(index) * 0.05, joints: startPose.joints)
    )
}
expect(staticStartUpdate.repetitions == 0, "holding the start pose at live-count start must not count")
expect(staticStartUpdate.phaseProgress <= 0.2, "holding the start pose must not boost rep path progress toward completion")

let completeCounter = FewShotRepetitionCounter()
completeCounter.load(templates: templates)
var completeUpdate = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
let completeRep = makeBurpeeLikeRep(start: 200, frameCount: 72, amplitude: 1.0)
for frame in completeRep {
    completeUpdate = completeCounter.update(with: frame)
}
expect(completeUpdate.repetitions == 1, "complete ordered action should increment at terminal phase with minimal delay")

print("streaming phase state machine counting verified")
SWIFT

swift "$tmp_file"
