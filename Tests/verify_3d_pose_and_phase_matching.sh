#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pose_file="$repo_root/VisionRep/Models/PoseFrame.swift"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"

rg -q 'z: Double\?' "$pose_file"
rg -q 'z: nil' "$repo_root/VisionRep/Services/YoloCoreMLPoseEstimator.swift"
rg -q 'z: Double\?' "$pose_file"
rg -q 'phaseGatePasses' "$counter_file"
rg -q 'featureVectors\(from:' "$counter_file"
rg -q 'angleFeatures' "$counter_file"
rg -q 'velocity' "$counter_file"

tmp_file="$(mktemp /tmp/visionrep-3d-phase-matching-XXXXXX.swift)"
trap 'rm -f "$tmp_file"' EXIT

cat "$pose_file" "$counter_file" > "$tmp_file"
cat >> "$tmp_file" <<'SWIFT'

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func joint(_ x: Double, _ y: Double, _ z: Double, confidence: Double = 0.96) -> PoseJoint {
    PoseJoint(x: x, y: y, confidence: confidence, z: z)
}

func makeComplexRep(start: TimeInterval, frameCount: Int = 56, zScale: Double = 1.0) -> [PoseFrame] {
    (0..<frameCount).map { index in
        let progress = Double(index) / Double(frameCount - 1)
        let raise = sin(min(progress / 0.24, 1) * .pi)
        let crouch = max(0, sin(((progress - 0.20) / 0.30) * .pi))
        let prone = max(0, sin(((progress - 0.42) / 0.34) * .pi))
        let stand = max(0, sin(((progress - 0.72) / 0.28) * .pi))
        let t = start + (Double(index) * 0.05)
        let depth = prone * 0.82 * zScale

        return PoseFrame(timestamp: t, joints: [
            .leftShoulder: joint(-0.24, -0.68 + raise * -0.30 + crouch * 0.18 + prone * 0.42 - stand * 0.10, depth),
            .rightShoulder: joint(0.24, -0.68 + raise * -0.30 + crouch * 0.18 + prone * 0.42 - stand * 0.10, depth),
            .leftElbow: joint(-0.38, -0.42 + raise * -0.52 + crouch * 0.18 + prone * 0.32, depth + prone * 0.08),
            .rightElbow: joint(0.38, -0.42 + raise * -0.52 + crouch * 0.18 + prone * 0.32, depth + prone * 0.08),
            .leftWrist: joint(-0.48, -0.14 + raise * -0.92 + crouch * 0.20 + prone * 0.26, depth + prone * 0.10),
            .rightWrist: joint(0.48, -0.14 + raise * -0.92 + crouch * 0.20 + prone * 0.26, depth + prone * 0.10),
            .leftHip: joint(-0.18, 0.00 + crouch * 0.34 + prone * 0.38, depth + prone * 0.04),
            .rightHip: joint(0.18, 0.00 + crouch * 0.34 + prone * 0.38, depth + prone * 0.04),
            .leftKnee: joint(-0.19, 0.48 + crouch * 0.22 + prone * 0.22, depth - prone * 0.08),
            .rightKnee: joint(0.19, 0.48 + crouch * 0.22 + prone * 0.22, depth - prone * 0.08),
            .leftAnkle: joint(-0.20, 0.94 - crouch * 0.08 + prone * 0.08, depth - prone * 0.16),
            .rightAnkle: joint(0.20, 0.94 - crouch * 0.08 + prone * 0.08, depth - prone * 0.16)
        ])
    }
}

func holdEndPose(after rep: [PoseFrame], count: Int) -> [PoseFrame] {
    guard let last = rep.last else { return [] }
    return (1...count).map { offset in
        PoseFrame(timestamp: last.timestamp + (Double(offset) * 0.05), joints: last.joints)
    }
}

func makePhaseSkippedAttempt(start: TimeInterval, source: [PoseFrame]) -> [PoseFrame] {
    let first = source.first!
    let last = source.last!
    return (0..<source.count).map { index in
        let progress = Double(index) / Double(source.count - 1)
        let t = start + (Double(index) * 0.05)
        if progress < 0.45 {
            return PoseFrame(timestamp: t, joints: first.joints)
        }
        return PoseFrame(timestamp: t, joints: last.joints)
    }
}

let normalized3D = PoseFrameFactory.normalized(makeComplexRep(start: 0).first!)
expect(normalized3D.joint(.leftWrist)?.z != nil, "3D normalization should preserve normalized depth")
expect(normalized3D.joint(.leftWrist)?.hasDepth == true, "3D joints should report depth availability")

let trainer = FewShotRepetitionCounter()
let templates = [
    trainer.makeTemplate(index: 1, frames: makeComplexRep(start: 0, zScale: 1.0), averageQuality: 0.96),
    trainer.makeTemplate(index: 2, frames: makeComplexRep(start: 10, zScale: 1.05), averageQuality: 0.95),
    trainer.makeTemplate(index: 3, frames: makeComplexRep(start: 20, zScale: 0.95), averageQuality: 0.95)
].compactMap { $0 }

expect(templates.count == 3, "expected three 3D templates")

let counter = FewShotRepetitionCounter()
counter.load(templates: templates)

var update = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
let skipped = makePhaseSkippedAttempt(start: 100, source: makeComplexRep(start: 100))
for frame in skipped + holdEndPose(after: skipped, count: 4) {
    update = counter.update(with: frame)
}

expect(update.repetitions == 0, "start/end-like motion that skips kneel/prone phases must not count")

let complete = makeComplexRep(start: 130, zScale: 1.02)
for frame in complete + holdEndPose(after: complete, count: 4) {
    update = counter.update(with: frame)
}

expect(update.repetitions == 1, "complete 3D multi-phase movement should count after final stable pose")
expect(counter.onlineTemplateCount == 1, "confident 3D match should still feed session-only online adaptation")

print("3D pose normalization and phase-aware matching verified")
SWIFT

swift "$tmp_file"
