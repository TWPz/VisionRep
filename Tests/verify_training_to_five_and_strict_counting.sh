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
rg -q 'conservativeCountGateRepetitionLimit = 10' "$counter_file"
rg -q 'hasExitedCompletionPoseSinceLastCount' "$counter_file"
rg -q 'updateCompletionResetGate' "$counter_file"
rg -q 'completionResetThreshold' "$counter_file"
rg -q 'completionPoseMatches' "$counter_file"
rg -q 'terminalCompletionPasses' "$counter_file"
rg -q 'completionPoseIsStable' "$counter_file"
rg -q 'minimumTerminalCandidateFrameCount' "$counter_file"
rg -q 'conservativeCompletionCoverageRatio' "$counter_file"
if rg -q 'candidate\.template\.sourceFrameCount / 5' "$counter_file"; then
    echo "completion should not accept one-fifth-length candidates because they can count mid-action" >&2
    exit 1
fi

python3 - "$counter_file" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
terminal = re.search(r'private func terminalCompletionPasses\([^{]+\{(?P<body>.*?)\n    \}', source, re.S)
if not terminal:
    raise SystemExit("missing terminal completion gate")
body = terminal.group("body")
if "candidateCompletesImmediately(candidate, with: frame)" not in body:
    raise SystemExit("terminal completion must require the trained end pose")
if "completionPoseIsStable()" not in body:
    raise SystemExit("terminal completion must require short end-pose stability")

immediate = re.search(r'private func immediateCompletionCandidate\([^{]+\{(?P<body>.*?)\n    \}', source, re.S)
if not immediate or "terminalCompletionPasses(candidate, with: frame, requiresCandidateEndVector: true)" not in immediate.group("body"):
    raise SystemExit("immediate completion should go through terminalCompletionPasses")
pending = re.search(r'private func completedPendingCandidate\([^{]+\{(?P<body>.*?)\n    \}', source, re.S)
if not pending or "terminalCompletionPasses(pendingCompletion.candidate, with: frame, requiresCandidateEndVector: false)" not in pending.group("body"):
    raise SystemExit("pending completion should validate the current terminal pose without requiring a stale candidate end vector")
PY
