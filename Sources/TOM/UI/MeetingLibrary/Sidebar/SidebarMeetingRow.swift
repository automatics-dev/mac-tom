import SwiftUI

// MARK: - Sidebar Meeting Row

struct SidebarMeetingRow: View {
    let meeting: Meeting
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accent.opacity(0.15))
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: meeting.kind.icon)
                        .font(.system(size: 11))
                        .foregroundColor(.accent)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .accent : .primary)
                    .lineLimit(1)

                Text("Default")
                    .font(.system(size: 10))
                    .foregroundColor(.subtleText)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.cardSelected : Color.clear)
                .padding(.horizontal, 8)
        )
    }
}

