import Foundation
import Darwin

struct StateRepository: Sendable {
    let directory: URL
    var stateURL: URL { directory.appendingPathComponent("state.json") }
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SignFlow", isDirectory: true)) { self.directory = directory }
    func load() throws -> PersistedState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return PersistedState() }
        do { return try JSONDecoder.signFlow.decode(PersistedState.self, from: Data(contentsOf: stateURL)) }
        catch { throw FlowError(.persistence, "SignFlow 数据无法读取，已暂停自动任务", technical: error.localizedDescription, suggestion: "原始文件已保留：\(stateURL.path)。请恢复备份或检查数据格式。", requiresUser: true) }
    }
    func save(_ state: PersistedState) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder.signFlow.encode(state)
            // Preserve file protection after boot while allowing this desktop
            // scheduler to reopen state after the user locks the screen.
            try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch { throw FlowError(.persistence, "无法保存 SignFlow 数据", technical: error.localizedDescription, requiresUser: true) }
    }
}

extension JSONEncoder {
    static var signFlow: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var signFlow: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

// A lifetime flock prevents two app instances/schedulers from writing the same state.
final class InstanceLease {
    private var descriptor: Int32 = -1
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent("scheduler.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor); descriptor = -1 }
            throw FlowError(.persistence, "另一个 SignFlow 实例正在运行", suggestion: "请使用已有窗口或菜单栏入口。", requiresUser: true)
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}

actor ProjectMutex {
    private var active: Set<String> = []
    func acquire(_ project: ManagedProject) -> Bool {
        // Different schemes in one container still share build and signing resources.
        let key = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
        return active.insert(key).inserted
    }
    func release(_ project: ManagedProject) { active.remove(URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path) }
}

enum RecoveryPolicy {
    static func recover(_ tasks: [FlowTask], now: Date = Date()) -> [FlowTask] {
        tasks.map { original in
            var task = original
            if task.phase.isExecuting {
                task.recovered = true
                task.transition(.queued, "上次执行被中断；将重新验证已有产物与安装记录后恢复。", now: now)
            }
            return task
        }
    }
    static func nextRetry(count: Int, maxRetries: Int, base: Int, now: Date = Date()) -> Date? {
        guard count < maxRetries else { return nil }
        return now.addingTimeInterval(min(3600, Double(max(1, base)) * pow(2, Double(count))))
    }
}

// Commit both projections in one state write. The marker also identifies legacy
// result snapshots that were saved before their project projection was updated.
enum TaskResultCommitter {
    static func record(_ original: FlowTask, in state: inout PersistedState) {
        guard let taskIndex = state.tasks.firstIndex(where: { $0.id == original.id }) else { return }
        var task = original
        if !task.phase.isExecuting && task.phase != .queued {
            if let projectIndex = state.projects.firstIndex(where: { $0.id == task.projectID }) {
                var project = state.projects[projectIndex]
                let snapshotIsCurrent = task.updatedAt >= (project.lastCheck ?? .distantPast)
                if snapshotIsCurrent {
                    if !task.newSignatures.isEmpty { project.signatures = task.newSignatures; project.lastCheck = task.updatedAt }
                    if let path = task.artifactPath { project.artifactPath = path }
                }
                for evidence in task.deployments {
                    if let current = project.deployments.first(where: { $0.id == evidence.id }), current.verifiedAt > evidence.verifiedAt { continue }
                    project.deployments.removeAll { $0.id == evidence.id }; project.deployments.append(evidence)
                }
                if task.kind == .renew && task.phase == .completed && task.assessment == .advanced {
                    let date = task.finishedAt ?? task.updatedAt
                    if date > (project.lastRenewal ?? .distantPast) { project.lastRenewal = date }
                }
                state.projects[projectIndex] = project
            }
            task.projectResultCommittedAt = task.updatedAt
        }
        state.tasks[taskIndex] = task
    }

    static func reconcile(_ state: inout PersistedState) {
        // Chronological replay plus per-field timestamps preserves newer evidence.
        let pending = state.tasks.enumerated().filter { $0.element.projectResultCommittedAt == nil && !$0.element.phase.isExecuting && $0.element.phase != .queued }
            .sorted {
                if $0.element.updatedAt == $1.element.updatedAt { return $0.offset > $1.offset }
                return $0.element.updatedAt < $1.element.updatedAt
            }.map(\.element)
        for task in pending { record(task, in: &state) }
    }
}
