    public func moveTab(fromIndex: Int, toIndex: Int, side: PaneSide) {
        if side == .left {
            guard fromIndex >= 0 && fromIndex < leftTabs.count,
                  toIndex >= 0 && toIndex < leftTabs.count,
                  fromIndex != toIndex else { return }
            let item = leftTabs.remove(at: fromIndex)
            leftTabs.insert(item, at: toIndex)
            saveSession()
        } else {
            guard fromIndex >= 0 && fromIndex < rightTabs.count,
                  toIndex >= 0 && toIndex < rightTabs.count,
                  fromIndex != toIndex else { return }
            let item = rightTabs.remove(at: fromIndex)
            rightTabs.insert(item, at: toIndex)
            saveSession()
        }
    }
    
    // MARK: - Tabs Export & Import (JSON)
    
    /// Экспорт всех открытых вкладок обеих панелей со статусом закрепления в JSON-файл
    public func exportTabsToFile(url: URL) throws {
        updateActiveTab(side: .left)
        updateActiveTab(side: .right)
        
        let exportData = TabsExportData(
            leftTabs: leftTabs,
            rightTabs: rightTabs,
            leftActiveTabId: leftActiveTabId,
            rightActiveTabId: rightActiveTabId
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(exportData)
        try data.write(to: url, options: .atomic)
        statusMessage = "Вкладки сохранены: \(url.lastPathComponent)"
    }
    
    /// Валидация пути и названия вкладки для безопасного импорта
    private func sanitizeImportedTab(_ tab: PanelTab) -> PanelTab {
        var validPath = tab.path
        if tab.source == .localMac {
            if validPath.hasPrefix("/storage") || !FileManager.default.fileExists(atPath: validPath) {
                validPath = FileManager.default.homeDirectoryForCurrentUser.path
            }
        } else {
            if !validPath.hasPrefix("/storage") {
                validPath = "/storage/emulated/0"
            }
        }
        let title = tab.title.isEmpty ? (URL(fileURLWithPath: validPath).lastPathComponent) : tab.title
        return PanelTab(
            id: tab.id,
            title: (title.isEmpty || validPath == "/") ? "⌂" : title,
            path: validPath,
            source: tab.source,
            isPinned: tab.isPinned
        )
    }
    
    /// Импорт вкладок из JSON-файла:
    /// - .replace: полностью замещает существующие вкладки в обеих панелях
    /// - .append: добавляет импортированные вкладки к существующим (с уникальными новыми id)
    public func importTabsFromFile(url: URL, mode: TabImportMode) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let imported = try decoder.decode(TabsExportData.self, from: data)
        
        switch mode {
        case .replace:
            let sanitizedLeft = imported.leftTabs.map { sanitizeImportedTab($0) }
            let sanitizedRight = imported.rightTabs.map { sanitizeImportedTab($0) }
            
            if !sanitizedLeft.isEmpty {
                leftTabs = sanitizedLeft
                if let activeId = imported.leftActiveTabId, leftTabs.contains(where: { $0.id == activeId }) {
                    leftActiveTabId = activeId
                } else if let first = leftTabs.first {
                    leftActiveTabId = first.id
                }
            }
            
            if !sanitizedRight.isEmpty {
                rightTabs = sanitizedRight
                if let activeId = imported.rightActiveTabId, rightTabs.contains(where: { $0.id == activeId }) {
                    rightActiveTabId = activeId
                } else if let first = rightTabs.first {
                    rightActiveTabId = first.id
                }
            }
            
            refreshPaneToActiveTab(side: .left)
            refreshPaneToActiveTab(side: .right)
            saveSession()
            let totalCount = leftTabs.count + rightTabs.count
            statusMessage = "Вкладки импортированы (\(totalCount) шт.)"
            
        case .append:
            var addedCount = 0
            for importedTab in imported.leftTabs {
                let sanitized = sanitizeImportedTab(importedTab)
                // Создаем новый уникальный UUID для добавляемой вкладки
                let newTab = PanelTab(
                    id: UUID(),
                    title: sanitized.title,
                    path: sanitized.path,
                    source: sanitized.source,
                    isPinned: sanitized.isPinned
                )
                leftTabs.append(newTab)
                addedCount += 1
            }
            
            for importedTab in imported.rightTabs {
                let sanitized = sanitizeImportedTab(importedTab)
                let newTab = PanelTab(
                    id: UUID(),
                    title: sanitized.title,
                    path: sanitized.path,
                    source: sanitized.source,
                    isPinned: sanitized.isPinned
                )
                rightTabs.append(newTab)
                addedCount += 1
            }
            
            saveSession()
            statusMessage = "Вкладки добавлены (\(addedCount) шт.)"
        }
    }
    
    /// Вызов диалогового окна сохранения вкладок (Save tabs)
    public func saveTabsWithSavePanel() {
        let panel = NSSavePanel()
        panel.title = "Сохранить вкладки в JSON"
        panel.nameFieldStringValue = "MacDroidCommander_tabs.json"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let targetURL = panel.url {
            do {
                try exportTabsToFile(url: targetURL)
            } catch {
                errorMessage = "Ошибка при сохранении вкладок: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
    }
    
    /// Вызов диалогового окна выбора файла для импорта вкладок (Import tabs / Add tabs)
    public func importTabsWithOpenPanel(mode: TabImportMode) {
        let panel = NSOpenPanel()
        panel.title = (mode == .replace) ? "Импортировать вкладки (с замещением)" : "Добавить вкладки из файла"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK, let fileURL = panel.url {
            do {
                try importTabsFromFile(url: fileURL, mode: mode)
            } catch {
                errorMessage = "Ошибка при чтении файла вкладок: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
    }
    
    // MARK: - Memoized Display Items