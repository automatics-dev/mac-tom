import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export Buttons

struct ExportButtons: View {
    let meeting: Meeting
    let activeTab: DetailTab
    @EnvironmentObject var appState: AppState
    @State private var copied = false

    /// Latest meeting state — pick up alias renames without waiting for the
    /// parent view to hand us a fresh `meeting`.
    private var liveMeeting: Meeting {
        appState.meetings.first(where: { $0.id == meeting.id }) ?? meeting
    }

    private var copyText: String {
        if activeTab == .summary {
            return liveMeeting.aliasedSummary ?? ""
        }
        return liveMeeting.aliasedTranscript ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
                tomLog("User action: copied \(activeTab == .summary ? "summary" : "transcript") to clipboard (\(copyText.count) chars, meeting=\(liveMeeting.id.uuidString.prefix(8)))")
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 11))
                    Text(copied ? "Copied!" : "Copy")
                        .font(.system(size: 11))
                }
                .foregroundColor(copied ? .green : .subtleText)
            }
            .buttonStyle(.plain)
            .disabled(copyText.isEmpty)

            Button {
                exportMarkdown(liveMeeting)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                    Text("Export")
                        .font(.system(size: 11))
                }
                .foregroundColor(.subtleText)
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 4)
    }

    private func exportMarkdown(_ meeting: Meeting) {
        let dateStr = shortDateFormatter.string(from: meeting.date)
        let dur = formatDuration(meeting.duration)
        var md = "# \(meeting.title)\n**Date:** \(dateStr)  **Duration:** \(dur)\n\n"
        if let summary = meeting.aliasedSummary, !summary.isEmpty {
            md += "## Summary\n\(summary)\n\n"
        }
        if let transcript = meeting.aliasedTranscript, !transcript.isEmpty {
            md += "## Transcript\n\(transcript)\n"
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let safeName = meeting.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeName)-\(dateStr).md"
        tomLog("User action: Export markdown (meeting=\(meeting.id.uuidString.prefix(8)))")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
                tomLog("Export markdown saved: \(url.lastPathComponent) (\(md.count) chars)")
            } catch {
                tomLog("Export markdown failed: \(error)")
            }
        } else {
            tomLog("Export markdown cancelled")
        }
    }
}

// MARK: - Quick View Export Buttons (single-click panel)

struct QuickViewExportButtons: View {
    let meeting: Meeting
    let activeTab: QuickViewTab
    @EnvironmentObject var appState: AppState
    @State private var copied = false

    private var liveMeeting: Meeting {
        appState.meetings.first(where: { $0.id == meeting.id }) ?? meeting
    }

    private var copyText: String {
        if activeTab == .summary {
            return liveMeeting.aliasedSummary ?? ""
        }
        return liveMeeting.aliasedTranscript ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
                tomLog("User action: copied \(activeTab == .summary ? "summary" : "transcript") to clipboard (\(copyText.count) chars, meeting=\(liveMeeting.id.uuidString.prefix(8)))")
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 11))
                    Text(copied ? "Copied!" : "Copy")
                        .font(.system(size: 12))
                }
                .foregroundColor(copied ? .green : .subtleText)
            }
            .buttonStyle(.plain)
            .disabled(copyText.isEmpty)

            Button {
                exportMarkdown(liveMeeting)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                    Text("Export")
                        .font(.system(size: 12))
                }
                .foregroundColor(.subtleText)
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 8)
    }

    private func exportMarkdown(_ meeting: Meeting) {
        let dateStr = shortDateFormatter.string(from: meeting.date)
        let dur = formatDuration(meeting.duration)
        var md = "# \(meeting.title)\n**Date:** \(dateStr)  **Duration:** \(dur)\n\n"
        if let summary = meeting.aliasedSummary, !summary.isEmpty {
            md += "## Summary\n\(summary)\n\n"
        }
        if let transcript = meeting.aliasedTranscript, !transcript.isEmpty {
            md += "## Transcript\n\(transcript)\n"
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let safeName = meeting.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeName)-\(dateStr).md"
        tomLog("User action: Export markdown (meeting=\(meeting.id.uuidString.prefix(8)))")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
                tomLog("Export markdown saved: \(url.lastPathComponent) (\(md.count) chars)")
            } catch {
                tomLog("Export markdown failed: \(error)")
            }
        } else {
            tomLog("Export markdown cancelled")
        }
    }
}
