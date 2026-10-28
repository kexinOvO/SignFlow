import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var refreshingStatus = false
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            VStack(spacing: 0) {
                List {
                    Section {
                        ForEach(SidebarPage.allCases) { page in
                            Button {
                                model.page = page
                            } label: {
                                Label {
                                    Text(page.rawValue)
                                        .foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: page.symbol)
                                        .foregroundStyle(.tint)
                                }
                                .fontWeight(model.page == page ? .semibold : .regular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, page == SidebarPage.allCases.first ? 10 : 0)
                            .accessibilityAddTraits(model.page == page ? .isSelected : [])
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(model.page == page ? sidebarSelectionColor : .clear)
                                    .padding(.horizontal, 10)
                                    .padding(.top, page == SidebarPage.allCases.first ? 10 : 0)
                            )
                        }
                    }
                    if !model.state.projects.isEmpty {
                        Section("本地产物签名有效期") {
                            ForEach(model.state.projects) { project in
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    SidebarProjectExpiryRow(project: project, now: context.date)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onMoveCommand { direction in
                    let pages = SidebarPage.allCases
                    guard let index = pages.firstIndex(of: model.page ?? .projects) else { return }
                    switch direction {
                    case .up: model.page = pages[max(0, index - 1)]
                    case .down: model.page = pages[min(pages.count - 1, index + 1)]
                    default: break
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Circle().fill(model.environment.ready ? .green : .orange).frame(width: 7, height: 7); Text(model.environment.ready ? "Xcode 已就绪" : "检查开发环境").font(.caption) }
                    Text("\(model.state.projects.count) 个项目 · \(model.state.devices.filter(\.canAttemptConnection).count) 台可用设备").font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    Text("Automatic Signing & Deployment").font(.system(size: 9)).foregroundStyle(.tertiary)
                }.padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationSplitViewColumnWidth(min: 190, ideal: 218, max: 270)
        } detail: {
            Group {
                switch model.page ?? .projects {
                case .projects:
                    if let project = model.selectedProject { ProjectDetailView(projectID: project.id, refreshingStatus: $refreshingStatus).id(project.id) }
                    else { ProjectsView() }
                case .devices: DevicesView()
                case .signing: SigningView()
                case .tasks: TasksView()
                case .settings: SettingsView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
                .toolbar {
                    if model.page == .projects && model.selectedProject != nil {
                        ToolbarItem(placement: .navigation) { Button { model.selectedProjectID = nil } label: { Label("返回项目", systemImage: "chevron.left") } }
                    }
                    if model.page != .projects || model.selectedProject == nil {
                        ToolbarItem(placement: .primaryAction) { RefreshStatusButton(refreshingStatus: $refreshingStatus) }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 980, maxWidth: .infinity, minHeight: 650, maxHeight: .infinity, alignment: .topLeading)
            .sheet(item: $model.importDraft) { _ in ImportProjectView().environmentObject(model) }
            .alert(model.alertError?.message ?? "提示", isPresented: Binding(get: { model.alertError != nil }, set: { if !$0 { model.alertError = nil } })) {
                Button(model.hasExclusiveAccess ? "好" : "退出此副本", role: .cancel) {
                    if model.hasExclusiveAccess { model.alertError = nil } else { NSApp.terminate(nil) }
                }
            } message: { Text([model.alertError?.suggestion, model.alertError?.technical.isEmpty == false ? model.alertError?.technical : nil].compactMap { $0 }.joined(separator: "\n\n")) }
            .onReceive(NotificationCenter.default.publisher(for: .signFlowOpenMain)) { _ in openWindow(id: "main") }
            .onAppear { let action = openWindow; model.windowOpener = { action(id: "main") } }
    }

    private var sidebarSelectionColor: Color {
        let increasedContrast = colorSchemeContrast == .increased
        return .black.opacity(colorScheme == .dark
                              ? (increasedContrast ? 0.42 : 0.28)
                              : (increasedContrast ? 0.18 : 0.09))
    }
}

struct RefreshStatusButton: View {
    @EnvironmentObject private var model: AppModel
    @Binding var refreshingStatus: Bool

    var body: some View {
        Button {
            refreshingStatus = true
            Task {
                await model.refreshEnvironment()
                await model.refreshDevices()
                refreshingStatus = false
            }
        } label: { Label("刷新状态", systemImage: "arrow.clockwise") }
            .disabled(refreshingStatus || model.isRefreshing)
            .help("刷新开发环境与设备状态")
    }
}

private struct SidebarProjectExpiryRow: View {
    @EnvironmentObject private var model: AppModel
    var project: ManagedProject
    var now: Date

    var body: some View {
        let summary = SignatureExpirySummary(signatures: project.signatures, at: now)
        let status = summary.map { ($0.health == .invalid ? "签名无效，" : "") + $0.remainingText } ?? "尚无签名记录"
        Button { model.showProject(project.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(project.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if let summary {
                        Text(summary.remainingText).font(.caption2.weight(.medium))
                            .foregroundStyle(summary.health.color).fixedSize()
                    }
                }
                if let summary {
                    ProgressView(value: summary.remainingFraction)
                        .progressViewStyle(.linear).controlSize(.small).tint(summary.health.color)
                    if summary.health == .invalid {
                        Text("签名无效").font(.caption2).foregroundStyle(.red)
                    }
                } else {
                    Text("尚无签名记录").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(summary.map { "本地产物签名到期：\($0.expirationDate.formatted())" } ?? "尚无本地产物签名记录")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(project.name)，本地产物签名有效期，\(status)")
        .accessibilityHint("打开项目详情")
    }
}

struct ImportProjectView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading("添加项目", subtitle: "读取 Xcode 的真实 Scheme 和构建设置。")
            if let draft = model.importDraft {
                Picker("Xcode 工程", selection: Binding(get: { model.importDraft?.selectedPath ?? "" }, set: { model.importDraft?.selectedPath = $0; Task { await model.loadImportSchemes() } })) {
                    ForEach(draft.candidates, id: \.path) { url in Text(url.path).tag(url.path) }
                }
                Picker("Scheme", selection: Binding(get: { model.importDraft?.selectedScheme ?? "" }, set: { model.importDraft?.selectedScheme = $0 })) {
                    ForEach(draft.schemes, id: \.self) { Text($0).tag($0) }
                }.disabled(draft.loading || draft.schemes.isEmpty)
                if draft.schemes.count > 1 { Text("此工程包含多个 Scheme，请选择要独立管理的应用。可再次导入其他 Scheme。").font(.callout).foregroundStyle(.secondary) }
                if draft.loading { ProgressView("正在查询 Xcode…").controlSize(.small) }
                if let error = draft.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                Text("添加项目只读取元数据。自动续签默认关闭，构建和安装由项目操作或你启用的续签规则触发。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack { Spacer(); Button("取消") { model.importDraft = nil }.keyboardShortcut(.cancelAction); Button("添加项目") { Task { await model.finishImport() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(draft.loading || draft.selectedScheme.isEmpty) }
            }
        }.padding(28).frame(width: 650, height: 360)
    }
}
