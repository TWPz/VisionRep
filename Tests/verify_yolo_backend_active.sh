#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
processor_file="$repo_root/VisionRep/Services/PoseFrameProcessor.swift"
estimator_file="$repo_root/VisionRep/Services/YoloCoreMLPoseEstimator.swift"
model_file="$repo_root/VisionRep/Resources/Models/yolo26n-pose.mlpackage"
podfile="$repo_root/Podfile"
lockfile="$repo_root/Podfile.lock"
workspace_file="$repo_root/VisionRep.xcworkspace/contents.xcworkspacedata"

test -f "$processor_file"
test -f "$estimator_file"
test -d "$model_file"

rg -q 'import CoreML' "$estimator_file"
rg -q 'import Vision' "$estimator_file"
rg -q 'final class YoloCoreMLPoseEstimator: PoseEstimating, @unchecked Sendable' "$estimator_file"
rg -q 'VNCoreMLModel' "$estimator_file"
rg -q 'VNCoreMLRequest' "$estimator_file"
rg -q 'VNImageRequestHandler' "$estimator_file"
rg -q 'YoloPoseDecoder' "$estimator_file"
rg -q 'static let modelResourceName = "yolo26n-pose"' "$estimator_file"
rg -q 'static let modelExtension = "mlpackage"' "$estimator_file"
rg -q 'self.poseEstimator = try YoloCoreMLPoseEstimator\(\)' "$processor_file"
rg -q 'YOLO pose estimator is unavailable' "$processor_file"

if test -f "$podfile"; then
    ! rg -q "MediaPipeTasksVision" "$podfile"
fi

if test -f "$lockfile"; then
    ! rg -q "MediaPipeTasksVision|MediaPipeTasksCommon" "$lockfile"
fi

if test -f "$workspace_file"; then
    ! rg -q 'Pods/Pods.xcodeproj' "$workspace_file"
fi

! rg -q 'MediaPipeTasksVision|MediaPipePoseEstimator|PoseLandmarker|pose_landmarker' "$repo_root/VisionRep" "$repo_root/README.md" "$repo_root/docs/pose-model-backends.md"

echo "YOLO Core ML active backend verified"
