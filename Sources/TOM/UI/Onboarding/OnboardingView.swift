import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import SwiftUI

struct OnboardingView: View {
    @State private var step = 1
    @State private var screenRecordingGranted = false
    @State private var microphoneGranted = false
    @StateObject private var downloads = ModelDownloadManager.shared

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: 8) {
                ForEach(1...totalSteps, id: \.self) { s in
                    Circle()
                        .fill(s == step ? Color.accent : Color.primary.opacity(0.15))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 24)

            Spacer()

            switch step {
            case 1: welcomeStep
            case 2: permissionsStep
            case 3: downloadStep
            default: readyStep
            }

            Spacer()

            // Navigation
            HStack {
                if step > 1 {
                    Button("Back") {
                        tomLog("User action: Onboarding step \(step) → \(step - 1)")
                        step -= 1
                    }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .disabled(downloads.anyDownloading && step == 3)
                }

                Spacer()

                Button(step == totalSteps ? "Get Started" : "Next") {
                    if step == totalSteps {
                        tomLog("User action: Onboarding completed (Get Started)")
                        UserDefaults.standard.set(true, forKey: "tom.onboardingCompleted")
                        NSApp.keyWindow?.close()
                    } else {
                        tomLog("User action: Onboarding step \(step) → \(step + 1)")
                        step += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .disabled(step == 3 && downloads.anyDownloading && !downloads.allReady)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 540, height: 480)
        .onAppear { checkPermissions() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if step == 2 { checkPermissions() }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 50))
                .foregroundColor(.accent)

            Text("Welcome to TOM")
                .font(.system(size: 22, weight: .bold))

            Text("Private meeting intelligence that runs entirely on your Mac")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 10) {
                onboardingBullet(icon: "wifi.slash", text: "No accounts, no API keys, no cloud — your audio never leaves the Mac.")
                onboardingBullet(icon: "brain", text: "On-device AI handles transcription, summaries, and search.")
                onboardingBullet(icon: "arrow.down.circle", text: "First launch downloads ~4 GB of AI models. Free space recommended: 6 GB.")
            }
            .padding(.horizontal, 32)
        }
    }

    private func onboardingBullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accent)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundColor(.accent)

            Text("Grant Permissions")
                .font(.system(size: 22, weight: .bold))

            Text("TOM needs two permissions to record meetings")
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Screen Recording",
                    description: "Capture meeting windows",
                    granted: screenRecordingGranted,
                    action: {
                        tomLog("User action: Grant Screen Recording (opens System Settings)")
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )

                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Capture your voice",
                    granted: microphoneGranted,
                    action: {
                        tomLog("User action: Grant Microphone (system prompt)")
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            DispatchQueue.main.async {
                                microphoneGranted = granted
                                tomLog("Microphone permission request resolved: granted=\(granted)")
                            }
                        }
                    }
                )
            }
            .padding(.horizontal, 32)

            Text("You may need to restart TOM after granting Screen Recording")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func permissionRow(icon: String, title: String, description: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(description).font(.system(size: 11)).foregroundColor(.secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 18))
            } else {
                Button("Grant") { action() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Step 3: Download Models

    private var downloadStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundColor(.accent)

            Text("Set up on-device AI")
                .font(.system(size: 22, weight: .bold))

            Text("Downloads about 4 GB. You can keep using your Mac while this runs in the background.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            UnifiedModelDownloadCard(
                downloads: downloads,
                startAll: { Task { await downloads.downloadAll() } },
                redownloadAll: { Task { await downloads.wipeAndRedownloadAll() } }
            )
            .padding(.horizontal, 32)
        }
        .onAppear {
            downloads.refreshFromDisk()
            Task { await downloads.downloadAll() }
        }
    }

    // MARK: - Step 4: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 50))
                .foregroundColor(.accent)

            Text("You're All Set")
                .font(.system(size: 22, weight: .bold))

            VStack(spacing: 8) {
                instructionRow(icon: "menubar.rectangle", text: "Click the TOM icon in your menu bar to start")
                instructionRow(icon: "record.circle", text: "Select \"Record a Window\" to capture a meeting")
                instructionRow(icon: "lock.shield.fill", text: "Recordings, transcripts, and summaries stay 100% local")
            }
            .padding(.horizontal, 32)

            if !downloads.allReady {
                Text("Models are still downloading in the background. You can record now — transcription and summaries will run as soon as their model is ready.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    private func instructionRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accent)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.primary)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func checkPermissions() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = status == .authorized

        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                await MainActor.run { screenRecordingGranted = true }
            } catch {
                await MainActor.run { screenRecordingGranted = false }
            }
        }
    }
}
