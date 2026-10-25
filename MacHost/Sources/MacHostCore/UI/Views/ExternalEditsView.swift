import SwiftUI

public struct ExternalEditsView: View {
    @ObservedObject var manager: ExternalEditManager
    @Environment(\.dismiss) private var dismiss

    public init(manager: ExternalEditManager) { self.manager = manager }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Рабочие копии файлов телефона").font(.title2)
                Spacer()
                if manager.isRefreshing { ProgressView().controlSize(.small) }
                Button("Проверить изменения") { Task { await manager.refresh() } }
                    .disabled(manager.isRefreshing)
            }
            Text("Сначала сохраните файл во внешнем редакторе. Здесь можно отправить изменённую копию в ту же папку телефона под новым именем. Оригинал сохранится.")
                .foregroundStyle(.secondary)
            if let error = manager.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if manager.sessions.isEmpty {
                ContentUnavailableView("Пока нет рабочих копий", systemImage: "doc.badge.arrow.up",
                                       description: Text("Откройте файл телефона двойным щелчком или через «Открыть с помощью»."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(manager.sessions) { session in
                            sessionRow(session)
                            Divider()
                        }
                    }.padding(4)
                }
            }
            HStack {
                Text("Рабочие копии хранятся на Mac и восстанавливаются после перезапуска.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 740, idealWidth: 820, minHeight: 440, idealHeight: 560)
        .task { await manager.refresh() }
    }

    private func sessionRow(_ session: ExternalEditSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: manager.changed.contains(session.id) ? "pencil.circle.fill" : "doc")
                    .foregroundStyle(manager.changed.contains(session.id) ? .orange : .secondary)
                Text(session.fileName).font(.headline)
                if manager.busy.contains(session.id) { ProgressView().controlSize(.small) }
            }
            Text(session.remotePath).font(.caption).textSelection(.enabled)
            Text("Телефон: \(session.deviceFingerprint)").font(.caption2).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(manager.messages[session.id] ?? "Проверка…")
                .font(.callout).textSelection(.enabled)
            if let path = session.lastSavedPath {
                Text("Последняя подтверждённая копия: \(path)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let pending = session.pendingRemotePath {
                Text("Есть неподтверждённая попытка. Перед повторной отправкой проверьте на телефоне: \(pending)")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(session.previousUnconfirmedPaths, id: \.self) { path in
                Text("Предыдущая неподтверждённая попытка: \(path)")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Button("Открыть копию") { Task { await manager.open(session) } }
                Button("Показать в Finder") { Task { await manager.reveal(session) } }
                Spacer()
                Button("Сохранить на телефон как копию") {
                    Task { await manager.saveCopy(session) }
                }
                .disabled(!manager.changed.contains(session.id) || manager.busy.contains(session.id))
            }
        }
        .disabled(manager.busy.contains(session.id))
    }
}
