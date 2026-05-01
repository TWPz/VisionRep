#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pose_file="$repo_root/VisionRep/Models/PoseFrame.swift"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"

tmp_file="$(mktemp /tmp/visionrep-3d-depth-discrimination-XXXXXX.swift)"
trap 'rm -f "$tmp_file"' EXIT

cat "$pose_file" "$counter_file" > "$tmp_file"
cat >> "$tmp_file" <<'SWIFT'

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func joint(_ x: Double, _ y: Double, z: Double?, confidence: Double = 0.96) -> PoseJoint {
    PoseJoint(x: x, y: y, confidence: confidence, z: z)
}

func makeDepthRep(start: TimeInterval, frameCount: Int = 56, depthScale: Double?, invertDepth: Bool = false) -> [PoseFrame] {
    (0..<frameCount).map { index in
        let progress = Double(index) / Double(frameCount - 1)
        let raise = sin(min(progress / 0.24, 1) * .pi)
        let crouch = max(0, sin(((progress - 0.18) / 0.30) * .pi))
        let prone = max(0, sin(((progress - 0.42) / 0.34) * .pi))
        let stand = max(0, sin(((progress - 0.72) / 0.28) * .pi))
        let t = start + (Double(index) * 0.05)
        let direction = invertDepth ? -1.0 : 1.0
        let depth = depthScale.map { direction * prone * 0.86 * $0 }
        let wristDepth = depth.map { $0 + direction * prone * 0.20 }
        let kneeDepth = depth.map { $0 - direction * prone * 0.20 }

        return PoseFrame(timestamp: t, joints: [
            .leftShoulder: joint(-0.24, -0.68 + raise * -0.30 + crouch * 0.18 + prone * 0.42 - stand * 0.10, z: depth),
            .rightShoulder: joint(0.24, -0.68 + raise * -0.30 + crouch * 0.18 + prone * 0.42 - stand * 0.10, z: depth),
            .leftElbow: joint(-0.38, -0.42 + raise * -0.52 + crouch * 0.18 + prone * 0.32, z: wristDepth),
            .rightElbow: joint(0.38, -0.42 + raise * -0.52 + crouch * 0.18 + prone * 0.32, z: wristDepth),
            .leftWrist: joint(-0.48, -0.14 + raise * -0.92 + crouch * 0.20 + prone * 0.26, z: wristDepth),
            .rightWrist: joint(0.48, -0.14 + raise * -0.92 + crouch * 0.20 + prone * 0.26, z: wristDepth),
            .leftHip: joint(-0.18, 0.00 + crouch * 0.34 + prone * 0.38, z: depth),
            .rightHip: joint(0.18, 0.00 + crouch * 0.34 + prone * 0.38, z: depth),
            .leftKnee: joint(-0.19, 0.48 + crouch * 0.22 + prone * 0.22, z: kneeDepth),
            .rightKnee: joint(0.19, 0.48 + crouch * 0.22 + prone * 0.22, z: kneeDepth),
            .leftAnkle: joint(-0.20, 0.94 - crouch * 0.08 + prone * 0.08, z: kneeDepth),
            .rightAnkle: joint(0.20, 0.94 - crouch * 0.08 + prone * 0.08, z: kneeDepth)
        ])
    }
}

func holdEndPose(after rep: [PoseFrame], count: Int) -> [PoseFrame] {
    guard let last = rep.last else { return [] }
    return (1...count).map { offset in
        PoseFrame(timestamp: last.timestamp + (Double(offset) * 0.05), joints: last.joints)
    }
}

func run(_ frames: [PoseFrame], through counter: FewShotRepetitionCounter) -> CountUpdate {
    var update = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
    for frame in frames {
        update = counter.update(with: frame)
    }
    return update
}

let trainer = FewShotRepetitionCounter()
let templates = [
    trainer.makeTemplate(index: 1, frames: makeDepthRep(start: 0, depthScale: 1.0), averageQuality: 0.96),
    trainer.makeTemplate(index: 2, frames: makeDepthRep(start: 10, depthScale: 1.05), averageQuality: 0.96),
    trainer.makeTemplate(index: 3, frames: makeDepthRep(start: 20, depthScale: 0.95), averageQuality: 0.96)
].compactMap { $0 }
expect(templates.count == 3, "expected three depth-rich templates")

let trueCounter = FewShotRepetitionCounter()
trueCounter.load(templates: templates)
let trueRep = makeDepthRep(start: 100, depthScale: 1.02)
let trueUpdate = run(trueRep + holdEndPose(after: trueRep, count: 5), through: trueCounter)
expect(trueUpdate.repetitions == 1, "matching 3D depth movement should still count")

let twoDimensionalCounter = FewShotRepetitionCounter()
twoDimensionalCounter.load(templates: templates)
let twoDimensionalImpostor = makeDepthRep(start: 200, depthScale: nil)
let twoDimensionalUpdate = run(twoDimensionalImpostor + holdEndPose(after: twoDimensionalImpostor, count: 5), through: twoDimensionalCounter)
expect(twoDimensionalUpdate.repetitions == 0, "2D-only live movement must not satisfy a depth-rich 3D template")

let invertedDepthCounter = FewShotRepetitionCounter()
invertedDepthCounter.load(templates: templates)
let invertedDepthImpostor = makeDepthRep(start: 300, depthScale: 1.0, invertDepth: true)
let invertedDepthUpdate = run(invertedDepthImpostor + holdEndPose(after: invertedDepthImpostor, count: 5), through: invertedDepthCounter)
expect(invertedDepthUpdate.repetitions == 0, "opposite front/back depth motion must not satisfy the 3D template")

print("3D depth discrimination verified")
SWIFT

swift "$tmp_file"
