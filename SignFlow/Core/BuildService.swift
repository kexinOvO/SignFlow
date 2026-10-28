import Foundation

struct BuildRequest: Sendable {
    var project: ManagedProject
    var taskID: UUID
    var outputRoot: URL
    var developerDirectory: String
    var destinationUDID: String?
    var supportsProvisioningUpdates: Bool
    var supportsDeviceRegistration: Bool
    var attempt = 0
    // nil is an ordinary build; even an empty renewal baseline requests the
    // renewal preflight, without guessing which global profiles may be changed.
    var renewalBaseline: [SignedBundle]? = nil
}
struct BuildProduct: Sendable {
    var app: URL
    var derivedData: URL
    var command: ToolCommand
}
protocol AppBuilding: Sendable {
    func build(_ request: BuildRequest, output: @escaping @Sendable (String) -> Void) async throws -> BuildProduct
}

struct BuildService: AppBuilding {
    let runner: any CommandExecuting
    var profileRefresher: (any ProfileRefreshing)? = nil
    func build(_ request: BuildRequest, output: @escaping @Sendable (String) -> Void) async throws -> BuildProduct {
        let command = try Self.command(for: request)
        let operation: @Sendable () async throws -> BuildProduct = {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: request.outputRoot, withIntermediateDirectories: true)
            let result = try await runner.run(command, output: output)
            _ = try result.requireSuccess(category: .build)
            try Task.checkCancellation()
            let derived = Self.taskDirectory(request).appendingPathComponent("DerivedData")
            let app = try Self.findApplication(in: derived.appendingPathComponent("Build/Products"), bundleID: request.project.bundleID)
            return BuildProduct(app: app, derivedData: derived, command: command)
        }
        if let profileRefresher { return try await profileRefresher.withFreshProfiles(for: request, output: output, build: operation) }
        guard request.renewalBaseline == nil else { throw FlowError(.signing, "续签刷新服务不可用", suggestion: "重新启动 SignFlow 后重试。", requiresUser: true) }
        return try await operation()
    }
    static func command(for request: BuildRequest) throws -> ToolCommand {
        let project = request.project
        guard !project.scheme.isEmpty, !project.bundleID.isEmpty else { throw FlowError(.project, "缺少可构建的 Scheme 或 Bundle ID") }
        guard project.primaryTarget?.platform == .iOS || project.primaryTarget?.platform == .watchOS else { throw FlowError(.project, "仅支持 iOS 和 watchOS 应用构建") }
        let output = request.outputRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let source = URL(fileURLWithPath: project.path).deletingLastPathComponent().resolvingSymlinksInPath().path
        guard output != source, !output.hasPrefix(source + "/"), output != "/", output != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw FlowError(.permission, "构建输出目录不能位于所管理项目的源码目录内", suggestion: "使用 SignFlow 默认的独立 DerivedData 目录。", requiresUser: true)
        }
        let taskRoot = taskDirectory(request)
        let derived = taskRoot.appendingPathComponent("DerivedData")
        let destination = request.destinationUDID.map { "id=\($0)" } ?? (project.primaryTarget?.platform ?? .iOS).destination
        var arguments = [project.kind.flag, project.path, "-scheme", project.scheme, "-configuration", project.configuration,
                         "-destination", destination, "-destination-timeout", "30", "-derivedDataPath", derived.path,
                         "-clonedSourcePackagesDirPath", taskRoot.appendingPathComponent("SourcePackages").path,
                         "-resultBundlePath", taskRoot.appendingPathComponent("Build.xcresult").path,
                         "CODE_SIGN_STYLE=Automatic"]
        if !project.teamOverride.isEmpty { arguments.append("DEVELOPMENT_TEAM=\(project.teamOverride)") }
        if project.allowProvisioningUpdates {
            guard request.supportsProvisioningUpdates else { throw FlowError(.environment, "当前 Xcode 不支持自动更新 Provisioning", requiresUser: true) }
            arguments.append("-allowProvisioningUpdates")
        }
        if project.allowDeviceRegistration {
            guard project.allowProvisioningUpdates && request.supportsDeviceRegistration else { throw FlowError(.environment, "当前配置无法自动注册设备", requiresUser: true) }
            arguments.append("-allowProvisioningDeviceRegistration")
        }
        if request.renewalBaseline != nil {
            guard project.allowProvisioningUpdates else { throw FlowError(.signing, "续签需要允许 Xcode 更新签名资源", suggestion: "在项目设置中开启自动更新 Provisioning 后重试。", requiresUser: true) }
            arguments += ["PROVISIONING_PROFILE=", "PROVISIONING_PROFILE_SPECIFIER="]
        }
        arguments.append("build")
        return ToolCommand(executable: "/usr/bin/xcodebuild", arguments: arguments, environment: request.developerDirectory.isEmpty ? [:] : ["DEVELOPER_DIR": request.developerDirectory], workingDirectory: URL(fileURLWithPath: project.path).deletingLastPathComponent().path, timeout: 1800)
    }
    static func taskDirectory(_ request: BuildRequest) -> URL { request.outputRoot.appendingPathComponent(request.taskID.uuidString).appendingPathComponent("Attempt-\(request.attempt)") }
    static func nextAttempt(taskID: UUID, outputRoot: URL, after previous: Int?, legacyAttempt: Int = 0) throws -> Int {
        guard previous != Int.max else { throw FlowError(.persistence, "构建次数记录无效", requiresUser: true) }
        var attempt = previous.map { max(0, $0) + 1 } ?? max(0, legacyAttempt)
        let directory = outputRoot.appendingPathComponent(taskID.uuidString)
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent("Attempt-\(attempt)").path) {
            guard attempt < Int.max else { throw FlowError(.persistence, "无法分配新的构建目录", requiresUser: true) }
            attempt += 1
        }
        return attempt
    }
    static func findApplication(in products: URL, bundleID: String) throws -> URL {
        guard let iterator = FileManager.default.enumerator(at: products, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { throw FlowError(.build, "构建完成，但未找到 App 产物") }
        var matches: [URL] = []
        for case let url as URL in iterator where url.pathExtension == "app" {
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            if info?["CFBundleIdentifier"] as? String == bundleID { matches.append(url) }
            iterator.skipDescendants()
        }
        guard matches.count == 1, let app = matches.first else {
            throw FlowError(.build, matches.isEmpty ? "构建完成，但没有找到对应 Bundle ID 的 App" : "找到多个同 Bundle ID 产物，无法安全选择", technical: "Bundle ID: \(bundleID)\nProducts: \(products.path)")
        }
        return app
    }
}
