import SwiftUI
import AppKit
import MacHostCore

extension KeyEquivalent {
    static let f3Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF3FunctionKey))!))
    static let f5Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF5FunctionKey))!))
    static let f6Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF6FunctionKey))!))
    static let f7Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF7FunctionKey))!))
    static let f8Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF8FunctionKey))!))
}

@main
struct MacFileManagerApp: App {
    @StateObject private var viewModel = DualPaneViewModel()

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Действия") {
                Button("Сменить панель (Tab)") {
                    viewModel.toggleActivePane()
                }
                .keyboardShortcut(.tab, modifiers: [])

                Button("Просмотр (Пробел)") {
                    viewModel.triggerQuickLook()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Просмотр (F3)") {
                    viewModel.triggerQuickLook()
                }
                .keyboardShortcut(.f3Key, modifiers: [])

                Button("Копировать (F5)") {
                    viewModel.triggerCopy()
                }
                .keyboardShortcut(.f5Key, modifiers: [])

                Button("Переместить (F6)") {
                    viewModel.triggerMove()
                }
                .keyboardShortcut(.f6Key, modifiers: [])

                Button("Новая папка (F7)") {
                    viewModel.showNewFolderDialog = true
                }
                .keyboardShortcut(.f7Key, modifiers: [])

                Button("Удалить (F8)") {
                    viewModel.triggerDelete()
                }
                .keyboardShortcut(.f8Key, modifiers: [])
                
                Button("Поменять панели местами (Cmd+U)") {
                    viewModel.swapPanes()
                }
                .keyboardShortcut("u", modifiers: [.command])
                
                Button("Перейти вверх (Backspace)") {
                    viewModel.navigateUp()
                }
                .keyboardShortcut(.delete, modifiers: [])
            }
        }
    }
}
