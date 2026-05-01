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
        resetLastReportedRepetitions()
        queue.async { [weak self] in
            guard let self else { return }
            self.counter.load(templates: templates)
            self.resetLastReportedRepetitions()
        }
    }

    func resetCount() {
        discardPendingFrames()
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
            pendingFrames.removeAll(keepingCapacity: true)
        } else {
            pendingFrames.removeAll { $0.frame.timestamp <= deadline }
        }
        stateLock.unlock()
    }
}
