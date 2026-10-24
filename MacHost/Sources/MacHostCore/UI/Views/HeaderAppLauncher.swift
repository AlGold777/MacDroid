import AppKit
import SwiftUI

/// Only installed desktop apps participate; stable IDs preserve order across moves and installs.
struct HeaderLaunchApp: Identifiable {
    let id: String
    let name: String
    let url: URL
    let icon: NSImage

    static func installed() -> [HeaderLaunchApp] {
        let definitions: [(String, String, [String])] = [
            ("com.openai.codex", "Codex", ["Codex.app", "ChatGPT.app"]),
            ("com.anthropic.claudefordesktop", "Claude", ["Claude.app"]),
            ("com.google.Chrome", "Chrome", ["Google Chrome.app"]),
            ("com.tdesktop.Telegram", "Telegram", ["Telegram.app"]),
            ("net.whatsapp.WhatsApp", "WhatsApp", ["WhatsApp.app"]),
            ("com.linguee.DeepLCopyTranslator", "DeepL", ["DeepL.app"]),
            ("notion.id", "Notion", ["Notion.app"]),
            ("com.google.GeminiMacOS", "Gemini", ["Gemini.app"]),
            ("com.microsoft.VSCode", "Visual Studio Code", ["Visual Studio Code.app"]),
            ("com.apple.Notes", "Заметки", ["Notes.app"]),
            ("com.apple.systempreferences", "Системные настройки", ["System Settings.app"])
        ]
        return definitions.compactMap { id, name, filenames in
            let roots = [URL(fileURLWithPath: "/Applications"),
                         URL(fileURLWithPath: "/System/Applications"),
                         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                ?? roots.flatMap { root in filenames.map { root.appendingPathComponent($0) } }
                    .first { Bundle(url: $0)?.bundleIdentifier == id }
            guard let url else { return nil }
            return HeaderLaunchApp(id: id, name: name, url: url,
                                   icon: NSWorkspace.shared.icon(forFile: url.path))
        }
    }
}

struct HeaderAppLauncher: View {
    let windowWidth: CGFloat
    @AppStorage("headerAppLauncherOrder") private var savedOrder = ""
    @State private var apps = HeaderLaunchApp.installed()
    @State private var launchError: String?

    private var orderedApps: [HeaderLaunchApp] {
        let ids = savedOrder.split(separator: "|").map(String.init)
        let defaults = apps.map(\.id)
        return apps.sorted { lhs, rhs in
            let left = ids.firstIndex(of: lhs.id) ?? (ids.count + (defaults.firstIndex(of: lhs.id) ?? 0))
            let right = ids.firstIndex(of: rhs.id) ?? (ids.count + (defaults.firstIndex(of: rhs.id) ?? 0))
            return left < right
        }
    }

    private var rightCount: Int {
        min(apps.count, max(0, Int((windowWidth / 2 - 430) / 26)))
    }

    private var displayedApps: [HeaderLaunchApp] {
        let ordered = orderedApps
        return Array(ordered.dropFirst(rightCount)) + Array(ordered.prefix(rightCount))
    }

    /// Append newly available apps to the visible right edge without disturbing saved positions.
    private func appendNewApps() {
        guard windowWidth > 0 else { return }
        let known = Set(savedOrder.split(separator: "|").map(String.init))
        let added = orderedApps.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return }
        let existing = orderedApps.filter { known.contains($0.id) }
        let previousRightCount = min(rightCount, existing.count)
        let visible = Array(existing.dropFirst(previousRightCount)) + Array(existing.prefix(previousRightCount)) + added
        let ids = visible.map(\.id)
        let stored = Array(ids.suffix(rightCount)) + Array(ids.dropLast(rightCount))
        savedOrder = stored.joined(separator: "|")
    }

    var body: some View {
        HStack(spacing: 2) {
            icons(displayedApps)
        }
        .fixedSize()
        .onAppear { appendNewApps() }
        .onChange(of: windowWidth) { _, _ in appendNewApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            apps = HeaderLaunchApp.installed()
            appendNewApps()
        }
        .alert("Не удалось открыть приложение", isPresented: Binding(
            get: { launchError != nil }, set: { if !$0 { launchError = nil } }
        )) { Button("OK") { launchError = nil } } message: { Text(launchError ?? "") }
    }

