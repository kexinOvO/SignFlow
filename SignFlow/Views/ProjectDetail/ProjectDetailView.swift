import SwiftUI
import AppKit

struct ProjectDetailView: View {
    @EnvironmentObject var model: AppModel
    var projectID: UUID
    @Binding var refreshingStatus: Bool
    @State private var tab = "概览"
    private let tabs = ["概览", "签名", "设备", "构建与安装", "自动续签", "日志"]
    var project: ManagedProject? { model.state.projects.first { $0.id == projectID } }
    func binding<T>(_ path: WritableKeyPath<ManagedProject, T>, fallback: T) -> Binding<T> {
        Binding(get: { project?[keyPath: path] ?? fallback }, set: { value in guard var p = project else { return }; p[keyPath: path] = value; model.updateProject(p) })
    }
    var body: some View {
        if let project {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch tab {
                    case "签名": signatureContent(project)
                    case "设备": deviceContent(project)
                    case "构建与安装": buildContent(project)
                    case "自动续签": renewalContent(project)
                    case "日志": logsContent(project)
                    default: overview(project)
                    }
                }.padding(28)
            }
            .navigationTitle(project.name)
            .navigationSubtitle(project.path)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("详情区域", selection: $tab) {
                            ForEach(tabs, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 8) {
                            Text(tab)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                        }
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("切换项目详情区域")
                    .accessibilityLabel("详情区域")
                    .accessibilityValue(tab)
                }
                ToolbarItem(placement: .primaryAction) { RefreshStatusButton(refreshingStatus: $refreshingStatus) }
                ToolbarItem(placement: .primaryAction) { ProjectActions(project: project) }
            }
        } else { EmptyPanel(title: "项目已移除", detail: "在项目页面添加一个 Xcode 工程。", symbol: "folder") }
    }
    @ViewBuilder func overview(_ p: ManagedProject) -> some View {
        Surface("项目配置") {
            InfoRow(title: "工程类型", value: p.kind == .workspace ? "Xcode Workspace" : "Xcode Project")
            InfoRow(title: "Scheme", value: p.scheme)
            InfoRow(title: "Bundle ID", value: p.bundleID)
            TextField("Build Configuration", text: binding(\.configuration, fallback: "Debug"))
            TextField("开发团队覆盖（留空使用项目配置）", text: binding(\.teamOverride, fallback: ""))
            Text("更换团队可能影响现有应用数据与 Keychain。SignFlow 遇到已知团队变化会停止覆盖安装。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("打开 Xcode") { model.openXcode(p) }; Button("显示于 Finder") { model.reveal(p) }; Button("重新定位…") { model.relocate(p) }; Spacer(); Button("重新读取元数据") { Task { await model.refreshProjectMetadata(p) } } }
        }
        Surface("已识别的 Target") {
            ForEach(p.targets) { target in
                HStack { Label(target.name, systemImage: target.platform.symbol); Spacer(); Text(target.platform.rawValue).foregroundStyle(.secondary); Text(target.automaticSigning ? "自动签名" : "手动 / 未识别").foregroundStyle(.secondary) }.font(.callout)
                Text(target.bundleID + (target.teamID.isEmpty ? "" : " · Team " + target.teamID)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        Surface("签名与部署概览") {
            ExpiryView(signatures: p.signatures)
            Text("上方有效期属于本地产物；设备预计时间依据上次安装记录，未直接读取设备签名。其他方式重新安装可能改变期限。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(p.deployments) { evidence in DeploymentRow(evidence: evidence, estimate: model.installationEstimate(for: evidence, in: p)) }
            if p.deployments.isEmpty { Text("还没有设备安装证据。").foregroundStyle(.secondary) }
            InfoRow(title: "最近签名检查", value: p.lastCheck?.formatted() ?? "未执行")
            InfoRow(title: "最近完整续签", value: p.lastRenewal?.formatted() ?? "尚无已确认记录")
        }
    }
    @ViewBuilder func signatureContent(_ p: ManagedProject) -> some View {
        Surface {
            HStack { Text("本地产物签名").font(.headline); Spacer(); Button("选择现有 .app…") { model.selectArtifact(p) }; Button("检查签名") { model.enqueue(p.id, kind: .inspect) } }
            Text(p.artifactPath ?? "尚未关联构建产物").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("验证包含 codesign 完整性、Profile、证书、Team ID、Bundle ID 和实际发现的嵌套 App / Extension。").font(.callout).foregroundStyle(.secondary)
        }
        if p.signatures.isEmpty { Surface { EmptyPanel(title: "尚无签名检查结果", detail: "执行一次构建，或选择已有 .app 以读取嵌套签名与到期时间。", symbol: "checkmark.shield") } }
        ForEach(p.signatures) { bundle in SignatureBundleView(bundle: bundle) }
    }
    @ViewBuilder func deviceContent(_ p: ManagedProject) -> some View {
        Surface("部署设备") {
            Picker("iPhone / iPad", selection: binding(\.phoneID, fallback: nil)) {
                Text("未选择").tag(String?.none)
                ForEach(model.state.devices.filter { $0.platform == .iOS }) { Text($0.name + " · " + $0.connection.title).tag(Optional($0.id)) }
            }
            Picker("Apple Watch", selection: binding(\.watchID, fallback: nil)) {
                Text("未选择").tag(String?.none)
                ForEach(model.state.devices.filter { $0.platform == .watchOS }) { Text($0.name + " · " + $0.connection.title).tag(Optional($0.id)) }
            }
            Text("Watch 独立选择。仅在系统提供可靠关联信息时显示配对关系；SignFlow 不推测 iPhone 与 Watch 的配对。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("刷新设备") { Task { await model.refreshDevices() } }.disabled(model.isRefreshing); Button("检查安装状态") { model.enqueue(p.id, kind: .verifyInstallation) } }
        }
        if let error = model.deviceError { ErrorPanel(error: error) }
        ForEach(p.deployments) { evidence in Surface { DeploymentRow(evidence: evidence, estimate: model.installationEstimate(for: evidence, in: p)) } }
        Surface("启动应用") {
            Text("启动已安装的应用不会重签或重新安装。需设备在线且工具链支持。").font(.callout).foregroundStyle(.secondary)
            ForEach(p.targets.filter { [.application, .watchApplication].contains($0.kind) }) { target in
                Button("启动 \(target.name)") {
                    let id = target.platform == .watchOS ? p.watchID : p.phoneID
                    guard let device = model.state.devices.first(where: { $0.id == id }) else { model.alertError = FlowError(.deviceOffline, "请先选择目标设备"); return }
                    Task { do { try await model.deviceService.launch(bundleID: target.bundleID, device: device) } catch { model.alertError = FlowError.wrap(error) } }
                }
            }
        }
    }
    @ViewBuilder func buildContent(_ p: ManagedProject) -> some View {
        Surface("构建与部署") {
            Toggle("允许 Xcode 更新 Provisioning 资源", isOn: binding(\.allowProvisioningUpdates, fallback: true))
            Toggle("允许 Xcode 向开发团队注册目标设备", isOn: binding(\.allowDeviceRegistration, fallback: false)).disabled(!p.allowProvisioningUpdates)
            Toggle("接受首次覆盖已有同 Bundle ID 应用的风险", isOn: binding(\.acceptExistingInstallRisk, fallback: false))
            Text("公开设备查询不能证明旧安装的团队和 Keychain 权限。首次接管已有安装时会暂停，直到在此确认。安装仅使用系统覆盖安装，失败不会自动卸载旧版本。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { model.enqueue(p.id, kind: .buildInstall) } label: { Label("立即构建并安装", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                Button("立即续签") { model.enqueue(p.id, kind: .renew) }
            }.disabled(model.pendingTasks.contains { $0.projectID == p.id })
            Text("输出目录：\(model.outputRoot.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if let task = model.state.tasks.first(where: { $0.projectID == p.id }) {
            Surface {
                TaskSummaryRow(task: task)
                if task.phase.isExecuting { ProgressView(value: task.phase.progress) }
                HStack {
                    Button("查看完整任务") { model.selectedTaskID = task.id; model.page = .tasks }
                    if !task.phase.isTerminal { Button("取消任务", role: .destructive) { model.cancel(task.id) } }
                }
                if let error = task.error { ErrorPanel(error: error) }
                if let text = model.logTails[task.id], !text.isEmpty { ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 280) }
            }
        }
    }
    @ViewBuilder func renewalContent(_ p: ManagedProject) -> some View {
        Surface("此项目的自动续签") {
            Toggle("启用此项目自动续签", isOn: binding(\.renewal.enabled, fallback: false))
            Stepper("检查间隔：\(p.renewal.intervalMinutes) 分钟", value: binding(\.renewal.intervalMinutes, fallback: 60), in: 5...1440, step: 5)
            Stepper("提前续签：\(p.renewal.advanceHours) 小时", value: binding(\.renewal.advanceHours, fallback: 48), in: 1...168)
            Toggle("签名验证后自动安装", isOn: binding(\.renewal.installAutomatically, fallback: true))
            Stepper("临时失败最多重试：\(p.renewal.maxRetries) 次", value: binding(\.renewal.maxRetries, fallback: 3), in: 0...10)
            Stepper("首次退避：\(p.renewal.retryBaseSeconds) 秒", value: binding(\.renewal.retryBaseSeconds, fallback: 60), in: 30...600, step: 30)
            Text("自动续签还需要全局开关开启、Mac 处于唤醒且用户已登录。账户认证、设备信任及签名未延长时暂停并等待操作。首次构建需手动触发以建立基线。").font(.callout).foregroundStyle(.secondary)
            Label(model.state.settings.automationEnabled && !model.state.settings.automationPaused ? "全局自动续签已开启" : "全局自动续签未运行", systemImage: "info.circle").foregroundStyle(.blue)
            Button("前往全局设置") { model.page = .settings }
        }
    }
    @ViewBuilder func logsContent(_ p: ManagedProject) -> some View {
        let tasks = model.state.tasks.filter { $0.projectID == p.id }
        if tasks.isEmpty { Surface { EmptyPanel(title: "没有任务记录", detail: "项目的构建、签名检查和部署结果会保存在这里。", symbol: "clock.arrow.circlepath") } }
        ForEach(tasks) { task in
            Surface { TaskSummaryRow(task: task); Button("查看详情") { model.selectedTaskID = task.id; model.page = .tasks } }
        }
    }
}

struct SignatureBundleView: View {
    var bundle: SignedBundle
    var body: some View {
        Surface {
            HStack { Label(bundle.displayName + (bundle.isExtension ? " · Extension" : ""), systemImage: bundle.platform.symbol).font(.headline); Spacer(); StatusPill(title: bundle.health.title, color: bundle.health.color, symbol: bundle.health.symbol) }
            InfoRow(title: "Bundle ID", value: bundle.bundleID)
            InfoRow(title: "Team ID", value: bundle.teamID ?? "无法读取")
            InfoRow(title: "版本", value: bundle.version + " (" + bundle.buildVersion + ")")
            if let profile = bundle.profile {
                ProfileDetails(profile: profile)
            } else { Text("无可用 Provisioning Profile").foregroundStyle(.orange) }
            DisclosureGroup("签名验证详情") { Text(bundle.validationMessage).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Text("检查时间：\(bundle.inspectedAt.formatted()) · 本地文件").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ProfileDetails: View {
    var profile: ProvisioningProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InfoRow(title: "Profile", value: profile.name)
            InfoRow(title: "UUID", value: profile.uuid)
            InfoRow(title: "Application Identifier", value: profile.applicationIdentifier)
            InfoRow(title: "创建时间", value: profile.creationDate.formatted())
            InfoRow(title: "到期时间", value: profile.expirationDate.formatted())
            InfoRow(title: "允许设备", value: profile.provisionsAllDevices ? "全部设备（Profile 声明）" : "\(profile.provisionedDevices.count) 台")
            DisclosureGroup("Entitlements 与证书") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(profile.entitlements.keys.sorted(), id: \.self) { key in Text(key + " = " + (profile.entitlements[key] ?? "")).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    ForEach(profile.certificates, id: \.fingerprint) { cert in Text(cert.name + " · 到期 " + (cert.expiresAt?.formatted() ?? "无法读取")).font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
        }
    }
}

struct DeploymentRow: View {
    var evidence: DeploymentEvidence
    var estimate: InstalledProfileEstimateStatus? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Label(evidence.deviceName, systemImage: evidence.platform.symbol); Spacer(); StatusPill(title: evidence.state.title, color: evidence.state.color, symbol: evidence.state == .installed ? "checkmark.circle" : "questionmark.circle") }
            Text(evidence.bundleID).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            if let estimate { InstalledProfileEstimateView(status: estimate, showExplanation: true) }
            Text(evidence.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("查询于 \(evidence.verifiedAt.formatted()) · 设备端签名：\(evidence.deviceSignatureVerified ? "已验证" : "无法直接验证")").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
