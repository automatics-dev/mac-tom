import SwiftUI

// MARK: - Meeting Library View (NavigationSplitView 3-Column Layout)
//
// Phase 03: HSplitView + custom resize handles + header placeholder + persistent
// player bar yapısı NavigationSplitView ile değiştirildi. Bu container yalnızca
// 3 kolonu kuran ince bir wrapper'dır; render mantığı SidebarColumn,
// MeetingListColumn ve DetailColumn içinde kalır.
//
// Requirement coverage:
//   - NAV-01: NavigationSplitView 3-kolon yapısı
//   - NAV-02: columnVisibility binding ile native sidebar toggle
//   - NAV-03: @AppStorage ile kolon görünürlük + ideal genişlik kalıcılığı
//   - NAV-04: List(selection:) Plan 02'de hazırlandı; native ↑↓ navigasyonu sağlar

struct MeetingLibraryView: View {
    @EnvironmentObject private var appState: AppState

    // NAV-03: Kolon genişlikleri @AppStorage ile UserDefaults'ta saklanır.
    // Anahtar konvensiyonu: "tom." prefix (mevcut TOMApp.swift kalıbıyla uyumlu).
    @AppStorage("tom.sidebarWidth") private var sidebarWidth: Double = 200
    @AppStorage("tom.listWidth")    private var listWidth: Double = 280

    // NAV-02 + NAV-03: Sidebar görünürlüğü.
    // @AppStorage kullanım gerekçesi: NavigationSplitViewVisibility, @SceneStorage'ın
    // gerektirdiği RawRepresentable (RawValue == String veya Int) conformance'ını
    // Apple'ın herkese açık API'sinde SUNMAMAKTADIR. Bu nedenle @SceneStorage ile
    // doğrudan depolanamaz — derleme hatası verir (UI-SPEC P-02 ile çakışma; bkz.
    // RESEARCH.md Open Questions (RESOLVED) #1). @AppStorage + Plan 01'in String
    // bridge extension'ı (rawStringValue / init?(rawStringValue:)) TEK geçerli
    // ve KARAR olarak benimsenmiş yaklaşımdır. Plan 01'de bu extension oluşturulur.
    @AppStorage("tom.splitViewColumnVisibility")
    private var columnVisibilityRaw: String = "all"
    @AppStorage("tom.prefersDark") private var prefersDark: Bool = false
    @State private var showSearch = false

    /// Türetilmiş Binding köprüsü — NavigationSplitView(columnVisibility:) bunu tüketir.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { NavigationSplitViewVisibility(rawStringValue: columnVisibilityRaw) ?? .all },
            set: { columnVisibilityRaw = $0.rawStringValue }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarColumn()
                .environmentObject(appState)
                .navigationSplitViewColumnWidth(min: 140, ideal: CGFloat(sidebarWidth), max: 300)
                .overlay(alignment: .trailing) { DividerCursorHint() }
        } content: {
            MeetingListColumn(showSearch: $showSearch)
                .environmentObject(appState)
                .navigationSplitViewColumnWidth(min: 200, ideal: CGFloat(listWidth), max: 400)
                .overlay(alignment: .trailing) { DividerCursorHint() }
        } detail: {
            DetailColumn()
                .environmentObject(appState)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            // Center: RAG search field (sidebar search moved here)
            ToolbarItem(placement: .principal) {
                ToolbarRAGSearchField()
                    .environmentObject(appState)
            }

            // Left: New Recording
            ToolbarItem(placement: .navigation) {
                Button {
                    tomLog("User action: New Recording (toolbar)")
                    AppDelegate.shared?.showWindowPicker(appState: appState)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 12))
                        Text("New Recording")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(appState.recordingBlockedReason ?? "Record a new meeting")
                .disabled(appState.isRecording || !appState.canCreateMeetings)
            }

            // Right: Appearance toggle
            ToolbarItem(placement: .primaryAction) {
                AppearanceToggleButton()
            }

            // Right: Settings gear (far right)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    tomLog("User action: Settings gear \(appState.showSettings ? "closed" : "opened") (toolbar)")
                    withAnimation(.spring(duration: 0.25)) {
                        appState.showSettings.toggle()
                    }
                } label: {
                    Image(systemName: appState.showSettings ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 13))
                }
                .help(appState.showSettings ? "Close Settings" : "Settings")
            }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
        .removeSidebarToggleOnMacOS14()
        .blur(radius: appState.showSettings ? 5 : 0)
        .overlay {
            if appState.showSettings {
                Color.black.opacity(0.35)
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.25)) {
                            appState.showSettings = false
                        }
                    }
                    .transition(.opacity)

                SettingsModalPanel()
                    .environmentObject(appState)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(duration: 0.25), value: appState.showSettings)
    }
}

