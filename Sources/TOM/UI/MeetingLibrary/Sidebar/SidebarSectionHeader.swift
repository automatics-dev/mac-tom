import SwiftUI

// MARK: - Section Header

struct SidebarSectionHeader: View {
    let title: LocalizedStringKey
    var onAdd: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
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
