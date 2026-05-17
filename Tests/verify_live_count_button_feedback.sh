#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"

test -f "$dashboard_file"

rg -q 'import AudioToolbox' "$dashboard_file"
rg -q 'import UIKit' "$dashboard_file"
rg -q 'LiveCountButtonFeedback\.prepare\(\)' "$dashboard_file"
rg -q 'LiveCountButtonFeedback\.play\(\)' "$dashboard_file"
rg -q 'private enum LiveCountButtonFeedback' "$dashboard_file"
rg -q 'private static let impactGenerator = UIImpactFeedbackGenerator\(style: \.medium\)' "$dashboard_file"
rg -q 'impactOccurred\(intensity: 0\.85\)' "$dashboard_file"
rg -q 'AudioServicesPlaySystemSound\(LiveCountButtonFeedback\.startSoundID\)' "$dashboard_file"
rg -q 'private static let startSoundID: SystemSoundID = 1104' "$dashboard_file"
rg -q 'static func prepare\(\)' "$dashboard_file"
rg -U -q 'private func performPrimaryAction\(\) \{\n\s*if model\.primaryActionTitle == "Count Live" \{\n\s*LiveCountButtonFeedback\.play\(\)\n\s*\}\n\s*model\.performPrimaryAction\(\)\n\s*\}' "$dashboard_file"
rg -U -q 'private func performAction\(\) \{\n\s*LiveCountButtonFeedback\.play\(\)\n\s*action\(\)\n\s*\}' "$dashboard_file"
if rg -U -q 'static func play\(\) \{\n\s*let generator = UIImpactFeedbackGenerator' "$dashboard_file"; then
    echo "live count feedback should not allocate a haptic generator on button press" >&2
    exit 1
fi

echo "live count button haptic and sound feedback verified"
