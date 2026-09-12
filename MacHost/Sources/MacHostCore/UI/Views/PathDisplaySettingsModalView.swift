import SwiftUI

public struct PathDisplaySettingsModalView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var tempMacPrefix: String = ""
    @State private var tempPhonePrefix: String = ""
    @State private var tempIsEnabled: Bool = true
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Заголовок
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 26))
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Настройки отображения пути")
                        .font(.system(size: 16, weight: .bold))
                    Text("Скрытие системных префиксов делает строку пути компактной и показывает только актуальные каталоги.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 4)
            
            Divider()
            
            // 1. Секция Mac
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Mac. Скрыть:")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Домашняя папка") {
                        tempMacPrefix = FileManager.default.homeDirectoryForCurrentUser.path
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                
                TextField("/Users/username", text: $tempMacPrefix)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                
                Text("Например: \(FileManager.default.homeDirectoryForCurrentUser.path)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            // 2. Секция Телефон (Android)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Phone. Скрыть:")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("По умолчанию") {
                        tempPhonePrefix = "/storage/emulated/0"
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                
                TextField("/storage/emulated/0", text: $tempPhonePrefix)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                
                Text("Например: /storage/emulated/0")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            // 3. Переключатель активности
            Toggle("Скрывать указанные префиксы в заголовках путей", isOn: $tempIsEnabled)
                .font(.system(size: 12))
            
            Divider()
                .padding(.top, 2)
            
            // 4. Кнопки действий
            HStack {
                Button("Сбросить по умолчанию") {
                    tempMacPrefix = FileManager.default.homeDirectoryForCurrentUser.path
                    tempPhonePrefix = "/storage/emulated/0"
                    tempIsEnabled = true
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.system(size: 12))
                
                Spacer()
                
                Button("Отмена") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Сохранить") {
                    vm.macHiddenPathPrefix = tempMacPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                    vm.phoneHiddenPathPrefix = tempPhonePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                    vm.isPathPrefixHidingEnabled = tempIsEnabled
                    vm.savePathDisplaySettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            tempMacPrefix = vm.macHiddenPathPrefix
            tempPhonePrefix = vm.phoneHiddenPathPrefix
            tempIsEnabled = vm.isPathPrefixHidingEnabled
        }
    }
}
