import Foundation

nonisolated final class LiveRepetitionCounterBridge: @unchecked Sendable {
    var onUpdate: ((CountUpdate, PoseQuality) -> Void)?

    private struct PendingFrame {
        var frame: PoseFrame
        var quality: PoseQuality
    }

    private let queue = DispatchQueue(label: "com.visionrep.repetition.counter", qos: .userInitiated)
    private let stateLock = NSLock()
    private let counter = FewShotRepetitionCounter()
    private let maxPendingFrameCount = 3
    private var isProcessing = false
    private var lastReportedRepetitions = 0
    private var pendingFrames: [PendingFrame] = []

    func load(templates: [MovementTemplate]) {
        discardPendingFrames()
        queue.async { [weak self] in
            self?.lastReportedRepetitions = 0
            self?.counter.load(templates: templates)
        }
    }

    func resetCount() {
        discardPendingFrames()
        queue.async { [weak self] in
            self?.lastReportedRepetitions = 0
            self?.counter.resetCount()
        }
    }

    func clearOnlineTemplates() {
        discardPendingFrames()
        queue.async { [weak self] in
            self?.counter.clearOnlineTemplates()
        }
    }

    func submit(_ frame: PoseFrame, quality: PoseQuality) {
        let item = PendingFrame(frame: frame, quality: quality)

        stateLock.lock()
        if isProcessing {
            pendingFrames.append(item)
            while pendingFrames.count > maxPendingFrameCount {
                pendingFrames.removeFirst()
            }
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
        let countedNewRepetition = update.repetitions > lastReportedRepetitions
        lastReportedRepetitions = update.repetitions

        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(update, item.quality)
        }

        if countedNewRepetition {
            discardPendingFrames()
        }
        processNextPendingFrame()
    }

    private func processNextPendingFrame() {
        stateLock.lock()
        guard !pendingFrames.isEmpty else {
            isProcessing = false
            stateLock.unlock()
            return
        }
        let item = pendingFrames.removeFirst()
        stateLock.unlock()

        queue.async { [weak self] in
            self?.process(item)
        }
    }

    private func discardPendingFrames() {
        stateLock.lock()
        pendingFrames.removeAll(keepingCapacity: true)
        stateLock.unlock()
    }
}
