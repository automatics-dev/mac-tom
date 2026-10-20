import SwiftUI

// MARK: - Detail Content Header

struct DetailContentHeader: View {
    let meeting: Meeting

    @EnvironmentObject private var appState: AppState
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                MeetingTitleField(title: meeting.title, fontSize: 18) { newTitle in
                    if let newTitle { appState.renameMeeting(id: meeting.id, title: newTitle) }
                    isEditing = false
                }
            } else {
                Text(meeting.title)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(.primary)
                    .onTapGesture(count: 2) { isEditing = true }
                    .help("Double-click to rename")
            }

            HStack(spacing: 12) {
                Text(shortDateFormatter.string(from: meeting.date))
                    .font(.system(size: 12))
                    .foregroundColor(.subtleText)

                if meeting.duration > 0 {
                    Text(formatDuration(meeting.duration))
                        .font(.system(size: 12))
                        .foregroundColor(.subtleText)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }
}
