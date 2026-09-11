import SwiftUI

public struct TransferQueueModalView: View {
    @ObservedObject var queue = TransferQueueManager.shared
    @EnvironmentObject var vm: DualPaneViewModel
    @Environment(\.dismiss) var dismiss
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Очередь файловых операций")
                    .font(.headline)
                Spacer()
                
                // Управление паузой / возобновлением
                if vm.currentTransferTask != nil {
                    if vm.isTransferPaused {
                        Button("Возобновить") {
                            vm.resumeTransfer()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.green)
                    } else {
                        Button("Пауза") {
                            vm.pauseTransfer()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.orange)
                    }
                    
                    Button("Отменить передачу") {
                        vm.cancelTransfer()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
                
                if queue.tasks.contains(where: { $0.status == .failed || $0.status == .cancelled }) {
                    Button("Повторить сбойные") {
                        queue.retryFailedTasks()
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Button("Очистить завершенные") {
                    queue.clearCompleted()
                }
                .buttonStyle(.bordered)
                
                Button("Закрыть") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            
            Divider()
            
            if queue.tasks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Очередь задач пуста")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(queue.tasks) { task in
                    HStack(spacing: 12) {
                        Image(systemName: task.isMove ? "arrow.right.circle.fill" : "doc.on.doc.fill")
                            .foregroundColor(task.isMove ? .orange : .blue)
                            .font(.system(size: 18))
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.sourceItem.name)
                                .font(.system(size: 13, weight: .medium))
                            
                            ProgressView(value: task.progress, total: 1.0)
                                .progressViewStyle(.linear)
                            
                            HStack {
                                Text("\(task.status.rawValue)")
                                    .font(.caption2)
                                    .foregroundColor(statusColor(task.status))
                                
                                if task.status == .running && task.speed > 0 {
                                    Text("• \(TransferSpeedTracker.formatSpeed(task.speed))")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                    
                                    if let eta = task.eta {
                                        Text("• \(TransferSpeedTracker.formatETA(eta))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                                Text("\(formatBytes(task.bytesTransferred)) / \(formatBytes(task.totalBytes))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack(spacing: 6) {
                            if task.status == .running {
                                Button(action: { queue.pauseTask(id: task.id) }) {
                                    Image(systemName: "pause.circle.fill")
                                }
                                .buttonStyle(.plain)
                            } else if task.status == .paused {
                                Button(action: { queue.resumeTask(id: task.id) }) {
                                    Image(systemName: "play.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            
                            Button(action: { queue.cancelTask(id: task.id) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
    
    private func statusColor(_ status: TransferTaskStatus) -> Color {
        switch status {
        case .queued: return .blue
        case .running: return .green
        case .paused: return .orange
        case .completed: return .secondary
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
    
    private func formatBytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
}
