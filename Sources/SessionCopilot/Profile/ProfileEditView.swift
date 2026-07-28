import SwiftUI
import UniformTypeIdentifiers
import PDFKit

/// Sheet view for creating or editing a Profile.
/// Allows pasting resume text, importing from file (PDF/TXT/MD), and entering a JD.
struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var resumeText: String = ""
    @State private var jd: String = ""
    @State private var showImportError = false
    @State private var importError = ""
    @FocusState private var nameFieldFocused: Bool

    let profile: Profile?
    var onSave: (String, String, String?) -> Void

    init(profile: Profile? = nil, onSave: @escaping (String, String, String?) -> Void) {
        self.profile = profile
        self.onSave = onSave
        if let p = profile {
            _name = State(initialValue: p.name)
            _resumeText = State(initialValue: p.resumeText)
            _jd = State(initialValue: p.defaultJD ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile == nil ? "Create Profile" : "Edit Profile")
                .font(.headline)

            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundColor(.secondary)
                TextField("Your Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFieldFocused)
                    .onAppear {
                        // macOS sheets don't auto-focus text fields
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            nameFieldFocused = true
                        }
                    }
            }

            // Resume
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Resume / Background").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Import…") { showFilePicker() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                TextEditor(text: $resumeText)
                    .font(.body)
                    .frame(minHeight: 120)
                    .border(Color.secondary.opacity(0.3))
            }

            // Job Description
            VStack(alignment: .leading, spacing: 4) {
                Text("Job Description (optional)").font(.caption).foregroundColor(.secondary)
                TextEditor(text: $jd)
                    .font(.body)
                    .frame(minHeight: 60)
                    .border(Color.secondary.opacity(0.3))
            }

            if showImportError {
                Text(importError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let jdText = jd.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(name, resumeText, jdText.isEmpty ? nil : jdText)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 480)
    }

    // MARK: - File Import

    private func showFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.pdf,
            UTType.plainText,
            UTType.text
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let text: String
                if url.pathExtension.lowercased() == "pdf" {
                    text = try extractPDFText(from: url)
                } else {
                    text = try String(contentsOf: url, encoding: .utf8)
                }
                resumeText = text
                showImportError = false
            } catch {
                importError = "Failed to import: \(error.localizedDescription)"
                showImportError = true
            }
        }
    }

    private func extractPDFText(from url: URL) throws -> String {
        guard let pdf = PDFDocument(url: url) else {
            throw ProfileError.pdfReadFailed
        }
        return (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
    }
}
