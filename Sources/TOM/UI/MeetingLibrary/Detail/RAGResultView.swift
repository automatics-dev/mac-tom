import SwiftUI

// MARK: - RAG Result View

struct RAGResultView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(.accent)

                Text(appState.ragQuery)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                Spacer()

                Button {
                    appState.ragQuery = ""
                    appState.ragAnswer = ""
                    appState.ragSources = []
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundColor(.subtleText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider().background(Color.divider)
                .padding(.horizontal, 24)

            if appState.ragIsLoading {
                ThinkingIndicator(stage: appState.ragStage)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        MarkdownWebView(markdown: appState.ragAnswer)
                            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)

                        if !appState.ragSources.isEmpty {
                            Divider().background(Color.divider)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Sources")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.subtleText)
                                    .textCase(.uppercase)

                                ForEach(Array(appState.ragSources.enumerated()), id: \.offset) { _, source in
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 10))
                                            .foregroundColor(.accent)
                                        Text("\(source.meetingTitle) — \(source.meetingDate)")
                                            .font(.system(size: 12))
                                            .foregroundColor(.dimText)
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

// MARK: - Thinking Indicator

/// Two-icon (search + brain) "TOM is thinking" indicator that pulses the
/// active stage. Replaces the previous one-spinner loading view to set the
/// right expectation: AI cold-loads take seconds, this is "Ask TOM,"
/// not "instant search." The Ask input is already labelled "Ask across
/// meetings…" and the input action says "ask," so framing the loading state
/// as thinking is consistent throughout.
private struct ThinkingIndicator: View {
    let stage: RAGStage

    private var statusText: String {
        switch stage {
        case .idle: return ""
        case .searching: return "Looking across your meetings…"
        case .synthesizing: return "Reading and writing the answer…"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            HStack(spacing: 28) {
                ThinkingStageIcon(systemName: "magnifyingglass", active: stage == .searching)
                ThinkingStageIcon(systemName: "brain", active: stage == .synthesizing)
            }
            Text(statusText)
                .font(.system(size: 13))
                .foregroundColor(.subtleText)
                .animation(.easeInOut(duration: 0.2), value: stage)
            if stage == .synthesizing {
                Text("First question after a quiet stretch loads the model — takes about 10 seconds. Subsequent questions are fast.")
                    .font(.system(size: 11))
                    .foregroundColor(.subtleText.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }
}

private struct ThinkingStageIcon: View {
    let systemName: String
    let active: Bool

    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accent.opacity(active ? 0.18 : 0.06))
                .frame(width: 56, height: 56)
                .scaleEffect(active && pulse ? 1.15 : 1.0)
                .animation(
                    active
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .easeInOut(duration: 0.2),
                    value: pulse
                )
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(active ? .accent : .accent.opacity(0.35))
        }
        .onAppear { pulse = active }
        .onChange(of: active) { _, newValue in
            pulse = newValue
        }
    }
}
