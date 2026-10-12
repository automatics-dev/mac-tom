import SwiftUI

// MARK: - Detail Player Bar (full-width, dark)

struct DetailPlayerBar: View {
    let meeting: Meeting
    @ObservedObject var playerManager: PlayerManager
    @State private var isDragging = false
    @State private var dragFraction: Double = 0

    private var progressFraction: Double {
        guard playerManager.duration > 0 else { return 0 }
        return playerManager.currentTime / playerManager.duration
    }

    private var displayFraction: Double {
        isDragging ? dragFraction : progressFraction
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerScrubber(
                playerManager: playerManager,
                isDragging: $isDragging,
                dragFraction: $dragFraction,
                displayFraction: displayFraction
            )

            HStack(spacing: 16) {
                // Left: track info
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.accent.opacity(0.2))
                        .frame(width: 38, height: 38)
                        .overlay(
                            Text(String(meeting.title.prefix(1)).uppercased())
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.accent)
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(meeting.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(shortDateFormatter.string(from: meeting.date))
                            .font(.system(size: 10))
                            .foregroundColor(.subtleText)
                    }
                }
                .frame(minWidth: 180, alignment: .leading)

                Spacer()

                // Center: playback controls
                HStack(spacing: 18) {
                    Button { playerManager.skipBackward() } label: {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 15))
                            .foregroundColor(.dimText)
                    }
                    .buttonStyle(.plain)

                    Button { playerManager.togglePlayPause() } label: {
                        Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)

                    Button { playerManager.skipForward() } label: {
                        Image(systemName: "goforward.15")
                            .font(.system(size: 15))
                            .foregroundColor(.dimText)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Right: time + volume + video toggle
                HStack(spacing: 10) {
                    Text(formatTimestamp(playerManager.currentTime))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.subtleText)
                        .frame(width: 46, alignment: .trailing)

                    Text("/")
                        .font(.system(size: 10))
                        .foregroundColor(.subtleText)

                    Text(formatTimestamp(playerManager.duration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.subtleText)
                        .frame(width: 46, alignment: .leading)

                    HStack(spacing: 4) {
                        Image(systemName: playerManager.volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.subtleText)

                        Slider(value: $playerManager.volume, in: 0...1)
                            .frame(width: 70)
                            .tint(.accent)
                    }

                    // Video/waveform switch only makes sense when the file
                    // actually has a video track — audio-only recordings
                    // (voice notes, audio imports) hide it.
                    if meeting.hasVideo {
                        Button { playerManager.toggleVideoMode() } label: {
                            Image(systemName: playerManager.showVideo ? "video.fill" : "waveform")
                                .font(.system(size: 11))
                                .foregroundColor(.subtleText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(height: 68)
        .background(Color.cardBg)
    }
}
