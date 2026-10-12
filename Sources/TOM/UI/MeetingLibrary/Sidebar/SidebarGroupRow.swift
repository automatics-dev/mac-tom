import SwiftUI

// MARK: - Group Row

struct SidebarGroupRow: View {
    let name: String
    let icon: String
    let count: Int
    let color: Color
    var isSelected: Bool = false

    var body: some View {
        // Pencil design: bare small glyph, no icon tile — tiles are reserved
        // for meetings; groups stay light so the sidebar reads as two
        // distinct densities.
        HStack(spacing: 8) {
            Group {
                if icon.unicodeScalars.allSatisfy({ $0.isASCII }) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(.accent)
                } else {
                    Text(icon).font(.system(size: 12))
                }
            }
            .frame(width: 18)

            Text(name)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .accent : .primary)
                .lineLimit(1)

            Spacer()

            Text("\(count)")
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .accent : .subtleText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? color.opacity(0.12) : Color.clear)
                .padding(.horizontal, 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? color.opacity(0.25) : Color.clear, lineWidth: 1)
                .padding(.horizontal, 8)
        )
    }
}
