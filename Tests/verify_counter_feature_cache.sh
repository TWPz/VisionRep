#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"

test -f "$counter_file"

rg -q 'private struct BufferedPoseFrame' "$counter_file"
rg -q 'var poseVector: PoseFeatureVector' "$counter_file"
rg -q 'buffer\.append\(BufferedPoseFrame\(frame: frame, poseVector: Self\.vector\(from: frame\)\)\)' "$counter_file"
rg -q 'let bufferPoseVectors = buffer\.map\(\\.poseVector\)' "$counter_file"
rg -q 'Self\.featureVectors\(fromPoseVectors: bufferPoseVectors\.suffix\(length\)\)' "$counter_file"
rg -q 'private static func featureVectors\(fromPoseVectors poseVectors: ArraySlice<PoseFeatureVector>\)' "$counter_file"
rg -q 'resample\(segmentVectors, targetCount: sampleCount\)' "$counter_file"
rg -q 'let segmentSlice = buffer\.suffix\(length\)' "$counter_file"
rg -q 'segmentDuration\(segmentSlice\)' "$counter_file"
rg -q 'segment: segmentSlice\.map\(\\.frame\)' "$counter_file"
rg -q 'Self\.phaseGatePasses\(comparableVectors, template: template, acceptanceThreshold: candidateThreshold\)' "$counter_file"
rg -q 'guard score <= max\(candidateThreshold \* 1\.25, candidateThreshold \+ 0\.05\) else' "$counter_file"
rg -q 'guard candidateRank < bestRank else' "$counter_file"
rg -q 'Self\.anchorPassThroughScore' "$counter_file"
rg -q 'makeOnlineTemplate\(from: candidate\)' "$counter_file"
rg -q 'private func makeOnlineTemplate\(from candidate: Candidate\) -> MovementTemplate\?' "$counter_file"
rg -q 'let weighted = Self\.applyFeatureVarianceWeights\(candidate\.vectors\)' "$counter_file"
rg -q 'var depthCoverage: Double' "$counter_file"
rg -q 'depthCoverage = try container\.decodeIfPresent\(Double\.self, forKey: \.depthCoverage\) \?\? 0' "$counter_file"
rg -q 'private static let rawPoseFeatureValueCount = jointOrder\.count \* 3' "$counter_file"
rg -q 'private static let angleFeatureValueCount = angleTriples\.count' "$counter_file"
rg -q 'private static let depthDerivedFeatureValueCount = depthRelationPairs\.count \+ depthDirectionPairs\.count \+ depthAsymmetryPairs\.count' "$counter_file"
rg -q 'private static let depthDerivedFeatureStartIndex = rawPoseFeatureValueCount \+ angleFeatureValueCount' "$counter_file"
rg -q 'private static let poseFeatureValueCount = rawPoseFeatureValueCount \+ angleFeatureValueCount \+ depthDerivedFeatureValueCount' "$counter_file"
rg -q 'private static let depthSensitiveFeatureIndices: \[Int\] = \{' "$counter_file"
rg -q 'depthCoverage: Self\.depthCoverage\(in: weighted\)' "$counter_file"
rg -q 'let templateCoverage = template\.depthCoverage' "$counter_file"
rg -q 'private var depthMatchingEnabled = true' "$counter_file"
rg -q 'depthMatchingEnabled = !Self\.shouldDisableDepthMatching\(for: loadedTemplates\)' "$counter_file"
rg -q 'private static func shouldDisableDepthMatching\(for templates: \[MovementTemplate\]\) -> Bool' "$counter_file"
rg -q 'private static func withoutDepthFeatures\(_ vectors: \[PoseFeatureVector\]\) -> \[PoseFeatureVector\]' "$counter_file"
rg -q 'let comparableVectors = depthMatchingEnabled \? vectors : Self\.withoutDepthFeatures\(vectors\)' "$counter_file"
if rg -q 'let segment = Array\(buffer\.suffix\(length\)\)' "$counter_file"; then
    echo "bestCandidate should avoid allocating frame arrays for every candidate length" >&2
    exit 1
fi
if rg -q 'let bufferPoseVectors = buffer\.map \{ Self\.vector\(from: \$0\) \}' "$counter_file"; then
    echo "counter should cache raw pose vectors instead of re-extracting the entire buffer" >&2
    exit 1
fi
if rg -q 'let velocityDistance = Self\.distance\(vectors, template\.vectors\)' "$counter_file"; then
    echo "phase gate should reuse the candidate/template distance already computed by bestCandidate" >&2
    exit 1
fi
if rg -U -q 'let anchorScore = closestAnchorScore[\s\S]*let score = Self\.distance' "$counter_file"; then
    echo "anchor corroboration should run only after a candidate can beat the current best rank" >&2
    exit 1
fi
if rg -q 'let templateCoverage = depthCoverage\(in: template\.vectors\)' "$counter_file"; then
    echo "template depth coverage should be precomputed on MovementTemplate" >&2
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
