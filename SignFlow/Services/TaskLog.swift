import Foundation

final class TaskLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var buffer = ""
    private var hidingKey = false
    private var writeFailure: String?
    var failureMessage: String? { lock.lock(); defer { lock.unlock() }; return writeFailure }
    let url: URL
    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
    }
    @discardableResult func append(_ chunk: String) -> String {
        lock.lock(); defer { lock.unlock() }
        buffer += chunk
        var visible = ""
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[...newline]); buffer.removeSubrange(...newline)
            if line.contains("-----BEGIN") && line.contains("PRIVATE KEY") { hidingKey = true; visible += "[私钥内容已隐藏]\n" }
            if hidingKey { if line.contains("-----END") { hidingKey = false }; continue }
            visible += LogRedactor.redact(line)
        }
        do { try handle.write(contentsOf: Data(visible.utf8)) } catch { writeFailure = error.localizedDescription }
        return visible
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        do {
            if !buffer.isEmpty && !hidingKey { try handle.write(contentsOf: Data(LogRedactor.redact(buffer).utf8)) }
            buffer = ""; try handle.synchronize()
        } catch { writeFailure = error.localizedDescription }
    }
    deinit { try? handle.close() }
}
