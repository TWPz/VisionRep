#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"

test -f "$counter_file"

rg -q 'let bufferPoseVectors = buffer\.map \{ Self\.vector\(from: \$0\) \}' "$counter_file"
rg -q 'Self\.featureVectors\(fromPoseVectors: bufferPoseVectors\.suffix\(length\)\)' "$counter_file"
rg -q 'private static func featureVectors\(fromPoseVectors poseVectors: ArraySlice<PoseFeatureVector>\)' "$counter_file"
rg -q 'resample\(segmentVectors, targetCount: sampleCount\)' "$counter_file"
rg -q 'let segmentSlice = buffer\.suffix\(length\)' "$counter_file"
rg -q 'segmentDuration\(segmentSlice\)' "$counter_file"
rg -q 'segment: Array\(segmentSlice\)' "$counter_file"
rg -q 'makeOnlineTemplate\(from: candidate\)' "$counter_file"
rg -q 'private func makeOnlineTemplate\(from candidate: Candidate\) -> MovementTemplate\?' "$counter_file"
rg -q 'let weighted = Self\.applyFeatureVarianceWeights\(candidate\.vectors\)' "$counter_file"
if rg -q 'let segment = Array\(buffer\.suffix\(length\)\)' "$counter_file"; then
    echo "bestCandidate should avoid allocating frame arrays for every candidate length" >&2
    exit 1
fi
if rg -q 'makeTemplate\(.*candidate\.segment' "$counter_file"; then
    echo "online promotion should reuse candidate vectors instead of rebuilding from raw frames" >&2
    exit 1
fi
if rg -q 'resample\(Self\.featureVectors\(from: segment\), targetCount: sampleCount\)' "$counter_file"; then
    echo "candidate matching should reuse cached pose vectors" >&2
    exit 1
fi

echo "live counter feature cache verified"
