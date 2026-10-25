import SwiftUI

public struct PhoneTrashView: View {
    @EnvironmentObject private var vm: DualPaneViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingEmpty = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            if let error = vm.phoneTrashError, !error.isEmpty {
                errorBanner(error)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            if vm.isPhoneTrashBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(vm.phoneTrashEntries.isEmpty ? "Загрузка корзины телефона…" : "Обновление корзины телефона…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            if vm.phoneTrashEntries.isEmpty {
                if vm.phoneTrashError == nil && !vm.isPhoneTrashBusy {
                    emptyState
                } else {
                    Spacer(minLength: 0)
                }
            } else {
                List(vm.phoneTrashEntries, id: \.id) { entry in
                    trashRow(entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 600, idealWidth: 760, minHeight: 380, idealHeight: 540)
        .interactiveDismissDisabled(vm.isPhoneTrashBusy)
        .alert("Удалить безвозвратно все \(vm.phoneTrashEntries.count) объектов?", isPresented: $isConfirmingEmpty) {
            Button("Удалить безвозвратно", role: .destructive) {
                vm.emptyPhoneTrash()
            }
            .disabled(vm.isPhoneTrashBusy || vm.phoneTrashEntries.isEmpty)

            Button("Отмена", role: .cancel) {}
        } message: {
            Text("После очистки корзины эти объекты нельзя будет восстановить.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.fill")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text("Корзина телефона")
                    .font(.headline)

                Text(vm.phoneTrashVolumePath.isEmpty ? "Путь тома не определён" : vm.phoneTrashVolumePath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Button {
                vm.reloadPhoneTrash()
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(vm.isPhoneTrashBusy)

            Button {
                isConfirmingEmpty = true
            } label: {
                Label("Очистить корзину", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(vm.phoneTrashEntries.isEmpty || vm.isPhoneTrashBusy)

            Button("Закрыть") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)
            .disabled(vm.isPhoneTrashBusy)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("Корзина телефона пуста")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .padding(.top, 1)

            Text(error)
                .font(.callout)
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func trashRow(_ entry: PhoneTrashEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 18))
                .foregroundColor(entry.isDirectory ? .accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(entry.originalPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Text("Удалён: \(entry.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Button("Восстановить") {
                vm.restorePhoneTrashEntry(entry)
            }
            .buttonStyle(.bordered)
            .disabled(vm.isPhoneTrashBusy)
        }
        .padding(.vertical, 4)
    }
}
