import SwiftUI

// MARK: - Group Row

struct SidebarGroupRow: View {
    let name: String
    let icon: String
    let count: Int
    let color: Color
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accent.opacity(0.15))
                .frame(width: 22, height: 22)
                .overlay(
                    Group {
                        if icon.unicodeScalars.allSatisfy({ $0.isASCII }) {
                            Image(systemName: icon)
                                .font(.system(size: 11))
                                .foregroundColor(.accent)
                        } else {
                            Text(icon).font(.system(size: 11))
                        }
                    }
                )

            Text(name)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .accent : .primary)
                .lineLimit(1)

            Spacer()

            Text("\(count)")
                .font(.system(size: 12))
                .foregroundColor(.subtleText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? color.opacity(0.15) : Color.clear)
                .padding(.horizontal, 8)
        )
    }
}
