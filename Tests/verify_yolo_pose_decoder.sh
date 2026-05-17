#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pose_file="$repo_root/VisionRep/Models/PoseFrame.swift"
protocol_file="$repo_root/VisionRep/Services/PoseEstimating.swift"
estimator_file="$repo_root/VisionRep/Services/YoloCoreMLPoseEstimator.swift"

tmp_file="$(mktemp /tmp/visionrep-yolo-decoder-XXXXXX.swift)"
trap 'rm -f "$tmp_file"' EXIT

cat "$pose_file" "$protocol_file" "$estimator_file" > "$tmp_file"
cat >> "$tmp_file" <<'SWIFT'

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

let shape = [1, 300, 57] as [NSNumber]
let output = try MLMultiArray(shape: shape, dataType: .float32)
for index in 0..<output.count {
    output[index] = 0
}

let detectionOffset = 57
output[detectionOffset + 4] = 0.82

func writeKeypoint(_ index: Int, x: Float, y: Float, confidence: Float) {
    let offset = detectionOffset + 6 + (index * 3)
    output[offset] = NSNumber(value: x)
    output[offset + 1] = NSNumber(value: y)
    output[offset + 2] = NSNumber(value: confidence)
}

writeKeypoint(0, x: 320, y: 64, confidence: 0.75)
writeKeypoint(5, x: 160, y: 192, confidence: 0.91)
writeKeypoint(6, x: 480, y: 192, confidence: 0.89)
writeKeypoint(7, x: 120, y: 320, confidence: 0.84)
writeKeypoint(8, x: 520, y: 320, confidence: 0.83)
writeKeypoint(9, x: 100, y: 430, confidence: 0.78)
writeKeypoint(10, x: 540, y: 430, confidence: 0.77)
writeKeypoint(11, x: 220, y: 420, confidence: 0.88)
writeKeypoint(12, x: 420, y: 420, confidence: 0.87)
writeKeypoint(13, x: 220, y: 560, confidence: 0.2)
writeKeypoint(14, x: 420, y: 560, confidence: 0.9)
writeKeypoint(15, x: 220, y: 620, confidence: 0.9)
writeKeypoint(16, x: 420, y: 620, confidence: 0.9)

let frame = try YoloPoseDecoder().makeFrame(from: output, timestamp: 12.5)
expect(frame != nil, "decoder should return a pose for a confident person")
expect(frame?.timestamp == 12.5, "decoder should preserve camera timestamp")
expect(abs((frame?.joint(.nose)?.x ?? 0) - 0.5) < 0.0001, "pixel x should normalize by 640")
expect(abs((frame?.joint(.nose)?.y ?? 0) - 0.1) < 0.0001, "pixel y should normalize by 640")
expect(frame?.joint(.leftKnee) == nil, "low-confidence keypoints should be dropped")
expect(frame?.joint(.neck) != nil, "decoder should derive neck from shoulders")
expect(frame?.joint(.root) != nil, "decoder should derive root from hips")
expect(frame?.joint(.neck)?.z == nil, "YOLO-derived joints should not synthesize depth")

let lowConfidenceOutput = try MLMultiArray(shape: shape, dataType: .float32)
for index in 0..<lowConfidenceOutput.count {
    lowConfidenceOutput[index] = 0
}
lowConfidenceOutput[4] = 0.1
let lowConfidenceFrame = try YoloPoseDecoder().makeFrame(from: lowConfidenceOutput, timestamp: 0)
expect(lowConfidenceFrame == nil, "decoder should ignore detections below confidence threshold")

print("YOLO pose decoder verified")
SWIFT

swift "$tmp_file"
