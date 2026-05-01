#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
overlay_file="$repo_root/VisionRep/Views/SkeletonOverlayView.swift"

test -f "$overlay_file"

rg -q 'sourceAspectRatio: CGFloat = 9\.0 / 16\.0' "$overlay_file"
rg -q 'rotatesLandscapeSourceToPortrait = true' "$overlay_file"
rg -q 'mirrorsFrontCameraPreview = true' "$overlay_file"
rg -q 'previewNormalizedPoint\(from joint: PoseJoint\)' "$overlay_file"
rg -q 'let rotatedPoint: CGPoint' "$overlay_file"
rg -q 'rotatedPoint = CGPoint\(x: 1 - joint\.y, y: joint\.x\)' "$overlay_file"
rg -q 'guard mirrorsFrontCameraPreview else \{ return rotatedPoint \}' "$overlay_file"
rg -q 'return CGPoint\(x: 1 - rotatedPoint\.x, y: rotatedPoint\.y\)' "$overlay_file"
rg -q 'let previewPoint = previewNormalizedPoint\(from: joint\)' "$overlay_file"
rg -q 'aspectFillPoint\(_ joint: PoseJoint, in size: CGSize\)' "$overlay_file"
rg -q 'let viewAspectRatio = size\.width / size\.height' "$overlay_file"
rg -q 'let drawnHeight = size\.width / sourceAspectRatio' "$overlay_file"
rg -q 'let drawnWidth = size\.height \* sourceAspectRatio' "$overlay_file"
rg -q 'private func isDrawable\(_ point: CGPoint, in size: CGSize\) -> Bool' "$overlay_file"
rg -q 'start\.confidence >= minimumJointConfidence' "$overlay_file"
rg -q 'SkeletonConnection\(start: \.leftShoulder, end: \.rightShoulder, group: \.torso\)' "$overlay_file"
rg -q 'case head, torso, arms, legs' "$overlay_file"
rg -q 'static func group\(for joint: PoseJointName\) -> SkeletonGroup' "$overlay_file"

echo "skeleton aspect-fill overlay mapping verified"
