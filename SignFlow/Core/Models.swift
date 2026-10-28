import Foundation

enum ProjectKind: String, Codable, Sendable { case project, workspace
    var flag: String { self == .workspace ? "-workspace" : "-project" }
}

enum ApplePlatform: String, Codable, CaseIterable, Sendable {
    case iOS, watchOS, macOS, unknown
    var symbol: String {
        switch self { case .iOS: return "iphone"; case .watchOS: return "applewatch"; case .macOS: return "macwindow"; case .unknown: return "questionmark.square" }
    }
    var destination: String { self == .watchOS ? "generic/platform=watchOS" : "generic/platform=iOS" }
}

enum TargetKind: String, Codable, Sendable { case application, watchApplication, appExtension, other }

struct TargetInfo: Codable, Hashable, Identifiable, Sendable {
    var id: String { name + ":" + bundleID }
    var name: String
    var bundleID: String
    var platform: ApplePlatform
    var kind: TargetKind
    var productType: String
    var teamID: String
    var automaticSigning: Bool
    var deploymentTarget: String
    var productPath: String?
    var companionBundleID: String?
}

struct RenewalPolicy: Codable, Equatable, Sendable {
    var enabled = false
    var intervalMinutes = 60
    var advanceHours = 48
    var maxRetries = 3
    var retryBaseSeconds = 60
    var installAutomatically = true
}

struct ManagedProject: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var path: String
    var kind: ProjectKind
    var bookmark: Data?
    var scheme: String
    var configuration = "Debug"
    var teamOverride = ""
    var allowProvisioningUpdates = true
    var allowDeviceRegistration = false
    var acceptExistingInstallRisk = false
    var targets: [TargetInfo] = []
    var phoneID: String?
    var watchID: String?
    var renewal = RenewalPolicy()
    var signatures: [SignedBundle] = []
    var deployments: [DeploymentEvidence] = []
    var lastCheck: Date?
    var lastRenewal: Date?
    var artifactPath: String?
    var customIconPath: String?
    var importedAt = Date()
    var platforms: [ApplePlatform] { Array(Set(targets.filter { $0.kind != .other }.map(\.platform))).sorted { $0.rawValue < $1.rawValue } }
    var primaryTarget: TargetInfo? { targets.first { $0.kind == .application && $0.platform == .iOS } ?? targets.first { $0.kind == .watchApplication || $0.kind == .application } }
    var bundleID: String { primaryTarget?.bundleID ?? "" }
    var hasWatch: Bool { targets.contains { $0.platform == .watchOS && $0.kind != .other } || signatures.contains { $0.platform == .watchOS } }
    var expiresAt: Date? { signatures.compactMap { $0.profile?.expirationDate }.min() }
}

struct ProfileCertificate: Codable, Equatable, Sendable {
    var name: String
    var fingerprint: String
    var expiresAt: Date?
    var teamID: String? = nil
}

struct ProvisioningProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String { uuid }
    var uuid: String
    var name: String
    var teamIDs: [String]
    var applicationIdentifier: String
    var creationDate: Date
    var expirationDate: Date
    var provisionedDevices: [String]
    var entitlements: [String: String]
    var certificates: [ProfileCertificate]
    var provisionsAllDevices: Bool
    var isDevelopment: Bool
    func health(at now: Date = Date(), advanceHours: Int = 48) -> SignatureHealth {
        if expirationDate <= now { return .expired }
        if expirationDate.timeIntervalSince(now) <= Double(advanceHours) * 3600 { return .expiring }
        return .valid
    }
    func matches(bundleID: String, teamID: String?) -> Bool {
        guard let prefix = applicationIdentifier.firstIndex(of: ".") else { return false }
        let identifier = String(applicationIdentifier[applicationIdentifier.index(after: prefix)...])
        let match = identifier.hasSuffix(".*") ? bundleID.hasPrefix(String(identifier.dropLast())) : (identifier == "*" || identifier == bundleID)
        return match && (teamID == nil || teamIDs.contains(teamID!))
    }
    func supports(deviceUDID: String) -> Bool { provisionsAllDevices || provisionedDevices.contains(deviceUDID) }
}

enum SignatureHealth: String, Codable, Sendable {
    case valid, expiring, expired, unsigned, unknown, invalid
    var title: String {
        switch self { case .valid: return "有效"; case .expiring: return "即将到期"; case .expired: return "已到期"; case .unsigned: return "未签名"; case .unknown: return "状态未知"; case .invalid: return "签名无效" }
    }
}

struct SignedBundle: Codable, Identifiable, Equatable, Sendable {
    var id: String { bundleID + "|" + path }
    var path: String
    var bundleID: String
    var displayName: String
    var version: String
    var buildVersion: String
    var platform: ApplePlatform
    var isExtension: Bool
    var parentBundleID: String?
    var teamID: String?
    var codeSignatureValid: Bool
    var validationMessage: String
    var profile: ProvisioningProfile?
    var inspectedAt: Date
    var health: SignatureHealth {
        if profile?.expirationDate ?? .distantFuture <= Date() { return .expired }
        guard codeSignatureValid else { return .invalid }
        return profile?.health() ?? .unsigned
    }
}

