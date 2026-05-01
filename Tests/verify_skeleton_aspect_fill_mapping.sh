#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
overlay_file="$repo_root/VisionRep/Views/SkeletonOverlayView.swift"

test -f "$overlay_file"

rg -q 'sourceAspectRatio: CGFloat = 9\.0 / 16\.0' "$overlay_file"
rg -q 'rotatesLandscapeSourceToPortrait = true' "$overlay_file"
rg -q 'mirrorsFrontCameraPreview = true' "$overlay_file"
rg -q 'private struct AspectFillLayout' "$overlay_file"
rg -q 'let layout = AspectFillLayout\(size: size, sourceAspectRatio: sourceAspectRatio\)' "$overlay_file"
rg -q 'layout\.point\(for: start, rotation: rotatesLandscapeSourceToPortrait, mirrored: mirrorsFrontCameraPreview\)' "$overlay_file"
rg -q 'func point\(for joint: PoseJoint, rotation: Bool, mirrored: Bool\) -> CGPoint' "$overlay_file"
rg -q '\(previewX, previewY\) = \(1 - CGFloat\(joint\.y\), CGFloat\(joint\.x\)\)' "$overlay_file"
rg -q 'if mirrored \{' "$overlay_file"
rg -q 'previewX = 1 - previewX' "$overlay_file"
rg -q 'let normalizedY = 1 - previewY' "$overlay_file"
rg -q 'let viewAspectRatio = size\.width / size\.height' "$overlay_file"
rg -q 'let drawnDimension: CGFloat' "$overlay_file"
rg -q 'private func isDrawable\(_ point: CGPoint, in size: CGSize\) -> Bool' "$overlay_file"
rg -q 'start\.confidence >= minimumJointConfidence' "$overlay_file"
rg -q 'SkeletonConnection\(start: \.leftShoulder, end: \.rightShoulder, group: \.torso\)' "$overlay_file"
rg -q 'case head, torso, arms, legs' "$overlay_file"
rg -q 'static func group\(for joint: PoseJointName\) -> SkeletonGroup' "$overlay_file"

echo "skeleton aspect-fill overlay mapping verified"
