import SwiftUI

struct ResponsibleUseView: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Responsible Use")
                .font(.title)

            Divider()

            Group {
                Text("SessionCopilot is a personal productivity tool for:")
                    .fontWeight(.medium)
                Bullet("Interview practice and mock sessions")
                Bullet("Meetings where AI-assisted notes are permitted")
                Bullet("Coding practice and problem analysis")

                Text("SessionCopilot is NOT:")
                    .fontWeight(.medium)
                    .padding(.top)
                Bullet("A tool for cheating in interviews or assessments")
                Bullet("Designed to hide its presence from interviewers")
                Bullet("Endorsed by any testing or assessment platform")
            }

            Group {
                Text("Privacy")
                    .fontWeight(.medium)
                    .padding(.top)
                Bullet("Audio and text are processed using your own API keys")
                Bullet("Session data is stored locally on your device")
                Bullet("Nothing is sent to a first-party server")
                Bullet("A network indicator shows when data is in transit")
            }

            Spacer()

            HStack {
                Spacer()
                Button("I Understand") {
                    OnboardingState.hasShownResponsibleUse = true
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 450, height: 420)
    }
}

private struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top) {
            Text("•")
            Text(text)
        }
        .font(.body)
    }
}
