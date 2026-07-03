import SwiftUI

// MARK: - Player Scrubber

struct PlayerScrubber: View {
    @ObservedObject var playerManager: PlayerManager
    @Binding var isDragging: Bool
    @Binding var dragFraction: Double
    let displayFraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.06))
                Rectangle().fill(Color.accent)
                    .frame(width: geo.size.width * displayFraction)
                    .animation(isDragging ? nil : .linear(duration: 0.1), value: displayFraction)
                Circle()
                    .fill(Color.accent)
                    .frame(width: 10, height: 10)
                    .offset(x: geo.size.width * displayFraction - 5)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .animation(isDragging ? nil : .linear(duration: 0.1), value: displayFraction)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragFraction = max(0, min(1, value.location.x / geo.size.width))
                    }
                    .onEnded { value in
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        playerManager.seek(to: fraction * playerManager.duration)
                        isDragging = false
                    }
            )
        }
        .frame(height: 10)
        .padding(.top, -3)
    }
}
