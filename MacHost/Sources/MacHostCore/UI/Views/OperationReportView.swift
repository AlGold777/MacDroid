import SwiftUI

/// Диалог итогового отчёта о завершённой операции (копирование/перемещение/удаление)
public struct OperationReportView: View {
    @EnvironmentObject var vm: DualPaneViewModel
    let report: DualPaneViewModel.OperationReport
    
    public init(report: DualPaneViewModel.OperationReport) {
        self.report = report
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Заголовок
            HStack {
                Image(systemName: report.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundColor(report.failed.isEmpty ? .green : .orange)
                
                VStack(alignment: .leading) {
                    Text(report.failed.isEmpty ? "Операция завершена успешно" : "Операция завершена с ошибками")
                        .font(.headline)
                    Text("Длительность: \(formattedDuration)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Divider()
            
            // Сводная статистика
            HStack(spacing: 24) {
                statItem(count: report.succeeded.count, label: "Успешно", color: .green)
                statItem(count: report.failed.count, label: "Ошибок", color: .red)
                statItem(count: report.skipped.count, label: "Пропущено", color: .gray)
                
                if report.totalBytes > 0 {
                    VStack {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(report.totalBytes), countStyle: .file))
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Передано")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if report.averageSpeedBytesPerSec > 0 {
                    VStack {
                        Text(TransferSpeedTracker.formatSpeed(report.averageSpeedBytesPerSec))
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                        Text("Ср. скорость")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Список ошибок (если есть)
            if !report.failed.isEmpty {
                Divider()
                
                Text("Ошибки:")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(report.failed.enumerated()), id: \.offset) { _, failure in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.system(size: 12))
                                    .padding(.top, 2)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: failure.path).lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(failure.error)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            
            // Список пропущенных (если есть)
            if !report.skipped.isEmpty {
                Divider()
                
                Text("Пропущены:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(report.skipped, id: \.self) { path in
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.right.circle")
                                    .foregroundColor(.gray)
                                    .font(.system(size: 11))
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 100)
            }
            
            Divider()
            
            // Кнопки
            HStack {
                Spacer()
                Button("Закрыть") {
                    vm.showOperationReport = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 450, idealWidth: 500, maxWidth: 600)
    }
    
    @ViewBuilder
    private func statItem(count: Int, label: String, color: Color) -> some View {
        VStack {
            Text("\(count)")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(count > 0 ? color : .secondary)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var formattedDuration: String {
        let seconds = Int(report.duration)
        if seconds < 60 {
            return "\(seconds) сек"
        } else {
            let minutes = seconds / 60
            let secs = seconds % 60
            return "\(minutes) мин \(secs) сек"
        }
    }
}
