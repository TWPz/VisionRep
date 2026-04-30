#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bridge_file="$repo_root/VisionRep/Services/LiveRepetitionCounterBridge.swift"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"

test -f "$bridge_file"
rg -q 'final class LiveRepetitionCounterBridge' "$bridge_file"
rg -q 'DispatchQueue\(label: "com\.visionrep\.repetition\.counter"' "$bridge_file"
rg -q 'private var pendingFrame' "$bridge_file"
rg -q 'func submit\(_ frame: PoseFrame, quality: PoseQuality\)' "$bridge_file"
rg -q 'counter\.update\(with: item\.frame\)' "$bridge_file"
rg -q 'DispatchQueue\.main\.async' "$bridge_file"

rg -q 'liveRepetitionCounter\.submit\(frame, quality: quality\)' "$model_file"
rg -q 'handleLiveCountUpdate' "$model_file"
rg -q 'guard mode == \.counting, isLiveCountingActive else' "$model_file"
rg -q 'liveRepetitionCounter\.load\(templates: templates\)' "$model_file"
rg -q 'liveRepetitionCounter\.resetCount\(\)' "$model_file"
rg -q 'liveRepetitionCounter\.clearOnlineTemplates\(\)' "$model_file"
! rg -q 'let update = repetitionCounter\.update\(with: frame\)' "$model_file"

echo "live count background performance bridge verified"
