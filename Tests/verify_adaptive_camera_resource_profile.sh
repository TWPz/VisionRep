#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
camera_file="$repo_root/VisionRep/Services/CameraFrameSource.swift"

! rg -q 'enum CameraResourceProfile|setResourceProfile|applyEffectiveResourceProfileIfNeeded' "$camera_file"
rg -q 'enum CameraCaptureProfile' "$camera_file"
rg -q 'func setCaptureProfile\(_ profile: CameraCaptureProfile\)' "$camera_file"
rg -q 'applyCaptureProfileToActiveDevice' "$camera_file"
rg -q 'supportedFrameRate' "$camera_file"
rg -U -q 'case \.ready:\n\s*12' "$camera_file"
rg -U -q 'case \.active:\n\s*24' "$camera_file"
rg -q 'min\(max\(framesPerSecond, 8\), 24\)' "$camera_file"
rg -q 'CMVideoDimensions\(width: 640, height: 480\)' "$camera_file"
rg -q '\[\.vga640x480, \.iFrame960x540, \.hd1280x720\]' "$camera_file"
rg -q 'ProcessInfo\.thermalStateDidChangeNotification' "$camera_file"
rg -q 'onThermalStateChange\?\(ProcessInfo\.processInfo\.thermalState\)' "$camera_file"
! rg -q 'Notification\.Name\.NSProcessInfoPowerStateDidChange' "$camera_file"
rg -q 'formatDistanceFromTargetResolution' "$camera_file"

python3 - "$camera_file" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'func setCaptureProfile\(_ profile: CameraCaptureProfile\) \{(?P<body>.*?)\n    \}', source, re.S)
if not match:
    raise SystemExit("missing setCaptureProfile body")
body = match.group("body")
if "stopRunning" in body or "startRunning" in body or "configureSession()" in body:
    raise SystemExit("setCaptureProfile must not restart/reconfigure the camera session")
if "captureProfile != profile" in body:
    raise SystemExit("setCaptureProfile must reapply the requested profile even when the stored profile already matches")
if "resetActualFrameRateWindow()" not in body:
    raise SystemExit("setCaptureProfile must reset actual FPS measurement after profile changes")
PY

echo "fixed camera capture and thermal-state callback verified"
