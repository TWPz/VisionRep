#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
processor_file="$repo_root/VisionRep/Services/PoseFrameProcessor.swift"

test -f "$processor_file"

rg -q 'private let targetThreeDimensionalFramesPerSecond: Double = 15' "$processor_file"
rg -q 'private let minimum3DFrameInterval: TimeInterval' "$processor_file"
rg -q 'private var lastThreeDimensionalFrame: PoseFrame\?' "$processor_file"
rg -q 'private var lastThreeDimensionalTimestamp: TimeInterval = -\.infinity' "$processor_file"
rg -q 'shouldRefreshThreeDimensionalPose\(at: timestamp\)' "$processor_file"
rg -q 'timestamp - lastThreeDimensionalTimestamp >= minimum3DFrameInterval' "$processor_file"
rg -q 'mergeDepth\(from: lastThreeDimensionalFrame, into: twoDimensionalFrame, timestamp: timestamp\)' "$processor_file"
rg -q 'let twoDimensionalFrame = try makeFrame\(from: observation, timestamp: timestamp\)' "$processor_file"
rg -q 'let x = usableFallbackPoint.map \{ Double\(\$0.location.x\) \} \?\? projectedPoint\?\.x' "$processor_file"

echo "adaptive 3D cadence and 2D display fusion verified"