struct SignatureExpirySummary {
    let expirationDate: Date
    let remainingFraction: Double
    let remainingDays: Int?
    let health: SignatureHealth

    init?(signatures: [SignedBundle], at now: Date = Date()) {
        guard let profile = signatures.compactMap(\.profile).min(by: {
            if $0.expirationDate == $1.expirationDate { return $0.creationDate < $1.creationDate }
            return $0.expirationDate < $1.expirationDate
        }) else { return nil }

        let secondsRemaining = profile.expirationDate.timeIntervalSince(now)
        expirationDate = profile.expirationDate
        remainingFraction = max(0, min(1, secondsRemaining / max(1, profile.expirationDate.timeIntervalSince(profile.creationDate))))
        remainingDays = secondsRemaining > 0 ? max(1, Int(ceil(secondsRemaining / 86400))) : nil
        health = signatures.contains(where: { !$0.codeSignatureValid }) ? .invalid : profile.health(at: now)
    }
}

enum RenewalAssessment: String, Codable, Sendable {
    case advanced, unchanged, initialSignature, invalid
    var title: String {
        switch self { case .advanced: return "本地签名已更新"; case .unchanged: return "Profile 未延长"; case .initialSignature: return "首次建立签名基线"; case .invalid: return "签名验证未通过" }
    }
}

enum ConnectionState: String, Codable, Sendable { case connected, available, offline, unknown
    var title: String {
        switch self { case .connected: return "已连接"; case .available: return "已配对，待连接"; case .offline: return "设备离线"; case .unknown: return "状态未知" }
    }
}
enum DeveloperMode: String, Codable, Sendable { case enabled, disabled, unknown
    var title: String { self == .enabled ? "已开启" : self == .disabled ? "未开启" : "无法确认" }
}

struct ManagedDevice: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var udid: String
    var name: String
    var platform: ApplePlatform
    var model: String
    var osVersion: String
    var connection: ConnectionState
    var developerMode: DeveloperMode
    var pairingState: String
    var transport: String
    var lastConnected: Date?
    var lastDiscovered: Date = Date()
    var capabilities: [String]
    var companionID: String?
    var canAttemptConnection: Bool { connection == .connected || connection == .available }
    var canInstall: Bool { capabilities.contains { $0.lowercased().contains("installapp") || $0.lowercased().contains("install.app") } }
}

enum InstallationState: String, Codable, Sendable {
    case installed, notInstalled, offline, unknown, failed, awaitingWatchSync
    var title: String {
        switch self { case .installed: return "已安装"; case .notInstalled: return "未安装"; case .offline: return "设备离线"; case .unknown: return "安装状态未知"; case .failed: return "部署失败"; case .awaitingWatchSync: return "等待 Watch 安装验证" }
    }
}

struct DeploymentEvidence: Codable, Identifiable, Equatable, Sendable {
    var id: String { deviceID + "|" + bundleID }
    var deviceID: String
    var deviceName: String
    var bundleID: String
    var platform: ApplePlatform
    var state: InstallationState
    var installedVersion: String?
    var installedBuild: String?
    var verifiedAt: Date
    var sourceTaskID: UUID?
    // CoreDevice exposes installation metadata, not the installed embedded profile.
    var deviceSignatureVerified = false
    var message: String
}

enum TaskKind: String, Codable, CaseIterable, Sendable {
    case inspect, buildInstall, renew, verifyInstallation
    var title: String {
        switch self { case .inspect: return "检查签名"; case .buildInstall: return "构建并安装"; case .renew: return "续签并部署"; case .verifyInstallation: return "检查设备安装" }
    }
}

enum TaskPhase: String, Codable, CaseIterable, Sendable {
    case queued, checking, needsRenewal, preparing, building, verifyingSignature, waitingDevice, installing, verifyingInstallation
    case completed, cancelled, waitingUser, retryableFailure, failed, partialSuccess
    var title: String {
        switch self {
        case .queued: return "待检查"; case .checking: return "检查中"; case .needsRenewal: return "待续签"
        case .preparing: return "准备构建"; case .building: return "构建中"; case .verifyingSignature: return "验证签名"
        case .waitingDevice: return "等待设备"; case .installing: return "安装中"; case .verifyingInstallation: return "验证安装"
        case .completed: return "已完成"; case .cancelled: return "已取消"; case .waitingUser: return "等待用户操作"
        case .retryableFailure: return "可重试失败"; case .failed: return "不可重试失败"; case .partialSuccess: return "部分成功"
        }
    }
    var isTerminal: Bool { [.completed, .cancelled, .failed, .partialSuccess].contains(self) }
    var isExecuting: Bool { [.checking, .needsRenewal, .preparing, .building, .verifyingSignature, .installing, .verifyingInstallation].contains(self) }
    var progress: Double {
        switch self {
        case .queued: return 0; case .checking: return 0.08; case .needsRenewal: return 0.12; case .preparing: return 0.18
        case .building: return 0.4; case .verifyingSignature: return 0.65; case .waitingDevice: return 0.7
        case .installing: return 0.8; case .verifyingInstallation: return 0.92; case .completed: return 1
        default: return 0
        }
    }
}

