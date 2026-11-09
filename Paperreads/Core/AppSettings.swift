import Foundation
import Combine

// CONTRACT FILE. The API key is stored in a 0600 JSON file rather than the Keychain:
// the app is ad-hoc signed, and every rebuild would otherwise re-trigger keychain
// access prompts. ANTHROPIC_API_KEY in the environment takes precedence if set.

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let availableModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    @Published var apiKey: String = ""
    @Published var model: String = "claude-opus-5-5"

    private struct Stored: Codable { var apiKey: String; var model: String }
    private var url: URL { PaperStore.appSupport.appendingPathComponent("config.json") }

    private init() { load() }

    var effectiveAPIKey: String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        apiKey = s.apiKey
        if Self.availableModels.contains(s.model) { model = s.model }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(Stored(apiKey: apiKey, model: model)) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
