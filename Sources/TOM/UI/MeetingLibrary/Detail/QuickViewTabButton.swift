import SwiftUI

// MARK: - Quick View Tab

enum QuickViewTab {
    case summary, transcript, video
}

// MARK: - Quick View Tab Button

struct QuickViewTabButton: View {
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
                    .font(.system(size: 13, weight: .regular))
            }
            .foregroundColor(isSelected ? .accent : .subtleText)
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
