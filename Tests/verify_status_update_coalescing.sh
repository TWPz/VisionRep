#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"

test -f "$model_file"

rg -q 'private func updateStatus\(_ message: String\)' "$model_file"
rg -q 'guard statusMessage != message else \{ return \}' "$model_file"
rg -q 'updateStatus\(quality\.guidance\)' "$model_file"
rg -q 'updateStatus\("Track the full recorded movement path\."\)' "$model_file"
rg -q 'updateStatus\("Movement matched template' "$model_file"

echo "status update coalescing verified"
