#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"

rg -q 'SkeletonOverlayLayer\(model: model\)' "$dashboard_file"
rg -q 'renderFramesPerSecond: Self\.skeletonOverlayFramesPerSecond' "$dashboard_file"
rg -q 'private struct SkeletonOverlayLayer: View' "$dashboard_file"
rg -q '@Bindable var model: WorkoutSessionModel' "$dashboard_file"
rg -q 'private static let skeletonOverlayFramesPerSecond: Double = 12' "$dashboard_file"
if rg -q 'private var skeletonOverlayFramesPerSecond: Double' "$dashboard_file"; then
    echo "skeleton overlay FPS should be a single global constant, not a computed per-mode property" >&2
    exit 1
fi
! rg -q 'case \.recordingTemplate, \.counting' "$dashboard_file"
rg -q 'private var liveViewPoseUpdateInterval: TimeInterval' "$model_file"
rg -q 'private var targetLiveViewPoseUpdateInterval: TimeInterval' "$model_file"
rg -U -q 'case \.recordingTemplate, \.counting:\n\s*1\.0 / 12\.0' "$model_file"
rg -U -q 'case \.setup, \.cameraReady, \.templatesReady:\n\s*1\.0 / 8\.0' "$model_file"
if rg -U -q 'case \.recordingTemplate, \.counting:\n\s*1\.0 / (24\.0|15\.0)' "$model_file"; then
    echo "skeleton overlay pose delivery must stay capped at 12 FPS during active sessions" >&2
    exit 1
fi

echo "skeleton overlay mode cadence verified"
