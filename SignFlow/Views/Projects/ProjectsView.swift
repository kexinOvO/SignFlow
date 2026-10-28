import SwiftUI
import AppKit

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    var projects: [ManagedProject] { model.state.projects.filter { model.search.isEmpty || ($0.name + $0.path + $0.bundleID + $0.scheme).localizedCaseInsensitiveContains(model.search) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if projects.isEmpty {
                    Surface {
                        EmptyPanel(title: model.search.isEmpty ? "把你的 App 交给 SignFlow" : "没有匹配的项目", detail: model.search.isEmpty ? "添加 iOS 或 watchOS 的 Xcode 工程，统一查看签名有效期、构建任务和设备部署状态。" : "试试其他项目名称、路径或 Bundle ID。", symbol: "square.stack.3d.up", actionTitle: model.search.isEmpty ? "添加第一个项目" : nil, action: model.addProject)
                    }
                } else {
                    ProjectCardGrid {
                        ForEach(projects) { project in ProjectCard(project: project) }
                    }
                }
                HStack { Text("工作台概览").font(.title3.weight(.semibold)); Spacer(); Text("来自本机实时查询与任务记录").font(.caption).foregroundStyle(.secondary) }.padding(.top, 8)
                DashboardOverview()
                if let warning = model.registryWarning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(28)
        }
        .navigationTitle("项目")
        .navigationSubtitle("\(model.state.projects.count) 个项目")
        .searchable(text: $model.search, placement: .toolbar, prompt: "搜索项目、Scheme 或 Bundle ID")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: model.addProject) { Label("添加项目", systemImage: "plus") }
                    .help("添加 Xcode 项目")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("检查全部项目", action: model.checkAll)
                    Button("执行到期续签") { model.renewDue() }
                    Button("导出任务日志") { model.exportLogs() }
                } label: { Label("更多项目操作", systemImage: "ellipsis") }
                    .help("更多项目操作")
            }
        }
    }
}

// Measure every card at its actual column width so differing content can share
// one height without clipping, including when the window or project state changes.
private struct ProjectCardGrid: Layout {
    private let minimumColumnWidth: CGFloat = 335
    private let spacing: CGFloat = 20

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? minimumColumnWidth
        let metrics = measure(width: width, subviews: subviews)
        return CGSize(width: width, height: metrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = measure(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let column = index % metrics.columnCount
            let row = index / metrics.columnCount
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * (metrics.columnWidth + spacing),
                            y: bounds.minY + CGFloat(row) * (metrics.cardHeight + spacing)),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: metrics.columnWidth, height: metrics.cardHeight)
            )
        }
    }

    private func measure(width: CGFloat, subviews: Subviews) -> (columnCount: Int, columnWidth: CGFloat, cardHeight: CGFloat, height: CGFloat) {
        let columnCount = max(1, Int((width + spacing) / (minimumColumnWidth + spacing)))
        let columnWidth = (width - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)
        let cardHeight = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
        let rowCount = (subviews.count + columnCount - 1) / columnCount
        let height = CGFloat(rowCount) * cardHeight + CGFloat(max(0, rowCount - 1)) * spacing
        return (columnCount, columnWidth, cardHeight, height)
    }
}

