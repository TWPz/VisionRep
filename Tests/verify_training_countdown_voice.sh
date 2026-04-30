#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"
voice_file="$repo_root/VisionRep/Services/VoiceCommandListener.swift"
project_file="$repo_root/VisionRep.xcodeproj/project.pbxproj"

rg -q 'trainingCountdownRemaining' "$model_file"
rg -q 'startTrainingCountdown' "$model_file"
rg -q 'isTemplateCaptureActive' "$model_file"
rg -q 'guard isTemplateCaptureActive else' "$model_file"
rg -q 'startVoiceCommands' "$model_file"
rg -q 'handleVoiceCommand' "$model_file"
rg -q 'VoiceCommandListener' "$voice_file"
rg -q 'requiresOnDeviceRecognition = true' "$voice_file"
rg -q 'stop' "$voice_file"
rg -q 'CenterTrainingCountdownView' "$dashboard_file"
rg -q 'model\.trainingCountdownRemaining' "$dashboard_file"
rg -q 'countdownOverlay' "$dashboard_file"
! rg -q 'countdownRemaining:' "$dashboard_file"
rg -q 'NSSpeechRecognitionUsageDescription' "$project_file"
rg -q 'NSMicrophoneUsageDescription' "$project_file"
