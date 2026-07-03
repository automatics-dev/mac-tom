import SwiftUI

// MARK: - Tab Enum

enum DetailTab {
    case summary, transcript
}

// MARK: - Tab Button

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? .primary : .subtleText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.cardSelected : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - State Pill

struct StatePill: View {
    let state: MeetingState
    private var color: Color {
        switch state {
        case .recording: .red; case .transcribing: .yellow; case .processing: .orange
        case .completed: .accent; case .failed: .red
        }
    }
    private var label: String {
        switch state {
        case .recording: "Recording"; case .transcribing: "Transcribing"; case .processing: "Processing"
        case .completed: "Completed"; case .failed: "Failed"
        }
    }
    var body: some View {
        Text(label).font(.system(size: 9, weight: .semibold)).textCase(.uppercase).tracking(0.3)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.15)).foregroundColor(color).clipShape(Capsule())
    }
}
