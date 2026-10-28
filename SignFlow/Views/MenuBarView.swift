import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Label("SignFlow", systemImage: "checkmark.shield.fill").font(.headline); Spacer(); Text(model.runningTasks.isEmpty ? "空闲" : "执行中").font(.caption).foregroundStyle(.secondary) }
            Divider()
            if let project = model.nextExpiring, let expiry = project.expiresAt {
                Text("下一个到期的本地产物").font(.caption).foregroundStyle(.secondary)
                Button { model.showProject(project.id); openWindow(id: "main"); model.openMainWindow() } label: { VStack(alignment: .leading, spacing: 4) { Text(project.name).font(.callout.weight(.medium)); Text(expiry.formatted()).font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain)
            } else { Text("尚无签名有效期记录").font(.callout).foregroundStyle(.secondary) }
            if let task = model.runningTasks.first { Text("\(task.projectName) · \(task.phase.title)").font(.caption); ProgressView(value: task.phase.progress) }
            Divider()
            Button("检查全部项目", action: model.checkAll)
            Button("执行到期续签") { model.renewDue() }
            Toggle("暂停自动续签", isOn: Binding(get: { model.state.settings.automationPaused }, set: { value in model.updateSettings { $0.automationPaused = value } }))
            Divider()
            HStack { Button("打开主窗口") { openWindow(id: "main"); model.openMainWindow() }; Spacer(); Button("退出") { NSApp.terminate(nil) } }
        }.padding(20).frame(width: 330)
    }
}
