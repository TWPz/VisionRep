#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"
session_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"

rg -q 'onlineTemplateCount' "$counter_file"
rg -q 'clearOnlineTemplates' "$counter_file"
rg -q 'TemplateMatchSource' "$counter_file"
rg -q 'anchorCorroborates' "$counter_file"
rg -q 'promoteOnlineTemplate' "$counter_file"
rg -q 'onlineAcceptanceThreshold' "$counter_file"
rg -q 'anchorThreshold' "$counter_file"
rg -q 'liveRepetitionCounter.clearOnlineTemplates\(\)' "$session_file"

tmp_file="$(mktemp /tmp/visionrep-online-template-adaptation-XXXXXX.swift)"
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

func makeRep(start: TimeInterval, frameCount: Int = 20, amplitude: Double = 10.0) -> [PoseFrame] {
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

func makeStaticFrames(from frame: PoseFrame, start: TimeInterval, frameCount: Int = 64) -> [PoseFrame] {
    (0..<frameCount).map { index in
        PoseFrame(timestamp: start + (Double(index) * 0.05), joints: frame.joints)
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
    trainer.makeTemplate(index: 1, frames: makeRep(start: 0, amplitude: 10.00), averageQuality: 0.96),
    trainer.makeTemplate(index: 2, frames: makeRep(start: 10, amplitude: 10.10), averageQuality: 0.95),
    trainer.makeTemplate(index: 3, frames: makeRep(start: 20, amplitude: 9.90), averageQuality: 0.95)
].compactMap { $0 }

expect(templates.count == 3, "expected three synthetic anchor templates")

let counter = FewShotRepetitionCounter()
counter.load(templates: templates)
expect(counter.onlineTemplateCount == 0, "first live rep must start with no online templates")

var latest = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
let firstLiveRep = makeRep(start: 100, amplitude: 10.0)
for frame in firstLiveRep + holdEndPose(after: firstLiveRep, count: 2) {
    latest = counter.update(with: frame)
}

expect(latest.repetitions == 1, "a clean anchor-matched rep should count")
expect(counter.onlineTemplateCount == 1, "a confident counted rep should become one online template")

counter.resetCount()
expect(counter.onlineTemplateCount == 1, "resetting count should preserve online templates within an active session")

counter.clearOnlineTemplates()
expect(counter.onlineTemplateCount == 0, "explicit clearing should wipe online templates")

let secondLiveRep = makeRep(start: 200, amplitude: 10.0)
for frame in secondLiveRep + holdEndPose(after: secondLiveRep, count: 2) {
    latest = counter.update(with: frame)
}

expect(latest.repetitions == 1, "counter should still count from immutable anchor templates after clearing online templates")
expect(counter.onlineTemplateCount == 1, "online template should be re-learned after another confident anchor-backed rep")

counter.load(templates: templates)
expect(counter.onlineTemplateCount == 0, "loading anchors for a new session should clear online templates")

counter.resetCount()
for frame in makeStaticFrames(from: makeRep(start: 300).first!, start: 300) {
    latest = counter.update(with: frame)
}

expect(latest.repetitions == 0, "static starting pose should not count")
expect(latest.phaseProgress < 0.05, "static starting pose should not advance visible phase progress")
expect(counter.onlineTemplateCount == 0, "static starting pose should not be promoted")

print("online template adaptation behavior verified")
SWIFT

swift "$tmp_file"
