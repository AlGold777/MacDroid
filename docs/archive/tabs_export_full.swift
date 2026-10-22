    /// Экспорт всех открытых вкладок обеих панелей со статусом закрепления в JSON-файл
    public func exportTabsToFile(url: URL) throws {
        let exportData = TabsExportData(
            leftTabs: leftTabs,
            rightTabs: rightTabs,
            leftActiveTabId: leftActiveTabId,
            rightActiveTabId: rightActiveTabId
        )