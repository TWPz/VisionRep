#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"

rg -q 'countingCountdownRemaining' "$model_file"
rg -q 'isLiveCountingActive' "$model_file"
rg -q 'startCountingCountdown' "$model_file"
rg -q 'stride\(from: 5, through: 1' "$model_file"
rg -q 'guard isLiveCountingActive else' "$model_file"
rg -q 'model\.countingCountdownRemaining \?\? model\.trainingCountdownRemaining' "$dashboard_file"
rg -q 'model\.countingCountdownRemaining == nil' "$dashboard_file"
! rg -q 'MetricChip\(title: "Match"' "$dashboard_file"
! rg -q 'MetricChip\(title: "Frames"' "$dashboard_file"
rg -F -q 'Text("Confidence \(model.matchConfidence, format: .percent.precision(.fractionLength(0)))")' "$dashboard_file"
rg -F -q '.accessibilityLabel("Live count \(model.repetitionCount) reps, confidence \(Int(model.matchConfidence * 100)) percent")' "$dashboard_file"
rg -q 'let previousRepetitionCount = repetitionCount' "$model_file"
rg -U -q 'repetitionCount = update\.repetitions\n\s*if update\.repetitions > previousRepetitionCount \{\n\s*matchConfidence = update\.confidence\n\s*\}' "$model_file"
rg -q 'minimumCandidateMovement' "$counter_file"
rg -q 'movementMagnitude' "$counter_file"
rg -q 'candidateMovement' "$counter_file"
