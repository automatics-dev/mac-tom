import AppKit
import Carbon.HIToolbox
import Combine
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Drives the annotation side of a Feedback recording: the drawing overlay
/// on the recorded screen, the floating HUD, the ⌥A / ⌥M / Esc hotkeys, and
/// the screenshots + rows saved for each annotation. The recording itself is
/// a normal display or window recording owned by `RecordingManager`.
@MainActor
final class LearningSession: ObservableObject {

    @Published private(set) var isAnnotating = false
    /// Finishing a round captures a screenshot; input is ignored meanwhile.
    @Published private(set) var isCapturing = false
    @Published var tool: AnnotationMark.Tool = .box
    /// Marks of the round in progress.
    @Published private(set) var marks: [AnnotationMark] = []
    @Published private(set) var draft: AnnotationMark?
    @Published private(set) var annotationCount = 0

    let meetingId: UUID
    let recordingStart: Date
    private let display: SCDisplay
    /// Set when only this window is recorded; screenshots show just it.
    private let window: SCWindow?
    private let screen: NSScreen
    private let storage: StorageManager
    private let onStop: () -> Void
    /// Paused recording time so far; annotation times are on the recording
    /// timeline, which doesn't advance while paused.
    private let pausedDuration: () -> TimeInterval

    private var overlay: NSPanel?
    private var canvas: AnnotationCanvasView?
    private var hud: NSPanel?
    private var hudWindow: SCWindow?
    private var overlayWindow: SCWindow?
    private var hotKeys: [GlobalHotKey] = []
    private var escapeKey: GlobalHotKey?
    private var roundStart: TimeInterval = 0
    private var nextIndex = 1
    private var captureTask: Task<Void, Never>?
    private var isEnding = false

    /// Folder (inside the recordings directory) holding this session's
    /// screenshots.
    static func folderName(for meetingId: UUID) -> String {
        "\(meetingId.uuidString).annotations"
    }