private extension View {
    // NavigationSplitView macOS 13+'te kolon header'ına otomatik sidebar toggle ekler.
    // Bu toggle window toolbar'ındaki bizimkiyle çakışır ve iki satırlı görünüme neden olur.
    // macOS 14'te suppress ederek window toolbar'daki tek toggle ile Notes-style tek band sağlanır.
    @ViewBuilder
    func removeSidebarToggleOnMacOS14() -> some View {
        if #available(macOS 14, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

// MARK: - Settings Modal Panel

private struct SettingsModalPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        appState.showSettings = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Color(nsColor: .quaternaryLabelColor))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            SettingsView()
                .environmentObject(appState)
                .frame(height: 500)
        }
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 10)
    }
}

/// Sürüklenebilir kolon sınırlarında resize cursor gösterir.
/// NSSplitView drag'ı yönetir; bu view yalnızca cursor feedback sağlar.
private struct DividerCursorHint: View {
    var body: some View {
        Color.clear
            .frame(width: 8)
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.push()
                case .ended:  NSCursor.pop()
                }
            }
    }
}

/// Toolbar ortasındaki RAG arama alanı — sidebar'dan taşındı.
private struct ToolbarRAGSearchField: View {
    @EnvironmentObject private var appState: AppState

    /// Reflects the search scope: all meetings when no group is selected,
    /// otherwise just the selected group.
    private var placeholder: String {
        guard let gid = appState.selectedGroupId,
              let group = appState.groups.first(where: { $0.id == gid })
        else { return "Ask across all meetings..." }
        return "Ask within \(group.name)..."
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(.accent)
            TextField(placeholder, text: $appState.ragQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .frame(minWidth: 360, idealWidth: 480, maxWidth: 560)
                .onSubmit { appState.askQuestion(appState.ragQuery) }
            Button {
                appState.ragQuery = ""
                appState.ragAnswer = ""
                appState.ragSources = []
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .opacity(appState.ragQuery.isEmpty ? 0.3 : 1)
            }
            .buttonStyle(.plain)
            .disabled(appState.ragQuery.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        )
    }
}

/// Toolbar görünüm geçiş butonu.
/// NSApp.appearance üzerinden tüm uygulama görünümünü değiştirir.
/// Tercih @AppStorage("tom.prefersDark") ile kalıcıdır.
private struct AppearanceToggleButton: View {
    @AppStorage("tom.prefersDark") private var prefersDark: Bool = false

    var body: some View {
        Button {
            prefersDark.toggle()
            tomLog("User action: appearance → \(prefersDark ? "Dark Mode" : "Light Mode")")
            NSApp.appearance = prefersDark
                ? NSAppearance(named: .darkAqua)
                : NSAppearance(named: .aqua)
        } label: {
            Label(
                prefersDark ? "Switch to Light Mode" : "Switch to Dark Mode",
                systemImage: prefersDark ? "sun.max" : "moon"
            )
        }
        .help(prefersDark ? "Switch to Light Mode" : "Switch to Dark Mode")
    }
}