    private func icons(_ items: [HeaderLaunchApp]) -> some View {
        ForEach(items) { app in
            HeaderAppIcon(app: app, launch: {
                NSWorkspace.shared.openApplication(at: app.url, configuration: .init()) { _, error in
                    if let error {
                        DispatchQueue.main.async { launchError = "\(app.name): \(error.localizedDescription)" }
                    }
                }
            }, move: { id, before in
                var ids = displayedApps.map(\.id)
                guard id != app.id, let from = ids.firstIndex(of: id) else { return }
                ids.remove(at: from)
                guard let target = ids.firstIndex(of: app.id) else { return }
                ids.insert(id, at: target + (before ? 0 : 1))
                // Undo the display rotation so the exact indicated slot survives a redraw.
                let stored = Array(ids.suffix(rightCount)) + Array(ids.dropLast(rightCount))
                savedOrder = stored.joined(separator: "|")
            })
            .frame(width: 24, height: 28)
        }
    }
}

/// Native event handling distinguishes a click from a drag before NSButton starts tracking.
private struct HeaderAppIcon: NSViewRepresentable {
    let app: HeaderLaunchApp
    let launch: () -> Void
    let move: (String, Bool) -> Void

    func makeNSView(context: Context) -> HeaderAppIconButton {
        let button = HeaderAppIconButton(frame: NSRect(x: 0, y: 0, width: 24, height: 28))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        return button
    }

    func updateNSView(_ button: HeaderAppIconButton, context: Context) {
        button.appID = app.id
        let icon = app.icon.copy() as! NSImage
        icon.size = NSSize(width: 22, height: 22)
        button.image = icon
        button.toolTip = "\(app.name) — открыть. Перетащите на другую иконку, чтобы изменить порядок."
        button.setAccessibilityLabel("Открыть \(app.name)")
        button.launch = launch
        button.move = move
        button.target = button
        button.action = #selector(HeaderAppIconButton.openApp)
    }
}

private final class HeaderAppIconButton: NSButton {
    var appID = ""
    var launch: (() -> Void)?
    var move: ((String, Bool) -> Void)?
    private var mouseDownPoint: NSPoint?
    private var isDraggingIcon = false
    private weak var dropTarget: HeaderAppIconButton?
    private var insertionBefore: Bool? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let before = insertionBefore {
            NSColor.systemBlue.setFill()
            let marker = NSRect(x: before ? bounds.minX : bounds.maxX - 2,
                                y: bounds.minY + 2, width: 2, height: max(0, bounds.height - 4))
            NSBezierPath(roundedRect: marker, xRadius: 1, yRadius: 1).fill()
        }
    }

    @objc func openApp() { launch?() }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        isDraggingIcon = false
        highlight(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard isDraggingIcon || hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        isDraggingIcon = true
        highlight(false)
        alphaValue = 0.5
        NSCursor.closedHand.set()
        dropTarget?.insertionBefore = nil
        dropTarget = target(at: event.locationInWindow)
        if let destination = dropTarget {
            destination.insertionBefore = destination.convert(event.locationInWindow, from: nil).x < destination.bounds.midX
        }
    }

    override func mouseUp(with event: NSEvent) {
        let destination = target(at: event.locationInWindow)
        let wasDragging = isDraggingIcon
        let hadMouseDown = mouseDownPoint != nil
        highlight(false)
        dropTarget?.insertionBefore = nil
        dropTarget = nil
        alphaValue = 1
        mouseDownPoint = nil
        isDraggingIcon = false
        NSCursor.arrow.set()
        if wasDragging {
            if let destination {
                let before = destination.convert(event.locationInWindow, from: nil).x < destination.bounds.midX
                destination.move?(appID, before)
            }
        } else if hadMouseDown, bounds.contains(convert(event.locationInWindow, from: nil)) {
            performClick(nil)
        }
    }

    /// Keep this drag local to the header; dropping outside an app icon cancels it.
    private func target(at point: NSPoint) -> HeaderAppIconButton? {
        var root: NSView = self
        while let parent = root.superview { root = parent }
        func find(in view: NSView) -> HeaderAppIconButton? {
            if let button = view as? HeaderAppIconButton,
               button !== self, button.bounds.insetBy(dx: -1, dy: 0).contains(button.convert(point, from: nil)) {
                return button
            }
            for child in view.subviews {
                if let found = find(in: child) { return found }
            }
            return nil
        }
        return find(in: root)
    }
}