struct TaskEvent: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date = Date()
    var phase: TaskPhase
    var message: String
}

struct FlowTask: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var projectID: UUID
    var projectName: String
    var kind: TaskKind
    var phase: TaskPhase = .queued
    var createdAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var updatedAt = Date()
    var retryCount = 0
    // Last allocated build directory; independent of the automatic retry budget.
    var buildAttempt: Int?
    var projectResultCommittedAt: Date?
    var nextRetryAt: Date?
    var automatic = false
    // Keep the automatic origin for retry budgets, while allowing this explicit
    // user request to run independently of automation switches.
    var manualRetryRequested: Bool?
    var recovered = false
    var artifactPath: String?
    var oldSignatures: [SignedBundle] = []
    var newSignatures: [SignedBundle] = []
    var deployments: [DeploymentEvidence] = []
    var assessment: RenewalAssessment?
    var error: FlowError?
    var summary = "等待调度"
    var events: [TaskEvent] = []
    var logPath: String?
    var duration: TimeInterval? { startedAt.map { (finishedAt ?? Date()).timeIntervalSince($0) } }
    mutating func transition(_ phase: TaskPhase, _ message: String, now: Date = Date()) {
        self.phase = phase; summary = message; updatedAt = now
        projectResultCommittedAt = nil
        if startedAt == nil && phase != .queued { startedAt = now }
        if phase.isTerminal { finishedAt = now } else { finishedAt = nil }
        events.append(TaskEvent(date: now, phase: phase, message: message))
    }
}

enum ErrorCategory: String, Codable, Sendable {
    case environment, project, build, signing, profileUnchanged, authentication, entitlements
    case developerMode, deviceOffline, deviceConnection, watchConnection, install, verification, permission, timeout, cancelled, persistence, registry, unknown
}

struct FlowError: Error, LocalizedError, Codable, Equatable, Sendable {
    var category: ErrorCategory
    var message: String
    var technical: String
    var suggestion: String
    var retryable: Bool
    var requiresUser: Bool
    init(_ category: ErrorCategory, _ message: String, technical: String = "", suggestion: String = "", retryable: Bool = false, requiresUser: Bool = false) {
        self.category = category; self.message = message; self.technical = LogRedactor.redact(technical)
        self.suggestion = suggestion; self.retryable = retryable; self.requiresUser = requiresUser
    }
    var errorDescription: String? { message }
    static func wrap(_ error: Error) -> FlowError {
        if let value = error as? FlowError { return value }
        if error is CancellationError { return FlowError(.cancelled, "操作已取消") }
        return FlowError(.unknown, "操作未完成", technical: error.localizedDescription, suggestion: "请查看技术日志以确认原因。")
    }
}

struct SigningIdentity: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var teamID: String?
    var expiresAt: Date?
}

struct XcodeEnvironment: Codable, Equatable, Sendable {
    var developerDirectory = ""
    var version = ""
    var swiftVersion = ""
    var sdks = ""
    var devicectlPath: String?
    var supportsProvisioningUpdates = false
    var supportsDeviceRegistration = false
    var errors: [String] = []
    var checkedAt = Date()
    var ready: Bool { !developerDirectory.isEmpty && version.contains("Xcode") && errors.isEmpty }
}

struct AppSettings: Codable, Equatable, Sendable {
    var appearance = "system"
    var language = "zh-Hans"
    var showMenuBar = true
    var keepRunning = true
    var automationEnabled = false
    var automationPaused = false
    var intervalMinutes = 60
    var advanceHours = 48
    var installAutomatically = true
    var retryOffline = true
    var xcodePath = ""
    var defaultConfiguration = "Debug"
    var defaultProjectPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/xcode/Projects").path
    var derivedDataPath = ""
    var maxConcurrentTasks = 1
    var logRetentionDays = 30
    var notifyExpiry = true
    var notifyInstall = true
    var notifyRenewal = true
    var notifyFailure = true
    var notifyUserAction = true
    var notifyDevice = false
}

struct PersistedState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var projects: [ManagedProject] = []
    var devices: [ManagedDevice] = []
    var tasks: [FlowTask] = []
    var settings = AppSettings()
    var lastSchedulerCheck: Date?
    enum CodingKeys: String, CodingKey { case schemaVersion, projects, devices, tasks, settings, lastSchedulerCheck }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard schemaVersion <= 1 else { throw FlowError(.persistence, "此数据由更新版本的 SignFlow 创建，请更新应用。") }
        projects = try c.decodeIfPresent([ManagedProject].self, forKey: .projects) ?? []
        devices = try c.decodeIfPresent([ManagedDevice].self, forKey: .devices) ?? []
        tasks = try c.decodeIfPresent([FlowTask].self, forKey: .tasks) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        lastSchedulerCheck = try c.decodeIfPresent(Date.self, forKey: .lastSchedulerCheck)
        schemaVersion = 1
    }
}
