import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updater: UpdaterController
    @StateObject private var downloads = ModelDownloadManager.shared
    @StateObject private var cloudBrain = CloudBrainPreferences.shared

    @State private var selectedTab: SettingsTab = .general
    @State private var diskUsage: String = "Calculating…"
    @State private var advancedExpanded = false
    @State private var summaryPromptDraft: String = ""
    @State private var titlePromptDraft: String = ""
    @State private var openAIKeyDraft: String = ""
    @State private var anthropicKeyDraft: String = ""
    @State private var openAIValidating = false
    @State private var anthropicValidating = false
    @State private var openAIValidationError: String?
    @State private var anthropicValidationError: String?
    @AppStorage("tom.launchAtLogin") private var launchAtLogin = true
    @State private var showMenuBarIcon = StatusItemController.isVisible
    @AppStorage("tom.notifyMeetingStart") private var notifyMeetingStart = true
    /// Seeded from the RAM-aware default; the toggle then persists an
    /// explicit choice via `LiveTranscription.set`.
    @State private var liveTranscribe = LiveTranscription.isEnabled
    /// Raw engine preference; `TranscriptionEngine.selected` applies the
    /// model-readiness fallback at use time, the picker just stores intent.
    @AppStorage(TranscriptionEngine.key) private var transcriptionEngineRaw = TranscriptionEngine.selected.rawValue
    @AppStorage(WhisperRetranscription.key) private var retranscribeWithWhisper = false

    var body: some View {
        VStack(spacing: 0) {
            customTabBar
            Divider()
            tabContent
        }
        .onAppear {
            calculateDiskUsage()
            loadPromptDrafts()
            downloads.refreshFromDisk()
            tomLog("User action: opened Settings (tab=\(selectedTab.rawValue))")
        }
    }

    private var customTabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    guard selectedTab != tab else { return }
                    tomLog("User action: switched Settings tab \(selectedTab.rawValue) → \(tab.rawValue)")
                    selectedTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11))
                        Text(tab.title)
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(selectedTab == tab ? Color.accent.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(selectedTab == tab ? Color.accent : Color(nsColor: .secondaryLabelColor))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general: generalTab
        case .ai:      aiTab
        case .storage: storageTab
        case .about:   aboutTab
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingsToggleRow("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        tomLog("User action: Launch at Login toggled \(newValue ? "ON" : "OFF")")
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            tomLog("Login item error: \(error)")
                        }
                    }

                Divider()

                settingsToggleRow(
                    "Show menu bar icon",
                    description: "Quick access to recording from the menu bar. TOM always keeps its Dock icon.",
                    isOn: $showMenuBarIcon
                )
                .onChange(of: showMenuBarIcon) { _, newValue in
                    tomLog("User action: Show menu bar icon toggled \(newValue ? "ON" : "OFF")")
                    StatusItemController.shared.setVisible(newValue)
                }

                Divider()

                settingsToggleRow(
                    "Notify when a meeting starts",
                    description: "Detects Zoom, Google Meet, Teams, Webex and Slack Huddle windows and offers to record with one click.",
                    isOn: $notifyMeetingStart
                )
                .onChange(of: notifyMeetingStart) { _, newValue in
                    tomLog("User action: Notify when a meeting starts toggled \(newValue ? "ON" : "OFF")")
                }

                Divider()

                settingsToggleRow(
                    "Transcribe live while recording",
                    description: "Transcript streams in as you speak and is ready the moment the recording stops. Keeps the transcription model in memory during recording (~2 GB) — turn off on Macs with less than 16 GB if recordings stutter.",
                    isOn: $liveTranscribe
                )
                .onChange(of: liveTranscribe) { _, newValue in
                    tomLog("User action: Live transcription toggled \(newValue ? "ON" : "OFF")")
                    LiveTranscription.set(newValue)
                }

                Divider()

                softwareUpdatesSection

                Divider().padding(.vertical, 8)

                sectionHeader("Screen Recording")

                settingsRow {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Black video when recording Chrome or Arc?", systemImage: "exclamationmark.triangle")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)

                        Text("Chrome and Chromium-based browsers (Arc, Edge, Brave) use GPU-accelerated rendering that bypasses macOS screen capture. This affects all screen recorders, not just TOM.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("To fix, disable hardware acceleration in your browser:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Chrome → Settings → System → Toggle OFF \"Use hardware acceleration when available\" → Relaunch")
                                .font(.caption)
                            Text("Arc → Settings → Advanced → Toggle OFF \"Use hardware acceleration\" → Relaunch")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)

                        Text("Trade-off: slightly higher CPU usage during video playback.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                advancedSection
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Software Updates

    private var softwareUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsToggleRow("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                .onChange(of: updater.automaticallyChecksForUpdates) { _, newValue in
                    tomLog("User action: Automatically check for updates toggled \(newValue ? "ON" : "OFF")")
                }
            settingsToggleRow("Automatically download updates", isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.automaticallyChecksForUpdates)
                .opacity(updater.automaticallyChecksForUpdates ? 1 : 0.5)
                .onChange(of: updater.automaticallyDownloadsUpdates) { _, newValue in
                    tomLog("User action: Automatically download updates toggled \(newValue ? "ON" : "OFF")")
                }
            HStack(spacing: 10) {
                Button("Check for Updates") {
                    tomLog("User action: Check Now for updates")
                    updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!updater.canCheckForUpdates)
                Spacer()
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: - Advanced (Custom LLM Prompts)

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    advancedExpanded.toggle()
                }
                tomLog("User action: Advanced settings \(advancedExpanded ? "expanded" : "collapsed")")
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                    Text("Advanced settings")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if advancedExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Custom prompts apply only to new meetings or when re-transcribing existing ones. They are not applied retroactively to your meeting history.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    promptEditor(
                        title: "Summary prompt",
                        description: "Leave empty to use the built-in default. Enter your own system prompt to override it. Available placeholders: {{kindNoun}} (meeting type), {{language}} (detected transcript language).",
                        promptName: "summary-system",
                        text: $summaryPromptDraft
                    )

                    promptEditor(
                        title: "Title prompt",
                        description: "Leave empty to use the built-in default. Enter your own system prompt to override it. Available placeholders: {{kindNoun}} (meeting type), {{language}} (detected transcript language).",
                        promptName: "title-system",
                        text: $titlePromptDraft
                    )
                }
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func promptEditor(
        title: String,
        description: String,
        promptName: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if isCustomised(promptName: promptName, draft: text.wrappedValue) {
                    Text("Customised")
                        .font(.caption2)
                        .foregroundStyle(Color.accent)
                } else {
                    Text("Default")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 140)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if text.wrappedValue.isEmpty {
                    // Empty editor = "use bundled default." Default prompt
                    // text is intentionally hidden so the user picks
                    // explicitly between default and custom rather than
                    // editing a copy of the default.
                    Text("Empty — using the bundled default prompt. Type here to override.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 12)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Spacer()
                Button("Reset to default") {
                    resetPrompt(promptName, text: text)
                }
                .controlSize(.small)
                .disabled(!isCustomised(promptName: promptName, draft: text.wrappedValue)
                          && text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Save") {
                    savePrompt(promptName, content: text.wrappedValue)
                }
                .controlSize(.small)
                .disabled(!hasUnsavedChanges(promptName: promptName, draft: text.wrappedValue))
            }
        }
    }

    /// Loads the user's saved custom prompt into the editor draft. If none
    /// is saved, the editor stays empty — the default prompt is hidden
    /// from the UI so the choice is explicit (default vs. custom), not
    /// "edit a copy of the default."
    private func loadPromptDrafts() {
        summaryPromptDraft = PromptLoader.customTemplate("summary-system") ?? ""
        titlePromptDraft = PromptLoader.customTemplate("title-system") ?? ""
    }

    /// Persists the editor's content as a custom override. An empty (or
    /// whitespace-only) draft is treated as "use the bundled default" —
    /// equivalent to pressing Reset.
    private func savePrompt(_ name: String, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            PromptLoader.setCustomTemplate(name, content: nil)
            tomLog("User action: saved \(name) prompt with empty content — reverted to bundled default")
        } else {
            PromptLoader.setCustomTemplate(name, content: content)
            tomLog("User action: saved custom \(name) prompt (\(trimmed.count) chars)")
        }
    }

    /// Clears the custom override and empties the editor. Next render
    /// re-uses the bundled default at inference time.
    private func resetPrompt(_ name: String, text: Binding<String>) {
        PromptLoader.setCustomTemplate(name, content: nil)
        text.wrappedValue = ""
        tomLog("User action: reset \(name) prompt to bundled default")
    }

    private func isCustomised(promptName: String, draft: String) -> Bool {
        PromptLoader.customTemplate(promptName) != nil
    }

    private func hasUnsavedChanges(promptName: String, draft: String) -> Bool {
        let stored = PromptLoader.customTemplate(promptName) ?? ""
        return draft.trimmingCharacters(in: .whitespacesAndNewlines)
            != stored.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AI Models Tab

    private var aiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingsRow {
                    Text(modelsIntroCopy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 8)

                sectionHeader("Voice AI")
                settingsRow { voiceAICard }

                Divider().padding(.vertical, 8)

                sectionHeader("Think AI")
                settingsRow { thinkAICard }

                Divider().padding(.vertical, 8)

                sectionHeader("Search AI")
                settingsRow { searchAICard }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 20)
        }
    }

    // MARK: - AI Cards

    private var modelsIntroCopy: String {
        if cloudBrain.isActive {
            let provider = cloudBrain.backend == .openai ? "OpenAI" : "Anthropic"
            return "Voice AI (on-device transcription) and Search AI (semantic embeddings) always run on-device. Think AI is currently routed to \(provider) — summaries, action points, and Ask answers go through that provider's API. Local Qwen is optional in this mode."
        }
        return "All models run locally on Apple Silicon — your meetings never leave your Mac. You can optionally route Think AI to OpenAI's or Anthropic's most capable model below."
    }

    /// Voice AI = transcription. Two on-device engines: Parakeet (real-time,
    /// 25 languages) and Whisper (accuracy pick). The picker chooses the
    /// live/default engine; the toggle below re-runs Whisper over the full
    /// recording after each meeting for archival quality.
    @ViewBuilder
    private var voiceAICard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick which model turns speech into text while you record. Parakeet transcribes in real time across 25 languages; Whisper is slower but the most accurate.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Engine", selection: Binding(
                get: { TranscriptionEngine(rawValue: transcriptionEngineRaw) ?? .parakeet },
                set: { engine in
                    transcriptionEngineRaw = engine.rawValue
                    tomLog("User action: transcription engine → \(engine.rawValue)")
                }
            )) {
                Text("Parakeet").tag(TranscriptionEngine.parakeet)
                Text("Whisper").tag(TranscriptionEngine.whisper)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            modelCard(
                info: ModelDownloadManager.parakeetInfo,
                status: downloads.parakeetStatus,
                isOptional: false,
                download: {
                    tomLog("User action: Download Voice AI (Parakeet)")
                    Task { await downloads.downloadParakeet() }
                },
                redownload: {
                    tomLog("User action: Re-download Voice AI (Parakeet)")
                    Task { await downloads.wipeAndRedownloadParakeet() }
                }
            )

            modelCard(
                info: ModelDownloadManager.transcriptionInfo,
                status: downloads.transcriptionStatus,
                isOptional: false,
                download: {
                    tomLog("User action: Download Voice AI (Whisper)")
                    Task { await downloads.downloadTranscription() }
                },
                redownload: {
                    tomLog("User action: Re-download Voice AI (Whisper)")
                    Task { await downloads.wipeAndRedownloadTranscription() }
                }
            )

            Toggle(isOn: Binding(
                get: { retranscribeWithWhisper },
                set: { on in
                    retranscribeWithWhisper = on
                    tomLog("User action: Whisper re-transcription → \(on ? "on" : "off")")
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Refine with Whisper after each meeting")
                        .font(.system(size: 13))
                    Text("Runs a full Whisper pass once recording stops, replacing the live transcript with the most accurate version. Needs the Whisper model downloaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!downloads.transcriptionStatus.isReady)
        }
    }

    /// Think AI = summariser / RAG brain. Three backends — local Qwen, OpenAI,
    /// Anthropic. The picker is always visible; the body below it reflects
    /// the active selection (local download status vs cloud-provider key
    /// editor).
    @ViewBuilder
    private var thinkAICard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick which model writes summaries, extracts action points, and answers cross-meeting questions. Voice AI and Search AI are unaffected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Only show the backend picker when more than one backend is
            // offered. With a single option the lone segment is noise.
            if CloudBrainBackend.userSelectableCases.count > 1 {
                Picker("Backend", selection: Binding(
                    get: { cloudBrain.backend },
                    set: { cloudBrain.setBackend($0) }
                )) {
                    ForEach(CloudBrainBackend.userSelectableCases) { b in
                        Text(thinkBackendShortLabel(b)).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch cloudBrain.backend {
            case .local:
                modelCard(
                    info: ModelDownloadManager.summaryInfo,
                    status: downloads.summaryStatus,
                    isOptional: false,
                    download: {
                        tomLog("User action: Download Think AI (local Qwen)")
                        Task { await downloads.downloadSummary() }
                    },
                    redownload: {
                        tomLog("User action: Re-download Think AI (local Qwen)")
                        Task { await downloads.wipeAndRedownloadSummary() }
                    }
                )
            case .openai:
                openAIKeyEditor
            case .anthropic:
                anthropicKeyEditor
            }
        }
        .onAppear {
            // A previously-persisted cloud backend is no longer offered for
            // selection; fall back to local so the active backend is valid.
            if !CloudBrainBackend.userSelectableCases.contains(cloudBrain.backend) {
                cloudBrain.setBackend(.local)
            }
        }
    }

    private func thinkBackendShortLabel(_ b: CloudBrainBackend) -> String {
        switch b {
        case .local:     return "Local"
        case .openai:    return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    /// Search AI = multilingual-e5-small. Always on-device; only download /
    /// re-download / ready state.
    @ViewBuilder
    private var searchAICard: some View {
        modelCard(
            info: ModelDownloadManager.embeddingInfo,
            status: downloads.embeddingStatus,
            isOptional: false,
            download: {
                tomLog("User action: Download Search AI (multilingual-e5-small)")
                Task { await downloads.downloadEmbedding() }
            },
            redownload: {
                tomLog("User action: Re-download Search AI (multilingual-e5-small)")
                Task { await downloads.wipeAndRedownloadEmbedding() }
            }
        )
    }

    /// Shared single-model row used by all three AI cards. Renders the
    /// model's name + size + status badge, with a Download button when not
    /// yet on disk, a Cancel-less progress bar while downloading, or a
    /// "Ready · Re-download" trailing action when on disk.
    @ViewBuilder
    private func modelCard(
        info: ModelDownloadManager.ModelInfo,
        status: ModelDownloadManager.Status,
        isOptional: Bool,
        download: @escaping () -> Void,
        redownload: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: info.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(modelIconColor(for: status))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(info.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                modelStatusBadge(status: status)
            }

            switch status {
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            case .ready:
                HStack {
                    Spacer()
                    Button("Re-download", action: redownload)
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
            case .notDownloaded, .failed, .unknown:
                HStack {
                    if case .failed(let message) = status {
                        Label(message, systemImage: "xmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(action: download) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private func modelStatusBadge(status: ModelDownloadManager.Status) -> some View {
        switch status {
        case .ready:
            Label("Ready", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .downloading:
            Label("Downloading…", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(Color.accent)
        case .failed:
            Label("Failed", systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .notDownloaded:
            Label("Not downloaded", systemImage: "tray")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unknown:
            Label("Checking…", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func modelIconColor(for status: ModelDownloadManager.Status) -> Color {
        switch status {
        case .ready: return .green
        case .downloading: return .accent
        case .failed: return .red
        case .notDownloaded, .unknown: return .secondary.opacity(0.6)
        }
    }

    private var openAIKeyEditor: some View {
        providerKeyEditor(
            providerName: "OpenAI",
            modelName: OpenAISummarizer.model,
            placeholder: "sk-…",
            hasKey: cloudBrain.hasOpenAIKey,
            isActiveProvider: cloudBrain.backend == .openai && cloudBrain.isActive,
            draft: $openAIKeyDraft,
            keyURL: "https://platform.openai.com/api-keys",
            keyURLLabel: "platform.openai.com",
            isValidating: $openAIValidating,
            validationError: $openAIValidationError,
            validateAndSave: { key in
                try await OpenAISummarizer.validate(key: key)
                await MainActor.run {
                    cloudBrain.setOpenAIKey(key)
                    openAIKeyDraft = ""
                }
            },
            clear: { cloudBrain.clearOpenAIKey(); openAIKeyDraft = ""; openAIValidationError = nil }
        )
    }

    private var anthropicKeyEditor: some View {
        providerKeyEditor(
            providerName: "Anthropic",
            modelName: AnthropicSummarizer.model,
            placeholder: "sk-ant-…",
            hasKey: cloudBrain.hasAnthropicKey,
            isActiveProvider: cloudBrain.backend == .anthropic && cloudBrain.isActive,
            draft: $anthropicKeyDraft,
            keyURL: "https://console.anthropic.com/settings/keys",
            keyURLLabel: "console.anthropic.com",
            isValidating: $anthropicValidating,
            validationError: $anthropicValidationError,
            validateAndSave: { key in
                try await AnthropicSummarizer.validate(key: key)
                await MainActor.run {
                    cloudBrain.setAnthropicKey(key)
                    anthropicKeyDraft = ""
                }
            },
            clear: { cloudBrain.clearAnthropicKey(); anthropicKeyDraft = ""; anthropicValidationError = nil }
        )
    }

    @ViewBuilder
    private func providerKeyEditor(
        providerName: String,
        modelName: String,
        placeholder: String,
        hasKey: Bool,
        isActiveProvider: Bool,
        draft: Binding<String>,
        keyURL: String,
        keyURLLabel: String,
        isValidating: Binding<Bool>,
        validationError: Binding<String?>,
        validateAndSave: @escaping (String) async throws -> Void,
        clear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField(hasKey ? "•••••••• (key stored in Keychain)" : placeholder, text: draft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isValidating.wrappedValue)
                    .onChange(of: draft.wrappedValue) { _, _ in
                        // User edits → clear any stale validation error so
                        // they're not staring at a "key rejected" message
                        // for the value they've already corrected.
                        validationError.wrappedValue = nil
                    }

                Button {
                    let key = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return }
                    Task {
                        await runValidateAndSave(
                            key: key,
                            isValidating: isValidating,
                            validationError: validationError,
                            validateAndSave: validateAndSave
                        )
                    }
                } label: {
                    if isValidating.wrappedValue {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .disabled(isValidating.wrappedValue
                          || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasKey {
                    Button("Clear", action: clear)
                        .disabled(isValidating.wrappedValue)
                }
            }

            if let error = validationError.wrappedValue {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if isActiveProvider {
                    Label("Active — using \(modelName)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Label("Add a \(providerName) API key to activate", systemImage: "key")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Spacer()
                Text("[Get a key at \(keyURLLabel)](\(keyURL))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Your API key is stored in macOS Keychain on this Mac. Transcripts and questions are sent to \(providerName) only while this backend is selected. Audio recordings and the search index remain local.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Probes the provider with the new key, persists it only on success.
    /// Strict on network failure: an unreachable provider keeps the key
    /// out of Keychain so we never end up with a "saved key = works"
    /// invariant violation.
    private func runValidateAndSave(
        key: String,
        isValidating: Binding<Bool>,
        validationError: Binding<String?>,
        validateAndSave: (String) async throws -> Void
    ) async {
        isValidating.wrappedValue = true
        validationError.wrappedValue = nil
        defer { isValidating.wrappedValue = false }
        do {
            try await validateAndSave(key)
        } catch {
            validationError.wrappedValue = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Storage Tab

    private var storageTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingsRow {
                    HStack {
                        Text("Disk Usage").foregroundStyle(.primary)
                        Spacer()
                        Text(diskUsage).foregroundStyle(.secondary)
                    }
                }

                Divider()

                settingsRow {
                    HStack {
                        Text("Meetings Stored").foregroundStyle(.primary)
                        Spacer()
                        Text("\(appState.meetings.count)").foregroundStyle(.secondary)
                    }
                }

                Divider()

                settingsRow {
                    Button("Open Data Folder") {
                        let url = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".tom/data", isDirectory: true)
                        tomLog("User action: Open Data Folder (\(url.path))")
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider().padding(.vertical, 8)

                sectionHeader("Diagnostics")

                settingsRow {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Diagnostic log")
                                .foregroundStyle(.primary)
                            Text("Timestamped trace of TOM's runtime (recording, AI routing, downloads, errors). Useful when debugging a release build.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Reveal in Finder") {
                            tomLog("User action: Reveal diagnostic log in Finder")
                            NSWorkspace.shared.activateFileViewerSelecting([TOMLogFile.logURL])
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 20)
        }
    }

    // MARK: - About Tab

    private static let appVersion: String = {
        guard let url = Bundle.main.url(forResource: "VERSION", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "unknown"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    private var aboutTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("App Info")

                settingsRow {
                    HStack {
                        Text("App").foregroundStyle(.primary)
                        Spacer()
                        Text("TOM").foregroundStyle(.secondary)
                    }
                }

                Divider()

                settingsRow {
                    HStack {
                        Text("Version").foregroundStyle(.primary)
                        Spacer()
                        Text(Self.appVersion).foregroundStyle(.secondary)
                    }
                }

                settingsRow {
                    Text("Your data is never stored on our servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Standard preference row: title (+ optional description) on the left,
    /// a small switch on the right — the native macOS Settings pattern.
    @ViewBuilder
    private func settingsToggleRow(
        _ title: String,
        description: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.accent)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func calculateDiskUsage() {
        Task.detached {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".tom/data", isDirectory: true)
            let size = SettingsView.computeFolderSize(at: url)
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            await MainActor.run {
                diskUsage = formatted
            }
        }
    }

    private nonisolated static func computeFolderSize(at url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory == false,
                  let size = values.fileSize else { continue }
            total += UInt64(size)
        }
        return total
    }
}

// MARK: - Tab Enum

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, ai, storage, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .ai:      "AI Models"
        case .storage: "Storage"
        case .about:   "About"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .ai:      "cpu"
        case .storage: "internaldrive"
        case .about:   "info.circle"
        }
    }
}

// MARK: - Unified Model Download Card

/// Single-row replacement for the previous three per-model rows. Renders the
/// three function icons (waveform / brain / magnifyingglass), an aggregate
/// byte-weighted progress bar, and during a download the title of the
/// currently-streaming model + a coarse "~Xm Ys" ETA.
///
/// All three downloads run as one logical batch — splitting them into
/// independent rows wasn't useful because TOM is unusable until *all* models
/// are ready. Showing one bar matches that gating.
struct UnifiedModelDownloadCard: View {
    @ObservedObject var downloads: ModelDownloadManager
    let startAll: () -> Void
    let redownloadAll: () -> Void

    /// 1Hz tick so the ETA + elapsed time keep updating without depending on
    /// the underlying status @Published firing every second.
    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            iconStrip
            statusLine
            if downloads.anyDownloading {
                progressBlock
            } else if !downloads.allReady {
                Button(action: startAll) {
                    Label("Download all (~4 GB)", systemImage: "arrow.down.circle")
                }
            } else {
                HStack(spacing: 8) {
                    Label("All models ready", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Spacer()
                    Button(action: redownloadAll) {
                        Text("Re-download all")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .onReceive(timer) { now = $0 }
    }

    // MARK: - Subviews

    private var iconStrip: some View {
        HStack(spacing: 14) {
            modelIcon(systemName: "waveform",
                      label: "Speech",
                      status: downloads.transcriptionStatus)
            modelIcon(systemName: "brain",
                      label: "LLM",
                      status: downloads.summaryStatus)
            modelIcon(systemName: "magnifyingglass",
                      label: "Search",
                      status: downloads.embeddingStatus)
            Spacer()
        }
    }

    @ViewBuilder
    private func modelIcon(systemName: String, label: String, status: ModelDownloadManager.Status) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(iconColor(for: status))
                if case .ready = status {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 11, height: 11))
                        .offset(x: 9, y: 7)
                }
            }
            .frame(width: 30, height: 22)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private func iconColor(for status: ModelDownloadManager.Status) -> Color {
        switch status {
        case .ready: return .green
        case .downloading: return .accent
        case .failed: return .red
        case .notDownloaded, .unknown: return .secondary.opacity(0.6)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if downloads.anyDownloading {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accent)
                Text(downloadingTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(Int(downloads.aggregateFraction * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accent)
                    .monospacedDigit()
            }
        } else if downloads.allReady {
            EmptyView()
        } else {
            Text("Three models, downloaded once. Together they replace what cloud meeting apps do — on your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var downloadingTitle: String {
        if let title = downloads.currentlyDownloadingTitle { return "Downloading \(title)…" }
        return "Preparing…"
    }

    @ViewBuilder
    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: downloads.aggregateFraction)
                .progressViewStyle(.linear)
            HStack(spacing: 10) {
                Text(bytesLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if let etaText = etaText {
                    Label(etaText, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        // Touch `now` so the timer's @State change re-evaluates the ETA text.
        .id(now.timeIntervalSinceReferenceDate.rounded())
    }

    private var bytesLabel: String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useMB]
        fmt.countStyle = .file
        let done = fmt.string(fromByteCount: downloads.aggregateBytesDownloaded)
        let total = fmt.string(fromByteCount: ModelDownloadManager.bytesTotal)
        return "\(done) of \(total)"
    }

    private var etaText: String? {
        guard let eta = downloads.aggregateEtaSeconds, eta > 0 else { return nil }
        let minutes = Int(eta) / 60
        let seconds = Int(eta) % 60
        if minutes >= 1 {
            return "~\(minutes)m \(seconds)s remaining"
        }
        return "~\(seconds)s remaining"
    }
}
