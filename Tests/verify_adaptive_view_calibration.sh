#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"
session_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"

rg -q 'adaptiveCalibrationTemplateCount' "$counter_file"
rg -q 'TemplateMatchSource.*calibration|case calibration' "$counter_file"
rg -q 'promoteAdaptiveCalibrationTemplate' "$counter_file"
rg -q 'didCalibrateView' "$counter_file"
rg -q 'View calibrated' "$session_file"
! rg -q 'shouldRunAdaptiveCalibrationVerifier|lastAdaptiveCalibrationVerifierTimestamp' "$counter_file"

tmp_file="$(mktemp /tmp/visionrep-adaptive-view-calibration-XXXXXX.swift)"
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

func makeBurpeeLikeRep(start: TimeInterval, frameCount: Int = 56, amplitude: Double = 1.0) -> [PoseFrame] {
    (0..<frameCount).map { index in
        let progress = Double(index) / Double(frameCount - 1)
        let reach = sin(min(progress / 0.24, 1) * .pi)
        let crouch = max(0, sin(((progress - 0.18) / 0.28) * .pi))
        let plank = max(0, sin(((progress - 0.40) / 0.34) * .pi))
        let stand = max(0, sin(((progress - 0.72) / 0.28) * .pi))
        let t = start + (Double(index) * 0.05)
        let depth = plank * 0.72

        return PoseFrame(timestamp: t, joints: [
            .leftShoulder: joint(-0.24, -0.68 - reach * 0.28 * amplitude + crouch * 0.18 + plank * 0.40 - stand * 0.08, depth),
            .rightShoulder: joint(0.24, -0.68 - reach * 0.28 * amplitude + crouch * 0.18 + plank * 0.40 - stand * 0.08, depth),
            .leftElbow: joint(-0.40, -0.42 - reach * 0.52 * amplitude + crouch * 0.16 + plank * 0.32, depth + plank * 0.08),
            .rightElbow: joint(0.40, -0.42 - reach * 0.52 * amplitude + crouch * 0.16 + plank * 0.32, depth + plank * 0.08),
            .leftWrist: joint(-0.52, -0.12 - reach * 0.90 * amplitude + crouch * 0.18 + plank * 0.24, depth + plank * 0.10),
            .rightWrist: joint(0.52, -0.12 - reach * 0.90 * amplitude + crouch * 0.18 + plank * 0.24, depth + plank * 0.10),
            .leftHip: joint(-0.18, 0.00 + crouch * 0.34 + plank * 0.38, depth + plank * 0.04),
            .rightHip: joint(0.18, 0.00 + crouch * 0.34 + plank * 0.38, depth + plank * 0.04),
            .leftKnee: joint(-0.19, 0.48 + crouch * 0.22 + plank * 0.24, depth - plank * 0.08),
            .rightKnee: joint(0.19, 0.48 + crouch * 0.22 + plank * 0.24, depth - plank * 0.08),
            .leftAnkle: joint(-0.20, 0.94 - crouch * 0.08 + plank * 0.08, depth - plank * 0.16),
            .rightAnkle: joint(0.20, 0.94 - crouch * 0.08 + plank * 0.08, depth - plank * 0.16)
        ])
    }
}

func shiftedCameraView(_ frames: [PoseFrame], start: TimeInterval, yaw: Double = 0.42) -> [PoseFrame] {
    guard let firstTimestamp = frames.first?.timestamp else { return [] }
    return frames.map { frame in
        var joints: [PoseJointName: PoseJoint] = [:]
        for (name, poseJoint) in frame.joints {
            let verticalOffset = poseJoint.y - 0.08
            let sideBias = poseJoint.x >= 0 ? 0.018 : -0.018
            let x = (poseJoint.x * 0.88) + (verticalOffset * yaw) + sideBias
            let y = (poseJoint.y * 1.03) + (abs(poseJoint.x) * 0.04)
            let z = (poseJoint.z ?? 0) + (poseJoint.x * yaw * 0.35)
            joints[name] = PoseJoint(x: x, y: y, confidence: poseJoint.confidence, z: z)
        }
        return PoseFrame(timestamp: start + (frame.timestamp - firstTimestamp), joints: joints)
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
    trainer.makeTemplate(index: 1, frames: makeBurpeeLikeRep(start: 0, amplitude: 1.00), averageQuality: 0.96),
    trainer.makeTemplate(index: 2, frames: makeBurpeeLikeRep(start: 10, amplitude: 1.03), averageQuality: 0.95),
    trainer.makeTemplate(index: 3, frames: makeBurpeeLikeRep(start: 20, amplitude: 0.97), averageQuality: 0.95)
].compactMap { $0 }

expect(templates.count == 3, "expected three anchor templates")

let counter = FewShotRepetitionCounter()
counter.load(templates: templates)
expect(counter.adaptiveCalibrationTemplateCount == 0, "new live session should start without view calibration")

var update = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
let firstAngledRep = shiftedCameraView(makeBurpeeLikeRep(start: 100), start: 100)
var sawViewCalibration = false
for frame in firstAngledRep + holdEndPose(after: firstAngledRep, count: 4) {
    update = counter.update(with: frame)
    sawViewCalibration = sawViewCalibration || update.didCalibrateView
}

let firstRepCount = update.repetitions
expect(firstRepCount == 1, "first angle-shifted rep should count once after calibrating the new view")
expect(
    sawViewCalibration,
    "counter should report that the live view was calibrated; score=\(update.bestScore), confidence=\(update.confidence), source=\(String(describing: update.matchedTemplateSource)), calibrationCount=\(counter.adaptiveCalibrationTemplateCount)"
)
expect(counter.adaptiveCalibrationTemplateCount == 1, "one session-only view calibration template should be learned")

let secondAngledRep = shiftedCameraView(makeBurpeeLikeRep(start: 200), start: 200)
for frame in secondAngledRep + holdEndPose(after: secondAngledRep, count: 4) {
    update = counter.update(with: frame)
}

expect(update.repetitions == 2, "second rep from the calibrated camera placement should count")

counter.clearOnlineTemplates()
expect(counter.adaptiveCalibrationTemplateCount == 0, "clearing live adaptation should clear view calibration too")

counter.load(templates: templates)
expect(counter.adaptiveCalibrationTemplateCount == 0, "loading saved anchors for a new session should clear view calibration")

print("adaptive view calibration behavior verified")
SWIFT

swift "$tmp_file"
