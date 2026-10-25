import AppKit
import Darwin
import Foundation
import MacHostCore

private struct ArchiveInteractionTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ArchiveInteractionTestFailure(description: message) }
    print("  ✓ \(message)")
}

@MainActor
private func runQuickLookLifecycleTests() throws {
    print("\n[ArchiveInteractionTests] QuickLookBridge lifecycle")

    let bridge = QuickLookBridge.shared
    bridge.close()
    bridge.onNavigateNext = nil
    bridge.onNavigatePrevious = nil

    let firstURL = URL(fileURLWithPath: "/tmp/archive-preview-first.txt")
    let secondURL = URL(fileURLWithPath: "/tmp/archive-preview-second.txt")
    let thirdURL = URL(fileURLWithPath: "/tmp/archive-preview-third.txt")

    // Existing call sites omit onClose. Keep all three established entry points usable.
    bridge.preview(url: firstURL)
    try check(bridge.currentPreviewURL == firstURL,
              "The existing preview(url:) call stores the requested URL")
    bridge.updatePreview(url: firstURL, title: "same file")
    try check(bridge.currentPreviewURL == firstURL,
              "The existing updatePreview(url:title:) call remains compatible")
    bridge.close()
    try check(bridge.currentPreviewURL == nil && bridge.currentPreviewItem == nil,
              "The existing close() call clears Quick Look state")

    var cleanupEvents: [String] = []
    bridge.preview(url: firstURL, onClose: { cleanupEvents.append("first") })
    bridge.updatePreview(url: firstURL, title: "same URL, new title")
    try check(cleanupEvents.isEmpty && bridge.currentPreviewURL == firstURL,
              "Updating the same URL preserves its active preview without cleanup")

    bridge.updatePreview(url: secondURL)
    try check(cleanupEvents == ["first"] && bridge.currentPreviewURL == secondURL,
              "Updating to another URL invokes the previous cleanup exactly once")

    bridge.preview(url: secondURL, onClose: { cleanupEvents.append("second") })
    try check(cleanupEvents == ["first"],
              "Previewing the same URL can attach cleanup without closing that preview")

    bridge.preview(url: thirdURL, title: "replacement", onClose: { cleanupEvents.append("third") })
    try check(cleanupEvents == ["first", "second"] && bridge.currentPreviewURL == thirdURL,
              "Replacing a preview through preview(url:) closes only the previous session")

    bridge.close()
    try check(cleanupEvents == ["first", "second", "third"] && bridge.currentPreviewURL == nil,
              "Explicit close invokes the active cleanup and clears state")
    bridge.close()
    try check(cleanupEvents == ["first", "second", "third"],
              "Repeated close does not invoke a cleanup more than once")
}

Task { @MainActor in
    do {
        try runQuickLookLifecycleTests()
        print("\n[ArchiveInteractionTests] All lifecycle checks passed.")
        exit(0)
    } catch {
        fputs("❌ [ArchiveInteractionTests] \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
