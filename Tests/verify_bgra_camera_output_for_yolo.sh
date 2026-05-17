#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
camera_file="$repo_root/VisionRep/Services/CameraFrameSource.swift"

test -f "$camera_file"

rg -q 'private let cameraPixelFormat = kCVPixelFormatType_32BGRA' "$camera_file"
rg -q 'kCVPixelBufferPixelFormatTypeKey as String: cameraPixelFormat' "$camera_file"
! rg -q 'kCVPixelFormatType_420YpCbCr8BiPlanarFullRange' "$camera_file"

echo "BGRA camera output for YOLO verified"
