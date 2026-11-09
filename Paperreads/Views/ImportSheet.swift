import SwiftUI
import AppKit
import SwiftData
import UniformTypeIdentifiers

/// ⌘L: import by arXiv id / URL or DOI; also offers "Choose PDF…".
struct ImportSheet: View {
    @EnvironmentObject private var app: AppCommands
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var error: String?
    @State private var choosingFile = false
    @FocusState private var focused: Bool

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Add a paper")
                    .font(.serif(26, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Paste an arXiv id or link, or a DOI. arXiv papers open as clean text with real equations; other PDFs are converted by Claude.")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("2401.12345  ·  arxiv.org/abs/…  ·  10.1145/…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.rounded(16))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit(submit)
                    .onChange(of: input) { error = nil }
                Rectangle()
                    .fill(focused ? Theme.accent : Theme.hairline)
                    .frame(height: focused ? 1.5 : 1)
                if let error {
                    Text(error)
                        .font(.rounded(13))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Space.xxs)
                }
            }

            HStack(spacing: Theme.Space.m) {
                Button("Choose PDF…") { choosingFile = true }
                    .buttonStyle(.text)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.text)
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: submit)
                    .buttonStyle(.pill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 540)
        .background(Theme.bg)
        .onAppear {
            // No clipboard prefill: reading the general pasteboard without a user paste action
            // pulls whatever was copied (often a password) into the app and can trigger the
            // system paste-permission alert on every open. Cmd-V in the field still works.
            focused = true
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                app.importPDFs(urls, context: context)
                dismiss()
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= 2048 else {
            error = "That's too long to be a link or identifier."
            return
        }
        do {
            try app.importLink(trimmed, context: context)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't recognise that. Try an arXiv id (2401.12345), an arxiv.org link, or a DOI (10.xxxx/…)."
        }
    }
}
