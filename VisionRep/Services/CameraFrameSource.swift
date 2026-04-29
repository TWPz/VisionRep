@preconcurrency import AVFoundation
import Foundation

nonisolated enum CameraState: Equatable, Sendable {
    case idle
    case needsPermission
    case configuring
    case running
    case failed(String)
}

nonisolated final class CameraFrameSource: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    var frameHandler: ((CMSampleBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.visionrep.camera.session")
    private let videoQueue = DispatchQueue(label: "com.visionrep.camera.frames", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
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

        guard let device = preferredFrontCamera() else {
            throw CameraConfigurationError.noCamera
        }

        try configureDevice(device)

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

    private func preferredFrontCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )

        return discovery.devices.first { $0.deviceType == .builtInUltraWideCamera }
            ?? discovery.devices.first { $0.deviceType == .builtInWideAngleCamera }
    }

    private func configureDevice(_ device: AVCaptureDevice) throws {
        configureCenterStageIfSupported(by: device)

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if let centerStageFormat = preferredCenterStageFormat(for: device) {
            device.activeFormat = centerStageFormat
        }

        let duration = CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        device.videoZoomFactor = device.minAvailableVideoZoomFactor
    }

    private func configureCenterStageIfSupported(by device: AVCaptureDevice) {
        guard device.formats.contains(where: \.isCenterStageSupported) else { return }

        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = true
    }

    private func preferredCenterStageFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { format in
            format.isCenterStageSupported && format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= 30 && range.maxFrameRate >= 30
            }
        }

        return formats.min { lhs, rhs in
            formatDistanceFrom720p(lhs) < formatDistanceFrom720p(rhs)
        }
    }

    private func formatDistanceFrom720p(_ format: AVCaptureDevice.Format) -> Int32 {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return abs(dimensions.width - 1280) + abs(dimensions.height - 720)
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
