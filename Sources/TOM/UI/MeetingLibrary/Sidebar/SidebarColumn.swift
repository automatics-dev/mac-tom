import SwiftUI
import UniformTypeIdentifiers

// MARK: - Column 1: Sidebar (~200px, darker)

struct SidebarColumn: View {
    @EnvironmentObject var appState: AppState
    @State private var showNewGroupDialog = false
    @State private var newGroupName = ""
    @State private var isAllMeetingsDropTarget = false

    private var recentMeetings: [Meeting] {
        Array(appState.meetings.sorted { $0.date > $1.date }.prefix(5))
    }

    var body: some View {
        ScrollView {
            sections
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .toolbar {
            // Notes-style "New Group" button in the sidebar's title-bar band.
            ToolbarItem(placement: .primaryAction) {
                Button { showNewGroupDialog = true } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13))
                }
                .help("New Group")
            }
        }
        .sheet(isPresented: $showNewGroupDialog) {
            NewGroupDialog(name: $newGroupName) {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { appState.createGroup(name: name) }
                newGroupName = ""
                showNewGroupDialog = false
            } onCancel: {
                newGroupName = ""
                showNewGroupDialog = false
            }
        }
    }

    /// Recent + Groups; scrolls once there are more groups than fit.
    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            // RECENT
            SidebarSectionHeader(title: "Recent")
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ForEach(recentMeetings) { meeting in
                SidebarMeetingRow(
                    meeting: meeting,
                    isSelected: appState.selectedMeeting?.id == meeting.id
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.selectedMeeting = meeting
                }
            }

            // GROUPS
            SidebarSectionHeader(title: "Groups")
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            SidebarGroupRow(
                name: "All Recordings",
                icon: "tray.full",
                count: appState.meetings.count,
                color: .accent,
                isSelected: appState.selectedGroupId == nil
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accent, lineWidth: isAllMeetingsDropTarget ? 2 : 0)
                    .padding(.horizontal, 8)
            )
            .contentShape(Rectangle())
            .onTapGesture { appState.selectedGroupId = nil }
            .onDrop(of: [.utf8PlainText], isTargeted: $isAllMeetingsDropTarget) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadDataRepresentation(forTypeIdentifier: "public.utf8-plain-text") { data, _ in
                    guard let data, let str = String(data: data, encoding: .utf8),
                          let id = UUID(uuidString: str) else { return }
                    DispatchQueue.main.async { appState.moveMeetingToGroup(meetingId: id, groupId: nil) }
                }
                return true
            }

            ForEach(appState.groups) { group in
                EditableSidebarGroupRow(
                    group: group,
                    count: appState.meetings.filter { $0.groupId == group.id }.count,
                    isSelected: appState.selectedGroupId == group.id,
                    onSelect: { appState.selectedGroupId = group.id },
                    onRename: { newName in appState.renameGroup(id: group.id, newName: newName) },
                    onDrop: { meetingId in appState.moveMeetingToGroup(meetingId: meetingId, groupId: group.id) },
                    onDelete: { appState.deleteGroup(group) }
                )
            }

        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - New Group Dialog

private struct NewGroupDialog: View {
    @Binding var name: String
    let onCreate: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accent.opacity(0.15))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundColor(.accent)
                    )
                Text("New Group")
                    .font(.headline)
            }

            HStack(spacing: 8) {
                Text("Name:")
                    .foregroundColor(.secondary)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if !name.trimmingCharacters(in: .whitespaces).isEmpty { onCreate() } }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accent)
            }
        }
        .padding(20)
        .frame(width: 280)
        .onAppear {
            name = ""
            focused = true
        }
    }
}
