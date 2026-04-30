#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
camera_file="$repo_root/VisionRep/Services/CameraFrameSource.swift"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"

rg -q 'enum CameraFramingMode' "$camera_file"
rg -q 'case widestView' "$camera_file"
rg -q 'case centerStageTracking' "$camera_file"
rg -q 'func setFramingMode' "$camera_file"
rg -q 'preferredFrontCamera\(for mode: CameraFramingMode\)' "$camera_file"
rg -q 'configureCenterStage\(for mode: CameraFramingMode' "$camera_file"
rg -Uq 'case \.widestView:[[:space:]]*\n[[:space:]]+AVCaptureDevice\.isCenterStageEnabled = false' "$camera_file"
rg -q 'AVCaptureDevice\.centerStageControlMode = \.cooperative' "$camera_file"
rg -q 'AVCaptureDevice\.isCenterStageEnabled = true' "$camera_file"
rg -q 'device.videoZoomFactor = device.minAvailableVideoZoomFactor' "$camera_file"

rg -q 'var cameraFramingMode: CameraFramingMode' "$model_file"
rg -q 'func toggleCameraFramingMode' "$model_file"
rg -q 'camera\.setFramingMode\(nextMode\)' "$model_file"

rg -q 'CameraFramingToggleButton' "$dashboard_file"
rg -q 'model\.toggleCameraFramingMode\(\)' "$dashboard_file"
rg -q 'accessibilityLabel\(mode\.accessibilityLabel\)' "$dashboard_file"

echo "camera framing toggle verified"
