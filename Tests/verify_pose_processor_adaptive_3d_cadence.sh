#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
processor_file="$repo_root/VisionRep/Services/PoseFrameProcessor.swift"

test -f "$processor_file"

rg -q 'private let targetThreeDimensionalFramesPerSecond: Double = 15' "$processor_file"
rg -q 'private let minimum3DFrameInterval: TimeInterval' "$processor_file"
rg -q 'private var lastThreeDimensionalFrame: PoseFrame\?' "$processor_file"
rg -q 'private var lastThreeDimensionalAttemptTimestamp: TimeInterval = -\.infinity' "$processor_file"
rg -q 'private var lastThreeDimensionalTimestamp: TimeInterval = -\.infinity' "$processor_file"
rg -q 'shouldRefreshThreeDimensionalPose\(at: timestamp\)' "$processor_file"
rg -q 'timestamp - lastThreeDimensionalAttemptTimestamp >= minimum3DFrameInterval' "$processor_file"
rg -U -q 'guard shouldRefreshThreeDimensionalPose\(at: timestamp\) else \{\n\s*return\n\s*\}\n\n\s*lastThreeDimensionalAttemptTimestamp = timestamp' "$processor_file"
rg -U -q 'lastThreeDimensionalFrame = frame\n\s*lastThreeDimensionalTimestamp = timestamp' "$processor_file"
rg -q 'mergeDepth\(from: lastThreeDimensionalFrame, into: twoDimensionalFrame, timestamp: timestamp\)' "$processor_file"
rg -q 'let twoDimensionalFrame = try makeFrame\(from: observation, timestamp: timestamp\)' "$processor_file"
rg -q 'let x = usableFallbackPoint.map \{ Double\(\$0.location.x\) \} \?\? projectedPoint\?\.x' "$processor_file"
rg -q 'let dx = joint2D\.x - depthJoint\.x' "$processor_file"
rg -q 'let dy = joint2D\.y - depthJoint\.y' "$processor_file"
rg -q 'guard \(dx \* dx \+ dy \* dy\) <= 0\.06 else' "$processor_file"
if rg -U -q 'lastThreeDimensionalTimestamp = timestamp\n\s*guard let observation' "$processor_file"; then
    echo "3D cadence timestamp should advance only after a successful 3D frame" >&2
    exit 1
fi

echo "adaptive 3D cadence and 2D display fusion verified"
