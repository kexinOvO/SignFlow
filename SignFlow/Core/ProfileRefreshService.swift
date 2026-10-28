import Foundation
import CryptoKit

protocol ProfileDecoding: Sendable {
    func decodeProfile(at url: URL) async throws -> ProvisioningProfile
}
extension SigningService: ProfileDecoding {}

protocol ProfileBackupRegistering: Sendable {
    func recordProfileBackup(at directory: URL, root: URL, source: String) async throws
}
extension ArtifactRegistry: ProfileBackupRegistering {
    func recordProfileBackup(at directory: URL, root: URL, source: String) async throws {
        // Apple-issued signing resources are retained user data, not disposable builds.
        try await register(path: directory, project: root, type: "USER_DATA", source: source, acceptModified: true)
    }
}

protocol ProfileRefreshing: Sendable {
    func withFreshProfiles(for request: BuildRequest, output: @escaping @Sendable (String) -> Void,
                           build: @escaping @Sendable () async throws -> BuildProduct) async throws -> BuildProduct
}

// Xcode only requests a new profile when no eligible local profile is available.
// Hold one permit through provisioning/build and restoration, including ordinary
// builds, so another SignFlow task cannot observe a temporarily absent profile.
actor ProfileRefreshService: ProfileRefreshing {
    static func cacheDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"].map { home.appendingPathComponent($0) }
    }

    private struct Scope {
        var bundleID: String
        var teamID: String
        var expiration: Date
    }
    private struct Entry: Codable {
        var originalPath: String
        var backupName: String
        var digest: String
    }
    private struct Journal: Codable {
        enum Status: String, Codable { case pending, restored }
        var status: Status = .pending
        var source: String
        var entries: [Entry]
    }
    private struct Candidate {
        var url: URL
        var data: Data
    }
    private let directories: [URL]
    private let backupRoot: URL
    private let decoder: any ProfileDecoding
    private let registry: any ProfileBackupRegistering
    private var occupied = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(backupRoot: URL, decoder: any ProfileDecoding, registry: any ProfileBackupRegistering, directories: [URL] = ProfileRefreshService.cacheDirectories()) {
        self.backupRoot = backupRoot.standardizedFileURL
        self.directories = directories.map(\.standardizedFileURL)
        self.decoder = decoder
        self.registry = registry
    }

    func recover(output: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await recoverPending(output: output)
    }

    func withFreshProfiles(for request: BuildRequest, output: @escaping @Sendable (String) -> Void,
                           build: @escaping @Sendable () async throws -> BuildProduct) async throws -> BuildProduct {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await recoverPending(output: output)
        guard let baseline = request.renewalBaseline else { return try await build() }
        guard request.project.allowProvisioningUpdates && request.supportsProvisioningUpdates else {
            throw FlowError(.signing, "续签需要允许 Xcode 更新签名资源", suggestion: "在项目设置中开启自动更新 Provisioning 后重试。", requiresUser: true)
        }
        let scopes = try Self.scopes(project: request.project, baseline: baseline)
        let candidates = try await candidates(for: scopes, output: output)
        guard !candidates.isEmpty else {
            output("未发现需要刷新的专属 Profile 缓存；由 Xcode 请求可用的签名资源。\n")
            return try await build()
        }
        let directory = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let journal = try prepare(candidates: candidates, directory: directory, source: "SignFlow renewal \(request.taskID.uuidString); project: \(request.project.path)")
        // A registration failure occurs before any cache file is removed.
        try await registry.recordProfileBackup(at: directory, root: backupRoot, source: journal.source)
        output("已备份 \(candidates.count) 个专属 Profile：\(directory.path)\n")
        let result: Result<BuildProduct, Error>
        do {
            for candidate in candidates {
                try Task.checkCancellation()
                try requireRegularFile(candidate.url)
                guard try Data(contentsOf: candidate.url) == candidate.data else {
                    throw FlowError(.signing, "Profile 缓存已被其他程序更新，已停止刷新", technical: candidate.url.path, suggestion: "等待 Xcode 完成签名资源更新后重试。", requiresUser: true)
                }
                try FileManager.default.removeItem(at: candidate.url)
            }
            output("已暂时移出匹配的旧 Profile，正在请求 Xcode 重新签发。\n")
            let product = try await build()
            try Task.checkCancellation()
            result = .success(product)
        } catch { result = .failure(error) }
        do {
            try restore(journal, directory: directory, output: output)
        } catch {
            let failure = FlowError.wrap(error)
            throw FlowError(.signing, "Profile 缓存恢复未完成，备份已保留", technical: "\(failure.message)\n\(failure.technical)", suggestion: "请从 \(directory.path) 恢复对应 Profile，再重试。", requiresUser: true)
        }
        // Cancellation must not cancel recovery or its central registry update.
        try await recordAfterRecovery(directory: directory, source: journal.source)
        return try result.get()
    }

    private static func scopes(project: ManagedProject, baseline: [SignedBundle]) throws -> [Scope] {
        try baseline.compactMap { bundle in
            guard let profile = bundle.profile, let team = bundle.teamID, !team.isEmpty,
                  profile.matches(bundleID: bundle.bundleID, teamID: team) else { return nil }
            let configuredTeam = project.teamOverride.isEmpty ? project.targets.first(where: { $0.bundleID == bundle.bundleID })?.teamID ?? "" : project.teamOverride
            guard configuredTeam.isEmpty || configuredTeam == team else {
                throw FlowError(.signing, "开发团队变更，已停止刷新 Profile", technical: bundle.bundleID, suggestion: "在 Xcode 确认当前开发团队后，重新建立签名基线。", requiresUser: true)
            }
            return Scope(bundleID: bundle.bundleID, teamID: team, expiration: profile.expirationDate)
        }
    }

    private func candidates(for scopes: [Scope], output: @escaping @Sendable (String) -> Void) async throws -> [Candidate] {
        guard !scopes.isEmpty else { return [] }
        var result: [Candidate] = []
        for directory in directories {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            try requireDirectory(directory)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension.lowercased() == "mobileprovision" {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let data = try Data(contentsOf: file)
                let profile: ProvisioningProfile
                do { profile = try await decoder.decodeProfile(at: file) }
                catch {
                    if error is CancellationError { throw error }
                    output("未能识别 Profile，保留原文件：\(file.lastPathComponent)\n")
                    continue
                }
                // Wildcard/shared, distribution, other-team and already newer
                // profiles are never evicted. Match IDs, not profile filenames.
                guard profile.isDevelopment, !profile.applicationIdentifier.contains("*"),
                      scopes.contains(where: { scope in
                          profile.teamIDs == [scope.teamID] && profile.matches(bundleID: scope.bundleID, teamID: scope.teamID) && profile.expirationDate <= scope.expiration
                      }) else { continue }
                guard try Data(contentsOf: file) == data else {
                    throw FlowError(.signing, "Profile 缓存在读取时发生变化", technical: file.path, suggestion: "等待 Xcode 完成签名资源更新后重试。", requiresUser: true)
                }
                result.append(Candidate(url: file, data: data))
            }
        }
        return result
    }

    private func prepare(candidates: [Candidate], directory: URL, source: String) throws -> Journal {
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireDirectory(backupRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var entries: [Entry] = []
        for (index, candidate) in candidates.enumerated() {
            let name = "\(index).mobileprovision"
            let backup = directory.appendingPathComponent(name)
            try candidate.data.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            guard try Data(contentsOf: backup) == candidate.data else { throw FlowError(.persistence, "Profile 备份校验失败", requiresUser: true) }
            entries.append(Entry(originalPath: candidate.url.standardizedFileURL.path, backupName: name, digest: Self.digest(candidate.data)))
        }
        let journal = Journal(source: source, entries: entries)
        try save(journal, directory: directory)
        return journal
    }

    private func restore(_ journal: Journal, directory: URL, output: @escaping @Sendable (String) -> Void) throws {
        try requireDirectory(directory)
        // Validate every destination and backup before writing any restored file.
        for entry in journal.entries {
            let original = URL(fileURLWithPath: entry.originalPath).standardizedFileURL
            guard original.path == entry.originalPath, directories.contains(where: { $0.path == original.deletingLastPathComponent().path }),
                  original.pathExtension.lowercased() == "mobileprovision",
                  entry.backupName == URL(fileURLWithPath: entry.backupName).lastPathComponent,
                  !entry.backupName.hasPrefix("."), entry.backupName.hasSuffix(".mobileprovision") else {
                throw FlowError(.persistence, "Profile 恢复记录包含无效路径", technical: "Original: \(entry.originalPath)\nNormalized: \(original.path)\nCaches: \(directories.map(\.path))\nBackup: \(entry.backupName)", requiresUser: true)
            }
            let backup = directory.appendingPathComponent(entry.backupName)
            try requireRegularFile(backup)
            guard try Self.digest(Data(contentsOf: backup)) == entry.digest else { throw FlowError(.persistence, "Profile 备份内容已变化", requiresUser: true) }
            try requireDirectory(original.deletingLastPathComponent())
        }
        for entry in journal.entries {
            let original = URL(fileURLWithPath: entry.originalPath)
            // Never overwrite a replacement Xcode (or another program) created.
            // copyItem also refuses an existing destination in a concurrent race.
            if !FileManager.default.fileExists(atPath: original.path) {
                do { try FileManager.default.copyItem(at: directory.appendingPathComponent(entry.backupName), to: original) }
                catch {
                    guard FileManager.default.fileExists(atPath: original.path) else { throw error }
                }
            }
        }
        var restored = journal; restored.status = .restored
        try save(restored, directory: directory)
        output("Profile 缓存已恢复；Xcode 新生成的文件已保留。\n")
    }

    private func recoverPending(output: @escaping @Sendable (String) -> Void) async throws {
        guard FileManager.default.fileExists(atPath: backupRoot.path) else { return }
        try requireDirectory(backupRoot)
        for directory in try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).sorted(by: { $0.path < $1.path }) {
            let file = directory.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try requireDirectory(directory)
            try requireRegularFile(file)
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
            guard journal.status == .pending else { continue }
            output("恢复上次中断的 Profile 刷新：\(directory.lastPathComponent)\n")
            try restore(journal, directory: directory, output: output)
            try await recordAfterRecovery(directory: directory, source: journal.source)
        }
    }

    private func recordAfterRecovery(directory: URL, source: String) async throws {
        let registry = self.registry, root = backupRoot
        do {
            try await Task.detached(priority: .utility) {
                try await registry.recordProfileBackup(at: directory, root: root, source: source)
            }.value
        } catch {
            throw FlowError(.registry, "Profile 缓存已恢复，但备份登记未完成", technical: error.localizedDescription, suggestion: "备份保留在 \(directory.path)。请检查中央 AAR 工具与数据库。", requiresUser: true)
        }
    }
    private func save(_ journal: Journal, directory: URL) throws {
        let file = directory.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw FlowError(.permission, "Profile 目录不是普通目录", technical: url.path, requiresUser: true) }
    }
    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw FlowError(.permission, "Profile 不是普通文件", technical: url.path, requiresUser: true) }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if occupied { waiters.append((id, continuation)) }
                else { occupied = true; continuation.resume() }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().1.resume() }
    }
}
