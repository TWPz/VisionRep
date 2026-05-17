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
rg -q 'PhasePathProgressBar' "$dashboard_file"
rg -F -q 'Text("Rep path \(clampedProgress, format: .percent.precision(.fractionLength(0)))")' "$dashboard_file"
rg -F -q 'Text("Match \(clampedConfidence, format: .percent.precision(.fractionLength(0)))")' "$dashboard_file"
rg -q 'model\.displayedRepetitionCount' "$dashboard_file"
rg -q 'model\.movementPhaseProgress' "$dashboard_file"
rg -F -q '.accessibilityLabel("Live count \(model.displayedRepetitionCount) reps, confidence \(Int(model.matchConfidence * 100)) percent, phase \(Int(model.movementPhaseProgress * 100)) percent")' "$dashboard_file"
rg -q 'let previousRepetitionCount = repetitionCount' "$model_file"
rg -q 'let nextDisplayedRepetitionCount = update\.repetitions' "$model_file"
if rg -q 'let nextDisplayedRepetitionCount = update\.repetitions \+ \(update\.pendingRepetition \? 1 : 0\)' "$model_file"; then
    echo "visible rep count should only show confirmed repetitions, not pending matches" >&2
    exit 1
fi
rg -q 'movementPhaseProgress = roundedProgress' "$model_file"
rg -q 'minimumCandidateMovement' "$counter_file"
rg -q 'movementMagnitude' "$counter_file"
rg -q 'candidateMovement' "$counter_file"
