#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"
store_file="$repo_root/VisionRep/Services/ExerciseProfileStore.swift"
project_file="$repo_root/VisionRep.xcodeproj/project.pbxproj"
readme_file="$repo_root/README.md"

rg -q '# MPiPE' "$readme_file"
rg -q 'Text\("MPiPE"\)' "$dashboard_file"
rg -q 'appending\(path: "MPiPE"' "$store_file"
rg -q 'PRODUCT_BUNDLE_IDENTIFIER = com.twpz.mpipe;' "$project_file"
rg -q 'PRODUCT_NAME = MPiPE;' "$project_file"
rg -q 'path = MPiPE.app;' "$project_file"
rg -q 'INFOPLIST_KEY_CFBundleDisplayName = MPiPE;' "$project_file"

stale_four_letter_brand='R''TMW'
stale_mixed_case_brand='M''Pipe'
if rg -q "VisionRep \(Codex\)|pz\.VisionRep|path = VisionRep\.app;|# VisionRep|${stale_four_letter_brand}|pz\.${stale_four_letter_brand}|${stale_mixed_case_brand}|pz\.${stale_mixed_case_brand}" "$readme_file" "$dashboard_file" "$store_file" "$project_file"; then
    echo "stale branding remains in MPiPE copy" >&2
    exit 1
fi

echo "MPiPE branding verified"
