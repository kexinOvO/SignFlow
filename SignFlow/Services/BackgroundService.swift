import AppKit
import ServiceManagement

@MainActor
final class BackgroundService {
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var wakeTask: Task<Void, Never>?
    var running: Bool { loop != nil }
    var loginStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已启用登录启动"
        case .requiresApproval: return "等待系统设置批准"
        case .notRegistered: return "未启用"
        case .notFound: return "登录项不可用"
        @unknown default: return "状态未知"
        }
    }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setLoginEnabled(_ enabled: Bool) async throws {
        if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func start(tick: @escaping @MainActor () async -> Void) {
        guard loop == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.loop != nil, self.wakeTask == nil else { return }
                self.wakeTask = Task { @MainActor [weak self] in
                    await tick(); self?.wakeTask = nil
                }
            }
        }
        loop = Task { @MainActor in
            while !Task.isCancelled {
                await tick()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    @discardableResult func stop() -> [Task<Void, Never>] {
        let tasks = [loop, wakeTask].compactMap { $0 }
        tasks.forEach { $0.cancel() }; loop = nil; wakeTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
        return tasks
    }
}
