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

                if meeting.state == .completed, selectedTab != .video {
                    QuickViewExportButtons(meeting: meeting, activeTab: selectedTab)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)

            switch selectedTab {
            case .summary:    DetailSummaryContent(meeting: meeting)
            case .transcript: DetailTranscriptContent(meeting: meeting, playerManager: appState.playerManager)
            case .video:      VideoTabContent(meeting: meeting, playerManager: appState.playerManager)
            }
        }
        // A meeting that is transcribing live opens on its Transcript tab.
        .task(id: meeting.id) {
            if appState.liveTranscripts[meeting.id] != nil { selectedTab = .transcript }
        }
    }
}
