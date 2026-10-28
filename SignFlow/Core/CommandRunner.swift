import Foundation
import Darwin

struct ToolCommand: Sendable, Equatable {
    var executable: String
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var workingDirectory: String?
    var timeout: TimeInterval = 120
}

struct CommandResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var duration: TimeInterval
    var combined: String { stdout + "\n" + stderr }
    func requireSuccess(category: ErrorCategory = .unknown) throws -> CommandResult {
        guard exitCode == 0 else { throw ErrorClassifier.classify(combined, fallback: category) }
        return self
    }
}

protocol CommandExecuting: Sendable {
    func run(_ command: ToolCommand, output: @escaping @Sendable (String) -> Void) async throws -> CommandResult
}
extension CommandExecuting {
    func run(_ command: ToolCommand) async throws -> CommandResult { try await run(command, output: { _ in }) }
}

// Each invocation owns its process, pipes, timeout and cancellation. No shell is used.
struct ProcessCommandRunner: CommandExecuting {
    func run(_ command: ToolCommand, output: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        let context = RunningProcess(command: command, output: output)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { context.start($0) }
        } onCancel: { context.cancel() }
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SignFlow.Command.\(UUID().uuidString)", qos: .utility)
    private let command: ToolCommand
    private let output: @Sendable (String) -> Void
    private var processSource: DispatchSourceProcess?
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var sources: [DispatchSourceRead?] = [nil, nil]
    private var pending = [Data(), Data()]
    private var closing = [false, false]
    private var closed = [false, false]
    private var timeoutWork: DispatchWorkItem?
    private var drainWork: DispatchWorkItem?
    private var forceWork: DispatchWorkItem?
    private var pipeCloseWork: DispatchWorkItem?
    private var reapWork: DispatchWorkItem?
    private var startedAt = Date()
    private var pid: Int32?
    private var ownedGroup: Int32?
    private var exitCode: Int32?
    private var readError: FlowError?
    private var cancelled = false
    private var timedOut = false
    private var stopping = false
    private var finished = false
    private var out = Data()
    private var err = Data()
    private let limit = 16 * 1024 * 1024
    init(command: ToolCommand, output: @escaping @Sendable (String) -> Void) { self.command = command; self.output = output }
    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            cancelled = true
            if pid != nil { stopProcesses() }
        }
    }
    private func signalOwnedProcesses(_ signal: Int32) {
        guard let pid else { return }
        if let group = ownedGroup {
            let currentGroup = getpgid(pid)
            // A surviving group can outlive its leader. If the leader PID now
            // exists after exit, it may have been reused; do not signal that group.
            if exitCode == nil && currentGroup == group || currentGroup == -1 && errno == ESRCH {
                kill(-group, signal)
            }
        }
        // Until waitpid has reaped our child, its PID cannot be reused.
        if exitCode == nil { kill(pid, signal) }
    }
    private func stopProcesses() {
        guard !finished, !stopping else { return }
        stopping = true
        signalOwnedProcesses(SIGTERM)
        reapChild()
        guard !finished else { return }
        let force = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.signalOwnedProcesses(SIGKILL)
            let close = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                for index in 0..<2 { self.closeStream(index) }
            }
            self.pipeCloseWork = close
            self.queue.asyncAfter(deadline: .now() + 0.25, execute: close)
        }
        forceWork = force
        queue.asyncAfter(deadline: .now() + 1, execute: force)
    }
    func start(_ continuation: CheckedContinuation<CommandResult, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            startedAt = Date()
            if cancelled { complete(.failure(CancellationError())); return }
            do {
                for index in 0..<2 { try startReader(index) }
                try spawn()
                try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            } catch {
                try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                complete(.failure(FlowError(.environment, "无法启动系统工具", technical: error.localizedDescription, suggestion: "检查 Xcode 路径和文件访问权限。"))); return
            }
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                self.timedOut = true; self.stopProcesses()
            }
            timeoutWork = timeout
            queue.asyncAfter(deadline: .now() + max(0, command.timeout), execute: timeout)
        }
    }
    private func spawn() throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ code: Int32) throws { if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) } }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        var mask = sigset_t(); sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t(); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGQUIT, SIGPIPE] { sigaddset(&defaults, signal) }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        // A group of zero atomically makes the new child its own group leader,
        // including when it exits before the parent can observe getpgid().
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
        if let directory = command.workingDirectory {
            if #available(macOS 26, *) { try check(posix_spawn_file_actions_addchdir(&actions, directory)) }
            else { try check(posix_spawn_file_actions_addchdir_np(&actions, directory)) }
        }
        let arguments = [command.executable] + command.arguments
        let environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }.map { "\($0.key)=\($0.value)" }
        guard !(arguments + environment).contains(where: { $0.contains("\0") }) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let code = argv.withUnsafeMutableBufferPointer { argv in
            envp.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&child, command.executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        try check(code)
        let spawnedPID = child
        pid = spawnedPID; ownedGroup = spawnedPID
        let source = DispatchSource.makeProcessSource(identifier: spawnedPID, eventMask: .exit, queue: queue)
        source.setEventHandler { [self] in reapChild() }
        source.setCancelHandler { [self] in
            source.setEventHandler {}; source.setCancelHandler {}
            processSource = nil
        }
        processSource = source
        source.resume()
        reapChild()
    }
    private func reapChild() {
        guard !finished, exitCode == nil, let pid else { return }
        reapWork?.cancel()
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result == -1 && errno == EINTR
        if result == 0 {
            // Nonblocking fallback covers an exit racing source registration.
            let poll = DispatchWorkItem { [weak self] in self?.reapChild() }
            reapWork = poll
            queue.asyncAfter(deadline: .now() + 0.1, execute: poll)
            return
        }
        if result == pid { exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f }
        else {
            exitCode = -1
            readError = FlowError(.environment, "无法读取系统工具退出状态", technical: String(cString: strerror(errno)))
        }
        processSource?.cancel()
        finishIfReady()
        guard !finished else { return }
        // Reaping and output EOF are separate events. Descendants may keep
        // inherited descriptors open after their parent has exited.
        let drain = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.timedOut = true; self.stopProcesses()
        }
        drainWork = drain
        queue.asyncAfter(deadline: .now() + 1, execute: drain)
    }
    private func startReader(_ index: Int) throws {
        let handle = (index == 0 ? stdout : stderr).fileHandleForReading
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [self] in readAvailable(index, descriptor: descriptor) }
        source.setCancelHandler { [self] in
            try? handle.close()
            source.setEventHandler {}; source.setCancelHandler {}
            sources[index] = nil; closed[index] = true
            finishIfReady()
        }
        sources[index] = source
        source.resume()
    }
    private func readAvailable(_ index: Int, descriptor: Int32) {
        guard !finished, !closing[index] else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // Yield between batches so an indefinitely writing child cannot starve
        // cancellation or timeout events on this serial queue.
        for _ in 0..<64 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let data = Data(bytes.prefix(count))
                if index == 0 { out.append(data); if out.count > limit { out.removeFirst(out.count - limit) } }
                else { err.append(data); if err.count > limit { err.removeFirst(err.count - limit) } }
                pending[index].append(data)
                if let text = String(data: pending[index], encoding: .utf8) {
                    output(text); pending[index].removeAll(keepingCapacity: true)
                } else if pending[index].count > 65_536 {
                    output(String(decoding: pending[index], as: UTF8.self)); pending[index].removeAll(keepingCapacity: true)
                }
            } else if count == 0 { closeStream(index); return }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else {
                readError = FlowError(.unknown, "无法读取系统工具输出", technical: String(cString: strerror(errno)))
                closeStream(index); stopProcesses(); return
            }
        }
    }
    private func closeStream(_ index: Int) {
        guard !closing[index], !closed[index] else { return }
        closing[index] = true
        if !pending[index].isEmpty { output(String(decoding: pending[index], as: UTF8.self)); pending[index].removeAll() }
        if let source = sources[index] { source.cancel() }
        else { try? (index == 0 ? stdout : stderr).fileHandleForReading.close(); closed[index] = true }
    }
    private func finishIfReady() {
        guard !finished, let exitCode, closed.allSatisfy({ $0 }) else { return }
        if stopping { signalOwnedProcesses(SIGKILL) }
        if cancelled { complete(.failure(CancellationError())) }
        else if timedOut {
            // Logs have already been streamed. Keep error redaction bounded even
            // when a tool has filled both multi-megabyte capture buffers.
            let tail = String(decoding: out.suffix(12_000), as: UTF8.self) + "\n" + String(decoding: err.suffix(12_000), as: UTF8.self)
            complete(.failure(FlowError(.timeout, "操作超时", technical: tail, suggestion: "系统工具或其子进程未及时结束，请检查连接与日志后重试。", retryable: true)))
        }
        else if let readError { complete(.failure(readError)) }
        else {
            complete(.success(CommandResult(exitCode: exitCode, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self), duration: Date().timeIntervalSince(startedAt))))
        }
    }
    private func complete(_ result: Result<CommandResult, Error>) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel(); drainWork?.cancel(); forceWork?.cancel(); pipeCloseWork?.cancel(); reapWork?.cancel()
        for index in 0..<2 { closeStream(index) }
        let callback = continuation; continuation = nil
        callback?.resume(with: result)
    }
}

