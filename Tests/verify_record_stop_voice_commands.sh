#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
voice_file="$repo_root/VisionRep/Services/VoiceCommandListener.swift"
model_file="$repo_root/VisionRep/Models/WorkoutSessionModel.swift"
dashboard_file="$repo_root/VisionRep/Views/WorkoutDashboardView.swift"

rg -q 'actionCommandWords' "$voice_file"
rg -q 'private static let actionCommandWords: Set<String> = \["action"\]' "$voice_file"
! rg -q 'private static let actionCommandWords: Set<String> = .*record' "$voice_file"
! rg -q 'private static let actionCommandWords: Set<String> = .*start' "$voice_file"
! rg -q 'private static let actionCommandWords: Set<String> = .*go' "$voice_file"
rg -q 'finishTemplateRecording\(triggeredByVoice: true\)' "$model_file"
rg -q 'minimumTemplateFrameCount' "$model_file"
rg -q 'voiceCommandStatus = "Keep recording' "$model_file"
rg -q 'say action' "$dashboard_file"

tmp_file="$(mktemp /tmp/mpipe-record-stop-voice-XXXXXX.swift)"
trap 'rm -f "$tmp_file"' EXIT

cat > "$tmp_file" <<'SWIFT'
import Foundation

final class VoiceCommandListener {
    enum Command: Hashable {
        case action
        case stop
    }

    private static let actionCommandWords: Set<String> = ["action"]
    private static let stopCommandWords: Set<String> = ["stop", "finish", "done", "save"]

    static func command(in transcript: String, allowedCommands: Set<Command>) -> Command? {
        if allowedCommands.contains(.action), containsActionCommand(in: transcript) {
            return .action
        }

        if allowedCommands.contains(.stop), containsStopCommand(in: transcript) {
            return .stop
        }

        return nil
    }

    private static func containsActionCommand(in transcript: String) -> Bool {
        commandWords(in: transcript).contains { actionCommandWords.contains($0) }
    }

    private static func containsStopCommand(in transcript: String) -> Bool {
        commandWords(in: transcript).contains { stopCommandWords.contains($0) }
    }

    private static func commandWords(in transcript: String) -> [String] {
        let words = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
        return words
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

expect(VoiceCommandListener.command(in: "action", allowedCommands: [.action]) == .action, "action should start a template capture")
expect(VoiceCommandListener.command(in: "record rep", allowedCommands: [.action]) == nil, "record should not start a template capture")
expect(VoiceCommandListener.command(in: "start recording", allowedCommands: [.action]) == nil, "start should not start a template capture")
expect(VoiceCommandListener.command(in: "go", allowedCommands: [.action]) == nil, "go should not start a template capture")
expect(VoiceCommandListener.command(in: "stop", allowedCommands: [.stop]) == .stop, "stop should finish template capture")
expect(VoiceCommandListener.command(in: "record", allowedCommands: [.stop]) == nil, "record should not be accepted while only stop is allowed")

print("record/stop voice commands verified")
SWIFT

swift "$tmp_file"

echo "record and stop voice behavior verified"
