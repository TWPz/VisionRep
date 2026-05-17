#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"

rg -q 'private func effectivePoseFramesPerSecond\(for profile: PoseRuntimeProfile\) -> Double' "$model_file"
rg -U -q 'private func effectiveCameraFramesPerSecond\(\n\s*for profile: PoseRuntimeProfile,\n\s*poseFramesPerSecond: Double\n\s*\) -> Double' "$model_file"
rg -q 'private func currentRuntimeProfile\(\) -> PoseRuntimeProfile' "$model_file"
rg -q 'private func reapplyRuntimeProfileForThermalState\(\)' "$model_file"
rg -q 'frameBridge\.setTargetFramesPerSecond\(poseFramesPerSecond\)' "$model_file"
rg -q 'camera\.setCaptureProfile\(\.adaptive\(cameraFramesPerSecond\)\)' "$model_file"
rg -U -q 'case \.fair:\n\s*return min\(profile\.poseFramesPerSecond, 20\)' "$model_file"
rg -U -q 'case \.serious:\n\s*return min\(profile\.poseFramesPerSecond, 15\)' "$model_file"
rg -U -q 'case \.critical:\n\s*return min\(profile\.poseFramesPerSecond, 8\)' "$model_file"
rg -U -q 'heatStatus = nextStatus\n\s*reapplyRuntimeProfileForThermalState\(\)' "$model_file"

python3 - "$model_file" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
apply_match = re.search(r'private func applyRuntimeProfile\(_ profile: PoseRuntimeProfile\) \{(?P<body>.*?)\n    \}', source, re.S)
if not apply_match:
    raise SystemExit("missing applyRuntimeProfile")
body = apply_match.group("body")
if "profile.cameraCaptureProfile" in body:
    raise SystemExit("applyRuntimeProfile must use the thermal-adjusted camera FPS, not the raw profile")

thermal_match = re.search(r'private func updateHeatStatus\(_ thermalState: ProcessInfo\.ThermalState\) \{(?P<body>.*?)\n    \}', source, re.S)
if not thermal_match:
    raise SystemExit("missing updateHeatStatus")
if "reapplyRuntimeProfileForThermalState()" not in thermal_match.group("body"):
    raise SystemExit("thermal changes must reapply the runtime FPS profile")
PY

echo "thermal FPS backoff verified"
