#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
camera_file="$repo_root/VisionRep/Services/CameraFrameSource.swift"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"

rg -q 'position: \.front' "$camera_file"
rg -q 'builtInUltraWideCamera' "$camera_file"
stale_tracking_api='center''Stage''ControlMode'
stale_enabled_api='is''Center''StageEnabled'
stale_framing_method='set''Framing''Mode'
stale_framing_type='Camera''Framing''Mode'
if rg -q "${stale_tracking_api}|${stale_enabled_api}|${stale_framing_method}|${stale_framing_type}" "$camera_file" "$dashboard_file"; then
    echo "camera UI should not include camera tracking or framing-mode code" >&2
    exit 1
fi
rg -q 'shouldShowCenterReadout' "$dashboard_file"
rg -q 'model\.mode == \.counting && model\.templates\.count >= 3' "$dashboard_file"
rg -q 'SlimTrainingStatus' "$dashboard_file"
rg -q 'shouldShowTrainingStatus' "$dashboard_file"
rg -Uq 'case \.cameraReady, \.templatesReady:\n[[:space:]]+true' "$dashboard_file"
! rg -q 'private var trainingReadout' "$dashboard_file"
