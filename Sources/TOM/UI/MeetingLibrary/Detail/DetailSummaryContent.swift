import SwiftUI

// MARK: - Detail Summary Content

struct DetailSummaryContent: View {
    let meeting: Meeting

    var body: some View {
        if meeting.state == .completed, let summary = meeting.summary, !summary.isEmpty {
            MarkdownWebView(markdown: summary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 8)
        } else if meeting.state == .completed {
            Spacer()
            Text("No summary available.")
                .font(.system(size: 13))
                .foregroundColor(.subtleText)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7).progressViewStyle(.circular)
                Text("Processing...").font(.system(size: 13)).foregroundColor(.subtleText).italic()
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }
}
