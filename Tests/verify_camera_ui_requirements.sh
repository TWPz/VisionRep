#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
camera_file="$repo_root/VisionRep/Services/CameraFrameSource.swift"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"

rg -q 'position: \.front' "$camera_file"
rg -q 'builtInUltraWideCamera' "$camera_file"
rg -q 'centerStageControlMode = \.cooperative' "$camera_file"
rg -q 'isCenterStageEnabled = true' "$camera_file"
rg -q 'shouldShowCenterReadout' "$dashboard_file"
rg -q 'model\.mode == \.counting && model\.templates\.count >= 3' "$dashboard_file"
rg -q 'SlimTrainingStatus' "$dashboard_file"
rg -q 'shouldShowTrainingStatus' "$dashboard_file"
rg -Uq 'case \.cameraReady, \.templatesReady:\n[[:space:]]+true' "$dashboard_file"
! rg -q 'private var trainingReadout' "$dashboard_file"
