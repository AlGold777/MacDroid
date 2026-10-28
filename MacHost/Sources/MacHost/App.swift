import SwiftUI
import AppKit
import MacHostCore
import Darwin

extension KeyEquivalent {
    static let f2Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF2FunctionKey))!))
    static let f3Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF3FunctionKey))!))
    static let f5Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF5FunctionKey))!))
    static let f6Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF6FunctionKey))!))
    static let f7Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF7FunctionKey))!))
    static let f8Key = KeyEquivalent(Character(Unicode.Scalar(Int(NSF8FunctionKey))!))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(0, forKey: "NSInitialToolTipDelay")
        updateAppMenuTitle()
        configureWindows()
    }
    
    func configureWindows() {
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.titleVisibility = .hidden
            }
        }
    }

    func updateAppMenuTitle() {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            let title = "MacDroid Commander \(version)"
            if let firstItem = NSApp.mainMenu?.items.first {
                firstItem.title = title
                firstItem.submenu?.title = title
            }
        }
    }
}

@main
struct MacFileManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = DualPaneViewModel()

    init() {
        signal(SIGPIPE, SIG_IGN)
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        UserDefaults.standard.set(0, forKey: "NSInitialToolTipDelay")
        KeyCommandMonitor.installGlobalMonitor()
    }

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear {
                    DualPaneViewModel.shared = viewModel
                    KeyCommandMonitor.activeViewModel = viewModel
                    KeyCommandMonitor.installGlobalMonitor()
                    appDelegate.updateAppMenuTitle()
                    appDelegate.configureWindows()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Найти точные дубликаты…") {
                    viewModel.showDuplicateFinder = true
                }
            }

            CommandGroup(after: .toolbar) {
                Picker("Режим панелей", selection: Binding(
                    get: { viewModel.panelLayoutMode },
                    set: { viewModel.setPanelLayoutMode($0) }
                )) {
                    Text("Двухпанельный режим (T)").tag(PanelLayoutMode.dual)
                    Text("Режим Finder с боковой панелью (F)").tag(PanelLayoutMode.finder)
                }
                
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
                
                Toggle("Сравнение файлов", isOn: Binding(
                    get: { viewModel.isFileDiffActive },
                    set: { _ in viewModel.triggerFileDiff() }
                ))
                
                Divider()
                
                Button("Обновить активную вкладку (Cmd+R)") {
                    viewModel.refreshPaneToActiveTab(side: viewModel.activePane)
                }
                .keyboardShortcut("r", modifiers: [.command])
                
                Button("Сбросить кэш эскизов") {
                    ThumbnailCacheManager.shared.clearCache()
                }
                
                Divider()
                
                Button("Настройки пути...") {
                    viewModel.showPathDisplaySettings = true
                }
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
                
                Button("Перейти вверх (Cmd+↑)") {
                    viewModel.navigateUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                
                Button("Ввести путь вручную (Cmd+L)") {
                    viewModel.startEditingPath(side: viewModel.activePane)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }
            
            CommandMenu("Действия") {
                Button("Открыть (Return)") {
                    viewModel.openSelected()
                }

                Button("Сменить панель (Tab)") {
                    viewModel.toggleActivePane()
                }
                .keyboardShortcut(.tab, modifiers: [])

                Button("Новая вкладка (Cmd+T)") {
                    viewModel.addTab(side: viewModel.activePane)
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("Новая вкладка (Ctrl+T)") {
                    viewModel.addTab(side: viewModel.activePane)
                }
                .keyboardShortcut("t", modifiers: [.control])

                Button("Обновить активную вкладку (Ctrl+R)") {
                    viewModel.refreshPaneToActiveTab(side: viewModel.activePane)
                }
                .keyboardShortcut("r", modifiers: [.control])

                Button("Просмотр (F3 / Пробел)") {
                    viewModel.triggerQuickLook(preferNativeQuickLook: true)
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

                Button("Распаковать выбранный архив полностью") {
                    let items = viewModel.activePane == .left ? viewModel.leftItems : viewModel.rightItems
                    let selection = viewModel.activePane == .left ? viewModel.leftSelection : viewModel.rightSelection
                    if selection.count == 1, let item = items.first(where: { selection.contains($0.id) || selection.contains($0.path) }),
                       !item.isDirectory, ArchiveService.isArchive(fileName: item.name) {
                        viewModel.unarchive(item: item, side: viewModel.activePane)
                    } else {
                        viewModel.statusMessage = "Выберите один архив для полной распаковки"
                    }
                }

                Button("Переместить (F6)") {
                    viewModel.triggerMove()
                }
                .keyboardShortcut(.f6Key, modifiers: [])

                Button("Переименовать (F2)") {
                    viewModel.triggerRename()
                }
                .keyboardShortcut(.f2Key, modifiers: [])

                Button("Новая папка (F7)") {
                    viewModel.prepareNewFolder()
                }
                .keyboardShortcut(.f7Key, modifiers: [])

                Button("Удалить (F8 / Delete)") {
                    viewModel.triggerDelete()
                }
                .keyboardShortcut(.f8Key, modifiers: [])

                Button("Удалить в корзину (Cmd+Delete)") {
                    if !KeyCommandMonitor.isTextEditingActive(in: viewModel) {
                        viewModel.triggerDelete()
                    }
                }
                .keyboardShortcut(.delete, modifiers: [.command])

                Button("Корзина телефона…") {
                    viewModel.openPhoneTrash()
                }
                .disabled(viewModel.isPhoneTrashBusy)

                Button("Найти точные дубликаты…") {
                    viewModel.showDuplicateFinder = true
                }
                
                Button("Свойства (Cmd+I)") {
                    viewModel.triggerProperties()
                }
                .keyboardShortcut("i", modifiers: [.command])
                
                Button("Свойства (Ctrl+I)") {
                    viewModel.triggerProperties()
                }
                .keyboardShortcut("i", modifiers: [.control])
                
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
                    if !KeyCommandMonitor.performTextShortcut(keyCode: 0) {
                        viewModel.selectAll()
                    }
                }
                .keyboardShortcut("a", modifiers: [.command])
                
                Button("Выделить всё (Ctrl+A)") {
                    if !KeyCommandMonitor.performTextShortcut(keyCode: 0) {
                        viewModel.selectAll()
                    }
                }
                .keyboardShortcut("a", modifiers: [.control])
                
                Button("Копировать в буфер (Cmd+C)") {
                    if !KeyCommandMonitor.performTextShortcut(keyCode: 8) {
                        viewModel.copyToClipboard()
                    }
                }
                .keyboardShortcut("c", modifiers: [.command])
                
                Button("Копировать в буфер (Ctrl+C)") {
                    if !KeyCommandMonitor.performTextShortcut(keyCode: 8) {
                        viewModel.copyToClipboard()
                    }
                }
                .keyboardShortcut("c", modifiers: [.control])
                
                Button("Скопировать полный путь (Shift+Ctrl+Cmd+C)") {
                    viewModel.copySelectedPath()
                }
                .keyboardShortcut("c", modifiers: [.command, .control, .shift])

                Button("Скопировать имя (Cmd+Shift+C)") {
                    viewModel.copySelectedNamesToClipboard()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                
                Button("Вставить из буфера (Cmd+V)") {
                    if !KeyCommandMonitor.performTextShortcut(keyCode: 9) {
                        viewModel.pasteFromClipboard()
                    }
                }
                .keyboardShortcut("v", modifiers: [.command])
                
                Button("Вставить из буфера (Ctrl+V)") {
                    if !KeyCommandMonitor.performTextShortcut(keyCode: 9) {
                        viewModel.pasteFromClipboard()
                    }
                }
                .keyboardShortcut("v", modifiers: [.control])

                Button("Вырезать (Cmd+X)") {
                    if !KeyCommandMonitor.performTextShortcut(keyCode: 7) {
                        viewModel.cutToClipboard()
                    }
                }
                .keyboardShortcut("x", modifiers: [.command])

                Button("Вырезать (Ctrl+X)") {
                    if !KeyCommandMonitor.performTextShortcut(keyCode: 7) {
                        viewModel.cutToClipboard()
                    }
                }
                .keyboardShortcut("x", modifiers: [.control])
                
                Button("Дублировать (Cmd+Shift+D)") {
                    viewModel.duplicateItem()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                
                Button("Поменять панели местами (Cmd+U)") {
                    viewModel.swapPanes()
                }
                .keyboardShortcut("u", modifiers: [.command])
                
                Button("Сортировка папок: раздельно / вместе (Finder)") {
                    viewModel.toggleFolderSortMode(for: viewModel.activePane)
                }
                
                Button("Сравнить каталоги (Cmd+D)") {
                    viewModel.comparePanes()
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Групповое переименование (Ctrl+M)") {
                    viewModel.triggerBatchRename()
                }
                .keyboardShortcut("m", modifiers: [.control])
                
                Button("Поиск файлов (Cmd+F)") {
                    viewModel.openSearch(side: viewModel.activePane)
                }
                .keyboardShortcut("f", modifiers: [.command])
                
                Button("Фильтр файлов (Cmd+Shift+F)") {
                    viewModel.toggleFilter()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                
                Button("Очередь передач (Cmd+J)") {
                    viewModel.showQueueDialog = true
                }
                .keyboardShortcut("j", modifiers: [.command])
                
                Divider()
                
                Button("Сопряжение / Подключение телефона (Cmd+Shift+P)") {
                    viewModel.showPairingDialog = true
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}
