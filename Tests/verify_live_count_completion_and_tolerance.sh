#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"

rg -q 'pendingCompletion' "$counter_file"
rg -q 'completionPoseMatches' "$counter_file"
rg -q 'completionPoseIsStable' "$counter_file"
rg -q 'completeLengthRange' "$counter_file"
rg -q 'minimumCandidateDuration' "$counter_file"
rg -q '2\.4' "$counter_file"

tmp_file="$(mktemp /tmp/visionrep-live-count-completion-XXXXXX.swift)"
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

func makeRep(start: TimeInterval, frameCount: Int, amplitude: Double = 8.0) -> [PoseFrame] {
    (0..<frameCount).map { index in
        let progress = Double(index) / Double(frameCount - 1)
        let raise = sin(progress * .pi)
        let kneel = max(0, sin((progress - 0.24) * .pi))
        let prone = max(0, sin((progress - 0.52) * .pi))
        let t = start + (Double(index) * 0.05)

        return PoseFrame(timestamp: t, joints: [
            .leftShoulder: joint(-0.25, -0.72 + raise * -0.10 * amplitude + prone * 0.18),
            .rightShoulder: joint(0.25, -0.72 + raise * -0.10 * amplitude + prone * 0.18),
            .leftElbow: joint(-0.42, -0.45 + raise * -0.35 * amplitude + prone * 0.24),
            .rightElbow: joint(0.42, -0.45 + raise * -0.35 * amplitude + prone * 0.24),
            .leftWrist: joint(-0.54, -0.18 + raise * -0.76 * amplitude + prone * 0.30),
            .rightWrist: joint(0.54, -0.18 + raise * -0.76 * amplitude + prone * 0.30),
            .leftHip: joint(-0.18, 0.0 + kneel * 0.18 + prone * 0.30),
            .rightHip: joint(0.18, 0.0 + kneel * 0.18 + prone * 0.30),
            .leftKnee: joint(-0.20, 0.50 + kneel * 0.34 + prone * 0.22),
            .rightKnee: joint(0.20, 0.50 + kneel * 0.34 + prone * 0.22),
            .leftAnkle: joint(-0.22, 1.0 + kneel * 0.08 + prone * 0.08),
            .rightAnkle: joint(0.22, 1.0 + kneel * 0.08 + prone * 0.08)
        ])
    }
}

func holdEndPose(after rep: [PoseFrame], count: Int) -> [PoseFrame] {
    guard let last = rep.last else { return [] }
    return (1...count).map { offset in
        PoseFrame(timestamp: last.timestamp + (Double(offset) * 0.05), joints: last.joints)
    }
}

let trainer = FewShotRepetitionCounter()
let templates = [
    trainer.makeTemplate(index: 1, frames: makeRep(start: 0, frameCount: 44, amplitude: 8.0), averageQuality: 0.96),
    trainer.makeTemplate(index: 2, frames: makeRep(start: 10, frameCount: 46, amplitude: 8.1), averageQuality: 0.95),
    trainer.makeTemplate(index: 3, frames: makeRep(start: 20, frameCount: 42, amplitude: 7.9), averageQuality: 0.95)
].compactMap { $0 }

expect(templates.count == 3, "expected three templates")

let counter = FewShotRepetitionCounter()
counter.load(templates: templates)

let slowRep = makeRep(start: 100, frameCount: 68, amplitude: 8.0)
var latest = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)

for frame in slowRep.dropLast(4) {
    latest = counter.update(with: frame)
}

expect(latest.repetitions == 0, "live count should not increment before the final pose is reached")

for frame in slowRep.suffix(4) + holdEndPose(after: slowRep, count: 3) {
    latest = counter.update(with: frame)
}

expect(latest.repetitions == 1, "slower complete live rep should count after the action is done")
expect(counter.onlineTemplateCount == 1, "completed counted rep should still be available for online adaptation")

let secondRep = makeRep(start: 120, frameCount: 36, amplitude: 8.0)
for frame in secondRep + holdEndPose(after: secondRep, count: 2) {
    latest = counter.update(with: frame)
}

expect(latest.repetitions == 2, "faster complete live rep should also count once finished")

print("live count completion and timing tolerance verified")
SWIFT

swift "$tmp_file"
