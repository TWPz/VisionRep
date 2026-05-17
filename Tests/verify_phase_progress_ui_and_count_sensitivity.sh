#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"

rg -q 'PhasePathProgressBar' "$dashboard_file"
rg -q 'phasePathProgress' "$dashboard_file"
rg -q 'Rep path' "$dashboard_file"
rg -q 'Match' "$dashboard_file"

rg -q 'completionProgressGate\(for:' "$counter_file"
if rg -q 'streamingProgress >= 0\.98' "$counter_file"; then
    echo "streaming completion should not require a nearly perfect phase path before terminal validation" >&2
    exit 1
fi
rg -q 'terminalPoseMatchesAnyTemplate\(currentPoseVector\)' "$counter_file"

python3 - "$model_file" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
body = re.search(r'private func updateLiveCountDisplay\(_ update: CountUpdate\) -> Bool \{(?P<body>.*?)\n    \}', source, re.S)
if not body:
    raise SystemExit("missing updateLiveCountDisplay")

text = body.group("body")
if "if abs(matchConfidence - update.confidence) >= 0.01" not in text:
    raise SystemExit("match confidence should update continuously while tracking, not only after a counted rep")
if "update.repetitions > previousRepetitionCount, matchConfidence != update.confidence" in text:
    raise SystemExit("match confidence is still gated behind counted repetitions")
PY

echo "phase progress UI and count sensitivity verified"
