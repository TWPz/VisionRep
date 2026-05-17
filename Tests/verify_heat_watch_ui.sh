#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"

rg -q 'struct HeatStatus: Equatable' "$model_file"
rg -q 'var heatStatus = HeatStatus\.current\(\)' "$model_file"
rg -q 'ProcessInfo\.processInfo\.thermalState|processInfo\.thermalState' "$model_file"
rg -q 'camera\.onThermalStateChange = \{ \[weak self\] thermalState in' "$model_file"
rg -q 'private func updateHeatStatus\(_ thermalState: ProcessInfo\.ThermalState\)' "$model_file"
rg -q 'guard heatStatus != nextStatus else \{ return \}' "$model_file"
! rg -q 'celsius|temperatureText|heatMonitorRefreshInterval|startHeatMonitoring|heatMonitorTask|Task\.sleep\(for: self\?\.heatMonitorRefreshInterval' "$model_file"

rg -q 'HeatWatchBadge\(status: model\.heatStatus\)' "$dashboard_file"
rg -q 'FPSDebugBadge\(' "$dashboard_file"
rg -q 'cameraFramesPerSecond: model\.debugCameraFramesPerSecond' "$dashboard_file"
rg -q 'poseFramesPerSecond: model\.debugPoseFramesPerSecond' "$dashboard_file"
rg -q 'uiFramesPerSecond: model\.debugUIDeliveryFramesPerSecond' "$dashboard_file"
rg -q 'repetitionFramesPerSecond: model\.debugRepetitionFramesPerSecond' "$dashboard_file"
rg -q 'private struct HeatWatchBadge' "$dashboard_file"
rg -q 'private struct FPSDebugBadge' "$dashboard_file"
rg -q 'Text\("Heat"\)' "$dashboard_file"
rg -q 'Text\("FPS"\)' "$dashboard_file"
rg -q '\.frame\(width: 104, height: 62\)' "$dashboard_file"
rg -q 'status\.stateLabel' "$dashboard_file"
rg -q 'accessibilityLabel\("Thermal state' "$dashboard_file"
rg -F -q '.accessibilityLabel("Actual camera \(cameraText) frames per second, pose \(poseText) frames per second, UI \(uiText) frames per second, repetition counter \(repetitionText) frames per second")' "$dashboard_file"
! rg -q 'status\.temperatureText|-- °C|°C' "$dashboard_file"

echo "heat watch UI verified"
