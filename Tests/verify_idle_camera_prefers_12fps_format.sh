#!/usr/bin/env zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
camera_file="$repo_root/VisionRep/Services/CameraFrameSource.swift"

rg -q 'format\(_ format: AVCaptureDevice\.Format, supportsFrameRate requestedFrameRate: Double\)' "$camera_file"
rg -q 'let devicesSupportingRequestedFrameRate = discovery\.devices\.filter' "$camera_file"
rg -q 'let rankedDevices = devicesSupportingRequestedFrameRate\.isEmpty' "$camera_file"
rg -q 'preferredWideFieldOfViewFormat\(for: device\) != nil' "$camera_file"
rg -q 'if let preferredFormat = preferredWideFieldOfViewFormat\(for: device\)' "$camera_file"
rg -q 'device\.videoZoomFactor = device\.minAvailableVideoZoomFactor' "$camera_file"
rg -q 'return lhs\.videoFieldOfView < rhs\.videoFieldOfView' "$camera_file"

python3 - "$camera_file" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
preferred = re.search(r'private func widestSupportedFieldOfView\(for device: AVCaptureDevice\) -> Float \{(?P<body>.*?)\n    \}', source, re.S)
if not preferred:
    raise SystemExit("missing widestSupportedFieldOfView")
if "?? device.formats.map(\\.videoFieldOfView).max()" in preferred.group("body"):
    raise SystemExit("unsupported devices must not be ranked by their widest fallback FOV when selecting an idle 12 FPS camera")

apply = re.search(r'private func applyCaptureProfileToLockedDevice\(_ device: AVCaptureDevice\) throws \{(?P<body>.*?)\n    \}', source, re.S)
if not apply:
    raise SystemExit("missing applyCaptureProfileToLockedDevice")
body = apply.group("body")
if body.find("preferredWideFieldOfViewFormat(for: device)") > body.find("supportedFrameRate(for: device"):
    raise SystemExit("capture profile must reselect a format before calculating supported frame duration")
PY

echo "idle camera 12 FPS format preference verified"
