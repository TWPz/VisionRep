#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
store_file="$repo_root/VisionRep/Services/ExerciseProfileStore.swift"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"

test -f "$store_file"
test -f "$model_file"

rg -q 'func save\(_ templates: \[MovementTemplate\]\) -> Bool' "$store_file"
rg -q 'return true' "$store_file"
rg -q 'return false' "$store_file"
rg -q 'let didSaveTemplates = profileStore\.save\(templates\)' "$model_file"
rg -q 'didSaveTemplates \? trainingProgressMessage : "Template save failed - check device storage\."' "$model_file"
if rg -q 'assertionFailure\("Failed to save movement templates' "$store_file"; then
    echo "template save failure must be surfaced in release builds instead of assertion-only" >&2
    exit 1
fi

echo "profile store save failure handling verified"
