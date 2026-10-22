        // 6. Direct item.tags matching in itemMatchesTag
        assertCondition(DualPaneViewModel.itemMatchesTag(itemBlue, tag: "Blue"), "itemMatchesTag matches direct item.tags")
        assertCondition(DualPaneViewModel.itemMatchesTag(itemBlue, tag: "Синий"), "itemMatchesTag matches synonym for direct item.tags")
    }
}

func runTest67() async {
    print("\n[TEST 67] Tabs Export, Import (Replace) & Import (Add) Invariants:")
    await MainActor.run {
        let vm = DualPaneViewModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TabsExportTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let jsonURL = tempDir.appendingPathComponent("test_tabs.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let tabLeft1 = PanelTab(id: UUID(), title: "Home", path: FileManager.default.homeDirectoryForCurrentUser.path, source: .localMac, isPinned: true)
        let tabLeft2 = PanelTab(id: UUID(), title: "Tmp", path: "/tmp", source: .localMac, isPinned: false)
        let tabRight1 = PanelTab(id: UUID(), title: "0", path: "/storage/emulated/0", source: .remotePhone, isPinned: true)
        let tabRight2 = PanelTab(id: UUID(), title: "DCIM", path: "/storage/emulated/0/DCIM", source: .remotePhone, isPinned: false)
        
        vm.leftTabs = [tabLeft1, tabLeft2]
        vm.leftActiveTabId = tabLeft1.id
        vm.rightTabs = [tabRight1, tabRight2]
        vm.rightActiveTabId = tabRight2.id
        
        // 1. Export tabs to JSON file
        do {
            try vm.exportTabsToFile(url: jsonURL)
            assertCondition(FileManager.default.fileExists(atPath: jsonURL.path), "exportTabsToFile successfully creates JSON file")
            assertCondition(vm.statusMessage.contains("Вкладки сохранены"), "statusMessage confirms export: \(vm.statusMessage)")
            
            let data = try Data(contentsOf: jsonURL)
            let exportedObj = try JSONDecoder().decode(TabsExportData.self, from: data)
            assertCondition(exportedObj.leftTabs.count == 2, "Exported leftTabs count is 2")
            assertCondition(exportedObj.rightTabs.count == 2, "Exported rightTabs count is 2")
            assertCondition(exportedObj.leftTabs.first?.isPinned == true, "Left pinned tab preserved in export JSON")
            assertCondition(exportedObj.rightTabs.first?.isPinned == true, "Right pinned tab preserved in export JSON")
            assertCondition(exportedObj.rightTabs.last?.isPinned == false, "Right unpinned tab preserved in export JSON")
        } catch {
            assertCondition(false, "exportTabsToFile threw error: \(error)")
        }
        
        // 2. Import tabs with Replace mode (.replace)
        let otherTabLeft = PanelTab(id: UUID(), title: "Downloads", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path, source: .localMac, isPinned: false)
        let otherTabRight = PanelTab(id: UUID(), title: "Download", path: "/storage/emulated/0/Download", source: .remotePhone, isPinned: false)
        vm.leftTabs = [otherTabLeft]
        vm.leftActiveTabId = otherTabLeft.id
        vm.rightTabs = [otherTabRight]
        vm.rightActiveTabId = otherTabRight.id
        
        do {
            try vm.importTabsFromFile(url: jsonURL, mode: .replace)
            assertCondition(vm.leftTabs.count == 2, "Import (replace) restored 2 left tabs")
            assertCondition(vm.rightTabs.count == 2, "Import (replace) restored 2 right tabs")
            assertCondition(vm.leftTabs.first?.title == "Home", "Left tab 0 is Home")
            assertCondition(vm.leftTabs.first?.isPinned == true, "Left tab 0 is pinned")
            assertCondition(vm.rightTabs.first?.isPinned == true, "Right tab 0 is pinned")
            assertCondition(vm.rightTabs.last?.title == "DCIM", "Right tab 1 is DCIM")
            assertCondition(vm.rightTabs.last?.isPinned == false, "Right tab 1 is unpinned")
            assertCondition(vm.statusMessage.contains("Вкладки импортированы"), "statusMessage confirms replacement import: \(vm.statusMessage)")
        } catch {
            assertCondition(false, "importTabsFromFile (replace) threw error: \(error)")
        }
        
        // 3. Import tabs with Add mode (.append)
        do {
            let leftCountBefore = vm.leftTabs.count
            let rightCountBefore = vm.rightTabs.count
            
            try vm.importTabsFromFile(url: jsonURL, mode: .append)
            assertCondition(vm.leftTabs.count == leftCountBefore + 2, "Import (append) added 2 left tabs (total \(vm.leftTabs.count))")
            assertCondition(vm.rightTabs.count == rightCountBefore + 2, "Import (append) added 2 right tabs (total \(vm.rightTabs.count))")
            
            // Appended tabs must have fresh unique IDs so they don't collide
            let leftIds = vm.leftTabs.map(\.id)
            let uniqueLeftIds = Set(leftIds)
            assertCondition(leftIds.count == uniqueLeftIds.count, "All left tab IDs are unique after append")
            
            let appendedLeftTab = vm.leftTabs[2]
            assertCondition(appendedLeftTab.title == "Home", "Appended left tab preserved title")
            assertCondition(appendedLeftTab.isPinned == true, "Appended left tab preserved isPinned")
            
            assertCondition(vm.statusMessage.contains("Вкладки добавлены"), "statusMessage confirms append: \(vm.statusMessage)")
        } catch {
            assertCondition(false, "importTabsFromFile (append) threw error: \(error)")
        }
    }
}
