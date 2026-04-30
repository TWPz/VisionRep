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
    private var isProcessing = false
    private var pendingFrame: PendingFrame?

    func load(templates: [MovementTemplate]) {
        discardPendingFrame()
        queue.async { [weak self] in
            self?.counter.load(templates: templates)
        }
    }

    func resetCount() {
        discardPendingFrame()
        queue.async { [weak self] in
            self?.counter.resetCount()
        }
    }

    func clearOnlineTemplates() {
        discardPendingFrame()
        queue.async { [weak self] in
            self?.counter.clearOnlineTemplates()
        }
    }

    func submit(_ frame: PoseFrame, quality: PoseQuality) {
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

        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(update, item.quality)
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

    private func discardPendingFrame() {
        stateLock.lock()
        pendingFrame = nil
        stateLock.unlock()
    }
}
