import Foundation

nonisolated final class LiveRepetitionCounterBridge: @unchecked Sendable {
    var onUpdate: ((CountUpdate, PoseQuality) -> Void)?

    private let queue = DispatchQueue(label: "com.visionrep.repetition.counter", qos: .userInitiated)
    private let counter = FewShotRepetitionCounter()

    func load(templates: [MovementTemplate]) {
        queue.async { [weak self] in
            self?.counter.load(templates: templates)
        }
    }

    func resetCount() {
        queue.async { [weak self] in
            self?.counter.resetCount()
        }
    }

    func clearOnlineTemplates() {
        queue.async { [weak self] in
            self?.counter.clearOnlineTemplates()
        }
    }

    func submit(_ frame: PoseFrame, quality: PoseQuality) {
        queue.async { [weak self] in
            guard let self else { return }
            let update = self.counter.update(with: frame)
            DispatchQueue.main.async { [weak self] in
                self?.onUpdate?(update, quality)
            }
        }
    }
}
