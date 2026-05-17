#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"
camera_preview_file="$repo_root/VisionRep/Views/CameraPreview.swift"
skeleton_file="$repo_root/VisionRep/Views/SkeletonOverlayView.swift"

rg -q 'private let activeCaptureFrameCountDisplayInterval: TimeInterval = 1\.0 / 4\.0' "$model_file"
rg -q 'private func updateDisplayedActiveCaptureFrameCount' "$model_file"
rg -q 'guard activeCaptureFrameCount != displayedCount else \{ return \}' "$model_file"
rg -q 'private func updateLiveCountDisplay' "$model_file"
rg -q 'movementPhaseProgress = roundedProgress' "$model_file"
rg -q '@ObservationIgnored private var latestMatcherScore' "$model_file"

rg -q 'guard uiView\.videoPreviewLayer\.session !== session else \{ return \}' "$camera_preview_file"
rg -q 'TimelineView\(\.periodic' "$skeleton_file"

echo "UI update coalescing verified"
