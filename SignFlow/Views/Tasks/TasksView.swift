import SwiftUI
import AppKit

struct TaskSummaryRow: View {
    var task: FlowTask
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(task.projectName).font(.headline); Text(task.kind.title).font(.caption).foregroundStyle(.secondary); Spacer(); StatusPill(title: task.phase.title, color: task.phase.color, symbol: task.phase == .completed ? "checkmark.circle.fill" : task.phase == .failed ? "exclamationmark.circle.fill" : "clock") }
            Text(task.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            HStack { Text(task.createdAt.formatted(date: .abbreviated, time: .shortened)); if let duration = task.duration { Text("· \(Int(duration)) 秒") }; if task.automatic { Text("· 自动任务") }; if task.recovered { Text("· 已恢复") } }.font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct TasksView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var filter = "全部"
    var filtered: [FlowTask] {
        model.state.tasks.filter { task in
            let textMatch = search.isEmpty || (task.projectName + task.summary + task.kind.title).localizedCaseInsensitiveContains(search)
            let statusMatch = filter == "全部" || (filter == "进行中" && !task.phase.isTerminal) || (filter == "已完成" && task.phase == .completed) || (filter == "需处理" && [.waitingUser, .waitingDevice, .failed, .partialSuccess, .retryableFailure].contains(task.phase))
            return textMatch && statusMatch
        }
    }
    var selected: FlowTask? { filtered.first { $0.id == model.selectedTaskID } ?? filtered.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if filtered.isEmpty {
                EmptyPanel(title: "没有任务记录", detail: "从项目页执行检查或构建，运行阶段与原始日志会显示在这里。", symbol: "clock.arrow.circlepath").frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    List(filtered, selection: $model.selectedTaskID) { task in TaskSummaryRow(task: task).padding(.vertical, 8).tag(task.id) }.listStyle(.inset).frame(minWidth: 300, idealWidth: 340, maxWidth: 430)
                    if let task = selected { TaskDetailView(task: task).frame(minWidth: 310, maxWidth: .infinity) }
                }
            }
        }
        .navigationTitle("任务日志")
        .navigationSubtitle("\(filtered.count) 条记录")
        .searchable(text: $search, placement: .toolbar, prompt: "搜索项目、类型或结果")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("任务状态", selection: $filter) {
                    ForEach(["全部", "进行中", "需处理", "已完成"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("筛选任务状态")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.exportLogs() } label: { Label("导出日志…", systemImage: "square.and.arrow.up") }
                    .help("导出任务日志")
            }
        }
    }
}

struct TaskDetailView: View {
    @EnvironmentObject var model: AppModel
    var task: FlowTask
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Surface {
                    TaskSummaryRow(task: task)
                    if task.phase.isExecuting { ProgressView(value: task.phase.progress) }
                    if let assessment = task.assessment { InfoRow(title: "本地签名结果", value: assessment.title) }
                    InfoRow(title: "重试次数", value: "\(task.retryCount)")
                    if let next = task.nextRetryAt { InfoRow(title: "下次重试", value: next.formatted()) }
                    if let path = task.artifactPath { DisclosureGroup("构建产物") { Text(path).font(.caption).textSelection(.enabled); Button("显示产物") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } } }
                    HStack {
                        if !task.phase.isTerminal { Button("取消任务", role: .destructive) { model.cancel(task.id) } }
                        if [.waitingUser, .waitingDevice, .retryableFailure, .failed, .partialSuccess, .cancelled].contains(task.phase) { Button("立即重试") { model.retry(task.id) } }
                        Spacer()
                        Button("复制日志") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.logText(task), forType: .string) }
                        Button("导出…") { model.exportLogs(task: task) }
                    }
                    Button("打开项目详情") { model.showProject(task.projectID) }.buttonStyle(.link)
                }
                if let error = task.error { ErrorPanel(error: error) }
                if !task.deployments.isEmpty { Surface("设备部署结果") { ForEach(task.deployments) { DeploymentRow(evidence: $0); if $0.id != task.deployments.last?.id { Divider() } } } }
                Surface("执行阶段") {
                    ForEach(task.events) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: event.phase == .completed ? "checkmark.circle.fill" : "circle.fill").font(.system(size: 9)).foregroundStyle(event.phase.color).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 4) { Text(event.phase.title).font(.callout.weight(.medium)); Text(event.message).font(.caption).foregroundStyle(.secondary) }
                            Spacer(minLength: 4)
                            Text(event.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Surface("原始日志（已脱敏）") {
                    Text(model.logTails[task.id] ?? model.logText(task)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(24)
        }
    }
}
