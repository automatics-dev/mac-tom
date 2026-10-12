import SwiftUI

// MARK: - Live Transcription Preview

/// Streaming transcript preview shown while a meeting's primary audio stream
/// is being transcribed. Fed by `AppState.liveTranscripts` — each utterance
/// the decoder discovers appends a line, so the user sees text flowing in
/// instead of an opaque "Processing…" spinner. Replaced by the real utterance
/// list the moment the pipeline saves the final segments.
struct LiveTranscriptionView: View {
    let text: String
    /// Words heard but not yet committed (Parakeet rolling preview). Shown
    /// dimmer after the committed text and rewritten as recognition settles.
    var volatile: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .progressViewStyle(.circular)
                Text("Live transcript")
                    .font(.system(size: 13))
                    .foregroundColor(.subtleText)
                    .italic()
            }

            if text.isEmpty && volatile.isEmpty {
                // Entry registered but no words yet: either the model is
                // still loading (first run after an update recompiles the
                // CoreML graph — minutes, not seconds) or the first chunk
                // hasn't been decoded yet.
                Text("Warming up the transcription model — first words will appear shortly. The first run after an update can take a few minutes.")
                    .font(.system(size: 13))
                    .foregroundColor(.subtleText)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                (Text(text).foregroundStyle(Color.dimText)
                    + Text(volatileSuffix).foregroundStyle(Color.subtleText))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var volatileSuffix: String {
        guard !volatile.isEmpty else { return "" }
        return text.isEmpty ? volatile : "\n" + volatile
    }
}
