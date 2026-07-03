import SwiftUI

// MARK: - Section Header

struct SidebarSectionHeader: View {
    let title: String
    var onAdd: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.subtleText)

            Spacer()

            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.subtleText)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
