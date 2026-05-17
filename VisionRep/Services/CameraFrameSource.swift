@preconcurrency import AVFoundation
import Foundation

nonisolated enum CameraState: Equatable, Sendable {
    case idle
    case needsPermission
    case configuring
    case running
    case failed(String)
}

nonisolated enum CameraCaptureProfile: Equatable, Sendable {
    case ready
    case active
    case adaptive(Double)

    var targetFramesPerSecond: Double {
        switch self {
        case .ready:
            12
        case .active:
            24
        case .adaptive(let framesPerSecond):
            min(max(framesPerSecond, 8), 24)
        }
    }

    var targetDimensions: CMVideoDimensions {
        CMVideoDimensions(width: 640, height: 480)
    }
}

nonisolated final class CameraFrameSource: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    var frameHandler: ((CMSampleBuffer) -> Void)?
    var onThermalStateChange: ((ProcessInfo.ThermalState) -> Void)?
    var onActualFramesPerSecondChange: ((Double) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.visionrep.camera.session")
    private let videoQueue = DispatchQueue(label: "com.visionrep.camera.frames", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let cameraPixelFormat = kCVPixelFormatType_32BGRA
    private let preferredSessionPresets: [AVCaptureSession.Preset] = [.vga640x480, .iFrame960x540, .hd1280x720]
    private var captureProfile: CameraCaptureProfile = .ready
    private var thermalObserver: NSObjectProtocol?
    private var isConfigured = false
    private var actualFrameRateWindowStartTimestamp: TimeInterval?
    private var actualFrameRateWindowFrameCount = 0

    override init() {
        super.init()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.onThermalStateChange?(ProcessInfo.processInfo.thermalState)
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

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

    func setCaptureProfile(_ profile: CameraCaptureProfile) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureProfile = profile
            self.resetActualFrameRateWindow()
            guard self.isConfigured,
                  let device = (self.session.inputs.first as? AVCaptureDeviceInput)?.device
            else { return }

            do {
                try self.applyCaptureProfileToActiveDevice(device)
            } catch {
                self.onThermalStateChange?(ProcessInfo.processInfo.thermalState)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        recordActualCameraFrameRate(sampleBuffer)
        frameHandler?(sampleBuffer)
    }

    private func recordActualCameraFrameRate(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard let windowStartTimestamp = actualFrameRateWindowStartTimestamp else {
            actualFrameRateWindowStartTimestamp = timestamp
            actualFrameRateWindowFrameCount = 0
            return
        }

        actualFrameRateWindowFrameCount += 1
        let elapsed = timestamp - windowStartTimestamp
        guard elapsed >= 1 else { return }

        let framesPerSecond = Double(actualFrameRateWindowFrameCount) / elapsed
        actualFrameRateWindowStartTimestamp = timestamp
        actualFrameRateWindowFrameCount = 0
        onActualFramesPerSecondChange?(framesPerSecond)
    }

    private func resetActualFrameRateWindow() {
        actualFrameRateWindowStartTimestamp = nil
        actualFrameRateWindowFrameCount = 0
        onActualFramesPerSecondChange?(0)
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

        for preset in preferredSessionPresets where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
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
            kCVPixelBufferPixelFormatTypeKey as String: cameraPixelFormat
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
            deviceTypes: [.builtInUltraWideCamera, .builtInTrueDepthCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )

        let devicesSupportingRequestedFrameRate = discovery.devices.filter { device in
            preferredWideFieldOfViewFormat(for: device) != nil
        }
        let rankedDevices = devicesSupportingRequestedFrameRate.isEmpty
            ? discovery.devices
            : devicesSupportingRequestedFrameRate

        return rankedDevices.max { lhs, rhs in
            widestSupportedFieldOfView(for: lhs) < widestSupportedFieldOfView(for: rhs)
        }
    }

    private func configureDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if let wideFormat = preferredWideFieldOfViewFormat(for: device) {
            device.activeFormat = wideFormat
        }

        try applyCaptureProfileToLockedDevice(device)
        device.videoZoomFactor = device.minAvailableVideoZoomFactor
    }

    private func applyCaptureProfileToActiveDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        try applyCaptureProfileToLockedDevice(device)
    }

    private func applyCaptureProfileToLockedDevice(_ device: AVCaptureDevice) throws {
        if let preferredFormat = preferredWideFieldOfViewFormat(for: device),
           device.activeFormat != preferredFormat {
            device.activeFormat = preferredFormat
        }

        guard let supportedFrameRate = supportedFrameRate(for: device, requestedFrameRate: captureProfile.targetFramesPerSecond) else {
            throw CameraConfigurationError.noSupportedFrameRate
        }

        let duration = CMTime(value: 1, timescale: CMTimeScale(supportedFrameRate.rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private func preferredWideFieldOfViewFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let frameRateFormats = device.formats.filter { format in
            self.format(format, supportsFrameRate: captureProfile.targetFramesPerSecond)
        }

        return frameRateFormats.max { lhs, rhs in
            if lhs.videoFieldOfView == rhs.videoFieldOfView {
                return formatDistanceFromTargetResolution(lhs) > formatDistanceFromTargetResolution(rhs)
            }
            return lhs.videoFieldOfView < rhs.videoFieldOfView
        }
    }

    private func widestSupportedFieldOfView(for device: AVCaptureDevice) -> Float {
        preferredWideFieldOfViewFormat(for: device)?.videoFieldOfView
            ?? 0
    }

    private func format(_ format: AVCaptureDevice.Format, supportsFrameRate requestedFrameRate: Double) -> Bool {
        format.videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= requestedFrameRate && requestedFrameRate <= range.maxFrameRate
        }
    }

    private func supportedFrameRate(for device: AVCaptureDevice, requestedFrameRate: Double) -> Double? {
        let supportedFrameRates = device.activeFormat.videoSupportedFrameRateRanges
            .filter { range in
                range.minFrameRate <= requestedFrameRate && requestedFrameRate <= range.maxFrameRate
            }
        if !supportedFrameRates.isEmpty {
            return requestedFrameRate
        }

        return device.activeFormat.videoSupportedFrameRateRanges
            .map(\.maxFrameRate)
            .filter { $0 <= requestedFrameRate }
            .max()
            ?? device.activeFormat.videoSupportedFrameRateRanges.map(\.minFrameRate).min()
    }

    private func formatDistanceFromTargetResolution(_ format: AVCaptureDevice.Format) -> Int32 {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let targetDimensions = captureProfile.targetDimensions
        return abs(dimensions.width - targetDimensions.width) + abs(dimensions.height - targetDimensions.height)
    }
}

private enum CameraConfigurationError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case noSupportedFrameRate

    var errorDescription: String? {
        switch self {
        case .noCamera:
            "No front camera is available on this device."
        case .cannotAddInput:
            "Unable to add the camera input."
        case .cannotAddOutput:
            "Unable to add the camera output."
        case .noSupportedFrameRate:
            "The selected camera format does not support the requested frame rate."
        }
    }
}
