import SwiftUI

// MARK: - Sidebar Search Bar

struct SidebarSearchBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.subtleText)
            TextField("Ask across recordings...", text: $appState.ragQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    appState.askQuestion(appState.ragQuery)
                }
            if !appState.ragQuery.isEmpty {
                Button {
                    appState.ragQuery = ""
                    appState.ragAnswer = ""
                    appState.ragSources = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.subtleText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.cardBg)
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