enum LogRedactor {
    static func redact(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in [
            ("(?i)(authorization[\\s:]+(?:bearer|basic)\\s+)[^\\s]+", "$1[已脱敏]"),
            ("(?i)((?:password|passwd|token|secret|session-id|cookie|authenticationKeyPath)\\s*[=:]\\s*)[^\\s,;]+", "$1[已脱敏]"),
            (#"(?i)("(?:password|passwd|token|secret|cookie|authorization)"\s*:\s*)"[^"\r\n]*""#, "$1\"[已脱敏]\""),
            (#"(?i)(https?://)[^/@\s]+@"#, "$1[已脱敏]@"),
            (#"(?i)((?:--password|--token|--secret)\s+)\S+"#, "$1[已脱敏]"),
            ("[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "[已脱敏]"),
            ("-----BEGIN [^-]*PRIVATE KEY-----[\\s\\S]*?-----END [^-]*PRIVATE KEY-----", "[已脱敏]")
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }
}

enum ErrorClassifier {
    static func classify(_ raw: String, fallback: ErrorCategory = .unknown) -> FlowError {
        let value = raw.lowercased()
        func error(_ category: ErrorCategory, _ message: String, _ suggestion: String, _ retry: Bool = false, _ user: Bool = false) -> FlowError {
            FlowError(category, message, technical: String(raw.suffix(24_000)), suggestion: suggestion, retryable: retry, requiresUser: user)
        }
        if value.contains("remotepairingerror") && value.contains("1001") {
            return error(.watchConnection, "无法访问配对的 Apple Watch（RemotePairing 1001）", "保持 iPhone 与 Watch 解锁并靠近，在 Xcode 的设备窗口检查连接。", true)
        }
        if value.contains("coredeviceerror") && value.contains("4000") {
            return error(.deviceConnection, "CoreDevice 无法建立设备连接（4000）", "在 Xcode 设备窗口检查连接；此错误不能单独确定是配对、信任还是网络原因。", true)
        }
        if value.contains("developer mode") && (value.contains("disabled") || value.contains("not enabled")) {
            return error(.developerMode, "设备未开启开发者模式", "在设备的设置 → 隐私与安全性中开启开发者模式。", false, true)
        }
        if value.contains("authentication") || value.contains("session has expired") || value.contains("log in") || value.contains("two-factor") || value.contains("no accounts") {
            return error(.authentication, "Xcode 账户需要验证", "打开 Xcode → 设置 → 账户，完成登录或双重认证，然后手动重试。", false, true)
        }
        if value.contains("personal development teams") || value.contains("does not support") && value.contains("capabilit") || value.contains("doesn't support") && value.contains("entitlement") {
            return error(.entitlements, "当前团队不支持项目请求的签名能力", "在 Xcode 检查 Signing & Capabilities。Personal Team 只支持部分能力；SignFlow 不会删除权限或更改 Bundle ID。", false, true)
        }
        if value.contains("maximum number") || value.contains("app id limit") || value.contains("too many app") {
            return error(.signing, "Apple 签名资源达到限制", "在 Xcode 查看 Personal Team 的 App ID、设备或安装数量限制，等待额度恢复或使用适用的开发团队。", false, true)
        }
        if value.contains("no signing certificate") || value.contains("no profiles for") || value.contains("requires a development team") {
            return error(.signing, "缺少可用的签名身份或 Provisioning Profile", "在 Xcode 选择团队并启用自动签名，先完成一次账户验证。", false, true)
        }
        if value.contains("not trusted") || value.contains("trust this") || value.contains("not paired") {
            return error(.permission, "设备需要信任或配对授权", "在设备上确认信任 Mac，并在 Xcode 设备窗口完成授权。", false, true)
        }
        if value.contains("timed out") || value.contains("timeout") || value.contains("tunnel") {
            return error(.deviceConnection, "设备连接或 CoreDevice tunnel 未完成", "保持设备解锁并检查有线或局域网连接，稍后重试。", true)
        }
        if value.contains("network connection") || value.contains("could not resolve host") || value.contains("internet connection") {
            return error(.deviceConnection, "网络暂时不可用", "恢复网络连接后会按重试策略继续。", true)
        }
        if value.contains("permission denied") || value.contains("operation not permitted") {
            return error(.permission, "文件或系统服务访问被拒绝", "检查项目目录授权和 macOS 隐私与安全性设置。", false, true)
        }
        if value.contains("unable to find a destination") || value.contains("device is not connected") || value.contains("device is unavailable") {
            return error(.deviceOffline, "目标设备不可用", "连接并解锁设备后重试。", true)
        }
        let title: String
        switch fallback { case .build: title = "Xcode 构建失败"; case .install: title = "设备安装失败"; case .signing: title = "签名检查失败"; case .project: title = "无法读取 Xcode 项目"; default: title = "系统工具执行失败" }
        return error(fallback, title, "展开技术日志查看工具返回的具体原因。")
    }
}
