#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"
bridge_file="$repo_root/VisionRep/Services/LiveRepetitionCounterBridge.swift"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"

rg -q 'var debugCameraFramesPerSecond = 0\.0' "$model_file"
rg -q 'var debugPoseFramesPerSecond = 0\.0' "$model_file"
rg -q 'var debugUIDeliveryFramesPerSecond = 0\.0' "$model_file"
rg -q 'var debugRepetitionFramesPerSecond = 0\.0' "$model_file"
rg -q 'liveRepetitionCounter\.onActualFramesPerSecondChange = \{ \[weak self\] framesPerSecond in' "$model_file"
rg -q 'recordLiveViewFrameRate\(now: now\)' "$model_file"
rg -q 'private func handleActualCameraFrameRateChange\(_ framesPerSecond: Double\)' "$model_file"
rg -q 'private func handleActualPoseFrameRateChange\(_ framesPerSecond: Double\)' "$model_file"
rg -q 'private func handleActualRepetitionFrameRateChange\(_ framesPerSecond: Double\)' "$model_file"
rg -q 'private func recordLiveViewFrameRate\(now: TimeInterval\)' "$model_file"
rg -q 'private func resetDebugFrameRates\(\)' "$model_file"

rg -q 'var onActualFramesPerSecondChange: \(\(Double\) -> Void\)\?' "$bridge_file"
rg -q 'private var actualFrameRateWindowStartTime: TimeInterval\?' "$bridge_file"
rg -q 'private var actualFrameRateWindowFrameCount = 0' "$bridge_file"
rg -q 'resetActualFrameRateWindow\(\)' "$bridge_file"
rg -q 'recordActualFrameRate\(\)' "$bridge_file"
rg -q 'onActualFramesPerSecondChange\?\(framesPerSecond\)' "$bridge_file"

rg -q 'FPSDebugBadge\(' "$dashboard_file"
rg -q 'cameraFramesPerSecond: model\.debugCameraFramesPerSecond' "$dashboard_file"
rg -q 'poseFramesPerSecond: model\.debugPoseFramesPerSecond' "$dashboard_file"
rg -q 'uiFramesPerSecond: model\.debugUIDeliveryFramesPerSecond' "$dashboard_file"
rg -q 'repetitionFramesPerSecond: model\.debugRepetitionFramesPerSecond' "$dashboard_file"
rg -F -q 'Text("C\(cameraText) P\(poseText)")' "$dashboard_file"
rg -F -q 'Text("U\(uiText) R\(repetitionText)")' "$dashboard_file"
rg -F -q 'repetition counter \(repetitionText) frames per second' "$dashboard_file"

echo "pipeline FPS reporting verified"
