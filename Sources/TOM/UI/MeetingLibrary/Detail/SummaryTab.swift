import SwiftUI

// MARK: - Summary Tab

struct SummaryTabContent: View {
    let meeting: Meeting
    @EnvironmentObject var appState: AppState

    /// Latest meeting state from AppState — speaker renames update aliases on
    /// the live meeting and we want them to flow into the summary immediately
    /// without the parent re-creating us.
    private var liveMeeting: Meeting {
        appState.meetings.first(where: { $0.id == meeting.id }) ?? meeting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if liveMeeting.state == .completed,
               let summary = liveMeeting.aliasedSummary, !summary.isEmpty {
                SummaryContent(text: summary)
            } else if liveMeeting.state == .completed {
                Text("No summary available.")
                    .font(.system(size: 14))
                    .foregroundColor(.subtleText)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .progressViewStyle(.circular)
                    Text("Processing...")
                        .font(.system(size: 14))
                        .foregroundColor(.subtleText)
                        .italic()
                }
            }

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
    }
}

struct SummaryContent: View {
    let text: String

    var body: some View {
        MarkdownWebView(markdown: text)
            .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    }
}
