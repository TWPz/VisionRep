import Foundation

nonisolated final class LiveRepetitionCounterBridge: @unchecked Sendable {
    var onUpdate: ((CountUpdate, PoseQuality) -> Void)?
    var onActualFramesPerSecondChange: ((Double) -> Void)?

    private struct PendingFrame {
        var frame: PoseFrame
        var quality: PoseQuality
    }

    private let queue = DispatchQueue(label: "com.visionrep.repetition.counter", qos: .userInitiated)
    private let stateLock = NSLock()
    private let counter = FewShotRepetitionCounter()
    private let targetFramesPerSecond: Double = 12
    private var isProcessing = false
    private var lastReportedRepetitions = 0
    private var lastAcceptedFrameTimestamp: TimeInterval = -.infinity
    private var pendingFrame: PendingFrame?
    private var actualFrameRateWindowStartTime: TimeInterval?
    private var actualFrameRateWindowFrameCount = 0

    func load(templates: [MovementTemplate]) {
        discardPendingFrames()
        resetThrottle()
        resetActualFrameRateWindow()
        resetLastReportedRepetitions()
        queue.async { [weak self] in
            guard let self else { return }
            self.counter.load(templates: templates)
            self.resetLastReportedRepetitions()
        }
    }

    func resetCount() {
        discardPendingFrames()
        resetThrottle()
        resetActualFrameRateWindow()
        resetLastReportedRepetitions()
        queue.async { [weak self] in
            guard let self else { return }
            self.counter.resetCount()
            self.resetLastReportedRepetitions()
        }
    }

    func clearOnlineTemplates() {
        discardPendingFrames()
        queue.async { [weak self] in
            self?.counter.clearOnlineTemplates()
        }
    }

    func submit(_ frame: PoseFrame, quality: PoseQuality) {
        guard shouldAcceptFrame(timestamp: frame.timestamp) else {
            return
        }

        let item = PendingFrame(frame: frame, quality: quality)

        stateLock.lock()
        if isProcessing {
            pendingFrame = item
            stateLock.unlock()
            return
        }
        isProcessing = true
        stateLock.unlock()

        queue.async { [weak self] in
            self?.process(item)
        }
    }

    private func process(_ item: PendingFrame) {
        let update = counter.update(with: item.frame)
        recordActualFrameRate()
        let countedNewRepetition = recordReportedRepetitions(update.repetitions)

        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(update, item.quality)
        }

        if countedNewRepetition {
            discardPendingFrames(olderThan: item.frame.timestamp)
        }
        processNextPendingFrame()
    }

    private func processNextPendingFrame() {
        stateLock.lock()
        guard let item = pendingFrame else {
            isProcessing = false
            stateLock.unlock()
            return
        }
        pendingFrame = nil
        stateLock.unlock()

        queue.async { [weak self] in
            self?.process(item)
        }
    }

    private func shouldAcceptFrame(timestamp: TimeInterval) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard timestamp - lastAcceptedFrameTimestamp >= minimumFrameInterval else {
            return false
        }
        lastAcceptedFrameTimestamp = timestamp
        return true
    }

    private func resetThrottle() {
        stateLock.lock()
        lastAcceptedFrameTimestamp = -.infinity
        stateLock.unlock()
    }

    private func resetActualFrameRateWindow() {
        stateLock.lock()
        actualFrameRateWindowStartTime = nil
        actualFrameRateWindowFrameCount = 0
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onActualFramesPerSecondChange?(0)
        }
    }

    private func recordActualFrameRate() {
        let now = Date().timeIntervalSince1970

        stateLock.lock()
        guard let windowStartTime = actualFrameRateWindowStartTime else {
            actualFrameRateWindowStartTime = now
            actualFrameRateWindowFrameCount = 0
            stateLock.unlock()
            return
        }

        actualFrameRateWindowFrameCount += 1
        let elapsed = now - windowStartTime
        guard elapsed >= 1 else {
            stateLock.unlock()
            return
        }

        let framesPerSecond = Double(actualFrameRateWindowFrameCount) / elapsed
        actualFrameRateWindowStartTime = now
        actualFrameRateWindowFrameCount = 0
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onActualFramesPerSecondChange?(framesPerSecond)
        }
    }

    private var minimumFrameInterval: TimeInterval {
        1 / targetFramesPerSecond
    }

    private func resetLastReportedRepetitions() {
        stateLock.lock()
        lastReportedRepetitions = 0
        stateLock.unlock()
    }

    private func recordReportedRepetitions(_ repetitions: Int) -> Bool {
        stateLock.lock()
        let countedNewRepetition = repetitions > lastReportedRepetitions
        lastReportedRepetitions = repetitions
        stateLock.unlock()
        return countedNewRepetition
    }

    private func discardPendingFrames(olderThan deadline: TimeInterval = .infinity) {
        stateLock.lock()
        if deadline == .infinity {
            pendingFrame = nil
        } else if let existing = pendingFrame, existing.frame.timestamp <= deadline {
            pendingFrame = nil
        }
        stateLock.unlock()
    }
}