struct ProjectCard: View {
    @EnvironmentObject var model: AppModel
    var project: ManagedProject
    var busy: Bool { model.pendingTasks.contains { $0.projectID == project.id } }
    var body: some View {
        Surface(fillsHeight: true) {
            HStack(alignment: .top, spacing: 13) {
                HStack(alignment: .top, spacing: 0) {
                    Button {
                        model.showProject(project.id)
                    } label: {
                        ProjectArtwork(project: project)
                            .padding(.trailing, 13)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("查看详情")
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Button {
                            model.showProject(project.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(project.name).font(.title3.weight(.semibold))
                                HStack(spacing: 7) { ForEach(project.platforms, id: \.self) { platform in Label(platform.rawValue, systemImage: platform.symbol).font(.caption).foregroundStyle(.secondary) } }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("查看详情")
                        .accessibilityLabel("查看 \(project.name) 详情")
                        .accessibilityValue(project.platforms.map(\.rawValue).joined(separator: "、"))
                        ZStack(alignment: .leading) {
                            // Reserve the same intrinsic height even when there is no task.
                            Label(" ", systemImage: "clock")
                                .font(.caption)
                                .hidden()
                                .accessibilityHidden(true)
                            if let task = model.pendingTasks.first(where: { $0.projectID == project.id }) {
                                Button { model.selectedTaskID = task.id; model.page = .tasks } label: { Label(task.phase.title + " · " + task.summary, systemImage: "clock").font(.caption).lineLimit(1) }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(task.phase.color)
                                    .help(task.phase.title + " · " + task.summary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ProjectActions(project: project)
            }
            Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(project.path)
            VStack(alignment: .leading, spacing: 6) {
                Label(project.scheme, systemImage: "hammer").lineLimit(1)
                Text(project.bundleID.isEmpty ? "Bundle ID 未识别" : project.bundleID).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.font(.callout)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                ForEach(project.platforms.filter { [.iOS, .watchOS].contains($0) }, id: \.self) { platform in
                    HStack {
                        Label(platform == .watchOS ? "Apple Watch" : "iPhone / iPad", systemImage: platform.symbol).font(.callout)
                        Spacer(minLength: 4)
                        let evidence = project.selectedDeployment(for: platform)
                        StatusPill(title: evidence?.state.title ?? "安装状态未知", color: evidence?.state.color ?? .secondary, symbol: evidence?.state == .installed ? "checkmark.circle.fill" : "questionmark.circle")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                ExpiryView(signatures: project.signatures)
                HStack(spacing: 8) {
                    Button { model.enqueue(project.id, kind: .buildInstall) } label: { Label("构建并安装", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                    Button("立即续签") { model.enqueue(project.id, kind: .renew) }.buttonStyle(.bordered)
                    Spacer(minLength: 0)
                    Button { model.showProject(project.id) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("查看详情").accessibilityLabel("查看 \(project.name) 详情")
                }.disabled(busy)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

struct ProjectActions: View {
    @EnvironmentObject var model: AppModel
    var project: ManagedProject
    var body: some View {
        Menu {
            Button("检查签名") { model.enqueue(project.id, kind: .inspect) }
            Button("检查设备安装") { model.enqueue(project.id, kind: .verifyInstallation) }
            Button("查看详情 / 编辑设置") { model.showProject(project.id) }
            Button("查看最近任务") { model.showTasks(project.id) }
            Divider()
            Button("选择项目图标…") { model.selectProjectIcon(project) }
            if project.customIconPath != nil {
                Button("恢复自动图标") { model.resetProjectIcon(project) }
            }
            Divider()
            Button("在 Xcode 中打开") { model.openXcode(project) }
            Button("在 Finder 中显示") { model.reveal(project) }
            Button("复制工程路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.path, forType: .string)
            }
            Divider()
            Button("从 SignFlow 移除", role: .destructive) { model.removeProject(project.id) }
        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("项目操作").accessibilityLabel("\(project.name) 项目操作")
    }
}

struct DashboardOverview: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], alignment: .leading, spacing: 16) {
            Surface("设备状态") {
                Label("\(model.state.devices.filter(\.canAttemptConnection).count) 台设备可尝试连接", systemImage: "iphone.and.arrow.forward").font(.callout)
                Text(model.state.devices.isEmpty ? "连接并解锁设备后刷新。" : model.state.devices.prefix(2).map(\.name).joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button("管理设备") { model.page = .devices }.buttonStyle(.link)
            }
            Surface("签名与账户") {
                Label(model.environment.ready ? "Xcode 环境已就绪" : "Xcode 环境待检查", systemImage: "checkmark.shield").font(.callout)
                Text("\(model.identities.count) 个本地签名身份 · 账户由 Xcode 管理").font(.caption).foregroundStyle(.secondary)
                Button("查看签名资源") { model.page = .signing }.buttonStyle(.link)
            }
            Surface("自动任务") {
                Label(model.state.settings.automationEnabled ? model.state.settings.automationPaused ? "自动续签已暂停" : "自动续签已启用" : "自动续签未开启", systemImage: "arrow.triangle.2.circlepath").font(.callout)
                Text("\(model.pendingTasks.count) 个待处理任务 · 默认提前 \(model.state.settings.advanceHours) 小时").font(.caption).foregroundStyle(.secondary)
                Button("配置自动续签") { model.page = .settings }.buttonStyle(.link)
            }
            Surface("最近任务") {
                if let task = model.state.tasks.first {
                    Text(task.projectName).font(.callout)
                    Text(task.phase.title + " · " + task.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Button("查看任务") { model.selectedTaskID = task.id; model.page = .tasks }.buttonStyle(.link)
                } else { Text("还没有任务记录").font(.callout); Text("导入项目后开始第一次检查。 ").font(.caption).foregroundStyle(.secondary); Button("查看任务日志") { model.page = .tasks }.buttonStyle(.link) }
            }
        }
    }
}
