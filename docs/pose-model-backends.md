# Pose Model Backend

The app uses the provided Ultralytics YOLO26n pose Core ML package as its active iOS pose backend. The model runs as single-frame inference through Vision/Core ML and maps 17 COCO keypoints into the app's compact `PoseFrame`: nose, shoulders, elbows, wrists, hips, knees, ankles, plus derived neck/root.

## Active Model

`yolo26n-pose.mlpackage` is bundled under `VisionRep/Resources/Models`. `YoloCoreMLPoseEstimator` loads the compiled model from the app bundle when Xcode produces `mlmodelc`, or compiles the packaged model at runtime as a fallback for local/dev bundle layouts.

## Integration

The backend uses system frameworks only: `CoreML`, `Vision`, and `AVFoundation`, so CI and local builds can use the standalone `VisionRep.xcodeproj`.

## Data Flow

Camera frames are captured as BGRA sample buffers for a stable preview/inference path, then submitted to a `VNCoreMLRequest`. The YOLO output is decoded from `[1, 300, 57]`, selecting the highest-confidence person detection and reading 17 `(x, y, confidence)` keypoints. Keypoints are normalized into `PoseFrame`, smoothed, quality-scored, and passed into the repetition counter.

YOLO pose does not provide world landmarks, so live templates captured with this backend should be treated as 2D pose templates. Existing depth-aware counter code remains compatible with older/synthetic frames that include `z`, but YOLO frames intentionally leave `z` unset.

Source: https://docs.ultralytics.com/tasks/pose/
