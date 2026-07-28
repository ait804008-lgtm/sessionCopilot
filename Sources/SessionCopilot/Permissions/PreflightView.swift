import SwiftUI

struct PreflightView: View {
    @ObservedObject var viewModel: PreflightViewModel
    var onGoLive: () -> Void
    @State private var showCreateProfile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // MARK: - Profile Selection

            Text("Profile")
                .font(.headline)

            HStack {
                Picker("Select Profile", selection: $viewModel.selectedProfileId) {
                    Text("— None —").tag(UUID?.none)
                    ForEach(viewModel.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)

                Button("New…") {
                    showCreateProfile = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let p = viewModel.selectedProfile {
                Text(p.resumeText.prefix(80) + (p.resumeText.count > 80 ? "…" : ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            } else {
                Text("No profile selected — suggestions will be generic.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // MARK: - Permissions

            Text("Permissions Check")
                .font(.headline)

            Text("Grant these permissions before starting a session.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(viewModel.permissions) { permission in
                PermissionRow(permission: permission) {
                    viewModel.openSettings(for: permission.kind)
                } onRequest: {
                    Task { await viewModel.request(permission.kind) }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Go Live") {
                    onGoLive()
                }
                .disabled(!viewModel.allGranted)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(16)
        .sheet(isPresented: $showCreateProfile) {
            ProfileEditView { name, resumeText, jd in
                viewModel.addProfile(name: name, resumeText: resumeText, jd: jd)
            }
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let permission: PermissionStatus
    var onOpenSettings: () -> Void
    var onRequest: () -> Void

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading) {
                Text(permission.kind.label)
                    .font(.body)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }

            Spacer()

            if permission.state == .granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Grant") {
                    if permission.state == .notDetermined {
                        onRequest()
                    } else {
                        onOpenSettings()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch permission.kind {
        case .microphone: return "mic.fill"
        case .screenRecording: return "rectangle.on.rectangle.fill"
        case .accessibility: return "hand.raised.fill"
        case .speechRecognition: return "waveform.circle.fill"
        }
    }

    private var iconColor: Color {
        permission.isGranted ? .green : .orange
    }

    private var statusText: String {
        switch permission.state {
        case .granted: return "Granted"
        case .denied: return "Denied — open System Settings"
        case .notDetermined: return "Not yet granted"
        }
    }

    private var statusColor: Color {
        switch permission.state {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .secondary
        }
    }
}
