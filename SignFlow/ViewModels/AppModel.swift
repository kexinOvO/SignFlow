import AppKit
import SwiftUI
import Combine
import UserNotifications
import UniformTypeIdentifiers

enum SidebarPage: String, CaseIterable, Identifiable {
    case projects = "项目", devices = "设备", signing = "签名与账户", tasks = "任务日志", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .projects: return "square.grid.2x2"; case .devices: return "iphone.and.arrow.forward"; case .signing: return "checkmark.shield"; case .tasks: return "clock.arrow.circlepath"; case .settings: return "gearshape" }
    }
}

struct ImportDraft: Identifiable {
    var id = UUID()
    var rootURL: URL
    var bookmark: Data?
    var candidates: [URL]
    var selectedPath: String
    var schemes: [String] = []
    var selectedScheme = ""
    var error: String?
    var loading = false
}

@MainActor
final class AppModel: ObservableObject {
    @Published var state = PersistedState()
    @Published var page: SidebarPage? = .projects
    @Published var selectedProjectID: UUID?
    @Published var selectedTaskID: UUID?
    @Published var environment = XcodeEnvironment()
    @Published var identities: [SigningIdentity] = []
    @Published var profileLibrary: [ProvisioningProfile] = []
    @Published var profileReadErrors: [String] = []
    @Published var notificationError: String?
    @Published var deviceError: FlowError?
    @Published var alertError: FlowError?
    @Published var registryWarning: String?
    @Published var registryError: FlowError?
    @Published var isRefreshing = false
    @Published var importDraft: ImportDraft?
    @Published var logTails: [UUID: String] = [:]
    @Published var search = ""
    @Published var loginStatus = ""
    @Published var notificationStatus = "未授权"
    let repository: StateRepository
    let runner: any CommandExecuting
    let background = BackgroundService()
    let notifications = NotificationService()
    var windowOpener: (() -> Void)?
    private let mutex = ProjectMutex()
    private lazy var profileRefresher = ProfileRefreshService(backupRoot: dataRoot.appendingPathComponent("SigningBackups"), decoder: SigningService(runner: runner), registry: ArtifactRegistry(runner: runner))
    private var lease: InstanceLease?
    private var active: [UUID: Task<Void, Never>] = [:]
    private var launched = false
    private(set) var isStopping = false
    private var startupTask: Task<Void, Never>?
    private var stoppingBackgroundTasks: [Task<Void, Never>] = []
    private let workflow: (any WorkflowRunning)?
    private var canPersist = true
    private var tickInProgress = false
    private var lastDeviceRefresh: Date?
    private var scopedURLs: [UUID: URL] = [:]
    private var suspendedTasks: [UUID: String] = [:]
    var dataRoot: URL { repository.directory }
    var hasExclusiveAccess: Bool { lease != nil }
    var outputRoot: URL { state.settings.derivedDataPath.isEmpty ? dataRoot.appendingPathComponent("Builds") : URL(fileURLWithPath: state.settings.derivedDataPath).appendingPathComponent("SignFlowBuilds") }
    var developerDirectory: String {
        let value = state.settings.xcodePath
        return value.hasSuffix(".app") ? value + "/Contents/Developer" : value
    }
    var projectService: ProjectService { ProjectService(runner: runner, metadataRoot: dataRoot.appendingPathComponent("Inspection"), developerDirectory: developerDirectory) }
    var deviceService: DeviceService { DeviceService(runner: runner, developerDirectory: developerDirectory, temporaryRoot: dataRoot.appendingPathComponent("Inspection/DeviceQueries")) }
    var selectedProject: ManagedProject? { state.projects.first { $0.id == selectedProjectID } }
    func installationEstimate(for evidence: DeploymentEvidence, in project: ManagedProject) -> InstalledProfileEstimateStatus? {
        guard project.selectedDeployment(for: evidence.platform)?.id == evidence.id else { return nil }
        return InstalledProfileEstimateResolver.resolve(project: project, platform: evidence.platform, tasks: state.tasks)
    }
    var runningTasks: [FlowTask] { state.tasks.filter { active[$0.id] != nil || $0.phase == .queued } }
    var pendingTasks: [FlowTask] { state.tasks.filter { !$0.phase.isTerminal } }
    var nextExpiring: ManagedProject? { state.projects.filter { $0.expiresAt != nil }.min { $0.expiresAt! < $1.expiresAt! } }
    var appearance: ColorScheme? { state.settings.appearance == "light" ? .light : state.settings.appearance == "dark" ? .dark : nil }

