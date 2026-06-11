import SwiftUI

struct TaskQueueView: View {
    @StateObject private var queueManager = TaskQueueManager.shared
    @Binding var selectedTaskId: String?

    var body: some View {
        if queueManager.tasks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.title)
                    .foregroundStyle(.tertiary)
                Text("暂无任务")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            List(selection: $selectedTaskId) {
                ForEach(queueManager.tasks.reversed()) { task in
                    TaskRowView(task: task)
                        .contextMenu {
                            Button("在 Finder 中显示") {
                                if let outputPath = task.outputPath {
                                    NSWorkspace.shared.selectFile(outputPath, inFileViewerRootedAtPath: "")
                                }
                            }

                            Divider()

                            if task.status == .processing {
                                Button("取消") {
                                    queueManager.cancelTask(task.id)
                                }
                            }

                            Button("移除", role: .destructive) {
                                queueManager.removeTask(task.id)
                                if selectedTaskId == task.id {
                                    selectedTaskId = nil
                                }
                            }
                        }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct TaskRowView: View {
    @ObservedObject private var queueManager = TaskQueueManager.shared
    let task: OCRTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.title3)
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text(task.fileName)
                        .font(.subheadline)
                        .lineLimit(1)

                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if task.status == .processing {
                    Button {
                        queueManager.cancelTask(task.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("取消")
                }
            }

            if task.status == .processing {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: task.progress, total: 100)
                        .tint(.blue)
                    HStack {
                        if let stage = task.stage {
                            Text(stage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if task.totalPages > 0 {
                            Text("\(task.currentPage)/\(task.totalPages) 页")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(Int(task.progress))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = task.error, task.status == .failed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch task.status {
        case .pending: "等待中"
        case .processing: task.stage ?? "处理中"
        case .completed:
            if task.totalPages > 0 { "\(task.totalPages) 页完成" }
            else { "完成" }
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    private var statusIcon: String {
        switch task.status {
        case .pending: "clock"
        case .processing: "gearshape"
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle"
        case .cancelled: "slash.circle"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending: .secondary
        case .processing: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}
