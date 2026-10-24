import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
            Button {
                NSWorkspace.shared.openApplication(at: app.url, configuration: .init()) { _, error in
                    if let error {
                        DispatchQueue.main.async { launchError = "\(app.name): \(error.localizedDescription)" }
                    }
                }
            } label: {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Открыть \(app.name)")
            .help("\(app.name) — открыть. Перетащите на другую иконку, чтобы изменить порядок.")
            .onDrag {
                NSItemProvider(item: app.id as NSString, typeIdentifier: Self.dragType.identifier)
            }
            .onDrop(of: [Self.dragType], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: Self.dragType.identifier, options: nil) { item, _ in
                    let id: String?
                    if let data = item as? Data { id = String(data: data, encoding: .utf8) }
                    else { id = item as? String }
                    guard let id else { return }
                    DispatchQueue.main.async {
                        var ids = orderedApps.map(\.id)
                        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: app.id), from != to else { return }
                        ids.remove(at: from)
                        ids.insert(id, at: to)
                        savedOrder = ids.joined(separator: "|")
                    }
                }
                return true
            }
        }
    }

    private static let dragType = UTType(exportedAs: "com.macandroid.MacDroidCommander.header-app")
}
