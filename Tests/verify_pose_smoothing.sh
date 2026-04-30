#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pose_file="$repo_root/VisionRep/Models/PoseFrame.swift"
smoother_file="$repo_root/VisionRep/Services/PoseSmoother.swift"
processor_file="$repo_root/VisionRep/Services/PoseFrameProcessor.swift"

rg -q 'OneEuroFilter' "$smoother_file"
rg -q 'PoseSmoother' "$smoother_file"
rg -q 'lowConfidenceThreshold = 0\.5' "$smoother_file"
rg -q 'maxRecentFrameCount = 3' "$smoother_file"
rg -q 'recentFrames.suffix\(maxRecentFrameCount\)' "$smoother_file"
rg -q 'poseSmoother.refine' "$processor_file"

tmp_file="$(mktemp /tmp/visionrep-pose-smoothing-XXXXXX.swift)"
trap 'rm -f "$tmp_file"' EXIT

cat "$pose_file" "$smoother_file" > "$tmp_file"
cat >> "$tmp_file" <<'SWIFT'

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func joint(_ x: Double, _ y: Double, confidence: Double = 0.96, z: Double? = nil) -> PoseJoint {
    PoseJoint(x: x, y: y, confidence: confidence, z: z)
}

func frame(_ timestamp: TimeInterval, wristX: Double, confidence: Double = 0.96, z: Double? = nil) -> PoseFrame {
    PoseFrame(timestamp: timestamp, joints: [
        .leftShoulder: joint(0.30, 0.35),
        .rightShoulder: joint(0.70, 0.35),
        .leftWrist: joint(wristX, 0.70, confidence: confidence, z: z),
        .rightWrist: joint(0.72, 0.70),
        .leftHip: joint(0.38, 0.58),
        .rightHip: joint(0.62, 0.58),
        .leftKnee: joint(0.40, 0.78),
        .rightKnee: joint(0.60, 0.78),
        .leftAnkle: joint(0.42, 0.96),
        .rightAnkle: joint(0.58, 0.96)
    ])
}

let jitteryFrames = (0..<12).map { index in
    let jitter = index.isMultiple(of: 2) ? 0.04 : -0.04
    return frame(Double(index) / 30.0, wristX: 0.50 + jitter)
}

let smoother = PoseSmoother()
let smoothedFrames = jitteryFrames.map { smoother.refine($0) }
let rawDelta = abs(jitteryFrames[10].joint(.leftWrist)!.x - jitteryFrames[11].joint(.leftWrist)!.x)
let smoothDelta = abs(smoothedFrames[10].joint(.leftWrist)!.x - smoothedFrames[11].joint(.leftWrist)!.x)
expect(smoothDelta < rawDelta * 0.55, "1 euro filter should suppress frame-to-frame micro-jitter")

let fastSmoother = PoseSmoother()
_ = fastSmoother.refine(frame(0.0, wristX: 0.20))
let fastMove = fastSmoother.refine(frame(1.0 / 30.0, wristX: 0.82))
expect(fastMove.joint(.leftWrist)!.x > 0.44, "large movements should pass through with limited lag")

let repairSmoother = PoseSmoother()
let stable = repairSmoother.refine(frame(0.0, wristX: 0.64, confidence: 0.94, z: 0.22))
let repaired = repairSmoother.refine(frame(1.0 / 30.0, wristX: 0.10, confidence: 0.20, z: -0.80))
let repairedWrist = repaired.joint(.leftWrist)!
expect(abs(repairedWrist.x - stable.joint(.leftWrist)!.x) < 0.20, "low-confidence current joint should be repaired from recent high-confidence frames")
expect(repairedWrist.confidence > 0.75, "repaired joint should inherit decayed confidence from recent frames")
expect(repairedWrist.z != nil, "depth should be smoothed and preserved")

repairSmoother.reset()
let afterReset = repairSmoother.refine(frame(1.0, wristX: 0.10, confidence: 0.20))
expect(afterReset.joint(.leftWrist)!.confidence == 0.20, "reset should clear previous-frame repair history")

print("pose temporal smoothing and low-confidence refinement verified")
SWIFT

swift "$tmp_file"
