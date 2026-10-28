import SwiftUI

struct SigningView: View {
    @EnvironmentObject var model: AppModel
    @State private var loadingProfiles = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Surface("Xcode 开发环境") {
                    HStack { StatusPill(title: model.environment.ready ? "环境已就绪" : "环境需要检查", color: model.environment.ready ? .green : .orange, symbol: "hammer.fill"); Spacer(); Button("配置 Xcode 账户…") { model.openXcodeAccounts() } }
                    InfoRow(title: "版本", value: model.environment.version)
                    InfoRow(title: "开发者目录", value: model.environment.developerDirectory)
                    InfoRow(title: "Swift", value: model.environment.swiftVersion)
                    InfoRow(title: "设备工具", value: model.environment.devicectlPath ?? "不可用")
                    InfoRow(title: "自动 Provisioning 更新", value: model.environment.supportsProvisioningUpdates ? "工具链支持，仍需账户授权" : "不支持")
                    ForEach(model.environment.errors, id: \.self) { Text($0).foregroundStyle(.orange) }
                    DisclosureGroup("已安装 SDK") { Text(model.environment.sdks).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }
                Surface("Personal Team") {
                    Label("免费账户签名通常只有 7 天有效期", systemImage: "info.circle").foregroundStyle(.blue)
                    Text("先在 Xcode → 设置 → 账户中登录 Apple 账户，并在项目的 Signing & Capabilities 中选择 Personal Team。免费账户存在 App ID、设备、安装数量及能力限制；命令行能否无交互刷新以 Apple 与 Xcode 的实际返回为准。").font(.callout).foregroundStyle(.secondary)
                    Text("SignFlow 不接收 Apple ID 密码，不保存令牌或私钥。续签只有在 Profile 有效期真正延长、签名通过并完成独立部署验证后才记为完成。").font(.callout).foregroundStyle(.secondary)
                }
                Surface("本地签名身份与团队") {
                    if model.identities.isEmpty { Text("尚无可用的代码签名身份。请在 Xcode 账户设置中创建开发证书。").foregroundStyle(.secondary) }
                    ForEach(model.identities) { identity in
                        VStack(alignment: .leading, spacing: 7) {
                            Label(identity.name, systemImage: "person.crop.rectangle.badge.checkmark").font(.headline)
                            InfoRow(title: "Team ID", value: identity.teamID ?? "未识别")
                            InfoRow(title: "证书到期", value: identity.expiresAt?.formatted() ?? "无法读取")
                            Text(identity.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if identity.id != model.identities.last?.id { Divider() }
                    }
                    Text("团队来自可用证书与项目设置。仅凭 Team ID 不判断是否为 Personal Team；请在 Xcode 中确认成员资格。").font(.caption).foregroundStyle(.secondary)
                }
                Surface {
                    HStack { Text("本机 Provisioning Profiles").font(.headline); Spacer(); Button("读取 Profiles") { Task { loadingProfiles = true; await model.loadProfileLibrary(); loadingProfiles = false } }.disabled(loadingProfiles) }
                    if loadingProfiles { ProgressView().controlSize(.small) }
                    if model.profileLibrary.isEmpty { Text("尚未读取到 Profile。也可在项目签名页查看构建产物内的 Profile。").foregroundStyle(.secondary) }
                    ForEach(model.profileLibrary) { profile in DisclosureGroup(profile.name + " · " + profile.expirationDate.formatted(date: .abbreviated, time: .omitted)) { ProfileDetails(profile: profile).padding(.top, 12) } }
                    if !model.profileReadErrors.isEmpty { DisclosureGroup("\(model.profileReadErrors.count) 个 Profile 读取失败") { ForEach(model.profileReadErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).textSelection(.enabled) } } }
                }
                Surface("已导入项目") {
                    if model.state.projects.isEmpty { Text("尚未导入项目").foregroundStyle(.secondary) }
                    ForEach(model.state.projects) { project in HStack { Button(project.name) { model.showProject(project.id) }.buttonStyle(.link); Spacer(); Text(project.expiresAt?.formatted() ?? "尚无签名基线").foregroundStyle(.secondary) } }
                }
            }.padding(28)
        }
        .navigationTitle("签名与账户")
        .navigationSubtitle("\(model.identities.count) 个本地签名身份")
    }
}
