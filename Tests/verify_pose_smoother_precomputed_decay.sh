#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoother_file="$repo_root/VisionRep/Services/PoseSmoother.swift"

rg -q 'private static let repairDecayWeights = \[0\.9, 0\.81\]' "$smoother_file"
rg -q 'Self\.repairDecayWeights\[offset\]' "$smoother_file"

if rg -q 'pow\(0\.9' "$smoother_file"; then
    echo "PoseSmoother should use precomputed repair decay weights" >&2
    exit 1
fi

echo "pose smoother precomputed decay verified"
