import SwiftUI

// MARK: - Detail Content Header

struct DetailContentHeader: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(.primary)

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
