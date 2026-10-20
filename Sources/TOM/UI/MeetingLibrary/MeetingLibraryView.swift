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

    /// Toolbar layout matching the Pencil design 1:1: every custom control
    /// draws its own single capsule (or bare glyph) directly on the toolbar.
    /// On macOS 26 each ToolbarItem otherwise gets wrapped in its own Liquid
    /// Glass capsule — a second ring around our chrome — so the shared
    /// backing is hidden there.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { recordingControl }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .principal) {
                ToolbarRAGSearchField().environmentObject(appState)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { AppearanceToggleButton() }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { settingsGearButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { recordingControl }
            ToolbarItem(placement: .principal) {
                ToolbarRAGSearchField().environmentObject(appState)
            }
            ToolbarItem(placement: .primaryAction) { AppearanceToggleButton() }
            ToolbarItem(placement: .primaryAction) { settingsGearButton }
        }
    }

    /// Idle: Start Recording split capsule; while recording: the recording
    /// bar. See RecordingControls.swift.
    @ViewBuilder
    private var recordingControl: some View {
        if appState.isRecording {
            RecordingBar()
        } else {
            StartRecordingControl()
        }
    }

    private var settingsGearButton: some View {
        Button {
            tomLog("User action: Settings gear \(appState.showSettings ? "closed" : "opened") (toolbar)")
            withAnimation(.spring(duration: 0.25)) {
                appState.showSettings.toggle()
            }
        } label: {
            Image(systemName: appState.showSettings ? "gearshape.fill" : "gearshape")
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .help(appState.showSettings ? "Close Settings" : "Settings")
    }

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
        .toolbar { toolbarContent }
        // No forced toolbar background: on macOS 26 the toolbar renders as
        // glass sections, and forcing `.visible` painted only the content
        // sections — the sidebar section stayed glass, producing a hard seam
        // and a "floating" New Recording pill in light mode.
        .removeSidebarToggleOnMacOS14()
        .blur(radius: appState.showSettings ? 5 : 0)
        .overlay {
            if appState.showSettings {
                Color.black.opacity(0.25)
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
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        appState.showSettings = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close Settings")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            SettingsView()
                .environmentObject(appState)
                .frame(height: 500)
        }
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 40, x: 0, y: 16)
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
        else { return "Ask across all recordings..." }
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // Single capsule as in the Pencil design — the toolbar's own glass
        // backing is hidden for this item (sharedBackgroundVisibility), so
        // this is the only chrome around the field.
        .background(Capsule().fill(Color.cardBg))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// Toolbar görünüm geçiş butonu.
/// NSApp.appearance üzerinden tüm uygulama görünümünü değiştirir.
/// Cycles System → Light → Dark; tercih "tom.appearance" ile kalıcıdır.
private struct AppearanceToggleButton: View {
    @State private var preference: AppearancePreference = .current

    var body: some View {
        Button {
            preference = preference.next
            tomLog("User action: appearance → \(preference.rawValue)")
            AppearancePreference.set(preference)
        } label: {
            Label(preference.label, systemImage: preference.icon)
        }
        .help("\(preference.label) — click to switch")
    }
}
