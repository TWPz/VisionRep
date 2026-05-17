#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
overlay_file="$repo_root/VisionRep/Views/SkeletonOverlayView.swift"

rg -q 'var renderFramesPerSecond: Double = 12' "$overlay_file"
rg -q 'TimelineView\(\.periodic\(from: timelineStartDate, by: frameInterval\)\)' "$overlay_file"
rg -q 'State private var timelineStartDate' "$overlay_file"
rg -q 'private var frameInterval: TimeInterval' "$overlay_file"
rg -q 'private var interpolationDuration: TimeInterval' "$overlay_file"
rg -q 'private func interpolatedPose\(at date: Date\) -> PoseFrame\?' "$overlay_file"
rg -q 'private func blendedJoint' "$overlay_file"
rg -q 'onChange\(of: pose\)' "$overlay_file"
rg -q 'joints\.reserveCapacity' "$overlay_file"
! rg -q 'Set\(previousPose\.joints\.keys\)\.union\(targetPose\.joints\.keys\)' "$overlay_file"

echo "skeleton overlay interpolation verified"
