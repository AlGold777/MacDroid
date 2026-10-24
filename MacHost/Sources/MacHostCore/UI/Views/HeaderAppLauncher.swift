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
            ("com.google.GeminiMacOS", "Gemini", ["Gemini.app"])
        ]
        return definitions.compactMap { id, name, filenames in
            let roots = [URL(fileURLWithPath: "/Applications"),
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
    @ObservedObject var vm: DualPaneViewModel
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

    var body: some View {
        // Reserve the right-hand toolbar's width; overflow goes immediately before refresh.
        let rightCount = min(apps.count, max(0, Int((windowWidth / 2 - 430) / 26)))
        let right = Array(orderedApps.prefix(rightCount))
        let left = Array(orderedApps.dropFirst(rightCount))
        HStack(spacing: 2) {
            icons(left)
            TopToolbarCenterSplitResetButton(vm: vm)
            icons(right)
        }
        .fixedSize()
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            apps = HeaderLaunchApp.installed()
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
            }, move: { id in
                var ids = orderedApps.map(\.id)
                guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: app.id), from != to else { return }
                ids.remove(at: from)
                ids.insert(id, at: to)
                savedOrder = ids.joined(separator: "|")
            })
            .frame(width: 24, height: 28)
        }
    }
}

/// Native event handling distinguishes a click from a drag before NSButton starts tracking.
private struct HeaderAppIcon: NSViewRepresentable {
    let app: HeaderLaunchApp
    let launch: () -> Void
    let move: (String) -> Void

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
    var move: ((String) -> Void)?
    private var mouseDownPoint: NSPoint?
    private var isDraggingIcon = false
    private weak var dropTarget: HeaderAppIconButton?

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
        dropTarget?.highlight(false)
        dropTarget = target(at: event.locationInWindow)
        dropTarget?.highlight(true)
    }

    override func mouseUp(with event: NSEvent) {
        let destination = target(at: event.locationInWindow)
        let wasDragging = isDraggingIcon
        let hadMouseDown = mouseDownPoint != nil
        highlight(false)
        dropTarget?.highlight(false)
        dropTarget = nil
        alphaValue = 1
        mouseDownPoint = nil
        isDraggingIcon = false
        NSCursor.arrow.set()
        if wasDragging {
            destination?.move?(appID)
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
               button !== self, button.bounds.contains(button.convert(point, from: nil)) {
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
