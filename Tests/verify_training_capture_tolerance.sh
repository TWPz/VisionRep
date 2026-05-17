#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"

rg -q 'private let minimumTrainingFrameQuality = 0\.30' "$model_file"
rg -q 'private let idealTrainingFrameQuality = 0\.58' "$model_file"
rg -q 'guard quality\.score >= minimumTrainingFrameQuality else' "$model_file"
rg -q 'if quality\.score < idealTrainingFrameQuality' "$model_file"
rg -q 'activeCaptureFrames\.append\(frame\)' "$model_file"
! rg -q 'guard quality\.score >= 0\.48 else' "$model_file"

echo "training capture tolerance verified"
