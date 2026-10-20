import SwiftUI

// MARK: - Detail Content

struct DetailContent: View {
    let meeting: Meeting
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: QuickViewTab = .summary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailContentHeader(meeting: meeting)

            HStack(spacing: 0) {
                if meeting.kind == .learning {
                    QuickViewTabButton(title: "Review", icon: "pencil.and.scribble", isSelected: selectedTab == .review) {
                        if selectedTab != .review {
                            tomLog("User action: switched meeting tab → Review (\(meeting.id.uuidString.prefix(8)))")
                        }
                        selectedTab = .review
                    }
                }
                QuickViewTabButton(title: "Summary", icon: "text.alignleft", isSelected: selectedTab == .summary) {
                    if selectedTab != .summary {
                        tomLog("User action: switched meeting tab → Summary (\(meeting.id.uuidString.prefix(8)))")
                    }
                    selectedTab = .summary
                }
                QuickViewTabButton(title: "Transcript", icon: "text.quote", isSelected: selectedTab == .transcript) {
                    if selectedTab != .transcript {
                        tomLog("User action: switched meeting tab → Transcript (\(meeting.id.uuidString.prefix(8)))")
                    }
                    selectedTab = .transcript
                }
                if !meeting.recordingPath.isEmpty {
                    // Audio-only recordings get a "Player" tab with a waveform
                    // icon — no video surface, no video/waveform switch.
                    QuickViewTabButton(
                        title: meeting.hasVideo ? "Video" : "Player",
                        icon: meeting.hasVideo ? "play.rectangle" : "waveform",
                        isSelected: selectedTab == .video
                    ) {
                        if selectedTab != .video {
                            tomLog("User action: switched meeting tab → \(meeting.hasVideo ? "Video" : "Player") (\(meeting.id.uuidString.prefix(8)))")
                        }
                        selectedTab = .video
                    }
                }
                Spacer()

                if selectedTab == .review {
                    ExportMenuButton(meeting: meeting, fontSize: 12)
                        .padding(.trailing, 8)
                } else if meeting.state == .completed, selectedTab != .video {
                    QuickViewExportButtons(meeting: meeting, activeTab: selectedTab)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)

            switch selectedTab {
            case .summary:    DetailSummaryContent(meeting: meeting)
            case .transcript: DetailTranscriptContent(meeting: meeting, playerManager: appState.playerManager)
            case .video:      VideoTabContent(meeting: meeting, playerManager: appState.playerManager)
            case .review:     ReviewTabContent(meeting: meeting)
            }
        }
        // A meeting that is transcribing live opens on its Transcript tab.
        .task(id: meeting.id) {
            if appState.liveTranscripts[meeting.id] != nil {
                selectedTab = .transcript
            } else if meeting.kind == .learning {
                selectedTab = .review
            } else if selectedTab == .review {
                selectedTab = .summary
            }
        }
        // A Learning session watched live switches to its Review once done.
        .onChange(of: meeting.state) { _, state in
            if meeting.kind == .learning, state == .completed { selectedTab = .review }
        }
    }
}
