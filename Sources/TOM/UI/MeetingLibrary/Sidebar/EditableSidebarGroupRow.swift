import SwiftUI
import UniformTypeIdentifiers

// MARK: - Editable Group Row

struct EditableSidebarGroupRow: View {
    let group: MeetingGroup
    let count: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onDrop: (UUID) -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var editName = ""
    @State private var isDropTarget = false

    var body: some View {
        Group {
            if isEditing {
                HStack(spacing: 8) {
                    Group {
                        if group.icon.unicodeScalars.allSatisfy({ $0.isASCII }) {
                            Image(systemName: group.icon)
                                .font(.system(size: 12))
                                .foregroundColor(.accent)
                        } else {
                            Text(group.icon).font(.system(size: 12))
                        }
                    }
                    .frame(width: 18)

                    TextField("Group name", text: $editName, onCommit: {
                        let trimmed = editName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { onRename(trimmed) }
                        isEditing = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accent.opacity(0.12))
                        .padding(.horizontal, 8)
                )
            } else {
                SidebarGroupRow(
                    name: group.name,
                    icon: group.icon,
                    count: count,
                    color: .accent,
                    isSelected: isSelected
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.accent, lineWidth: isDropTarget ? 2 : 0)
                        .padding(.horizontal, 8)
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onDrop(of: [.utf8PlainText], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: "public.utf8-plain-text") { data, _ in
                guard let data, let str = String(data: data, encoding: .utf8),
                      let id = UUID(uuidString: str) else { return }
                DispatchQueue.main.async { onDrop(id) }
            }
            return true
        }
        .contextMenu {
            Button("Rename") {
                editName = group.name
                isEditing = true
            }
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete Group", systemImage: "trash")
            }
        }
    }
}
