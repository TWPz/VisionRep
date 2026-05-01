#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
processor_file="$repo_root/VisionRep/Services/PoseFrameProcessor.swift"

test -f "$processor_file"

rg -q 'private var bodyRegionOfInterest = CGRect\(x: 0, y: 0, width: 1, height: 1\)' "$processor_file"
rg -q 'private let fullFrameRegionOfInterest = CGRect\(x: 0, y: 0, width: 1, height: 1\)' "$processor_file"
rg -q 'bodyPose2DRequest.regionOfInterest = bodyRegionOfInterest' "$processor_file"
rg -q 'bodyPose3DRequest.regionOfInterest = bodyRegionOfInterest' "$processor_file"
rg -q 'updateRegionOfInterest\(from: twoDimensionalFrame\)' "$processor_file"
rg -q 'resetRegionOfInterest\(\)' "$processor_file"
rg -q 'private let minimumRequiredRegionJointRatio = 0\.7' "$processor_file"
rg -q 'private var consecutiveNoPoseFrameCount = 0' "$processor_file"
rg -q 'private let noPoseResetThreshold = 4' "$processor_file"
rg -q 'consecutiveNoPoseFrameCount \+= 1' "$processor_file"
rg -q 'if consecutiveNoPoseFrameCount >= noPoseResetThreshold' "$processor_file"
rg -q 'consecutiveNoPoseFrameCount = 0' "$processor_file"
rg -q 'PoseFrameFactory.requiredJoints.filter' "$processor_file"
rg -q 'private func updateRegionOfInterest\(from frame: PoseFrame\)' "$processor_file"
rg -q 'private func regionOfInterest\(for frame: PoseFrame\) -> CGRect\?' "$processor_file"
rg -q 'private func expandedRegionOfInterest\(from bodyBounds: CGRect\) -> CGRect' "$processor_file"
rg -q 'private func smoothedRegionOfInterest\(from target: CGRect\) -> CGRect' "$processor_file"
rg -q 'private func clampedUnitRect\(_ rect: CGRect\) -> CGRect' "$processor_file"

echo "pose ROI tracking verified"
