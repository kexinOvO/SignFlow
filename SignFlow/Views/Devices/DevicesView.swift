import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = model.deviceError { ErrorPanel(error: error).padding([.horizontal, .top], 28) }
            if model.state.devices.isEmpty {
                EmptyPanel(title: model.isRefreshing ? "正在查询设备" : "尚未发现设备", detail: "将设备连接到 Mac，解锁并完成信任授权。在 Xcode 的设备窗口确认配对状态后刷新。", symbol: "iphone.and.arrow.forward").frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    List(model.state.devices, selection: $selected) { device in
                        HStack(spacing: 12) {
                            Image(systemName: device.platform.symbol).font(.title2).foregroundStyle(device.canAttemptConnection ? .blue : .secondary).frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name).lineLimit(1).help(device.name)
                                Text(device.platform.rawValue + " " + device.osVersion + " · " + device.connection.title)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 7).tag(device.id)
                    }.listStyle(.inset).frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                    ScrollView {
                        if let device = model.state.devices.first(where: { $0.id == selected }) ?? model.state.devices.first {
                            VStack(alignment: .leading, spacing: 20) {
                                Surface(device.name) {
                                    InfoRow(title: "设备型号", value: device.model)
                                    InfoRow(title: "系统", value: device.platform.rawValue + " " + device.osVersion)
                                    InfoRow(title: "CoreDevice 标识", value: device.id, isIdentifier: true)
                                    InfoRow(title: "UDID", value: device.udid, isIdentifier: true)
                                    InfoRow(title: "连接状态", value: device.connection.title)
                                    InfoRow(title: "配对状态", value: device.pairingState)
                                    InfoRow(title: "连接方式", value: device.transport)
                                    InfoRow(title: "开发者模式", value: device.developerMode.title)
                                    InfoRow(title: "最近连接", value: device.lastConnected?.formatted() ?? "未知")
                                    InfoRow(title: "最近发现", value: device.lastDiscovered.formatted())
                                    if let companionID = device.companionID {
                                        InfoRow(title: "配套设备关联", value: companionID, isIdentifier: true)
                                    } else {
                                        InfoRow(title: "配套设备关联", value: "工具未提供可靠关联")
                                    }
                                    if device.platform == .watchOS { InfoRow(title: "当前直接安装能力", value: device.canInstall ? "CoreDevice 已公开能力" : "尚未公开，需同步后检查") }
                                }
                                Surface("关联项目与部署") {
                                    let projects = model.state.projects.filter { $0.phoneID == device.id || $0.watchID == device.id }
                                    if projects.isEmpty { Text("尚未关联项目。在项目详情的设备页选择这台设备。").foregroundStyle(.secondary) }
                                    ForEach(projects) { project in
                                        Button(project.name) { model.showProject(project.id) }.buttonStyle(.link)
                                        let deployments = project.deployments.filter { $0.deviceID == device.id }
                                        if deployments.isEmpty { Text("尚无安装验证记录").font(.caption).foregroundStyle(.secondary) }
                                        ForEach(deployments) { DeploymentRow(evidence: $0, estimate: model.installationEstimate(for: $0, in: project)) }
                                    }
                                }
                                Surface("连接诊断") {
                                    Text("已配对不代表 CoreDevice tunnel 已连接。安装或查询会尝试建立连接；具体失败原因以命令返回为准。").font(.callout).foregroundStyle(.secondary)
                                    if device.platform == .watchOS { Text("Watch 连接超时或 RemotePairing 1001 时，保持 iPhone 和 Watch 解锁、靠近，并在 Xcode 的设备窗口检查状态。SignFlow 不会重置配对关系。").font(.callout).foregroundStyle(.secondary) }
                                    Button("打开 Xcode 检查设备") { model.openXcode() }
                                }
                            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(minWidth: 360, idealWidth: 560, maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("设备")
        .navigationSubtitle("\(model.state.devices.count) 台设备")
    }
}
