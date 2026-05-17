#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
preview_file="$repo_root/VisionRep/Views/CameraPreview.swift"

rg -q 'configurePreviewConnection\(\)' "$preview_file"
! rg -q 'connection\.videoRotationAngle = 90' "$preview_file"
rg -q 'connection\.automaticallyAdjustsVideoMirroring = false' "$preview_file"
rg -q 'connection\.isVideoMirrored = true' "$preview_file"
rg -q 'videoPreviewLayer\.videoGravity = \.resizeAspectFill' "$preview_file"

echo "camera preview alignment verified"
