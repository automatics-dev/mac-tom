import SwiftUI

// MARK: - Empty Detail Placeholder

struct EmptyDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundColor(.subtleText)

            Text("Select a meeting to begin")
                .font(.system(size: 15))
                .foregroundColor(.subtleText)
        }
    }
}

// MARK: - Detail Section

struct DetailSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.subtleText)
            }

            content
        }
    }
}
