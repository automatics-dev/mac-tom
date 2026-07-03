import SwiftUI

// MARK: - Column 3: Detail (fills remaining, slightly lighter)

struct DetailColumn: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()

            if appState.ragIsLoading || !appState.ragAnswer.isEmpty {
                RAGResultView()
                    .environmentObject(appState)
            } else if let meeting = appState.selectedMeeting {
                DetailContent(meeting: meeting)
            } else {
                EmptyDetailPlaceholder()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardBg)
    }
}
