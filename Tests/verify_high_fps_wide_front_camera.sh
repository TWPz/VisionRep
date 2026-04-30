#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
processor_file="$repo_root/VisionRep/Services/PoseFrameProcessor.swift"
camera_file="$repo_root/VisionRep/Services/CameraFrameSource.swift"

rg -q 'init\(targetFramesPerSecond: Double = 30\)' "$processor_file"
rg -q 'private let targetCameraFramesPerSecond: Double = 30' "$camera_file"
rg -q 'preferredWideFieldOfViewFormat' "$camera_file"
rg -q 'videoFieldOfView' "$camera_file"
rg -q 'return lhs.videoFieldOfView < rhs.videoFieldOfView' "$camera_file"
rg -q 'device.videoZoomFactor = device.minAvailableVideoZoomFactor' "$camera_file"
rg -q 'builtInTrueDepthCamera' "$camera_file"
rg -q 'centerStageControlMode = \.cooperative' "$camera_file"
rg -q 'isCenterStageEnabled = true' "$camera_file"

echo "high FPS processing and widest front camera configuration verified"
