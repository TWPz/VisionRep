#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"
processor_file="$repo_root/VisionRep/Services/PoseFrameProcessor.swift"

rg -q 'targetFramesPerSecond: Double = 24' "$processor_file"
rg -q 'private var liveViewPoseUpdateInterval: TimeInterval' "$model_file"
rg -q 'private var targetLiveViewPoseUpdateInterval: TimeInterval' "$model_file"
rg -U -q 'case \.recordingTemplate, \.counting:\n\s*1\.0 / 12\.0' "$model_file"
rg -U -q 'case \.setup, \.cameraReady, \.templatesReady:\n\s*1\.0 / 8\.0' "$model_file"
rg -q 'poseQualityUpdateInterval: TimeInterval = 1\.0 / 4\.0' "$model_file"
rg -q 'updateLiveViewPose\(displayFrame, quality: quality\)' "$model_file"
rg -q 'updateDisplayedPoseQuality\(quality, now: now\)' "$model_file"
rg -q 'ingest\(normalizedFrame, quality: quality\)' "$model_file"
rg -q 'let now = Date\(\)\.timeIntervalSince1970' "$model_file"
rg -q 'now - lastLiveViewPoseUpdateTime >= liveViewPoseUpdateInterval' "$model_file"
rg -q 'now - lastPoseQualityUpdateTime >= poseQualityUpdateInterval \|\| quality\.label != poseQuality\.label' "$model_file"
rg -q 'private let processingQueue = DispatchQueue\(label: "com\.visionrep\.pose\.processing", qos: \.userInitiated\)' "$model_file"
rg -q 'private let stateLock = NSLock\(\)' "$model_file"
rg -q 'private var latestSampleBuffer: CMSampleBuffer\?' "$model_file"
rg -q 'private var isProcessing = false' "$model_file"
rg -q 'latestSampleBuffer = sampleBuffer' "$model_file"
rg -q 'processingQueue\.async' "$model_file"
rg -q 'guard let sampleBuffer = latestSampleBuffer else' "$model_file"
rg -q 'latestSampleBuffer = nil' "$model_file"
rg -q 'onActualFramesPerSecondChange' "$model_file"
rg -q 'recordActualPoseFrameRate' "$model_file"
! rg -q 'loadingModel|isPreparingProcessor|startPreparingProcessorIfNeeded' "$model_file"

python3 - "$model_file" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'if case \.skipped = result \{(?P<body>.*?)\n        \}', source, re.S)
if not match:
    raise SystemExit("missing skipped-result branch")
body = match.group("body")
if "processLatestFrames()" in body:
    raise SystemExit("skipped frames must not recursively drain the buffer")
if "latestSampleBuffer = nil" not in body:
    raise SystemExit("skipped frames should clear the pending sample buffer")
if "isProcessing = false" not in body:
    raise SystemExit("skipped frames should release the processing gate")
PY

echo "low-latency pose processing verified"
