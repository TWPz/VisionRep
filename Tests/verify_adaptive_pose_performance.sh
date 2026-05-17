#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
processor_file="$repo_root/VisionRep/Services/PoseFrameProcessor.swift"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"

rg -q 'PoseProcessingPerformanceController' "$processor_file"
rg -q 'recordProcessingDuration' "$processor_file"
rg -q 'targetFramesPerSecond' "$processor_file"
rg -q 'minimumFramesPerSecond' "$processor_file"
rg -q 'onTargetFramesPerSecondChange' "$processor_file"
rg -q 'mutating func setTargetFramesPerSecond\(_ targetFramesPerSecond: Double\)' "$processor_file"
rg -q 'minimumFrameInterval' "$processor_file"
! rg -q 'preferredCameraResourceProfile|onCameraResourceProfileChange|CameraResourceProfile' "$processor_file"
rg -q '\[24, 20, 18, 15, 12, 10, 8\]' "$processor_file"
rg -q 'frameIntervalTolerance' "$processor_file"
rg -q 'nextProcessingTimestamp: TimeInterval\?' "$processor_file"
rg -q 'private func shouldProcessFrame\(at timestamp: TimeInterval\) -> Bool' "$processor_file"
rg -q 'private func nextScheduledTimestamp' "$processor_file"
rg -q 'nextProcessingTimestamp = nil' "$processor_file"
! rg -q 'timestamp - lastProcessedTimestamp' "$processor_file"
rg -q 'downgradePressureFrameCount = 12' "$processor_file"
rg -q 'downgradeLoadThreshold = 0\.90' "$processor_file"
rg -q 'upgradeRecoveryFrameCount = 120' "$processor_file"
! rg -q 'onCameraResourceProfileChange|camera\.setResourceProfile' "$model_file"
rg -q 'applyRuntimeProfile\(\.ready\)' "$model_file"
rg -q 'applyRuntimeProfile\(\.active\)' "$model_file"

python3 - "$processor_file" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'func setTargetFramesPerSecond\(_ targetFramesPerSecond: Double\) \{(?P<body>.*?)\n    \}', source, re.S)
if not match:
    raise SystemExit("missing processor setTargetFramesPerSecond body")
if "PoseProcessingPerformanceController(" in match.group("body"):
    raise SystemExit("setTargetFramesPerSecond should retarget the controller, not replace it")
PY

tmp_file="$(mktemp /tmp/mpipe-adaptive-pose-performance-XXXXXX.swift)"
trap 'rm -f "$tmp_file"' EXIT

python3 - "$processor_file" "$tmp_file" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'private nonisolated struct PoseProcessingPerformanceController \{.*\n\}', source, re.S)
if not match:
    raise SystemExit("missing PoseProcessingPerformanceController")

snippet = match.group(0).replace("private nonisolated struct", "nonisolated struct")
pathlib.Path(sys.argv[2]).write_text(
    "import Foundation\n"
    "@preconcurrency import AVFoundation\n"
    + snippet
    + r'''

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

var controller = PoseProcessingPerformanceController(initialTargetFramesPerSecond: 24)
expect(controller.targetFramesPerSecond == 24, "controller should start at the requested 24 FPS")

for _ in 0..<11 {
    controller.recordProcessingDuration(0.13)
}
expect(controller.targetFramesPerSecond == 24, "brief startup pressure should not immediately drop active pose FPS")

controller.recordProcessingDuration(0.13)
expect(controller.targetFramesPerSecond == 20, "sustained slow inference should step down pose FPS gradually")

for _ in 0..<36 {
    controller.recordProcessingDuration(0.13)
}
expect(controller.targetFramesPerSecond == 12, "active live counting should not degrade below 12 FPS")

for _ in 0..<260 {
    controller.recordProcessingDuration(0.015)
}
expect(controller.targetFramesPerSecond > 15, "sustained fast inference should recover cautiously")
expect(controller.minimumFrameInterval <= 1.0 / 18.0, "recovered controller should allow smoother updates")

var retargetedController = PoseProcessingPerformanceController(initialTargetFramesPerSecond: 24)
retargetedController.recordProcessingDuration(0.13)
retargetedController.recordProcessingDuration(0.13)
retargetedController.setTargetFramesPerSecond(24)
retargetedController.recordProcessingDuration(0.13)
expect(retargetedController.targetFramesPerSecond == 24, "retargeting FPS should not immediately downgrade after a few pressure frames")

var readyController = PoseProcessingPerformanceController(initialTargetFramesPerSecond: 8)
expect(readyController.targetFramesPerSecond == 8, "ready mode should still be allowed to run at 8 FPS")
for _ in 0..<260 {
    readyController.recordProcessingDuration(0.010)
}
expect(readyController.targetFramesPerSecond == 8, "ready mode should not recover above its 8 FPS budget")

print("adaptive pose performance controller verified")
''',
)
PY

swift "$tmp_file"

echo "adaptive pose performance verified"
