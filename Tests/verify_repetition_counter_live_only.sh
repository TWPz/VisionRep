#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"

rg -U -q 'case \.counting:\n\s*guard isLiveCountingActive else \{\n\s*return\n\s*\}\n\s*liveRepetitionCounter\.submit\(frame, quality: quality\)' "$model_file"
rg -U -q 'private func handleActualRepetitionFrameRateChange\(_ framesPerSecond: Double\) \{\n\s*guard mode == \.counting, isLiveCountingActive else \{\n\s*debugRepetitionFramesPerSecond = 0\n\s*return\n\s*\}' "$model_file"
rg -U -q 'self\.countingCountdownRemaining = nil\n\s*self\.isLiveCountingActive = true\n\s*self\.liveRepetitionCounter\.resetCount\(\)' "$model_file"
rg -U -q 'func pauseCounting\(\) \{\n\s*stopCountingCountdown\(\)\n\s*isLiveCountingActive = false\n\s*debugRepetitionFramesPerSecond = 0' "$model_file"

python3 - "$model_file" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()

def body(name: str) -> str:
    match = re.search(rf"func {name}\([^)]*\) \{{(?P<body>.*?)\n    \}}", source, re.S)
    if not match:
        raise SystemExit(f"missing {name}")
    return match.group("body")

start_counting = body("startCounting")
if not re.search(r"isLiveCountingActive = false\s+mode = \.counting\s+startCountingCountdown\(\)", start_counting):
    raise SystemExit("startCounting should not activate live repetition processing until countdown finishes")

begin_training = body("beginTemplateRecording")
if not re.search(r"isLiveCountingActive = false\s+debugRepetitionFramesPerSecond = 0", begin_training):
    raise SystemExit("training should deactivate repetition processing telemetry")
PY

echo "repetition counter live-only activation verified"
