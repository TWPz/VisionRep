#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
counter_file="$repo_root/VisionRep/Repetition/FewShotRepetitionCounter.swift"

rg -q 'PhaseProgressTracker' "$counter_file"
rg -q 'MovementPhaseProfile' "$counter_file"
rg -q 'phaseProfile: MovementPhaseProfile' "$counter_file"
rg -q 'phaseProgress' "$counter_file"
rg -q 'phaseCheckpointIndices' "$counter_file"
rg -q 'updatePhaseTrackers' "$counter_file"
rg -q 'bestCandidate\(matching phaseSignal' "$counter_file"
rg -q 'phaseSignal != nil' "$counter_file"
rg -q 'pendingCompletion != nil' "$counter_file"
rg -q 'shouldRunFallbackVerifier' "$counter_file"

tmp_file="$(mktemp /tmp/visionrep-phase-gated-counting-XXXXXX.swift)"
trap 'rm -f "$tmp_file"' EXIT

cat "$repo_root/VisionRep/Models/PoseFrame.swift" "$counter_file" > "$tmp_file"
cat >> "$tmp_file" <<'SWIFT'

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func joint(_ x: Double, _ y: Double, _ z: Double = 0) -> PoseJoint {
    PoseJoint(x: x, y: y, confidence: 0.97, z: z)
}

func makeComplexRep(start: TimeInterval, frameCount: Int, amplitude: Double = 1.0, skipFloorPhase: Bool = false) -> [PoseFrame] {
    (0..<frameCount).map { index in
        let progress = Double(index) / Double(frameCount - 1)
        let drop = sin(min(progress, 0.42) / 0.42 * .pi / 2)
        let floorPhaseRaw = sin(max(0, min((progress - 0.24) / 0.34, 1)) * .pi)
        let floorPhase = skipFloorPhase ? 0 : floorPhaseRaw
        let returnPhase = max(0, sin(max(0, (progress - 0.58) / 0.42) * .pi / 2))
        let standRecovery = min(1, max(0, (progress - 0.68) / 0.32))
        let t = start + (Double(index) * 0.05)

        let torsoY = -0.72 + (drop * 0.62 * amplitude) - (standRecovery * 0.62 * amplitude)
        let hipY = -0.05 + (drop * 0.72 * amplitude) - (standRecovery * 0.72 * amplitude)
        let wristY = -0.25 + (drop * 0.85 * amplitude) - (returnPhase * 0.54 * amplitude)
        let ankleBack = floorPhase * 0.56 * amplitude
        let kneeBend = drop * 0.44 * amplitude - standRecovery * 0.36 * amplitude
        let armReach = floorPhase * 0.28 * amplitude
        let depthReach = floorPhase * 0.18 * amplitude

        return PoseFrame(timestamp: t, joints: [
            .leftShoulder: joint(-0.25, torsoY, -depthReach * 0.4),
            .rightShoulder: joint(0.25, torsoY, -depthReach * 0.4),
            .leftElbow: joint(-0.38 - armReach * 0.35, wristY - 0.20, -depthReach * 0.7),
            .rightElbow: joint(0.38 + armReach * 0.35, wristY - 0.20, -depthReach * 0.7),
            .leftWrist: joint(-0.48 - armReach, wristY, -depthReach),
            .rightWrist: joint(0.48 + armReach, wristY, -depthReach),
            .leftHip: joint(-0.18, hipY, depthReach * 0.3),
            .rightHip: joint(0.18, hipY, depthReach * 0.3),
            .leftKnee: joint(-0.22 - ankleBack * 0.25, 0.46 + kneeBend, depthReach * 0.5),
            .rightKnee: joint(0.22 + ankleBack * 0.25, 0.46 + kneeBend, depthReach * 0.5),
            .leftAnkle: joint(-0.24 - ankleBack, 0.98 + floorPhase * 0.18, depthReach * 0.8),
            .rightAnkle: joint(0.24 + ankleBack, 0.98 + floorPhase * 0.18, depthReach * 0.8)
        ])
    }
}

let trainer = FewShotRepetitionCounter()
let templates = [
    trainer.makeTemplate(index: 1, frames: makeComplexRep(start: 0, frameCount: 100, amplitude: 1.0), averageQuality: 0.97),
    trainer.makeTemplate(index: 2, frames: makeComplexRep(start: 10, frameCount: 104, amplitude: 1.04), averageQuality: 0.96),
    trainer.makeTemplate(index: 3, frames: makeComplexRep(start: 20, frameCount: 96, amplitude: 0.96), averageQuality: 0.96),
    trainer.makeTemplate(index: 4, frames: makeComplexRep(start: 30, frameCount: 102, amplitude: 1.02), averageQuality: 0.96),
    trainer.makeTemplate(index: 5, frames: makeComplexRep(start: 40, frameCount: 98, amplitude: 0.98), averageQuality: 0.96)
].compactMap { $0 }

expect(templates.count == 5, "expected five complex templates")
expect(templates.allSatisfy { $0.phaseProfile.checkpointIndices.count >= 5 }, "training templates should persist learned phase checkpoints")

let progressCounter = FewShotRepetitionCounter()
progressCounter.load(templates: templates)
var progressUpdate = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
for frame in makeComplexRep(start: 70, frameCount: 60, amplitude: 1.0).prefix(24) {
    progressUpdate = progressCounter.update(with: frame)
}
expect(progressUpdate.repetitions == 0, "partial complex movement must not count while phase is still in progress")
expect(progressUpdate.phaseProgress > 0.1, "counting should expose live phase progress after the movement starts")
expect(progressUpdate.phaseProgress < 1.0, "partial complex movement should not report completed phase progress")

let counter = FewShotRepetitionCounter()
counter.load(templates: templates)

var latest = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
let fastRep = makeComplexRep(start: 100, frameCount: 60, amplitude: 1.0)
for frame in fastRep.dropLast(24) {
    latest = counter.update(with: frame)
}
expect(latest.repetitions == 0, "complex rep must not count before the final learned phases")

for frame in fastRep.suffix(24) {
    latest = counter.update(with: frame)
}
expect(latest.repetitions == 1, "complex 3-second rep should count immediately when all phases complete")

let veryFastCounter = FewShotRepetitionCounter()
veryFastCounter.load(templates: templates)
var veryFast = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
for frame in makeComplexRep(start: 140, frameCount: 20, amplitude: 1.0) {
    veryFast = veryFastCounter.update(with: frame)
}
expect(veryFast.repetitions == 1, "rep duration shorter than training should not be a rejection reason when all learned phases are visible")

let verySlowCounter = FewShotRepetitionCounter()
verySlowCounter.load(templates: templates)
var verySlow = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
for frame in makeComplexRep(start: 300, frameCount: 160, amplitude: 1.0) {
    verySlow = verySlowCounter.update(with: frame)
}
expect(verySlow.repetitions == 1, "rep duration longer than training should not be a rejection reason when all learned phases are visible")

let partialCounter = FewShotRepetitionCounter()
partialCounter.load(templates: templates)
var partial = CountUpdate(repetitions: 0, confidence: 0, bestScore: .infinity, matchedTemplateIndex: nil)
for frame in makeComplexRep(start: 200, frameCount: 160, amplitude: 1.0, skipFloorPhase: true) {
    partial = partialCounter.update(with: frame)
}
expect(partial.repetitions == 0, "complex action that skips the floor/plank phase must not count")
expect(partial.phaseProgress < 1.0, "bad-form complex action must not show completed progress when no rep counted")

print("phase-gated complex counting verified")
SWIFT

swift "$tmp_file"
