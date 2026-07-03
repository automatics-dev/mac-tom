import SwiftUI

// MARK: - Recording Banner

struct RecordingBanner: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.3 : 1.0)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: pulsing
                )

            Text("Recording in progress...")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.red)

            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
        .cornerRadius(8)
        .onAppear { pulsing = true }
    }
}
