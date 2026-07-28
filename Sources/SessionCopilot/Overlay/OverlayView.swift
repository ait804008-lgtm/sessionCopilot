import SwiftUI

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    var onClose: (() -> Void)?
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            Divider()

            // Chat area
            chatList
        }
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding(8)
        // Error banner overlays at the bottom
        .overlay(alignment: .bottom) {
            errorBanner
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            // Live indicator with state feedback
            liveIndicator

            // Network indicator
            if viewModel.isStreaming {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .opacity(0.8)
                    .scaleEffect(pulsing ? 1.0 : 0.8)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
                    .onDisappear { pulsing = false }
                    .accessibilityLabel("Streaming")
            }

            // Mode picker
            Picker("Mode", selection: Binding(
                get: { viewModel.sessionMode },
                set: { viewModel.sessionMode = $0; viewModel.onChanged() }
            )) {
                ForEach(SessionMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
            .controlSize(.small)

            Spacer()

            // Opacity slider
            Slider(value: Binding(
                get: { viewModel.opacity },
                set: { viewModel.opacity = $0 }
            ), in: 0.1...1.0)
            .frame(width: 80)

            // Click-through toggle
            Button(action: {
                viewModel.clickThrough.toggle()
                viewModel.onChanged()
            }) {
                Image(systemName: viewModel.clickThrough ? "cursorarrow.slash" : "cursorarrow")
            }
            .buttonStyle(.borderless)
            .help("Click-through mode")

            // Close button
            Button(action: {
                viewModel.hide()
                onClose?()
            }) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Live Indicator

    @ViewBuilder
    private var liveIndicator: some View {
        if !viewModel.isLive {
            Text("SessionCopilot")
                .font(.headline)
                .foregroundColor(.primary)
        } else if viewModel.hasError {
            Text("● Error")
                .font(.headline)
                .foregroundColor(.red)
        } else if viewModel.isStreaming {
            Text("● Answering")
                .font(.headline)
                .foregroundColor(.orange)
        } else if viewModel.isDetectingSpeech {
            Text("● Listening")
                .font(.headline)
                .foregroundColor(.orange)
        } else {
            Text("● Live")
                .font(.headline)
                .foregroundColor(.green)
        }
    }

    // MARK: - Chat

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.chatMessages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: viewModel.chatMessages.count) { _, _ in
                if let last = viewModel.chatMessages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.chatMessages.last?.text) { _, _ in
                if let last = viewModel.chatMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Error Banner

    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                Button("Dismiss") {
                    viewModel.clearError()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(8)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(8)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Assistant Text (cached markdown)

/// Wraps an assistant message and caches the AttributedString parse.
/// Without this, streaming re-parses the full accumulated text on every token.
struct AssistantText: View {
    let text: String

    var body: some View {
        Text(attributed)
            .font(.body)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if message.role == .assistant {
                // AI avatar
                avatarView
                bubbleContent
                Spacer(minLength: 24)
            } else {
                Spacer(minLength: 24)
                bubbleContent
                avatarView
            }
        }
    }

    private var avatarView: some View {
        Group {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor))
            } else {
                Image(systemName: "person.fill")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.blue))
            }
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 2) {
            Text(roleLabel)
                .font(.caption2)
                .foregroundColor(.secondary)

            if message.role == .assistant {
                AssistantText(text: message.text)
            } else {
                Text(message.text)
                    .font(.body)
                    .italic(message.isInterim)
            }

            if message.isStreaming {
                HStack {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(height: 8)
                    Text("Generating...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(message.role == .assistant
                    ? Color.accentColor.opacity(0.1)
                    : Color.blue.opacity(0.08))
        )
    }

    private var roleLabel: String {
        message.role == .assistant ? "SessionCopilot" : "You"
    }
}
