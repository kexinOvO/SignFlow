import Foundation

protocol DeviceManaging: Sendable {
    func discover() async throws -> [ManagedDevice]
    func prepareForInstallation(_ device: ManagedDevice) async throws -> ManagedDevice
    func installation(bundleID: String, device: ManagedDevice) async throws -> DeploymentEvidence
    func install(app: URL, device: ManagedDevice, output: @escaping @Sendable (String) -> Void) async throws
    func launch(bundleID: String, device: ManagedDevice) async throws
}
extension DeviceManaging {
    func prepareForInstallation(_ device: ManagedDevice) async throws -> ManagedDevice { device }
}

struct DeviceService: DeviceManaging {
    let runner: any CommandExecuting
    var developerDirectory = ""
    // Use a file for compatibility with Xcode 15/16 (stdout JSON is newer).
    let temporaryRoot: URL
    var environment: [String: String] { developerDirectory.isEmpty ? [:] : ["DEVELOPER_DIR": developerDirectory] }
    func executeJSON(_ arguments: [String], timeout: TimeInterval = 45, output: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let file = temporaryRoot.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await runner.run(ToolCommand(executable: "/usr/bin/xcrun", arguments: ["devicectl"] + arguments + ["--timeout", String(Int(timeout)), "--json-output", file.path], environment: environment, timeout: timeout + 10), output: output)
        guard result.exitCode == 0 else { throw ErrorClassifier.classify(result.combined, fallback: arguments.contains("install") ? .install : .deviceConnection) }
        guard let data = try? Data(contentsOf: file), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let info = root["info"] as? [String: Any], info["outcome"] as? String == "success", let value = root["result"] as? [String: Any] else {
            throw FlowError(.verification, "设备工具未返回可验证的结果", technical: result.combined, suggestion: "刷新设备列表并查看诊断日志。")
        }
        return value
    }
    func discover() async throws -> [ManagedDevice] { try Self.parseDevices(try await executeJSON(["list", "devices"])) }
    static func parseDevices(_ result: [String: Any]) throws -> [ManagedDevice] {
        guard let rows = result["devices"] as? [[String: Any]] else { throw FlowError(.verification, "设备列表数据格式无法识别") }
        return rows.compactMap { item in
            guard let id = item["identifier"] as? String,
                  let hardware = item["hardwareProperties"] as? [String: Any],
                  hardware["reality"] as? String == "physical" else { return nil }
            let properties = item["deviceProperties"] as? [String: Any] ?? [:]
            let connection = item["connectionProperties"] as? [String: Any] ?? [:]
            let capabilities = (item["capabilities"] as? [[String: Any]] ?? []).compactMap { $0["featureIdentifier"] as? String }
            let platform = ApplePlatform(rawValue: hardware["platform"] as? String ?? "") ?? .unknown
            let tunnel = connection["tunnelState"] as? String ?? ""
            let pairing = connection["pairingState"] as? String ?? ""
            let boot = properties["bootState"] as? String ?? ""
            let state: ConnectionState = tunnel == "connected" ? .connected : tunnel == "unavailable" || boot == "shutdown" || pairing == "unpaired" ? .offline : (pairing == "paired" && boot == "booted" && capabilities.contains(where: { $0.contains("connectdevice") }) ? .available : .unknown)
            let modeString = properties["developerModeStatus"] as? String ?? ""
            let date = (connection["lastConnectionDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) ?? ISO8601DateFormatter.fractional.date(from: $0) }
            return ManagedDevice(id: id, udid: hardware["udid"] as? String ?? id, name: properties["name"] as? String ?? id, platform: platform, model: hardware["marketingName"] as? String ?? hardware["productType"] as? String ?? "未知设备", osVersion: properties["osVersionNumber"] as? String ?? "未知", connection: state, developerMode: DeveloperMode(rawValue: modeString) ?? .unknown, pairingState: pairing, transport: connection["transportType"] as? String ?? "未知", lastConnected: date, capabilities: capabilities, companionID: connection["companionIdentifier"] as? String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func prepareForInstallation(_ device: ManagedDevice) async throws -> ManagedDevice {
        // The paired/available list contains only connection capabilities until
        // CoreDevice establishes a tunnel. Resolve the live device before using
        // that snapshot to decide whether Watch supports direct installation.
        let help = try await runner.run(ToolCommand(executable: "/usr/bin/xcrun", arguments: ["devicectl", "device", "info", "details", "--help"], environment: environment, timeout: 20)).requireSuccess(category: .deviceConnection)
        var arguments = ["device", "info", "details", "--device", device.id]
        if help.combined.contains("--show") { arguments += ["--show", "detailed"] }
        let result = try await executeJSON(arguments)
        let row = result["device"] as? [String: Any] ?? result
        guard let resolved = try Self.parseDevices(["devices": [row]]).first,
              resolved.id == device.id, resolved.udid == device.udid, resolved.platform == device.platform else {
            throw FlowError(.verification, "连接后的设备信息与所选设备不一致", suggestion: "刷新设备列表并重新选择目标设备。", requiresUser: true)
        }
        guard resolved.canAttemptConnection else { throw FlowError(.deviceOffline, "\(device.name) 尚未连接", retryable: true) }
        return resolved
    }
    func installation(bundleID: String, device: ManagedDevice) async throws -> DeploymentEvidence {
        guard device.canAttemptConnection else { throw FlowError(.deviceOffline, "\(device.name) 不在线", retryable: true) }
        // Query developer apps and compare the bundle identifier locally, compatible with Xcode 15.
        let result = try await executeJSON(["device", "info", "apps", "--device", device.id])
        return try Self.parseInstallation(result, bundleID: bundleID, device: device)
    }
    static func parseInstallation(_ result: [String: Any], bundleID: String, device: ManagedDevice) throws -> DeploymentEvidence {
        guard let apps = result["apps"] as? [[String: Any]] else { throw FlowError(.verification, "设备应用列表格式无法识别，无法确认安装结果") }
        let app = apps.first { ($0["bundleIdentifier"] as? String) == bundleID }
        return DeploymentEvidence(deviceID: device.id, deviceName: device.name, bundleID: bundleID, platform: device.platform, state: app == nil ? .notInstalled : .installed, installedVersion: app?["version"] as? String ?? app?["shortVersionString"] as? String, installedBuild: app?["bundleVersion"] as? String, verifiedAt: Date(), message: app == nil ? "本次查询未发现此 Bundle ID 的开发应用。" : "已查询到此 Bundle ID。设备端 Provisioning Profile 无法通过公开工具读取；不据此推断签名到期时间。")
    }
    func install(app: URL, device: ManagedDevice, output: @escaping @Sendable (String) -> Void) async throws {
        guard device.canAttemptConnection else { throw FlowError(.deviceOffline, "\(device.name) 不在线", retryable: true) }
        guard device.developerMode != .disabled else { throw FlowError(.developerMode, "\(device.name) 未开启开发者模式", requiresUser: true) }
        if device.platform == .watchOS && !device.canInstall {
            throw FlowError(.watchConnection, "此 Watch 当前未公开直接安装能力", suggestion: "在 iPhone 的 Watch App 中安装配套应用，保持两台设备靠近后检查安装状态。", retryable: true)
        }
        _ = try await executeJSON(["device", "install", "app", "--device", device.id, app.path], timeout: 180, output: output)
    }
    func launch(bundleID: String, device: ManagedDevice) async throws {
        _ = try await executeJSON(["device", "process", "launch", "--device", device.id, bundleID])
    }
}

extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter { let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value }
}
