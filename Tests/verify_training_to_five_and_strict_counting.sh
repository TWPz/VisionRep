#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"

rg -q 'templates\.count >= 5 \? "Count Live" : "Record Rep"' "$model_file"
rg -q 'if templates\.count >= 5' "$model_file"
rg -q 'func startCountingFromTemplates' "$model_file"
rg -q 'LiveCountButton' "$dashboard_file"
rg -q 'model\.templates\.count >= 3 && model\.templates\.count < 5 && model\.mode == \.templatesReady' "$dashboard_file"
rg -q 'model\.templates\.count < 5' "$dashboard_file"
rg -q 'strictLengthRange' "$counter_file"
rg -q 'completeLengthRange' "$counter_file"
rg -q 'minimumCandidateDuration' "$counter_file"
rg -q 'completionCooldown' "$counter_file"
rg -q 'completionPoseMatches' "$counter_file"
