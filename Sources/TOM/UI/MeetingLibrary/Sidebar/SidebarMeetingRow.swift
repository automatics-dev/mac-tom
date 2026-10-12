import SwiftUI

// MARK: - Sidebar Meeting Row

struct SidebarMeetingRow: View {
    let meeting: Meeting
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accent.opacity(0.15))
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: meeting.kind.icon)
                        .font(.system(size: 11))
                        .foregroundColor(.accent)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 12.5))
                    .foregroundColor(isSelected ? .accent : .primary)
                    .lineLimit(1)

                Text("Default")
                    .font(.system(size: 10.5))
                    .foregroundColor(.subtleText)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accent.opacity(0.12) : Color.clear)
                .padding(.horizontal, 8)
        )
    }
}

