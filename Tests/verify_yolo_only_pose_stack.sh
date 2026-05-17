#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_file="$repo_root/VisionRep.xcodeproj/project.pbxproj"
processor_file="$repo_root/VisionRep/Services/PoseFrameProcessor.swift"
estimator_file="$repo_root/VisionRep/Services/YoloCoreMLPoseEstimator.swift"
model_dir="$repo_root/VisionRep/Resources/Models"

test -f "$project_file"
test -f "$processor_file"
test -f "$estimator_file"
test -d "$model_dir/yolo26n-pose.mlpackage"
test -f "$model_dir/yolo26n-pose.mlpackage/Manifest.json"
test -f "$model_dir/yolo26n-pose.mlpackage/Data/com.apple.CoreML/model.mlmodel"
test -f "$model_dir/yolo26n-pose.mlpackage/Data/com.apple.CoreML/weights/weight.bin"

! rg -q 'MediaPipeTasksVision|Pods_VisionRep|Pods-VisionRep|\\[CP\\] Check Pods Manifest.lock|SWIFT_OBJC_BRIDGING_HEADER' "$project_file"
! rg -q 'MediaPipeTasksVision|MediaPipePoseEstimator|PoseLandmarker|pose_landmarker|m[p]ipe3d|onnxruntime|OnnxRuntime' "$repo_root/VisionRep" "$repo_root/README.md" "$repo_root/docs/pose-model-backends.md"
! find "$model_dir" -type f \( -name 'pose_landmarker*.task' -o -name '*.onnx' -o -name '*mpipe*' \) | rg -q .

rg -q 'self.poseEstimator = try YoloCoreMLPoseEstimator\(\)' "$processor_file"
rg -q 'import CoreML' "$estimator_file"
rg -q 'import Vision' "$estimator_file"
rg -q 'private static let modelInputSize: Double = 640' "$estimator_file"
rg -q 'private static let minimumPoseConfidence: Float = 0.35' "$estimator_file"
rg -q 'private static let minimumKeypointConfidence: Float = 0.25' "$estimator_file"

echo "YOLO-only pose stack verified"
