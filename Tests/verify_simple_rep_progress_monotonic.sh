#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"

rg -q '!hasMeaningfulMotion && clampedProgress <= 0\.34' "$counter_file"

tmp_file="$(mktemp /tmp/mpipe-simple-progress-monotonic-XXXXXX.swift)"
trap 'rm -f "$tmp_file"' EXIT

cat "$repo_root/VisionRep/Models/PoseFrame.swift" "$counter_file" > "$tmp_file"
cat >> "$tmp_file" <<'SWIFT'

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func joint(_ x: Double, _ y: Double) -> PoseJoint {
    PoseJoint(x: x, y: y, confidence: 0.96)
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

func hold(_ frame: PoseFrame, count: Int) -> [PoseFrame] {
    (1...count).map { offset in
        PoseFrame(timestamp: frame.timestamp + Double(offset) * 0.05, joints: frame.joints)
    }
}

let trainer = FewShotRepetitionCounter()
let templates = [
    trainer.makeTemplate(index: 1, frames: makeArmsUpRep(start: 0, amplitude: 1.0), averageQuality: 0.96),
    trainer.makeTemplate(index: 2, frames: makeArmsUpRep(start: 10, amplitude: 1.04), averageQuality: 0.96),
    trainer.makeTemplate(index: 3, frames: makeArmsUpRep(start: 20, amplitude: 0.96), averageQuality: 0.96)
].compactMap { $0 }

let counter = FewShotRepetitionCounter()
counter.load(templates: templates)

let rep = makeArmsUpRep(start: 40)
var update = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
var peakProgress = 0.0
var maxProgressBeforeCount = 0.0
var firstCountTimestamp: TimeInterval?

for (index, frame) in rep.enumerated() {
    update = counter.update(with: frame)
    if update.repetitions > 0 && firstCountTimestamp == nil {
        firstCountTimestamp = frame.timestamp
    }
    if update.repetitions == 0 {
        maxProgressBeforeCount = max(maxProgressBeforeCount, update.phaseProgress)
    }
    if index == rep.count / 2 {
        peakProgress = update.phaseProgress
    }
}

for frame in hold(rep.last!, count: 4) {
    update = counter.update(with: frame)
    if update.repetitions > 0 && firstCountTimestamp == nil {
        firstCountTimestamp = frame.timestamp
    }
    if update.repetitions == 0 {
        maxProgressBeforeCount = max(maxProgressBeforeCount, update.phaseProgress)
    }
}

expect(peakProgress > 0.4, "arms-up peak should advance progress beyond the starting checkpoint")
expect(maxProgressBeforeCount >= peakProgress, "returning arms down should continue progress toward completion before the rep increments")
expect((firstCountTimestamp ?? 0) >= rep[rep.count - 4].timestamp, "counter should only increment near the completed terminal pose")
expect(update.repetitions == 1, "arms down -> up -> down should count as one completed rep")
expect(update.phaseProgress <= 0.05, "progress should clear immediately after a counted rep")

let secondRep = makeArmsUpRep(start: 80)
for frame in secondRep {
    update = counter.update(with: frame)
}

for frame in hold(secondRep.last!, count: 4) {
    update = counter.update(with: frame)
}

expect(update.repetitions == 2, "counter should evaluate the next completed rep after clearing the progress state")

print("simple rep progress monotonic verified")
SWIFT

swift "$tmp_file"
