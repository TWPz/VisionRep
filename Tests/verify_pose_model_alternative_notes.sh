#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
notes_file="$repo_root/docs/pose-model-backends.md"

test -f "$notes_file"

rg -q 'YOLO26n pose Core ML package' "$notes_file"
rg -q 'yolo26n-pose.mlpackage' "$notes_file"
rg -q 'YoloCoreMLPoseEstimator' "$notes_file"
rg -q 'Vision/Core ML' "$notes_file"
rg -q '\[1, 300, 57\]' "$notes_file"
rg -q '17 `\(x, y, confidence\)` keypoints' "$notes_file"
rg -q 'standalone `VisionRep.xcodeproj`' "$notes_file"
rg -q 'YOLO frames intentionally leave `z` unset' "$notes_file"
! rg -q 'MoveNet|RTMPose|whole-body|ONNX' "$notes_file"
! rg -q 'MediaPipe|pose_landmarker|CocoaPods' "$notes_file"

echo "pose model alternative notes verified"