    init?(
        meetingId: UUID,
        display: SCDisplay,
        window: SCWindow? = nil,
        recordingStart: Date,
        storage: StorageManager,
        pausedDuration: @escaping () -> TimeInterval,
        onStop: @escaping () -> Void
    ) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }) else { return nil }
        self.meetingId = meetingId
        self.display = display
        self.window = window
        self.screen = screen
        self.recordingStart = recordingStart
        self.storage = storage
        self.pausedDuration = pausedDuration
        self.onStop = onStop
    }

    // MARK: - Lifecycle

    /// Shows the overlay + HUD and registers the hotkeys. Returns the HUD's
    /// SCWindow so the caller can keep it out of the recording.
    func start() async -> SCWindow? {
        let overlay = Self.makePanel(frame: screen.frame, level: .screenSaver, keyable: false)
        overlay.ignoresMouseEvents = true
        let canvas = AnnotationCanvasView(session: self)
        overlay.contentView = canvas
        overlay.orderFrontRegardless()
        self.overlay = overlay
        self.canvas = canvas

        let hud = Self.makePanel(frame: .zero, level: NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1), keyable: true)
        hud.isMovableByWindowBackground = true
        // Only the label field takes keyboard focus; buttons leave it with
        // the app being reviewed.
        hud.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: LearningHUD(session: self))
        hud.contentView = host
        self.hud = hud
        resizeHUD(to: host.fittingSize)
        hud.orderFrontRegardless()

        let option = Int(optionKey)
        hotKeys = [
            GlobalHotKey(keyCode: kVK_ANSI_A, modifiers: option) { [weak self] in self?.toggleAnnotate() },
            GlobalHotKey(keyCode: kVK_ANSI_M, modifiers: option) { [weak self] in self?.addMarker() },
        ].compactMap { $0 }

        hudWindow = await lookUpWindow(hud)
        overlayWindow = await lookUpWindow(overlay)
        tomLog("Learning: session started on display \(display.displayID) (hotkeys=\(hotKeys.count), hud=\(hudWindow != nil), overlay=\(overlayWindow != nil))")
        return hudWindow
    }

    /// A panel as ScreenCaptureKit sees it, to keep it out of screenshots
    /// (and, for the HUD, the recording). The shareable-content list can
    /// lag a window that was just ordered front, so retry briefly.
    private func lookUpWindow(_ panel: NSPanel) async -> SCWindow? {
        let id = CGWindowID(panel.windowNumber)
        for attempt in 1...5 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
               let match = content.windows.first(where: { $0.windowID == id }) {
                return match
            }
            try? await Task.sleep(for: .milliseconds(100 * attempt))
        }
        tomLog("Learning: window \(id) not found in shareable content")
        return nil
    }

    /// Sizes the HUD panel to its content, keeping its top-center where it
    /// is (where the user dragged it), or just under the menu bar before it
    /// is first shown.
    func resizeHUD(to size: CGSize) {
        guard let hud, size.width > 0, size.height > 0 else { return }
        let top = hud.isVisible ? hud.frame.maxY : screen.visibleFrame.maxY - 12
        let midX = hud.isVisible ? hud.frame.midX : screen.visibleFrame.midX
        hud.setFrame(NSRect(x: (midX - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// Finishes an open round, then removes the overlay, HUD and hotkeys.
    func end() async {
        isEnding = true
        hotKeys = []
        // A finish or marker capture in flight still needs the overlay.
        await captureTask?.value
        if isAnnotating {
            isCapturing = true
            await finishRound()
        }
        escapeKey = nil
        overlay?.orderOut(nil)
        hud?.orderOut(nil)
        overlay = nil
        hud = nil
        canvas = nil
        tomLog("Learning: session ended (\(annotationCount) annotations)")
    }

    func stop() { onStop() }

    // MARK: - Rounds

    func toggleAnnotate() {
        guard !isCapturing, !isEnding else { return }
        if isAnnotating {
            // Claimed synchronously so a second press can't queue another
            // finish (and replace the task `end()` waits on).
            isCapturing = true
            captureTask = Task { await finishRound() }
        } else {
            beginRound()
        }
    }

    private func beginRound() {
        roundStart = elapsed
        marks = []
        draft = nil
        isAnnotating = true
        overlay?.ignoresMouseEvents = false
        escapeKey = GlobalHotKey(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.cancelRound() }
        canvas?.needsDisplay = true
        tomLog("Learning: annotation \(nextIndex) started at \(Int(roundStart))s")
    }

    func cancelRound() {
        guard isAnnotating, !isCapturing else { return }
        endRoundUI()
        marks = []
        canvas?.needsDisplay = true
        tomLog("Learning: annotation cancelled")
    }

    /// Callers set `isCapturing` first; it's cleared once the marks fade.
    private func finishRound() async {
        let end = elapsed
        draft = nil
        canvas?.needsDisplay = true
        await save(isMarker: false, start: roundStart, end: end, marks: marks)
        endRoundUI()
        // Still "capturing" through the fade so a new ⌥A can't start a
        // round on a fading overlay.
        await fadeOutMarks()
        isCapturing = false
    }

    func addMarker() {
        guard !isAnnotating, !isCapturing, !isEnding else { return }
        let time = elapsed
        isCapturing = true
        captureTask = Task {
            await save(isMarker: true, start: time, end: time, marks: [])
            isCapturing = false
        }
    }

    private func endRoundUI() {
        isAnnotating = false
        escapeKey = nil
        overlay?.ignoresMouseEvents = true
        // The label field is gone; give keyboard focus back to the app
        // being reviewed (ordering out a key panel hands key status back).
        if let hud, hud.isKeyWindow {
            hud.orderOut(nil)
            hud.orderFrontRegardless()
        }
    }

    private func fadeOutMarks() async {
        guard let overlay else { marks = []; return }
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            overlay.animator().alphaValue = 0
        }
        marks = []
        canvas?.needsDisplay = true
        overlay.alphaValue = 1
    }

    private var elapsed: TimeInterval { elapsed(at: Date()) }

    /// Position on the recording timeline at `date`.
    func elapsed(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(recordingStart) - pausedDuration())
    }

    // MARK: - Drawing (called by the canvas)

    func updateDraft(_ mark: AnnotationMark?) {
        draft = mark
        canvas?.needsDisplay = true
    }

    func commitDraft() {
        defer { updateDraft(nil) }
        guard let draft, Self.isMeaningful(draft) else { return }
        marks.append(draft)
    }

    func undoLastMark() {
        guard !marks.isEmpty else { return }
        marks.removeLast()
        canvas?.needsDisplay = true
    }

    /// Label of the most recent mark; the HUD's label field edits it.
    var lastLabel: String {
        get { marks.last?.label ?? "" }
        set {
            guard !marks.isEmpty else { return }
            marks[marks.count - 1].label = newValue
            canvas?.needsDisplay = true
        }
    }

    /// Ignores stray clicks: boxes and arrows need some extent.
    private static func isMeaningful(_ mark: AnnotationMark) -> Bool {
        let b = mark.bounds
        switch mark.tool {
        case .box, .arrow: return max(b.width, b.height) >= 6
        case .freehand:    return mark.points.count >= 3
        }
    }

    // MARK: - Capture

    private func save(isMarker: Bool, start: TimeInterval, end: TimeInterval, marks: [AnnotationMark]) async {
        let index = nextIndex
        let folder = Self.folderName(for: meetingId)
        let dir = RecordingManager.recordingsDirectory.appendingPathComponent(folder, isDirectory: true)
        let fullName = String(format: "%02d-full.png", index)
        let cropName = String(format: "%02d-crop.png", index)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let shot = try await capture(marks: marks)
            try Self.writePNG(shot.image, to: dir.appendingPathComponent(fullName))

            var cropPath: String?
            let scale = CGFloat(shot.image.width) / shot.size.width
            let labels = shot.marks.compactMap(AnnotationCanvasView.labelFrame(for:))
            if let rect = Annotation.cropRect(for: shot.marks, including: labels, in: CGRect(origin: .zero, size: shot.size)),
               let crop = shot.image.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral) {
                try Self.writePNG(crop, to: dir.appendingPathComponent(cropName))
                cropPath = "\(folder)/\(cropName)"
            }

            let annotation = Annotation(
                meetingId: meetingId,
                index: index,
                isMarker: isMarker,
                startTime: start,
                endTime: end,
                marks: shot.marks,
                screenshotPath: "\(folder)/\(fullName)",
                cropPath: cropPath
            )
            try storage.saveAnnotation(annotation)
            nextIndex += 1
            annotationCount += 1
            tomLog("Learning: saved \(isMarker ? "marker" : "annotation") \(index) (\(marks.count) marks, \(Int(start))–\(Int(end))s)")
        } catch {
            tomLog("Learning: failed to save annotation \(index): \(error)")
        }
    }

    /// Screenshot at native resolution with `marks` drawn on and the HUD
    /// left out: the recorded window by itself (wherever it is now, even
    /// when covered), else the whole display. Returns the marks moved into
    /// the image's point space, and that space's size. The marks are drawn
    /// into the image rather than captured from the overlay, which may not
    /// have reached the screen yet when ⌥A follows a stroke immediately.
    private func capture(marks: [AnnotationMark]) async throws -> (image: CGImage, marks: [AnnotationMark], size: CGSize) {
        if let window {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let current = content?.windows.first(where: { $0.windowID == window.windowID }) {
                let filter = SCContentFilter(desktopIndependentWindow: current)
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: Self.configuration(for: filter))
                let dx = current.frame.minX - display.frame.minX
                let dy = current.frame.minY - display.frame.minY
                let local = marks.map { mark in
                    var moved = mark
                    moved.points = mark.points.map { CGPoint(x: $0.x - dx, y: $0.y - dy) }
                    return moved
                }
                let size = current.frame.size
                return (AnnotationCanvasView.composite(local, onto: image, pointSize: size), local, size)
            }
            tomLog("Feedback: recorded window \(window.windowID) is gone; capturing the display")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [hudWindow, overlayWindow].compactMap { $0 })
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: Self.configuration(for: filter))
        // Overlay not excluded (lookup failed): its marks are in the image.
        let marked = overlayWindow == nil ? image : AnnotationCanvasView.composite(marks, onto: image, pointSize: screen.frame.size)
        return (marked, marks, screen.frame.size)
    }

    private static func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        return config
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func makePanel(frame: NSRect, level: NSWindow.Level, keyable: Bool) -> NSPanel {
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let panel = keyable
            ? KeyablePanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
            : NSPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

/// Borderless panels refuse key status by default; the HUD needs it for the
/// label field. Being non-activating, it never brings TOM to the front.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Canvas

/// Full-screen transparent view that draws the marks and turns mouse drags
/// into new ones while a round is open. Flipped, so its coordinates match
/// the screenshot's top-left origin.
final class AnnotationCanvasView: NSView {
    private weak var session: LearningSession?
    private var dragStart: CGPoint?

    static let strokeColor = NSColor(red: 0.93, green: 0.545, blue: 0.176, alpha: 1)  // accent #ED8B2D

    init(session: LearningSession) {
        self.session = session
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if session?.isAnnotating == true { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let session, session.isAnnotating, !session.isCapturing else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        session.updateDraft(AnnotationMark(tool: session.tool, points: [point, point]))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let session, let start = dragStart, var mark = session.draft else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch mark.tool {
        case .box, .arrow: mark.points = [start, point]
        case .freehand:    mark.points.append(point)
        }
        session.updateDraft(mark)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        session?.commitDraft()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let session else { return }
        window?.invalidateCursorRects(for: self)
        for mark in session.marks + [session.draft].compactMap({ $0 }) {
            Self.render(mark)
        }
    }

    /// Draws `marks` onto a screenshot, in the overlay's point space.
    static func composite(_ marks: [AnnotationMark], onto image: CGImage, pointSize: CGSize) -> CGImage {
        guard !marks.isEmpty, pointSize.width > 0 else { return image }
        // The capture's own color space keeps colors exact; it may not be a
        // valid 8-bit bitmap target, so fall back to sRGB.
        let spaces = [image.colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        guard let context = spaces.lazy.compactMap({
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: $0, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        }).first else {
            tomLog("Learning: could not draw marks onto the screenshot")
            return image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let scale = CGFloat(image.width) / pointSize.width
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        marks.forEach(render)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage() ?? image
    }

    private static func render(_ mark: AnnotationMark) {
        strokeColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = mark.points.first, let last = mark.points.last else { return }
        switch mark.tool {
        case .box:
            path.appendRoundedRect(mark.bounds, xRadius: 4, yRadius: 4)
        case .arrow:
            path.move(to: first)
            path.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            for side in [CGFloat.pi * 0.83, -CGFloat.pi * 0.83] {
                path.move(to: last)
                path.line(to: CGPoint(x: last.x + 16 * cos(angle + side), y: last.y + 16 * sin(angle + side)))
            }
        case .freehand:
            path.move(to: first)
            mark.points.dropFirst().forEach { path.line(to: $0) }
        }
        path.stroke()
        drawLabel(mark)
    }

    private static func labelText(_ mark: AnnotationMark) -> NSAttributedString? {
        guard let label = mark.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        return NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
    }

    /// Where a mark's label pill goes: above its top-left corner, or below
    /// the mark when there's no room above. nil without a label.
    static func labelFrame(for mark: AnnotationMark) -> CGRect? {
        guard let text = labelText(mark) else { return nil }
        let size = text.size()
        let bounds = mark.bounds
        let y = bounds.minY - size.height - 10 >= 0 ? bounds.minY - size.height - 10 : bounds.maxY + 6
        return CGRect(x: bounds.minX, y: y, width: size.width + 12, height: size.height + 4)
    }

    private static func drawLabel(_ mark: AnnotationMark) {
        guard let text = labelText(mark), let pill = labelFrame(for: mark) else { return }
        strokeColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2))
    }
}

// MARK: - HUD

/// Floating control bar for a Learning session: timer, Annotate / Mark,
/// Stop; while annotating it swaps to the drawing tools and label field.
private struct LearningHUD: View {
    @ObservedObject var session: LearningSession

    var body: some View {
        HStack(spacing: 10) {
            if session.isAnnotating {
                annotatingControls
            } else {
                idleControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.11))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
        )
        .foregroundStyle(Color(white: 0.95))
        .font(.system(size: 12, weight: .medium))
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { session.resizeHUD(to: $0) }
        .environment(\.colorScheme, .dark)
    }

    private var idleControls: some View {
        Group {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text(formatDuration(session.elapsed(at: context.date)))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
            }
            divider
            hudButton("Annotate", systemImage: "pencil.tip", shortcut: "⌥A") { session.toggleAnnotate() }
                .disabled(session.isCapturing)
            hudButton("Mark", systemImage: "bookmark", shortcut: "⌥M") { session.addMarker() }
                .disabled(session.isCapturing)
            if session.annotationCount > 0 {
                Text("\(session.annotationCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accent.opacity(0.25)))
                    .help("Annotations saved")
            }
            divider
            Button {
                session.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
        }
    }

    private var annotatingControls: some View {
        Group {
            ForEach(AnnotationMark.Tool.allCases, id: \.self) { tool in
                Button {
                    session.tool = tool
                } label: {
                    Image(systemName: Self.icon(tool))
                        .frame(width: 26, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(session.tool == tool ? Color.accent.opacity(0.35) : .clear))
                }
                .buttonStyle(.plain)
                .help(tool.rawValue.capitalized)
            }
            divider
            TextField("Label last mark", text: Binding(get: { session.lastLabel }, set: { session.lastLabel = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .disabled(session.marks.isEmpty)
            Button { session.undoLastMark() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain)
                .disabled(session.marks.isEmpty)
                .help("Undo last mark")
            divider
            hudButton("Finish", systemImage: "checkmark", shortcut: "⌥A") { session.toggleAnnotate() }
                .disabled(session.isCapturing)
            Button("Cancel") { session.cancelRound() }
                .buttonStyle(.plain)
                .foregroundStyle(Color(white: 0.6))
                .help("Discard this annotation (Esc)")
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 16)
    }

    private func hudButton(_ title: LocalizedStringKey, systemImage: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
                Text(shortcut).foregroundStyle(Color(white: 0.55))
            }
        }
        .buttonStyle(.plain)
    }

    private static func icon(_ tool: AnnotationMark.Tool) -> String {
        switch tool {
        case .box:      "rectangle"
        case .arrow:    "arrow.up.right"
        case .freehand: "scribble"
        }
    }
}
