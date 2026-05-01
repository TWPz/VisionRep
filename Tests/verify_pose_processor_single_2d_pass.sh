#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
processor_file="$repo_root/VisionRep/Services/PoseFrameProcessor.swift"

rg -q 'performTwoDimensionalPoseRequest' "$processor_file"
rg -q 'performThreeDimensionalPoseRequest' "$processor_file"
! rg -q 'processTwoDimensionalFallback' "$processor_file"
! rg -q 'VNImageRequestHandler' "$processor_file"

echo "pose processor single 2D pass verified"
