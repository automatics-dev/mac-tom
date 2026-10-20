import SwiftUI

// MARK: - Meeting List Search Bar

struct MeetingListSearchBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.subtleText)
            TextField("Search recordings...", text: $appState.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            Button { appState.searchQuery = "" } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.subtleText)
                    .opacity(appState.searchQuery.isEmpty ? 0.3 : 1)
            }
            .buttonStyle(.plain)
            .disabled(appState.searchQuery.isEmpty)
        }
        .padding(8)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
