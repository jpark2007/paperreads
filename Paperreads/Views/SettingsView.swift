import SwiftUI
import AppKit
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

    /// Notes folder (NotesFiles) — applied immediately, not part of Save.
    @State private var notesFolder = NotesFiles.folder
    @State private var exporting = false
    @State private var exportStatus: String?
    @State private var exportFailed = false

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

            section("Notes folder") {
                Text(NotesFiles.displayPath(notesFolder))
                    .font(.rounded(14))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("Each paper's notes and highlights are kept as a Markdown file here. Edits you make to the Notes section of a file are pulled back in when you next open that paper's notes. Deleting a paper never deletes its file.")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.m) {
                    Button("Reveal in Finder", action: revealNotesFolder)
                        .buttonStyle(.text)
                    Button("Change…", action: chooseNotesFolder)
                        .buttonStyle(.text)
                    if notesFolder.standardizedFileURL.path != NotesFiles.defaultFolder.standardizedFileURL.path {
                        Button("Use default") { setNotesFolder(nil) }
                            .buttonStyle(.text)
                    }
                    Button(exporting ? "Exporting…" : "Export all now", action: exportAll)
                        .buttonStyle(.text)
                        .disabled(exporting)
                    Spacer(minLength: 0)
                }
                .padding(.top, Theme.Space.xxs)
                if let exportStatus {
                    Text(exportStatus)
                        .font(.rounded(12))
                        .foregroundStyle(exportFailed ? Theme.danger : Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
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
            notesFolder = NotesFiles.folder
        }
    }

    // MARK: Notes folder

    private func revealNotesFolder() {
        let folder = NotesFiles.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            exportFailed = true
            exportStatus = "Couldn't create \(NotesFiles.displayPath(folder)): \(error.localizedDescription)"
        }
    }

    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where Paperreads keeps your notes as Markdown files."
        let current = NotesFiles.folder
        panel.directoryURL = FileManager.default.fileExists(atPath: current.path)
            ? current : current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setNotesFolder(url)
    }

    private func setNotesFolder(_ url: URL?) {
        NotesFiles.setFolder(url)
        notesFolder = NotesFiles.folder
        exportStatus = nil
        exportFailed = false
        // Populate the new folder right away (existing files elsewhere are left untouched).
        exportAll()
    }

    private func exportAll() {
        guard !exporting else { return }
        exporting = true
        exportStatus = nil
        exportFailed = false
        let snapshots = NotesFiles.allSnapshots()
        Task { @MainActor in
            let result = await NotesFiles.exportAll(snapshots)
            exporting = false
            if result.failures.isEmpty {
                exportStatus = result.count == 1 ? "1 notes file is up to date." : "\(result.count) notes files are up to date."
                exportFailed = false
            } else {
                exportFailed = true
                let first = result.failures.prefix(3).joined(separator: "\n")
                let more = result.failures.count > 3 ? "\n…and \(result.failures.count - 3) more." : ""
                exportStatus = "\(result.failures.count) of \(result.count + result.failures.count) files couldn't be written.\n\(first)\(more)"
            }
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
