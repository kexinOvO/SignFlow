import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false
    func binding<T>(_ path: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.state.settings[keyPath: path] }, set: { value in model.updateSettings { $0[keyPath: path] = value } })
    }
    var body: some View {
        Form {
            Section {
                Toggle("登录后运行 SignFlow", isOn: Binding(get: { model.background.loginEnabled }, set: { enabled in Task { await model.setLogin(enabled) } }))
                LabeledContent("登录项状态", value: model.loginStatus.isEmpty ? model.background.loginStatus : model.loginStatus)
                Button("打开系统登录项设置") { model.background.openLoginSettings() }
                Toggle("显示菜单栏图标", isOn: binding(\.showMenuBar))
                Toggle("关闭主窗口后继续运行", isOn: binding(\.keepRunning))
                Picker("外观", selection: binding(\.appearance)) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                LabeledContent("语言", value: "简体中文")
                HStack { TextField("默认项目目录", text: binding(\.defaultProjectPath)); Button("选择…") { chooseDirectory(\.defaultProjectPath) } }
            } header: { Text("通用") } footer: { Text("退出应用会停止调度。登录项由 macOS ServiceManagement 管理，系统可能要求在登录项设置中批准。") }
            Section {
                Toggle("启用全局自动续签", isOn: binding(\.automationEnabled))
                Toggle("暂停自动续签", isOn: binding(\.automationPaused)).disabled(!model.state.settings.automationEnabled)
                EditableNumberSetting("默认检查间隔", value: binding(\.intervalMinutes), unit: "分钟", range: 5...1440, step: 5)
                EditableNumberSetting("默认提前续签", value: binding(\.advanceHours), unit: "小时", range: 1...168, step: 1)
                Toggle("允许自动安装", isOn: binding(\.installAutomatically))
                Toggle("设备重新可用时继续等待任务", isOn: binding(\.retryOffline))
            } header: { Text("自动续签") } footer: { Text("每个项目还需要单独开启。默认时间用于新导入的项目；现有项目在详情页配置。睡眠、关机或未登录期间不会执行，唤醒后会补做检查。") }
            Section("构建") {
                HStack { TextField("Xcode 路径（留空使用系统选择）", text: binding(\.xcodePath)); Button("选择…") { chooseXcode() } }
                Button("检查当前工具链") { Task { await model.refreshEnvironment() } }
                TextField("默认 Build Configuration", text: binding(\.defaultConfiguration))
                HStack { TextField("DerivedData 目录（留空使用独立默认目录）", text: binding(\.derivedDataPath)); Button("选择…") { chooseDirectory(\.derivedDataPath) } }
                Text("当前输出：\(model.outputRoot.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Stepper("最大并发任务：\(model.state.settings.maxConcurrentTasks)", value: binding(\.maxConcurrentTasks), in: 1...4)
                Stepper("日志保留目标：\(model.state.settings.logRetentionDays) 天", value: binding(\.logRetentionDays), in: 1...365)
                Text("日志保留天数用于提示；SignFlow 不会自动批量删除日志或构建产物。可导出后自行管理。").font(.caption).foregroundStyle(.secondary)
            }
            Section("通知") {
                LabeledContent("系统通知权限", value: model.notificationStatus)
                if let error = model.notificationError { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("请求通知权限") { Task { await model.requestNotifications() } }
                Toggle("即将到期提醒", isOn: binding(\.notifyExpiry))
                Toggle("安装成功", isOn: binding(\.notifyInstall))
                Toggle("续签成功", isOn: binding(\.notifyRenewal))
                Toggle("续签或安装失败", isOn: binding(\.notifyFailure))
                Toggle("需要认证或人工操作", isOn: binding(\.notifyUserAction))
                Toggle("设备重新连接", isOn: binding(\.notifyDevice))
            }
            Section("高级") {
                LabeledContent("后台任务", value: model.background.running ? "应用内调度器正在运行" : "未运行")
                LabeledContent("上次调度检查", value: model.state.lastSchedulerCheck?.formatted() ?? "尚未检查")
                LabeledContent("互斥", value: "单实例锁 · 同工程串行 · 持久化恢复")
                HStack {
                    Button("复制诊断信息") {
                        let text = "SignFlow 1.0\n\(model.environment.version)\n\(model.environment.developerDirectory)\n\(model.state.projects.count) projects\n\(model.state.devices.count) devices\n\(model.state.tasks.count) tasks\n\(model.deviceError?.technical ?? "")"
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(LogRedactor.redact(text), forType: .string)
                    }
                    Button("导出日志…") { model.exportLogs() }
                    Button("重置项目查询缓存…", role: .destructive) { confirmReset = true }
                }
                Text("缓存重置仅针对 SignFlow 的元数据查询目录，保留工程、构建产物和任务记录。").font(.caption).foregroundStyle(.secondary)
                if let warning = model.registryWarning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if let error = model.registryError { ErrorPanel(error: error) }
                LabeledContent("版本", value: "SignFlow 1.0 (1) · macOS 14+")
                LabeledContent("数据目录") { Button("在 Finder 中显示") { NSWorkspace.shared.open(model.dataRoot) } }
            }
        }.formStyle(.grouped).navigationTitle("设置")
            .confirmationDialog("重置 SignFlow 自身查询缓存？", isPresented: $confirmReset) {
                Button("重置查询缓存", role: .destructive) { model.resetInspectionCache() }
                Button("取消", role: .cancel) { }
            } message: { Text("此操作仅删除 SignFlow/Inspection 中可重新生成的元数据。不会删除用户工程或已安装应用。") }
    }
    private func chooseDirectory(_ path: WritableKeyPath<AppSettings, String>) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateSettings { $0[keyPath: path] = url.path }
    }
    private func chooseXcode() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateSettings { $0.xcodePath = url.path }; Task { await model.refreshEnvironment() }
    }
}

private struct EditableNumberSetting: View {
    let title: String
    @Binding var value: Int
    let unit: String
    let range: ClosedRange<Int>
    let step: Int
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    init(_ title: String, value: Binding<Int>, unit: String, range: ClosedRange<Int>, step: Int) {
        self.title = title
        self._value = value
        self.unit = unit
        self.range = range
        self.step = step
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, text: $draft)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .focused($isEditing)
                    .accessibilityLabel("\(title)（\(unit)）")
                    .help("输入 \(range.lowerBound)–\(range.upperBound) \(unit)")
                    .onSubmit { commit() }
                Text(unit)
                Stepper(title, value: Binding(get: { value }, set: { newValue in
                    let adjustment = newValue - value
                    if isEditing { commit() }
                    value = min(max(value + adjustment, range.lowerBound), range.upperBound)
                    draft = String(value)
                }), in: range, step: step)
                    .labelsHidden()
            }
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { _, newValue in
            if !isEditing { draft = String(newValue) }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing { commit() }
        }
        .onDisappear { if isEditing { commit() } }
    }

    private func commit() {
        if let number = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)) {
            value = min(max(number, range.lowerBound), range.upperBound)
        }
        draft = String(value)
    }
}
