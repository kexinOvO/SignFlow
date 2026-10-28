import Foundation

enum ToolJSON {
    static func value(_ string: String) throws -> Any {
        let data = Data(string.utf8)
        if let result = try? JSONSerialization.jsonObject(with: data) { return result }
        // Xcode occasionally writes diagnostic lines before its JSON document.
        for index in string.indices where string[index] == "{" || string[index] == "[" {
            if let value = try? JSONSerialization.jsonObject(with: Data(string[index...].utf8)) { return value }
        }
        throw FlowError(.verification, "系统工具返回了无法识别的数据", technical: String(string.suffix(4000)))
    }
}

struct ProjectService: Sendable {
    let runner: any CommandExecuting
    let metadataRoot: URL
    var developerDirectory: String = ""
    var environment: [String: String] { developerDirectory.isEmpty ? [:] : ["DEVELOPER_DIR": developerDirectory] }
    func cacheDirectory(for url: URL) -> URL { metadataRoot.appendingPathComponent(XcodeProjectGraph.cacheKey(url), isDirectory: true) }

    static func candidates(at url: URL, maxDepth: Int = 5) throws -> [URL] {
        let fm = FileManager.default
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard fm.fileExists(atPath: url.path), fm.isReadableFile(atPath: url.path) else {
            throw FlowError(.project, "项目不存在或没有读取权限", technical: url.path, suggestion: "使用添加项目重新选择真实项目位置。", requiresUser: true)
        }
        if ["xcodeproj", "xcworkspace"].contains(url.pathExtension.lowercased()) { return [url] }
        guard let iterator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        let skip = Set(["build", "DerivedData", "node_modules", "Pods", "Carthage", "work", "output"])
        var result: [URL] = []
        for case let item as URL in iterator {
            if iterator.level > maxDepth || skip.contains(item.lastPathComponent) { iterator.skipDescendants(); continue }
            if ["xcodeproj", "xcworkspace"].contains(item.pathExtension.lowercased()) {
                result.append(item); iterator.skipDescendants()
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func kind(for url: URL) throws -> ProjectKind {
        switch url.pathExtension.lowercased() { case "xcodeproj": return .project; case "xcworkspace": return .workspace
        default: throw FlowError(.project, "请选择 .xcodeproj、.xcworkspace 或包含工程的目录") }
    }

    func schemes(at url: URL) async throws -> [String] {
        let kind = try Self.kind(for: url)
        let cache = cacheDirectory(for: url)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let result = try await runner.run(ToolCommand(executable: "/usr/bin/xcodebuild", arguments: [kind.flag, url.path, "-list", "-json", "-disableAutomaticPackageResolution", "-skipPackageUpdates", "-clonedSourcePackagesDirPath", cache.appendingPathComponent("SourcePackages").path], environment: environment, workingDirectory: url.deletingLastPathComponent().path, timeout: 120)).requireSuccess(category: .project)
        return try Self.parseSchemes(result.stdout)
    }

    static func parseSchemes(_ json: String) throws -> [String] {
        guard let root = try ToolJSON.value(json) as? [String: Any],
              let container = (root["workspace"] ?? root["project"]) as? [String: Any],
              let schemes = container["schemes"] as? [String] else {
            throw FlowError(.project, "Xcode 未返回有效的 Scheme 列表")
        }
        let values = Array(Set(schemes)).sorted()
        guard !values.isEmpty else { throw FlowError(.project, "项目没有可用的 Scheme", suggestion: "在 Xcode → Manage Schemes 中创建并共享一个 App Scheme。", requiresUser: true) }
        return values
    }

    func inspect(url: URL, scheme: String, configuration: String = "Debug", bookmark: Data? = nil) async throws -> ManagedProject {
        let kind = try Self.kind(for: url)
        let root = cacheDirectory(for: url).appendingPathComponent("Metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let arguments = [kind.flag, url.path, "-scheme", scheme, "-configuration", configuration,
                         "-showBuildSettings", "-json", "-derivedDataPath", root.path,
                         "-disableAutomaticPackageResolution", "-skipPackageUpdates"]
        let result = try await runner.run(ToolCommand(executable: "/usr/bin/xcodebuild", arguments: arguments, environment: environment, workingDirectory: url.deletingLastPathComponent().path, timeout: 180)).requireSuccess(category: .project)
        var targets = try Self.parseBuildSettings(result.stdout)
        // Follow actual Embed App / Extension phases, including cross-project proxies.
        // An unrelated Watch scheme in a workspace is never assumed to be a companion.
        if let primary = targets.first(where: { $0.kind == .application || $0.kind == .watchApplication }) {
            for reference in try XcodeProjectGraph.embeddedTargets(container: url, mainTargetName: primary.name) {
                try Task.checkCancellation()
                guard !targets.contains(where: { $0.name == reference.name }) else { continue }
                let extra = ["-project", reference.projectURL.path, "-target", reference.name, "-configuration", configuration, "-showBuildSettings", "-json", "-disableAutomaticPackageResolution", "-skipPackageUpdates", "SYMROOT=\(root.appendingPathComponent("Products").path)", "OBJROOT=\(root.appendingPathComponent("Intermediates").path)"]
                let nestedResult = try await runner.run(ToolCommand(executable: "/usr/bin/xcodebuild", arguments: extra, environment: environment, workingDirectory: reference.projectURL.deletingLastPathComponent().path, timeout: 120)).requireSuccess(category: .project)
                for target in try Self.parseBuildSettings(nestedResult.stdout) where !targets.contains(where: { $0.id == target.id }) { targets.append(target) }
            }
        }
        guard targets.contains(where: { [.application, .watchApplication].contains($0.kind) && [.iOS, .watchOS].contains($0.platform) }) else {
            throw FlowError(.project, "此 Scheme 没有可部署的 iOS 或 watchOS App", suggestion: "请选择主应用或 Watch App 的 Scheme。")
        }
        let primary = targets.first { $0.platform == .iOS && $0.kind == .application } ?? targets.first { $0.kind == .watchApplication || $0.kind == .application }
        return ManagedProject(name: primary?.name ?? scheme, path: url.path, kind: kind, bookmark: bookmark, scheme: scheme, configuration: configuration, targets: targets)
    }

    static func parseBuildSettings(_ json: String) throws -> [TargetInfo] {
        guard let rows = try ToolJSON.value(json) as? [[String: Any]] else { throw FlowError(.project, "无法解析 Build Settings") }
        return rows.compactMap { row in
            guard let settings = row["buildSettings"] as? [String: Any] else { return nil }
            func s(_ key: String) -> String { settings[key] as? String ?? "" }
            let product = s("PRODUCT_TYPE")
            let sdk = s("PLATFORM_NAME").isEmpty ? s("SDKROOT") : s("PLATFORM_NAME")
            let platform: ApplePlatform = sdk.contains("watch") ? .watchOS : (sdk.contains("iphone") || sdk.contains("ios")) ? .iOS : sdk.contains("mac") ? .macOS : .unknown
            let kind: TargetKind = product.contains("extension") ? .appExtension : product.contains("watchapp") ? .watchApplication : product.contains("application") ? (platform == .watchOS ? .watchApplication : .application) : .other
            let path = s("TARGET_BUILD_DIR").isEmpty || s("FULL_PRODUCT_NAME").isEmpty ? nil : URL(fileURLWithPath: s("TARGET_BUILD_DIR")).appendingPathComponent(s("FULL_PRODUCT_NAME")).path
            return TargetInfo(name: row["target"] as? String ?? s("TARGET_NAME"), bundleID: s("PRODUCT_BUNDLE_IDENTIFIER"), platform: platform, kind: kind, productType: product, teamID: s("DEVELOPMENT_TEAM"), automaticSigning: s("CODE_SIGN_STYLE") == "Automatic", deploymentTarget: s(platform == .watchOS ? "WATCHOS_DEPLOYMENT_TARGET" : "IPHONEOS_DEPLOYMENT_TARGET"), productPath: path, companionBundleID: s("INFOPLIST_KEY_WKCompanionAppBundleIdentifier").isEmpty ? nil : s("INFOPLIST_KEY_WKCompanionAppBundleIdentifier"))
        }
    }
}

struct XcodeService: Sendable {
    let runner: any CommandExecuting
    var overrideDirectory = ""
    var environment: [String: String] { overrideDirectory.isEmpty ? [:] : ["DEVELOPER_DIR": overrideDirectory] }
    func inspect() async -> XcodeEnvironment {
        var result = XcodeEnvironment()
        do {
            let directory: String
            if overrideDirectory.isEmpty {
                directory = try await runner.run(ToolCommand(executable: "/usr/bin/xcode-select", arguments: ["-p"])).requireSuccess(category: .environment).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            } else { directory = overrideDirectory }
            guard FileManager.default.fileExists(atPath: directory + "/usr/bin/xcodebuild") else {
                throw FlowError(.environment, "当前开发者目录不包含完整 Xcode", suggestion: "在设置中选择 Xcode.app，或安装完整 Xcode。")
            }
            result.developerDirectory = directory
            result.version = try await runner.run(ToolCommand(executable: "/usr/bin/xcodebuild", arguments: ["-version"], environment: environment)).requireSuccess(category: .environment).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            result.swiftVersion = try await runner.run(ToolCommand(executable: "/usr/bin/xcrun", arguments: ["swift", "--version"], environment: environment)).requireSuccess(category: .environment).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            result.sdks = try await runner.run(ToolCommand(executable: "/usr/bin/xcodebuild", arguments: ["-showsdks"], environment: environment)).requireSuccess(category: .environment).stdout
            let help = try await runner.run(ToolCommand(executable: "/usr/bin/xcodebuild", arguments: ["-help"], environment: environment))
            result.supportsProvisioningUpdates = help.combined.contains("-allowProvisioningUpdates")
            result.supportsDeviceRegistration = help.combined.contains("-allowProvisioningDeviceRegistration")
            let device = try await runner.run(ToolCommand(executable: "/usr/bin/xcrun", arguments: ["--find", "devicectl"], environment: environment))
            if device.exitCode == 0 { result.devicectlPath = device.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
            for tool in ["/usr/bin/codesign", "/usr/bin/security", "/usr/bin/xcrun"] where !FileManager.default.isExecutableFile(atPath: tool) { result.errors.append("缺少系统工具：\(tool)") }
        } catch { result.errors.append(FlowError.wrap(error).message) }
        return result
    }
}
