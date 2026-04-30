#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"
voice_file="$repo_root/VisionRep/Services/VoiceCommandListener.swift"

rg -q 'case action' "$voice_file"
rg -q 'containsActionCommand' "$voice_file"
rg -q 'listeningFor allowedCommands: Set<Command>' "$voice_file"
rg -q 'didHandleCommand' "$voice_file"
rg -q 'voiceSessionID' "$voice_file"
rg -q 'self\.voiceSessionID == sessionID' "$voice_file"
rg -q 'sessionID: Int' "$voice_file"
rg -q 'sessionID: sessionID' "$voice_file"
rg -q 'guard voiceSessionID == sessionID else' "$voice_file"
rg -q 'onCommand\(command\)' "$voice_file"

rg -q 'refreshVoiceCommandsForCurrentMode' "$model_file"
rg -Fq 'startVoiceCommands(listeningFor: [.action])' "$model_file"
rg -Fq 'startVoiceCommands(listeningFor: [.stop])' "$model_file"
rg -q 'case \.action:' "$model_file"
rg -q 'beginTemplateRecording\(\)' "$model_file"
rg -q 'templates\.count < 5' "$model_file"

rg -q 'say action' "$dashboard_file"
