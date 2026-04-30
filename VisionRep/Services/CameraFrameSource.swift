@preconcurrency import AVFoundation
import Foundation

nonisolated enum CameraState: Equatable, Sendable {
    case idle
    case needsPermission
    case configuring
    case running
    case failed(String)
}

nonisolated enum CameraFramingMode: Equatable, Sendable {
    case centerStageTracking
    case widestView
}

nonisolated final class CameraFrameSource: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    var frameHandler: ((CMSampleBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.visionrep.camera.session")
    private let videoQueue = DispatchQueue(label: "com.visionrep.camera.frames", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let targetCameraFramesPerSecond: Double = 30
    private var framingMode: CameraFramingMode = .centerStageTracking
    private var isConfigured = false

    func requestAccessAndConfigure(completion: @escaping (CameraState) -> Void) {
        #if targetEnvironment(simulator)
        completion(.failed("Live camera capture requires a physical iPhone. Build to a device to record templates and count reps."))
        return
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure(completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configure(completion: completion)
                } else {
                    DispatchQueue.main.async {
                        completion(.needsPermission)
                    }
                }
            }
        case .denied, .restricted:
            completion(.needsPermission)
        @unknown default:
            completion(.failed("Unknown camera authorization state."))
        }
        #endif
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func setFramingMode(_ mode: CameraFramingMode, completion: @escaping (CameraState) -> Void) {
        DispatchQueue.main.async {
            completion(.configuring)
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.framingMode = mode
            guard self.isConfigured else {
                DispatchQueue.main.async {
                    completion(.idle)
                }
                return
            }

            let wasRunning = self.session.isRunning
            if wasRunning {
                self.session.stopRunning()
            }

            do {
                try self.configureSession()
                if wasRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async {
                    completion(wasRunning ? .running : .idle)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failed(error.localizedDescription))
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameHandler?(sampleBuffer)
    }

    private func configure(completion: @escaping (CameraState) -> Void) {
        DispatchQueue.main.async {
            completion(.configuring)
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.configureSession()
                self.isConfigured = true
                DispatchQueue.main.async {
                    completion(.idle)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        guard let device = preferredFrontCamera(for: framingMode) else {
            throw CameraConfigurationError.noCamera
        }

        try configureDevice(device, for: framingMode)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraConfigurationError.cannotAddInput
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(output) else {
            throw CameraConfigurationError.cannotAddOutput
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
    }

    private func preferredFrontCamera(for mode: CameraFramingMode) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInTrueDepthCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )

        let candidates: [AVCaptureDevice]
        switch mode {
        case .widestView:
            let ultraWideDevices = discovery.devices.filter { $0.deviceType == .builtInUltraWideCamera }
            candidates = ultraWideDevices.isEmpty ? discovery.devices : ultraWideDevices
        case .centerStageTracking:
            let centerStageDevices = discovery.devices.filter { device in
                device.formats.contains(where: \.isCenterStageSupported)
            }
            candidates = centerStageDevices.isEmpty ? discovery.devices : centerStageDevices
        }

        return candidates.max { lhs, rhs in
            widestSupportedFieldOfView(for: lhs, mode: mode) < widestSupportedFieldOfView(for: rhs, mode: mode)
        }
    }

    private func configureDevice(_ device: AVCaptureDevice, for mode: CameraFramingMode) throws {
        configureCenterStage(for: mode, device: device)

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if let wideFormat = preferredWideFieldOfViewFormat(for: device, mode: mode) {
            device.activeFormat = wideFormat
        }

        let duration = CMTime(value: 1, timescale: CMTimeScale(targetCameraFramesPerSecond))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        device.videoZoomFactor = device.minAvailableVideoZoomFactor
    }

    private func configureCenterStage(for mode: CameraFramingMode, device: AVCaptureDevice) {
        switch mode {
        case .widestView:
            AVCaptureDevice.isCenterStageEnabled = false
        case .centerStageTracking:
            AVCaptureDevice.centerStageControlMode = .cooperative
            guard device.formats.contains(where: \.isCenterStageSupported) else {
                AVCaptureDevice.isCenterStageEnabled = false
                return
            }
            AVCaptureDevice.isCenterStageEnabled = true
        }
    }

    private func preferredWideFieldOfViewFormat(for device: AVCaptureDevice, mode: CameraFramingMode) -> AVCaptureDevice.Format? {
        let frameRateFormats = device.formats.filter { format in
            format.supports(frameRate: targetCameraFramesPerSecond)
        }
        let candidates: [AVCaptureDevice.Format]
        switch mode {
        case .widestView:
            candidates = frameRateFormats
        case .centerStageTracking:
            let centerStageFormats = frameRateFormats.filter(\.isCenterStageSupported)
            candidates = centerStageFormats.isEmpty ? frameRateFormats : centerStageFormats
        }

        return candidates.max { lhs, rhs in
            if lhs.videoFieldOfView == rhs.videoFieldOfView {
                return formatDistanceFrom720p(lhs) > formatDistanceFrom720p(rhs)
            }
            return lhs.videoFieldOfView < rhs.videoFieldOfView
        }
    }

    private func widestSupportedFieldOfView(for device: AVCaptureDevice, mode: CameraFramingMode) -> Float {
        preferredWideFieldOfViewFormat(for: device, mode: mode)?.videoFieldOfView
            ?? device.formats.map(\.videoFieldOfView).max()
            ?? 0
    }

    private func formatDistanceFrom720p(_ format: AVCaptureDevice.Format) -> Int32 {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return abs(dimensions.width - 1280) + abs(dimensions.height - 720)
    }
}

private extension AVCaptureDevice.Format {
    nonisolated func supports(frameRate: Double) -> Bool {
        videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= frameRate && range.maxFrameRate >= frameRate
        }
    }
}

private nonisolated enum CameraConfigurationError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera:
            "No front camera is available on this device."
        case .cannotAddInput:
            "The camera input could not be added."
        case .cannotAddOutput:
            "The video frame output could not be added."
        }
    }
}
