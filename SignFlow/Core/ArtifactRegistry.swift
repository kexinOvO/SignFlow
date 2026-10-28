import Foundation

struct ArtifactRegistry: Sendable {
    let runner: any CommandExecuting
    static var defaultExecutable: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Codex/monitor/bin/aar").path }
    var executable: String = ArtifactRegistry.defaultExecutable
    func register(path: URL, project: URL, type: String, source: String, rebuild: [String]? = nil, acceptModified: Bool = false) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw FlowError(.registry, "中央 AAR 登记工具不可用", technical: executable, suggestion: "恢复 aar 命令后重试；本次产物未登记。") }
        var arguments = ["register", "--path", path.path, "--project", project.path, "--type", type, "--source", source, "--json"]
        if let rebuild {
            let json = String(data: try JSONEncoder().encode(rebuild), encoding: .utf8)!
            arguments += ["--regenerable", "--argv-json", json]
        }
        // Runtime products can contain user source package checkouts. Do not mark them
        // recursively deletable. No cleanup command is ever executed by this app.
        if acceptModified { arguments.append("--accept-modified") }
        let result = try await runner.run(ToolCommand(executable: executable, arguments: arguments, timeout: 30))
        guard result.exitCode == 0 else { throw FlowError(.registry, "中央 AAR 产物登记失败", technical: result.combined, suggestion: "产物已保留，登记未成功。请检查中央数据库权限。") }
    }
}

// Explicit seam for a future IPA adapter; unsupported imports fail before mutation.
protocol ApplicationArtifactSource: Sendable { func applicationBundles() async throws -> [URL] }
struct ExistingAppSource: ApplicationArtifactSource {
    var url: URL
    func applicationBundles() async throws -> [URL] { try SigningService.bundleURLs(in: url) }
}
struct IPAArtifactSource: ApplicationArtifactSource {
    var url: URL
    func applicationBundles() async throws -> [URL] {
        throw FlowError(.project, "不支持此包：通用 IPA 重签尚未启用", suggestion: "请导入可构建的 Xcode 工程；IPA 需要单独验证 Entitlements 和适用 Profile。")
    }
}
