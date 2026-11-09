import SwiftUI
import NaturalLanguage

/// ⌘, — API key, model, embedding status. Persisted via `AppSettings.save()` (0600 file,
/// never the Keychain).
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var saved = false
    @FocusState private var keyFocused: Bool

    private var envKeyActive: Bool {
        guard let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else { return false }
        return !env.isEmpty
    }

    /// Loaded once (the model is cached by Embedder), not on every body evaluation.
    @State private var embeddingsAvailable = Embedder.isAvailable

    private var isDirty: Bool {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) != settings.apiKey || modelDraft != settings.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            Text("Settings")
                .font(.serif(26, weight: .semibold))
                .foregroundStyle(Theme.ink)

            section("Anthropic API key") {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("sk-ant-…", text: $keyDraft)
                        .textFieldStyle(.plain)
                        .font(.rounded(15))
                        .foregroundStyle(Theme.ink)
                        .focused($keyFocused)
                        .onSubmit(save)
                    Rectangle()
                        .fill(keyFocused ? Theme.accent : Theme.hairline)
                        .frame(height: keyFocused ? 1.5 : 1)
                }
                Text(envKeyActive
                     ? "ANTHROPIC_API_KEY is set in the environment and takes precedence over this key."
                     : "Stored in a private file in Application Support, readable only by your user account.")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Model") {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(AppSettings.availableModels, id: \.self) { id in
                        let selected = modelDraft == id
                        Button {
                            modelDraft = id
                        } label: {
                            HStack(spacing: Theme.Space.s) {
                                Text(Theme.modelDisplayName(id))
                                    .font(.rounded(14, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Theme.ink : Theme.muted)
                                Text(id)
                                    .font(.rounded(12))
                                    .foregroundStyle(Theme.faint)
                                Spacer(minLength: 0)
                                if selected {
                                    Text("Selected").capsLabel(Theme.ink)
                                }
                            }
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            section("Embeddings") {
                Text(embeddingsAvailable
                     ? "On-device sentence embeddings are available. Cited works are searched by meaning and keywords."
                     : "On-device embeddings aren't available on this Mac. Cited works are searched by keywords only.")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Space.m) {
                Spacer()
                if saved && !isDirty {
                    Text("Saved").font(.rounded(13, weight: .medium)).foregroundStyle(Theme.muted)
                }
                Button("Save", action: save)
                    .buttonStyle(.pill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 560)
        .background(Theme.bg)
        .onAppear {
            settings.load()
            keyDraft = settings.apiKey
            modelDraft = settings.model
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).capsLabel()
            content()
        }
    }

    private func save() {
        settings.apiKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if AppSettings.availableModels.contains(modelDraft) { settings.model = modelDraft }
        settings.save()
        keyDraft = settings.apiKey
        saved = true
    }
}
