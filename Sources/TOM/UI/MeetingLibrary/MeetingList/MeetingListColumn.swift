import SwiftUI

// MARK: - Column 2: Meeting List (~280px)

struct MeetingListColumn: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSearch: Bool
    @State private var hoveredMeetingID: UUID?

    private var filteredMeetings: [Meeting] {
        let base = appState.filteredMeetingsByGroup
        let sorted = base.sorted { $0.date > $1.date }
        guard !appState.searchQuery.isEmpty else { return sorted }
        let q = appState.searchQuery.lowercased()
        return sorted.filter { $0.title.lowercased().contains(q) }
    }

    private var selectedGroupName: String {
        if let gid = appState.selectedGroupId {
            return appState.groups.first { $0.id == gid }?.name ?? "Group"
        }
        return "All Meetings"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedGroupName)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                    Text("\(filteredMeetings.count) meetings")
                        .font(.system(size: 11))
                        .foregroundColor(.subtleText)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showSearch.toggle()
                        if !showSearch { appState.searchQuery = "" }
                    }
                } label: {
                    Image(systemName: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(.subtleText)
                }
                .buttonStyle(.plain)
                .help(showSearch ? "Hide Search" : "Search Meetings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if showSearch {
                MeetingListSearchBar()
                    .environmentObject(appState)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if appState.isRecording {
                RecordingBanner()
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            if filteredMeetings.isEmpty && !appState.searchQuery.isEmpty {
                if #available(macOS 14, *) {
                    ContentUnavailableView(
                        "No meetings match your search",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different keyword or clear the search field.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // macOS 13 fallback
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.subtleText)
                        Text("No meetings match your search")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("Try a different keyword or clear the search field.")
                            .font(.system(size: 12))
                            .foregroundColor(.subtleText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            } else {
                List(filteredMeetings) { meeting in
                    MeetingCard(
                        meeting: meeting,
                        isSelected: appState.selectedMeeting?.id == meeting.id,
                        isHovered: hoveredMeetingID == meeting.id
                    )
                    .overlay(alignment: .trailing) {
                        if hoveredMeetingID == meeting.id {
                            Button {
                                let menu = NSMenu()
                                menu.addItem(MeetingMenuItem("New Window", systemImage: "macwindow.badge.plus") {
                                    appState.selectedMeeting = meeting
                                    AppDelegate.shared?.showMeetingDetail(meeting: meeting, appState: appState)
                                })
                                menu.addItem(MeetingMenuItem("Retranscribe", systemImage: "arrow.clockwise") {
                                    appState.retranscribe(meeting)
                                })
                                menu.addItem(.separator())
                                menu.addItem(MeetingMenuItem("Delete", systemImage: "trash") {
                                    appState.deleteMeeting(meeting)
                                })
                                if let event = NSApp.currentEvent {
                                    NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
                                }
                            } label: {
                                MeetingMenuIcon()
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 10)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .onDrag { NSItemProvider(object: meeting.id.uuidString as NSString) }
                    .onTapGesture {
                        appState.selectedMeeting = meeting
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            appState.selectedMeeting = meeting
                            AppDelegate.shared?.showMeetingDetail(meeting: meeting, appState: appState)
                        }
                    )
                    .onHover { hovering in
                        hoveredMeetingID = hovering ? meeting.id : nil
                    }
                    .contextMenu {
                        Button {
                            appState.selectedMeeting = meeting
                            AppDelegate.shared?.showMeetingDetail(meeting: meeting, appState: appState)
                        } label: {
                            Label("New Window", systemImage: "macwindow.badge.plus")
                        }
                        Button {
                            appState.retranscribe(meeting)
                        } label: {
                            Label("Retranscribe", systemImage: "arrow.clockwise")
                        }
                        Divider()
                        Button(role: .destructive) {
                            appState.deleteMeeting(meeting)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .listStyle(.plain)
                .listSectionSeparator(.hidden)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct MeetingMenuIcon: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color(nsColor: .labelColor))
            .rotationEffect(.degrees(90))
            .frame(width: 28, height: 28)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private final class MeetingMenuItem: NSMenuItem {
    private let closure: () -> Void
    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.closure = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
        self.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func invoke() { closure() }
}
