import Foundation

nonisolated final class ExerciseProfileStore: @unchecked Sendable {
    private let fileName = "movement-templates.json"

    func loadTemplates() -> [MovementTemplate] {
        let url = templatesURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([MovementTemplate].self, from: data)
        } catch {
            return []
        }
    }

    func save(_ templates: [MovementTemplate]) -> Bool {
        do {
            let url = templatesURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(templates)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }

    func deleteTemplates() {
        let url = templatesURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func templatesURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "MPiPE", directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }
}
