import SwiftUI
import AppKit
import MacHostCore

extension KeyEquivalent {
    static let f2Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF2FunctionKey))!))
    static let f3Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF3FunctionKey))!))
    static let f5Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF5FunctionKey))!))
    static let f6Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF6FunctionKey))!))
    static let f7Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF7FunctionKey))!))
    static let f8Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF8FunctionKey))!))
}

@main
struct MacFileManagerApp: App {
    @StateObject private var viewModel = DualPaneViewModel()

    init() {
        KeyCommandMonitor.installGlobalMonitor()
    }

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .toolbar) {
                Divider()
                
                Toggle("Показывать скрытые файлы", isOn: Binding(
                    get: {
                        viewModel.activePane == .left ? viewModel.leftShowHidden : viewModel.rightShowHidden
                    },
                    set: { _ in
                        viewModel.toggleShowHidden(side: viewModel.activePane)
                    }
                ))
                .keyboardShortcut(".", modifiers: [.command, .shift])
                
                Toggle("Скрытые файлы: левая панель", isOn: Binding(
                    get: { viewModel.leftShowHidden },
                    set: { _ in viewModel.toggleShowHidden(side: .left) }
                ))
                
                Toggle("Скрытые файлы: правая панель", isOn: Binding(
                    get: { viewModel.rightShowHidden },
                    set: { _ in viewModel.toggleShowHidden(side: .right) }
                ))
                
                Divider()
                
                Toggle("Быстрый просмотр (Quick View)", isOn: Binding(
                    get: { viewModel.isQuickViewActive },
                    set: { _ in viewModel.toggleQuickView() }
                ))
                .keyboardShortcut("q", modifiers: [.control])
                
                Toggle("Сравнение панелей", isOn: Binding(
                    get: { viewModel.isComparing },
                    set: { _ in viewModel.comparePanes() }
                ))
                .keyboardShortcut("d", modifiers: [.command])
                
                Divider()
                
                Button("Обновить панель (Cmd+R)") {
                    viewModel.refreshPane(side: viewModel.activePane)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            
            CommandMenu("Переход") {
                Button("Домой (Cmd+Shift+H)") {
                    viewModel.navigateToHome()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                
                Button("Рабочий стол (Cmd+Shift+K)") {
                    viewModel.navigateToDesktop()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                
                Button("Загрузки (Cmd+Alt+L)") {
                    viewModel.navigateToDownloads()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                
                Divider()
                
                Button("Перейти вверх (Backspace)") {
                    viewModel.navigateUp()
                }
                .keyboardShortcut(.delete, modifiers: [])
                
                Button("Ввести путь вручную (Cmd+L)") {
                    viewModel.startEditingPath(side: viewModel.activePane)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }
            
            CommandMenu("Действия") {
                Button("Открыть (Return)") {
                    viewModel.openSelected()
                }
                .keyboardShortcut(.return, modifiers: [])

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

                Button("Создать архив (Alt+F5)") {
                    viewModel.triggerCreateArchive()
                }
                .keyboardShortcut(.f5Key, modifiers: [.option])

                Button("Переместить (F6)") {
                    viewModel.triggerMove()
                }
                .keyboardShortcut(.f6Key, modifiers: [])

                Button("Переименовать (F2)") {
                    viewModel.triggerRename()
                }
                .keyboardShortcut(.f2Key, modifiers: [])

                Button("Новая папка (F7)") {
                    viewModel.showNewFolderDialog = true
                }
                .keyboardShortcut(.f7Key, modifiers: [])

                Button("Удалить (F8)") {
                    viewModel.triggerDelete()
                }
                .keyboardShortcut(.f8Key, modifiers: [])
                
                Button("Свойства (Cmd+I)") {
                    viewModel.triggerProperties()
                }
                .keyboardShortcut("i", modifiers: [.command])
                
                Button("Назад (Cmd+[)") {
                    viewModel.navigateBack(side: viewModel.activePane)
                }
                .keyboardShortcut("[", modifiers: [.command])
                
                Button("Вперёд (Cmd+])") {
                    viewModel.navigateForward(side: viewModel.activePane)
                }
                .keyboardShortcut("]", modifiers: [.command])
                
                Button("Инвертировать выделение (Cmd+Shift+A)") {
                    viewModel.invertSelection()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                
                Button("Выделить всё (Cmd+A)") {
                    viewModel.selectAll()
                }
                .keyboardShortcut("a", modifiers: [.command])
                
                Button("Выделить всё (Ctrl+A)") {
                    viewModel.selectAll()
                }
                .keyboardShortcut("a", modifiers: [.control])
                
                Button("Копировать в буфер (Cmd+C)") {
                    viewModel.copyToClipboard()
                }
                .keyboardShortcut("c", modifiers: [.command])
                
                Button("Вставить из буфера (Cmd+V)") {
                    viewModel.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: [.command])
                
                Button("Вставить из буфера (Ctrl+V)") {
                    viewModel.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: [.control])
                
                Button("Дублировать (Cmd+Shift+D)") {
                    viewModel.duplicateItem()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                
                Button("Ввести путь вручную (Cmd+L)") {
                    viewModel.startEditingPath(side: viewModel.activePane)
                }
                .keyboardShortcut("l", modifiers: [.command])
                
                Button("Поменять панели местами (Cmd+U)") {
                    viewModel.swapPanes()
                }
                .keyboardShortcut("u", modifiers: [.command])
                
                Button("Сравнить каталоги (Cmd+D)") {
                    viewModel.comparePanes()
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Быстрый просмотр / Просмотрщик (Ctrl+Q)") {
                    viewModel.toggleQuickView()
                }
                .keyboardShortcut("q", modifiers: [.control])
                
                Button("Групповое переименование (Ctrl+M)") {
                    viewModel.triggerBatchRename()
                }
                .keyboardShortcut("m", modifiers: [.control])
                
                Button("Поиск файлов (Cmd+F)") {
                    viewModel.showSearchDialog = true
                }
                .keyboardShortcut("f", modifiers: [.command])
                
                Button("Очередь передач (Cmd+J)") {
                    viewModel.showQueueDialog = true
                }
                .keyboardShortcut("j", modifiers: [.command])
                
                Button("Перейти вверх (Backspace)") {
                    viewModel.navigateUp()
                }
                .keyboardShortcut(.delete, modifiers: [])
                
                Divider()
                
                Button("Сопряжение / Подключение телефона (Cmd+Shift+P)") {
                    viewModel.showPairingDialog = true
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}
