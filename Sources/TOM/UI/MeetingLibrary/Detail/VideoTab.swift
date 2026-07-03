import SwiftUI

// MARK: - Video Tab

struct VideoTabContent: View {
    let meeting: Meeting
    @ObservedObject var playerManager: PlayerManager

    @State private var showPlaybackIcon = false
    @State private var iconOpacity: Double = 0
    @State private var wasPlaying = false

    private var currentSegment: TranscriptSegment? {
        let idx = playerManager.currentSegmentIndex
        guard idx >= 0, idx < playerManager.segments.count else { return nil }
        return playerManager.segments[idx]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black

                if playerManager.showVideo {
                    PlayerVideoView(playerManager: playerManager)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .font(.system(size: 48, weight: .ultraLight))
                            .foregroundColor(.accent.opacity(0.4))
                        Text("Audio Only")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.45))
                    }
                }

                // Play/pause icon flash
                if showPlaybackIcon {
                    Image(systemName: wasPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                        .padding(20)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                        .opacity(iconOpacity)
                }

                // Karaoke subtitle overlay
                if let segment = currentSegment {
                    VStack {
                        Spacer()
                        karaokeText(segment: segment, currentTime: playerManager.currentTime)
                            .font(.system(size: 17, weight: .medium))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(.bottom, 48)
                            .padding(.horizontal, 24)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                wasPlaying = playerManager.isPlaying
                playerManager.togglePlayPause()
                showPlaybackIcon = true
                iconOpacity = 1
                withAnimation(.easeOut(duration: 0.6).delay(0.3)) {
                    iconOpacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    showPlaybackIcon = false
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DetailPlayerBar(meeting: meeting, playerManager: playerManager)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Cap on words rendered at once. Two-line overlay with size-17 medium
    /// at typical 720p+ video widths fits roughly this many comfortably —
    /// beyond it, `lineLimit(2)` truncates and the karaoke highlight runs
    /// off-screen as the segment plays. Pin to a rolling window centred
    /// near the active word so the spoken portion always stays visible.
    private static let karaokeWindow = 14

    /// Linearly interpolates the current word position from the segment's
    /// start/end timestamps (Whisper's utterance grouping loses per-word
    /// timing; this is the best estimate we have without re-running
    /// transcription with `wordTimestamps: true`). Returns a `Text` of at
    /// most `karaokeWindow` words sliding forward as playback progresses,
    /// with already-spoken words tinted accent and the rest white.
    private func karaokeText(segment: TranscriptSegment, currentTime: TimeInterval) -> Text {
        let words = segment.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else { return Text("") }

        let duration = segment.endTime - segment.startTime
        let progress: Double
        if duration > 0 {
            progress = max(0, min(1, (currentTime - segment.startTime) / duration))
        } else {
            progress = 0
        }
        let spokenCount = Int(progress * Double(words.count))

        // Rolling window: anchor the active word near the leading edge so the
        // viewer sees what's about to be said, not what was just said. Clamp
        // at the segment boundaries.
        let windowSize = min(Self.karaokeWindow, words.count)
        let lead = max(2, windowSize / 3)             // active word lands ~1/3 into the window
        let desiredStart = spokenCount - lead
        let windowStart = max(0, min(words.count - windowSize, desiredStart))
        let windowEnd = windowStart + windowSize

        var result = Text("")
        for idx in windowStart..<windowEnd {
            let word = words[idx]
            let spaced = idx == windowStart ? word : " " + word
            let colored = idx < spokenCount
                ? Text(spaced).foregroundColor(.accent)
                : Text(spaced).foregroundColor(.white)
            result = result + colored
        }
        return result
    }
}