    init(runner: any CommandExecuting = ProcessCommandRunner(), repository: StateRepository? = nil, workflow: (any WorkflowRunning)? = nil) {
        self.runner = runner
        self.workflow = workflow
        if let repository { self.repository = repository }
        else if let index = CommandLine.arguments.firstIndex(of: "--storage-root"), CommandLine.arguments.count > index + 1 {
            self.repository = StateRepository(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } else { self.repository = StateRepository() }
        do {
            lease = try InstanceLease(directory: self.repository.directory)
            state = try self.repository.load()
            TaskResultCommitter.reconcile(&state)
            state.tasks = RecoveryPolicy.recover(state.tasks)
        } catch { canPersist = false; alertError = FlowError.wrap(error) }
    }
    func start() async {
        guard !launched, !isStopping, canPersist else { return }; launched = true
        let startup = Task { [weak self] in
            guard let self else { return }
            await self.initialize()
        }
        startupTask = startup
        await startup.value
        startupTask = nil
    }
    private func initialize() async {
        guard !isStopping, !Task.isCancelled else { return }
        for project in state.projects { restoreAccess(project) }
        notifications.configure()
        notifications.onOpen = { [weak self] project, task in
            guard let self else { return }; self.openMainWindow()
            if let id = project.flatMap(UUID.init(uuidString:)) { self.selectedProjectID = id; self.page = .projects }
            if let id = task.flatMap(UUID.init(uuidString:)) { self.selectedTaskID = id; self.page = .tasks }
        }
        do { try await profileRefresher.recover() }
        catch {
            guard !isStopping, !Task.isCancelled else { return }
            alertError = FlowError.wrap(error); state.settings.automationPaused = true
        }
        guard !isStopping, !Task.isCancelled else { return }
        await refreshEnvironment()
        guard !isStopping, !Task.isCancelled else { return }
        await refreshDevices()
        guard !isStopping, !Task.isCancelled else { return }
        loginStatus = background.loginStatus
        await updateNotificationStatus()
        guard !isStopping, !Task.isCancelled else { return }
        background.start { [weak self] in await self?.tick() }
        save(); pump()
    }
    func save() {
        guard canPersist else { return }
        do { try repository.save(state) } catch {
            alertError = FlowError.wrap(error); state.settings.automationPaused = true; canPersist = false
            for task in active.values { task.cancel() }
        }
    }
    func updateSettings(_ action: (inout AppSettings) -> Void) {
        guard !isStopping else { return }
        var settings = state.settings; action(&settings)
        guard settings != state.settings else { return }
        state.settings = settings
        if !settings.automationEnabled || settings.automationPaused {
            for (id, running) in active where state.tasks.first(where: { $0.id == id })?.automatic == true {
                guard state.tasks.first(where: { $0.id == id })?.manualRetryRequested != true else { continue }
                suspendedTasks[id] = "自动任务已暂停；恢复调度后重新验证并继续。"; running.cancel()
            }
        }
        save(); pump()
    }
    func menuBarVisibilityChanged(_ visible: Bool) {
        guard visible != state.settings.showMenuBar else { return }
        // SwiftUI can write this binding while reconciling the scene graph.
        Task { @MainActor [weak self] in self?.updateSettings { $0.showMenuBar = visible } }
    }
    func updateProject(_ project: ManagedProject) {
        guard !isStopping, let index = state.projects.firstIndex(where: { $0.id == project.id }) else { return }
        state.projects[index] = project
        if !project.renewal.enabled {
            for (id, running) in active where state.tasks.first(where: { $0.id == id })?.projectID == project.id && state.tasks.first(where: { $0.id == id })?.automatic == true {
                guard state.tasks.first(where: { $0.id == id })?.manualRetryRequested != true else { continue }
                suspendedTasks[id] = "此项目的自动任务已暂停；重新启用后继续。"; running.cancel()
            }
        }
        save(); pump()
    }
    func showProject(_ id: UUID) { selectedProjectID = id; page = .projects }
    func showTasks(_ projectID: UUID? = nil) {
        selectedTaskID = state.tasks.first { projectID == nil || $0.projectID == projectID }?.id; page = .tasks
    }
    func removeProject(_ id: UUID) {
        guard !state.tasks.contains(where: { $0.projectID == id && !$0.phase.isTerminal }) else {
            alertError = FlowError(.project, "此项目仍有未结束的任务", suggestion: "先取消任务，再移除管理记录。项目源码不会被删除。"); return
        }
        state.projects.removeAll { $0.id == id }
        if let url = scopedURLs.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
        if selectedProjectID == id { selectedProjectID = nil }; save()
    }
    func restoreAccess(_ project: ManagedProject) {
        guard let data = project.bookmark else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            if url.startAccessingSecurityScopedResource() { scopedURLs[project.id] = url }
            // Bookmark may refer to an authorized parent directory. Project path remains explicit.
            if stale { registryWarning = "部分项目的目录授权已过期，请在项目详情重新定位。" }
        } catch { registryWarning = "项目目录授权无法恢复：\(project.name)。请重新定位项目。" }
    }
    func addProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择 Xcode 工程、Workspace 或包含它们的目录"
        panel.directoryURL = URL(fileURLWithPath: state.settings.defaultProjectPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let candidates = try ProjectService.candidates(at: url)
            guard let first = candidates.first else { throw FlowError(.project, "此目录中未找到 Xcode 工程或 Workspace") }
            let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            importDraft = ImportDraft(rootURL: url, bookmark: bookmark, candidates: candidates, selectedPath: first.path)
            Task { await loadImportSchemes() }
        } catch { alertError = FlowError.wrap(error) }
    }
    func loadImportSchemes() async {
        guard let draft = importDraft else { return }
        let id = draft.id, path = draft.selectedPath
        importDraft?.loading = true; importDraft?.error = nil; importDraft?.schemes = []
        do {
            let schemes = try await projectService.schemes(at: URL(fileURLWithPath: path))
            guard importDraft?.id == id, importDraft?.selectedPath == path else { return }
            importDraft?.schemes = schemes; importDraft?.selectedScheme = schemes.first ?? ""; importDraft?.loading = false
        } catch { guard importDraft?.id == id else { return }; importDraft?.error = FlowError.wrap(error).message; importDraft?.loading = false }
    }
    func finishImport() async {
        guard let draft = importDraft, !draft.selectedScheme.isEmpty else { return }
        importDraft?.loading = true
        do {
            if state.projects.contains(where: { $0.path == draft.selectedPath && $0.scheme == draft.selectedScheme }) { throw FlowError(.project, "此工程的这个 Scheme 已导入") }
            var project = try await projectService.inspect(url: URL(fileURLWithPath: draft.selectedPath), scheme: draft.selectedScheme, configuration: state.settings.defaultConfiguration, bookmark: draft.bookmark)
            project.renewal.intervalMinutes = state.settings.intervalMinutes; project.renewal.advanceHours = state.settings.advanceHours
            project.renewal.installAutomatically = state.settings.installAutomatically
            state.projects.append(project); restoreAccess(project); save(); selectedProjectID = project.id; page = .projects; importDraft = nil
            await registerInspection(project)
        } catch { importDraft?.error = FlowError.wrap(error).message; importDraft?.loading = false }
    }
    func relocate(_ project: ManagedProject) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.message = "重新选择 \(project.name) 的 .xcodeproj 或 .xcworkspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let candidates = try ProjectService.candidates(at: url)
                guard candidates.count == 1, let candidate = candidates.first else { throw FlowError(.project, "此目录包含多个工程，请直接选择一个工程包。") }
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                let checked = try await projectService.inspect(url: candidate, scheme: project.scheme, configuration: project.configuration, bookmark: bookmark)
                var value = project; value.path = checked.path; value.kind = checked.kind; value.targets = checked.targets; value.bookmark = bookmark
                updateProject(value); restoreAccess(value)
            } catch { alertError = FlowError.wrap(error) }
        }
    }
    func refreshProjectMetadata(_ project: ManagedProject) async {
        do {
            let value = try await projectService.inspect(url: URL(fileURLWithPath: project.path), scheme: project.scheme, configuration: project.configuration, bookmark: project.bookmark)
            guard var current = state.projects.first(where: { $0.id == project.id }) else { return }
            current.targets = value.targets; updateProject(current)
            await registerInspection(current)
        } catch { alertError = FlowError.wrap(error) }
    }
    func selectArtifact(_ project: ManagedProject) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.message = "选择一个现有 .app；只读取和检查签名"
        guard panel.runModal() == .OK, let url = panel.url, url.pathExtension == "app" else { return }
        var value = project; value.artifactPath = url.path; updateProject(value); enqueue(project.id, kind: .inspect)
    }
    func selectProjectIcon(_ project: ManagedProject) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "选择用于项目卡片的图标图片"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ProjectIconResolver.image(at: url) != nil else {
            alertError = FlowError(.project, "无法读取所选图片", suggestion: "请选择有效的图标图片。")
            return
        }
        guard var value = state.projects.first(where: { $0.id == project.id }) else { return }
        value.customIconPath = url.path; updateProject(value)
    }
    func resetProjectIcon(_ project: ManagedProject) {
        guard var value = state.projects.first(where: { $0.id == project.id }) else { return }
        value.customIconPath = nil; updateProject(value)
    }
    func refreshEnvironment() async {
        environment = await XcodeService(runner: runner, overrideDirectory: developerDirectory).inspect()
        do { identities = try await SigningService(runner: runner).identities() } catch { alertError = FlowError.wrap(error) }
    }
    func refreshDevices() async {
        guard !isRefreshing else { return }; isRefreshing = true; defer { isRefreshing = false }
        do {
            let old = state.devices
            let found = try await deviceService.discover()
            // Keep previously known devices visible, with explicitly stale/offline state.
            let missing = old.filter { previous in !found.contains { $0.id == previous.id } }.map { previous -> ManagedDevice in var value = previous; value.connection = .offline; return value }
            state.devices = found + missing; deviceError = nil; lastDeviceRefresh = Date(); save()
            if state.settings.notifyDevice {
                for device in found where device.canAttemptConnection && old.first(where: { $0.id == device.id })?.canAttemptConnection == false {
                    await notifications.send(key: "device-\(device.id)-\(Date().formatted(.dateTime.day()))", title: "设备重新可用", body: device.name)
                }
            }
        } catch { deviceError = FlowError.wrap(error); state.devices = state.devices.map { var value = $0; value.connection = .unknown; return value } }
    }
    func loadProfileLibrary() async {
        let roots = ["Library/MobileDevice/Provisioning Profiles", "Library/Developer/Xcode/UserData/Provisioning Profiles"]
        var profiles: [ProvisioningProfile] = []
        var errors: [String] = []
        let service = SigningService(runner: runner)
        for path in roots {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
            catch { errors.append(url.path + ": " + error.localizedDescription); continue }
            for file in files where ["mobileprovision", "provisionprofile"].contains(file.pathExtension) {
                do { let profile = try await service.decodeProfile(at: file); if !profiles.contains(where: { $0.uuid == profile.uuid }) { profiles.append(profile) } }
                catch { errors.append(file.lastPathComponent + ": " + FlowError.wrap(error).message) }
            }
        }
        profileLibrary = profiles.sorted { $0.expirationDate < $1.expirationDate }
        profileReadErrors = errors
    }
    func enqueue(_ projectID: UUID, kind: TaskKind, automatic: Bool = false) {
        guard canPersist, !isStopping, let project = state.projects.first(where: { $0.id == projectID }) else { return }
        if automatic && !canRunAutomatically(project) { return }
        let pending = state.tasks.filter { $0.projectID == projectID && !$0.phase.isTerminal }
        let readOnlyWhileWaiting = [.inspect, .verifyInstallation].contains(kind) && pending.allSatisfy { [.waitingDevice, .waitingUser, .retryableFailure].contains($0.phase) && $0.kind != kind }
        guard pending.isEmpty || readOnlyWhileWaiting else {
            if !automatic { alertError = FlowError(.build, "项目已有待处理任务", suggestion: "查看最近任务，继续、重试或取消该任务。") }; return
        }
        var task = FlowTask(projectID: project.id, projectName: project.name, kind: kind, automatic: automatic)
        task.oldSignatures = project.signatures
        task.logPath = dataRoot.appendingPathComponent("Logs/\(task.id.uuidString).log").path
        state.tasks.insert(task, at: 0); save(); pump()
    }
    private func pump() {
        guard canPersist, !isStopping else { return }
        let slots = max(1, min(4, state.settings.maxConcurrentTasks)) - active.count
        guard slots > 0 else { return }
        var paths = Set(active.keys.compactMap { id in state.tasks.first { $0.id == id }.flatMap { task in state.projects.first { $0.id == task.projectID }?.path } })
        for task in state.tasks.filter({ $0.phase == .queued }) {
            guard active.count < max(1, min(4, state.settings.maxConcurrentTasks)), let project = state.projects.first(where: { $0.id == task.projectID }), !paths.contains(project.path) else { continue }
            if !canRun(task, project: project) { continue }
            paths.insert(project.path)
            active[task.id] = Task { [weak self] in await self?.execute(task, project: project) }
        }
    }
    private func execute(_ task: FlowTask, project: ManagedProject) async {
        guard await mutex.acquire(project) else { active.removeValue(forKey: task.id); return }
        guard !isStopping, !Task.isCancelled, state.projects.first(where: { $0.id == project.id }).map({ canRun(task, project: $0) }) == true else {
            suspendedTasks.removeValue(forKey: task.id)
            await mutex.release(project); active.removeValue(forKey: task.id); return
        }
        let service = deviceService
        let engine: any WorkflowRunning = workflow ?? RenewalEngine(builder: BuildService(runner: runner, profileRefresher: profileRefresher), signer: SigningService(runner: runner), devices: service)
        let context = WorkflowContext(project: project, environment: environment, devices: state.devices, outputRoot: outputRoot, installAutomatically: task.automatic ? (state.settings.installAutomatically && project.renewal.installAutomatically) : true, trustExistingInstallation: project.acceptExistingInstallRisk)
        let logger: TaskLog
        do {
            guard let path = task.logPath else { throw FlowError(.persistence, "任务缺少日志路径") }
            logger = try TaskLog(url: URL(fileURLWithPath: path))
        } catch {
            var result = task; result.error = FlowError(.persistence, "无法创建任务日志，已停止执行", technical: error.localizedDescription, requiresUser: true)
            result.transition(.failed, result.error!.message); receive(result)
            await mutex.release(project); active.removeValue(forKey: task.id); pump(); return
        }
        let id = task.id
        let output: @Sendable (String) -> Void = { [weak self] chunk in
            let visible = logger.append(chunk)
            Task { @MainActor [weak self] in
                guard let self else { return }; self.logTails[id, default: ""] += visible
                if self.logTails[id, default: ""].count > 100_000 { self.logTails[id] = String(self.logTails[id]!.suffix(100_000)) }
            }
        }
        var result = await engine.execute(task: task, context: context, update: { [weak self] updated in
            guard let self else { return }
            await self.receiveProgress(updated, project: project, context: context)
        }, output: output)
        logger.append("\n\(result.phase.title)：\(result.summary)\n\(result.error?.technical ?? "")\n"); logger.finish()
        if let failure = logger.failureMessage {
            result.error = FlowError(.persistence, "任务日志写入失败", technical: failure, requiresUser: true)
            if result.phase == .completed { result.transition(.partialSuccess, "操作已执行，但任务日志未完整保存。") }
        }
        if let reason = suspendedTasks.removeValue(forKey: task.id), result.phase == .cancelled {
            result.error = nil; result.nextRetryAt = nil; result.transition(.queued, reason)
        }
        if result.phase == .retryableFailure {
            let next = RecoveryPolicy.nextRetry(count: result.retryCount, maxRetries: project.renewal.maxRetries, base: project.renewal.retryBaseSeconds)
            result.nextRetryAt = next
            if next == nil { result.transition(result.assessment == .advanced ? .partialSuccess : .failed, "重试次数已用尽。\(result.summary)") }
        } else if result.phase == .waitingDevice { result.nextRetryAt = Date().addingTimeInterval(60) }
        if result.phase != .queued { result.manualRetryRequested = nil }
        receive(result)
        if [.buildInstall, .renew].contains(result.kind), result.buildAttempt != nil {
            await registerBuild(task: result, project: project, context: context)
        }
        await notify(result)
        await mutex.release(project); active.removeValue(forKey: id); pump()
    }
    private func receive(_ task: FlowTask) {
        TaskResultCommitter.record(task, in: &state); save()
    }
    private func receiveProgress(_ task: FlowTask, project: ManagedProject, context: WorkflowContext) async {
        // The final result is committed after log flush and retry/suspension
        // policy, so a provisional completion cannot update lastRenewal early.
        guard task.phase.isExecuting || task.phase == .queued else { return }
        receive(task)
        if task.phase == .building, task.buildAttempt != nil { await registerBuild(task: task, project: project, context: context) }
    }
    private func canRunAutomatically(_ project: ManagedProject) -> Bool {
        !isStopping && project.renewal.enabled && state.settings.automationEnabled && !state.settings.automationPaused && !CommandLine.arguments.contains("--no-automation")
    }
    private func canRun(_ task: FlowTask, project: ManagedProject) -> Bool {
        !isStopping && (!task.automatic || task.manualRetryRequested == true || canRunAutomatically(project))
    }
    func cancel(_ id: UUID) {
        if let task = active[id] { task.cancel() }
        else if let index = state.tasks.firstIndex(where: { $0.id == id }) {
            state.tasks[index].manualRetryRequested = nil
            state.tasks[index].transition(.cancelled, "用户取消任务"); save()
        }
    }
    func retry(_ id: UUID) {
        guard canPersist, !isStopping, active[id] == nil, let index = state.tasks.firstIndex(where: { $0.id == id }), state.tasks[index].phase != .completed else { return }
        let projectID = state.tasks[index].projectID
        guard !state.tasks.contains(where: { $0.id != id && $0.projectID == projectID && !$0.phase.isTerminal }) else { alertError = FlowError(.build, "项目已有其他待处理任务"); return }
        let error = state.tasks[index].error
        if let category = error?.category, [.profileUnchanged, .signing, .authentication, .entitlements, .build, .project].contains(category) {
            state.tasks[index].artifactPath = nil; state.tasks[index].newSignatures = []; state.tasks[index].deployments = []; state.tasks[index].assessment = nil
        }
        state.tasks[index].manualRetryRequested = true
        state.tasks[index].error = nil; state.tasks[index].nextRetryAt = nil; state.tasks[index].transition(.queued, "用户请求立即重试"); save(); pump()
    }
    func checkAll() { for project in state.projects { enqueue(project.id, kind: .inspect) } }
    func renewDue(manual: Bool = true) {
        for project in state.projects {
            if let expiry = project.expiresAt, expiry.timeIntervalSinceNow <= Double(project.renewal.advanceHours) * 3600 {
                enqueue(project.id, kind: .renew, automatic: !manual)
            }
        }
    }
    func tick() async {
        guard !tickInProgress, !isStopping, canPersist else { return }; tickInProgress = true; defer { tickInProgress = false }
        if lastDeviceRefresh.map({ Date().timeIntervalSince($0) > 60 }) ?? true { await refreshDevices() }
        guard !isStopping, !Task.isCancelled else { return }
        let now = Date()
        for index in state.tasks.indices {
            guard active[state.tasks[index].id] == nil else { continue }
            let task = state.tasks[index]
            if task.automatic && state.projects.first(where: { $0.id == task.projectID }).map({ canRun(task, project: $0) }) != true { continue }
            if task.phase == .waitingDevice && state.settings.retryOffline && (task.nextRetryAt ?? .distantPast) <= now {
                guard let project = state.projects.first(where: { $0.id == task.projectID }),
                      state.devices.contains(where: { ($0.id == project.phoneID || $0.id == project.watchID) && $0.canAttemptConnection }) else { continue }
                state.tasks[index].nextRetryAt = now.addingTimeInterval(120); state.tasks[index].transition(.queued, "设备可能已恢复，重新验证后继续")
            } else if task.phase == .retryableFailure, let next = task.nextRetryAt, next <= now {
                state.tasks[index].retryCount += 1; state.tasks[index].transition(.queued, "按指数退避策略重试")
            }
        }
        if state.settings.automationEnabled && !state.settings.automationPaused && !CommandLine.arguments.contains("--no-automation") {
            for project in state.projects where project.renewal.enabled {
                if let expiry = project.expiresAt {
                    if expiry.timeIntervalSince(now) <= Double(project.renewal.advanceHours) * 3600 {
                        if state.settings.notifyExpiry { await notifications.send(key: "expiry-\(project.id)-\(Int(expiry.timeIntervalSince1970))", title: "\(project.name) 即将到期", body: "本地产物签名有效期：\(expiry.formatted())。正在检查续签条件。", projectID: project.id) }
                        // Exhausted and partial automatic tasks require an explicit retry. Never
                        // start a new retry budget every scheduler tick for the same baseline.
                        if SchedulingPolicy.canCreateAutomaticRenewal(project: project, tasks: state.tasks) {
                            enqueue(project.id, kind: .renew, automatic: true)
                        }
                    } else if project.lastCheck.map({ now.timeIntervalSince($0) >= Double(project.renewal.intervalMinutes) * 60 }) ?? true {
                        enqueue(project.id, kind: .inspect, automatic: true)
                    }
                } else if project.artifactPath != nil { enqueue(project.id, kind: .inspect, automatic: true) }
                // No baseline: the first real build is explicitly initiated in the UI.
            }
        }
        state.lastSchedulerCheck = now; save(); pump()
    }
    private func notify(_ task: FlowTask) async {
        guard !isStopping else { return }
        guard [.completed, .failed, .partialSuccess, .retryableFailure, .waitingUser, .waitingDevice].contains(task.phase) else { return }
        let s = state.settings
        let should = task.phase == .completed ? (task.kind == .renew ? s.notifyRenewal : s.notifyInstall) : task.phase == .waitingUser ? s.notifyUserAction : s.notifyFailure
        guard should else { return }
        await notifications.send(key: "task-\(task.id)-\(task.phase.rawValue)", title: "\(task.projectName) · \(task.phase.title)", body: task.summary, projectID: task.projectID, taskID: task.id)
        notificationError = notifications.lastError
    }
    private func registerInspection(_ project: ManagedProject) async {
        let cache = projectService.cacheDirectory(for: URL(fileURLWithPath: project.path))
        let derived = cache.appendingPathComponent("Metadata")
        do {
            try await ArtifactRegistry(runner: runner).register(path: cache, project: dataRoot, type: "CACHE", source: "SignFlow runtime metadata; source project \(project.path); scheme \(project.scheme)", rebuild: ["/usr/bin/env", "DEVELOPER_DIR=" + environment.developerDirectory, "/usr/bin/xcodebuild", project.kind.flag, project.path, "-scheme", project.scheme, "-derivedDataPath", derived.path, "-showBuildSettings", "-json", "-disableAutomaticPackageResolution", "-skipPackageUpdates"], acceptModified: true)
            registryWarning = nil; registryError = nil
        } catch { let error = FlowError.wrap(error); registryWarning = error.message; registryError = error }
    }
    private func registerBuild(task: FlowTask, project: ManagedProject, context: WorkflowContext) async {
        do {
            let primaryID = project.primaryTarget?.platform == .watchOS ? project.watchID : project.phoneID
            let device = context.devices.first { $0.id == primaryID && $0.canAttemptConnection }
            let request = BuildRequest(project: project, taskID: task.id, outputRoot: context.outputRoot, developerDirectory: context.environment.developerDirectory, destinationUDID: device?.udid, supportsProvisioningUpdates: context.environment.supportsProvisioningUpdates, supportsDeviceRegistration: context.environment.supportsDeviceRegistration, attempt: task.buildAttempt ?? task.retryCount, renewalBaseline: task.kind == .renew ? (task.oldSignatures.isEmpty ? project.signatures : task.oldSignatures) : nil)
            let command = try BuildService.command(for: request)
            try FileManager.default.createDirectory(at: context.outputRoot, withIntermediateDirectories: true)
            let argv = context.environment.developerDirectory.isEmpty ? [command.executable] + command.arguments : ["/usr/bin/env", "DEVELOPER_DIR=" + context.environment.developerDirectory, command.executable] + command.arguments
            try await ArtifactRegistry(runner: runner).register(path: BuildService.taskDirectory(request), project: context.outputRoot, type: "BUILD", source: "SignFlow managed builds; source project \(project.path); scheme \(project.scheme)", rebuild: argv, acceptModified: true)
            registryWarning = nil; registryError = nil
        } catch { let error = FlowError.wrap(error); registryWarning = error.message; registryError = error }
    }
    func setLogin(_ enabled: Bool) async {
        do { try await background.setLoginEnabled(enabled); loginStatus = background.loginStatus }
        catch { alertError = FlowError(.permission, "无法更新登录启动设置", technical: error.localizedDescription, suggestion: "在系统设置 → 通用 → 登录项中检查 SignFlow。", requiresUser: true) }
    }
    func requestNotifications() async { do { _ = try await notifications.requestAuthorization() } catch { alertError = FlowError.wrap(error) }; await updateNotificationStatus() }
    func updateNotificationStatus() async {
        let value = await notifications.status(); notificationStatus = value == .authorized ? "已授权" : value == .denied ? "系统已关闭通知" : "尚未授权"
    }
    func openXcode(_ project: ManagedProject? = nil) {
        if let project { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
        else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
    }
    func openXcodeAccounts() {
        openXcode()
        // Apple provides no stable public deep link to Xcode's Accounts pane.
        alertError = FlowError(.authentication, "在 Xcode 中打开「设置 → 账户」", suggestion: "使用 Xcode 官方界面添加 Apple 账户并完成认证，SignFlow 不接收账户密码。")
    }
    func reveal(_ project: ManagedProject) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
    func openMainWindow() {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "SignFlow" }) { window.makeKeyAndOrderFront(nil) }
        else { windowOpener?() }
    }
    func logText(_ task: FlowTask) -> String {
        let events = task.events.map { "\($0.date.formatted()) [\($0.phase.title)] \($0.message)" }.joined(separator: "\n")
        let content = task.logPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        return LogRedactor.redact("\(task.projectName) · \(task.kind.title)\n\(events)\n\(task.error?.technical ?? "")\n\(content)")
    }
    func exportLogs(task: FlowTask? = nil) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = task.map { "SignFlow-\($0.id).log" } ?? "SignFlow-日志.log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let text = task.map(logText) ?? state.tasks.map(logText).joined(separator: "\n\n"); try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { alertError = FlowError.wrap(error) }
    }
    func resetInspectionCache() {
        guard active.isEmpty else { alertError = FlowError(.build, "请先结束正在执行的任务"); return }
        let url = dataRoot.appendingPathComponent("Inspection")
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let roots = [dataRoot.path]
            Task {
                for root in roots {
                    do {
                        let result = try await runner.run(ToolCommand(executable: ArtifactRegistry.defaultExecutable, arguments: ["verify", "--project", root, "--json"], timeout: 30))
                        guard result.exitCode == 0 else { throw FlowError(.registry, "缓存已重置，但 AAR 状态同步失败", technical: result.combined) }
                    } catch { registryWarning = FlowError.wrap(error).message }
                }
            }
        }
        catch { alertError = FlowError.wrap(error) }
    }
    func stop() {
        guard !isStopping else { return }
        isStopping = true
        stoppingBackgroundTasks = background.stop()
        startupTask?.cancel()
        for (id, task) in active {
            if !task.isCancelled { suspendedTasks[id] = "应用已停止；下次启动时重新验证并继续。" }
            task.cancel()
        }
        save()
    }
    func shutdown() async {
        stop()
        let running = Array(active.values)
        await startupTask?.value
        for task in stoppingBackgroundTasks { await task.value }
        for task in running { await task.value }
        save()
    }
}

extension Notification.Name { static let signFlowOpenMain = Notification.Name("SignFlow.OpenMain") }
