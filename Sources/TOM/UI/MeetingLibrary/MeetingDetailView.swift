import SwiftUI

// MARK: - Meeting Detail View (Notion-style: Video → Title → Tabs)

struct MeetingDetailView: View {
    let meeting: Meeting
    @ObservedObject var playerManager: PlayerManager
    @State private var selectedTab: DetailTab = .summary

    var body: some View {
        VStack(spacing: 0) {
            // Video / Audio player area
            if !meeting.recordingPath.isEmpty {
                ZStack {
                    if playerManager.showVideo {
                        PlayerVideoView(playerManager: playerManager)
                    } else {
                        Color.black
                        VStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.system(size: 48, weight: .ultraLight))
                                .foregroundColor(.accent.opacity(0.4))
                            Text("Audio Only")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(Color.black)
            }

            // Content area
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Title + date header
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meeting.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)

                        HStack(spacing: 12) {
                            Text(shortDateFormatter.string(from: meeting.date))
                                .font(.system(size: 13))
                                .foregroundColor(.subtleText)

                            if meeting.duration > 0 {
                                Text(formatDuration(meeting.duration))
                                    .font(.system(size: 13))
                                    .foregroundColor(.subtleText)
                            }

                            if meeting.state != .completed {
                                StatePill(state: meeting.state)
                            }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    // Tab bar + export buttons
                    HStack(spacing: 0) {
                        if meeting.kind == .learning {
                            TabButton(
                                title: "Review",
                                icon: "pencil.and.scribble",
                                isSelected: selectedTab == .review
                            ) { selectedTab = .review }
                        }

                        TabButton(
                            title: "Summary",
                            icon: "text.alignleft",
                            isSelected: selectedTab == .summary
                        ) { selectedTab = .summary }

                        TabButton(
                            title: "Transcript",
                            icon: "text.quote",
                            isSelected: selectedTab == .transcript
                        ) { selectedTab = .transcript }

                        Spacer()

                        if selectedTab == .review {
                            ExportMenuButton(meeting: meeting, fontSize: 11)
                        } else if meeting.state == .completed {
                            ExportButtons(meeting: meeting, activeTab: selectedTab)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 4)

                    Divider().background(Color.divider)
                        .padding(.horizontal, 32)

                    // Tab content
                    switch selectedTab {
                    case .summary:
                        SummaryTabContent(meeting: meeting)
                    case .transcript:
                        TranscriptTabContent(meeting: meeting, playerManager: playerManager)
                    case .review:
                        ReviewTabContent(meeting: meeting, scrolls: false)
                    }
                }
            }

            // Player bar
            if !meeting.recordingPath.isEmpty {
                DetailPlayerBar(meeting: meeting, playerManager: playerManager)
            }
        }
        .frame(minWidth: 700, minHeight: 550)
        .background(Color.contentBg)
        .task(id: meeting.id) {
            if meeting.kind == .learning { selectedTab = .review }
        }
    }
}
