import XCTest
@testable import SignFlowCore

private struct FixtureProfileDecoder: ProfileDecoding {
    func decodeProfile(at url: URL) async throws -> ProvisioningProfile {
        try SigningService.parseProfile(Data(contentsOf: url))
    }
}
private actor BackupRecorder: ProfileBackupRegistering {
    var directories: [URL] = []
    var fail = false
    func setFailure() { fail = true }
    func recordProfileBackup(at directory: URL, root: URL, source: String) async throws {
        try Task.checkCancellation()
        if fail { throw FlowError(.registry, "Unavailable registry") }
        directories.append(directory)
    }
}
private actor Signal {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func send() { open = true; let waiting = waiters; waiters = []; waiting.forEach { $0.resume() } }
}
private actor RecordingRunner: CommandExecuting {
    var commands: [ToolCommand] = []
    let action: @Sendable (ToolCommand) throws -> Void
    init(action: @escaping @Sendable (ToolCommand) throws -> Void = { _ in }) { self.action = action }
    func run(_ command: ToolCommand, output: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        commands.append(command); try action(command)
        return CommandResult(exitCode: 0, stdout: "", stderr: "", duration: 0)
    }
}

private final class RefreshFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SignFlowProfileTests-\(UUID())", isDirectory: true)
    let registry = BackupRecorder()
    var caches: [URL] { [root.appendingPathComponent("Modern"), root.appendingPathComponent("Legacy")] }
    var backups: URL { root.appendingPathComponent("Backups") }
    var project: ManagedProject
    var request: BuildRequest { BuildRequest(project: project, taskID: UUID(), outputRoot: root.appendingPathComponent("Builds"), developerDirectory: "", destinationUDID: nil, supportsProvisioningUpdates: true, supportsDeviceRegistration: false, renewalBaseline: project.signatures) }
    var product: BuildProduct { BuildProduct(app: root.appendingPathComponent("Test.app"), derivedData: root.appendingPathComponent("Builds"), command: ToolCommand(executable: "fixture")) }
    init() throws {
        project = ManagedProject(name: "Test", path: root.appendingPathComponent("Source/Test.xcodeproj").path, kind: .project, scheme: "Test")
        project.targets = [TargetInfo(name: "Test", bundleID: "test.app", platform: .iOS, kind: .application, productType: "application", teamID: "TEAM123456", automaticSigning: true, deploymentTarget: "17", productPath: nil)]
        project.signatures = [signedBundle(expires: Date().addingTimeInterval(3600)), signedBundle(platform: .watchOS, expires: Date().addingTimeInterval(3600))]
        for cache in caches { try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true) }
    }
    func service() -> ProfileRefreshService { ProfileRefreshService(backupRoot: backups, decoder: FixtureProfileDecoder(), registry: registry, directories: caches) }
    func write(_ profile: ProvisioningProfile, name: String, cache: Int = 0) throws -> URL {
        let path = caches[cache].appendingPathComponent(name + ".mobileprovision")
        let plist: [String: Any] = ["UUID": profile.uuid, "Name": profile.name, "TeamIdentifier": profile.teamIDs,
                                  "CreationDate": profile.creationDate, "ExpirationDate": profile.expirationDate,
                                  "Entitlements": ["application-identifier": profile.applicationIdentifier, "get-task-allow": profile.isDevelopment]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: path)
        return path
    }
    func markPending(_ directory: URL) throws {
        let path = directory.appendingPathComponent("manifest.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        json["status"] = "pending"
        try JSONSerialization.data(withJSONObject: json).write(to: path)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

final class ProfileRefreshTests: XCTestCase {
    func testRefreshCoversBothCachesAndPreservesOtherSigningResources() async throws {
        let f = try RefreshFixture()
        var extensionBundle = signedBundle(); extensionBundle.bundleID = "test.app.share"; extensionBundle.isExtension = true
        extensionBundle.profile = f.project.signatures[0].profile
        extensionBundle.profile?.applicationIdentifier = "TEAM123456.test.app.share"
        f.project.signatures.append(extensionBundle)
        let phone = try f.write(f.project.signatures[0].profile!, name: "renamed-phone")
        let watch = try f.write(f.project.signatures[1].profile!, name: "renamed-watch", cache: 1)
        let duplicate = try f.write(f.project.signatures[0].profile!, name: "phone-copy", cache: 1)
        let extensionFile = try f.write(extensionBundle.profile!, name: "extension")
        let refreshed = [phone, watch, duplicate, extensionFile]
        let originals = try refreshed.map { try Data(contentsOf: $0) }
        var other = profile(); other.applicationIdentifier = "TEAM123456.other.app"
        let unrelated = try f.write(other, name: "unrelated")
        var wildcard = profile(); wildcard.applicationIdentifier = "TEAM123456.test.*"
        let shared = try f.write(wildcard, name: "shared")
        var team = profile(); team.teamIDs = ["OTHER12345"]; team.applicationIdentifier = "OTHER12345.test.app"
        let otherTeam = try f.write(team, name: "other-team")
        var distribution = f.project.signatures[0].profile!; distribution.isDevelopment = false
        let distributionFile = try f.write(distribution, name: "distribution")
        let newer = try f.write(profile(), name: "already-renewed")
        let invalid = f.caches[0].appendingPathComponent("invalid.mobileprovision"); try Data("unrecognized".utf8).write(to: invalid)
        let kept = [unrelated, shared, otherTeam, distributionFile, newer, invalid]
        let keptData = try kept.map { try Data(contentsOf: $0) }
        let product = f.product
        _ = try await f.service().withFreshProfiles(for: f.request, output: { _ in }) {
            for path in refreshed { XCTAssertFalse(FileManager.default.fileExists(atPath: path.path)) }
            for (path, data) in zip(kept, keptData) { XCTAssertEqual(try Data(contentsOf: path), data) }
            return product
        }
        for (path, data) in zip(refreshed, originals) { XCTAssertEqual(try Data(contentsOf: path), data) }
        let registrations = await f.registry.directories
        XCTAssertEqual(registrations.count, 2)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: registrations[0].appendingPathComponent("manifest.json"))) as! [String: Any]
        XCTAssertEqual(manifest["status"] as? String, "restored")
        XCTAssertEqual((manifest["entries"] as? [[String: Any]])?.count, 4)
    }

    func testFailedBuildRestoresProfilesAndPreservesItsError() async throws {
        let f = try RefreshFixture(); let phone = try f.write(f.project.signatures[0].profile!, name: "phone")
        let data = try Data(contentsOf: phone)
        do {
            _ = try await f.service().withFreshProfiles(for: f.request, output: { _ in }) {
                XCTAssertFalse(FileManager.default.fileExists(atPath: phone.path))
                throw FlowError(.authentication, "Xcode sign-in required", requiresUser: true)
            }
            XCTFail("Expected build failure")
        } catch { XCTAssertEqual((error as? FlowError)?.category, .authentication) }
        XCTAssertEqual(try Data(contentsOf: phone), data)
    }

    func testCancelledBuildRestoresProfilesAndRegistersRecovery() async throws {
        let f = try RefreshFixture(); let phone = try f.write(f.project.signatures[0].profile!, name: "phone")
        let data = try Data(contentsOf: phone), started = Signal(), service = f.service(), request = f.request, product = f.product
        let running = Task {
            try await service.withFreshProfiles(for: request, output: { _ in }) {
                await started.send()
                try await Task.sleep(for: .seconds(30))
                return product
            }
        }
        await started.wait(); running.cancel()
        do { _ = try await running.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: phone), data)
        let registrations = await f.registry.directories; XCTAssertEqual(registrations.count, 2)
    }

    func testNewProfileAtOriginalPathIsNeverOverwritten() async throws {
        let f = try RefreshFixture(); let phone = try f.write(f.project.signatures[0].profile!, name: "phone")
        let replacement = Data("Xcode replacement".utf8), product = f.product
        _ = try await f.service().withFreshProfiles(for: f.request, output: { _ in }) {
            try replacement.write(to: phone)
            return product
        }
        XCTAssertEqual(try Data(contentsOf: phone), replacement)
    }

    func testRegistryFailurePreventsCacheMutationAndBuild() async throws {
        let f = try RefreshFixture(); let phone = try f.write(f.project.signatures[0].profile!, name: "phone")
        let original = try Data(contentsOf: phone), product = f.product
        await f.registry.setFailure()
        do {
            _ = try await f.service().withFreshProfiles(for: f.request, output: { _ in }) { XCTFail("Must not build"); return product }
            XCTFail("Expected registry failure")
        } catch { XCTAssertEqual((error as? FlowError)?.category, .registry) }
        XCTAssertEqual(try Data(contentsOf: phone), original)
    }

    func testInterruptedRefreshRecoversOnNextLaunch() async throws {
        let f = try RefreshFixture(); let phone = try f.write(f.project.signatures[0].profile!, name: "phone")
        let original = try Data(contentsOf: phone), product = f.product
        _ = try await f.service().withFreshProfiles(for: f.request, output: { _ in }) { product }
        let directory = await f.registry.directories[0]
        try f.markPending(directory); try FileManager.default.removeItem(at: phone)
        try await f.service().recover()
        XCTAssertEqual(try Data(contentsOf: phone), original)
    }

    func testCorruptedBackupStopsRecoveryBeforeAnyFileIsRestored() async throws {
        let f = try RefreshFixture()
        let phone = try f.write(f.project.signatures[0].profile!, name: "phone")
        let watch = try f.write(f.project.signatures[1].profile!, name: "watch"), product = f.product
        _ = try await f.service().withFreshProfiles(for: f.request, output: { _ in }) { product }
        let directory = await f.registry.directories[0]
        try f.markPending(directory)
        try FileManager.default.removeItem(at: phone); try FileManager.default.removeItem(at: watch)
        try Data("modified backup".utf8).write(to: directory.appendingPathComponent("1.mobileprovision"))
        do { try await f.service().recover(); XCTFail("Expected integrity failure") }
        catch { XCTAssertEqual((error as? FlowError)?.category, .persistence) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: watch.path))
    }

    func testRecoveryRejectsDestinationOutsideProfileCaches() async throws {
        let f = try RefreshFixture(); _ = try f.write(f.project.signatures[0].profile!, name: "phone")
        let product = f.product
        _ = try await f.service().withFreshProfiles(for: f.request, output: { _ in }) { product }
        let directory = await f.registry.directories[0], manifest = directory.appendingPathComponent("manifest.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        var entries = json["entries"] as! [[String: Any]]
        let outside = f.root.appendingPathComponent("outside.mobileprovision")
        entries[0]["originalPath"] = outside.path; json["entries"] = entries; json["status"] = "pending"
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        do { try await f.service().recover(); XCTFail("Expected invalid destination") }
        catch { XCTAssertEqual((error as? FlowError)?.category, .persistence) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testOrdinaryBuildAndFirstBaselineLeaveProfilesInPlace() async throws {
        let f = try RefreshFixture(); let phone = try f.write(f.project.signatures[0].profile!, name: "phone"), product = f.product
        var ordinary = f.request; ordinary.renewalBaseline = nil
        var initial = f.request; initial.renewalBaseline = []
        for request in [ordinary, initial] {
            _ = try await f.service().withFreshProfiles(for: request, output: { _ in }) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: phone.path)); return product
            }
        }
        let registrations = await f.registry.directories; XCTAssertTrue(registrations.isEmpty)
    }

    func testDisabledProvisioningAndTeamChangeStopBeforeMutation() async throws {
        let f = try RefreshFixture(); let phone = try f.write(f.project.signatures[0].profile!, name: "phone"), product = f.product
        var disabled = f.request; disabled.project.allowProvisioningUpdates = false
        var changed = f.request; changed.project.teamOverride = "OTHER12345"
        for request in [disabled, changed] {
            do {
                _ = try await f.service().withFreshProfiles(for: request, output: { _ in }) { XCTFail("Must not build"); return product }
                XCTFail("Expected preflight failure")
            } catch { XCTAssertEqual((error as? FlowError)?.category, .signing) }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: phone.path))
        let registrations = await f.registry.directories; XCTAssertTrue(registrations.isEmpty)
    }

    func testProfileSymlinksArePreserved() async throws {
        let f = try RefreshFixture(); let target = try f.write(f.project.signatures[0].profile!, name: "outside")
        let original = try Data(contentsOf: target)
        let outside = f.root.appendingPathComponent("external.mobileprovision")
        try FileManager.default.moveItem(at: target, to: outside)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        let product = f.product
        _ = try await f.service().withFreshProfiles(for: f.request, output: { _ in }) { product }
        XCTAssertEqual(try Data(contentsOf: outside), original)
        XCTAssertTrue(try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testOrdinaryBuildWaitsUntilRenewalRestoresCache() async throws {
        let f = try RefreshFixture(); let phone = try f.write(f.project.signatures[0].profile!, name: "phone")
        let service = f.service(), started = Signal(), finish = Signal(), request = f.request, product = f.product
        let renewal = Task {
            try await service.withFreshProfiles(for: request, output: { _ in }) {
                await started.send(); await finish.wait(); return product
            }
        }
        await started.wait()
        var ordinary = request; ordinary.renewalBaseline = nil
        let ordinaryRequest = ordinary
        let build = Task {
            try await service.withFreshProfiles(for: ordinaryRequest, output: { _ in }) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: phone.path)); return product
            }
        }
        await finish.send()
        _ = try await renewal.value; _ = try await build.value
    }

    func testCancellingQueuedBuildDoesNotWaitForActiveBuild() async throws {
        let f = try RefreshFixture(); let service = f.service(), started = Signal(), finish = Signal(), request = f.request, product = f.product
        let first = Task {
            try await service.withFreshProfiles(for: request, output: { _ in }) { await started.send(); await finish.wait(); return product }
        }
        await started.wait()
        let queued = Task {
            try await service.withFreshProfiles(for: request, output: { _ in }) { XCTFail("Cancelled build must not run"); return product }
        }
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        await finish.send(); _ = try await first.value
        // The cancelled waiter must not leak the permit.
        _ = try await service.withFreshProfiles(for: request, output: { _ in }) { product }
    }

    func testRenewalCommandClearsPinnedProfilesAndRequiresUpdates() throws {
        let f = try RefreshFixture(); var request = f.request
        let command = try BuildService.command(for: request)
        XCTAssertTrue(command.arguments.contains("PROVISIONING_PROFILE="))
        XCTAssertTrue(command.arguments.contains("PROVISIONING_PROFILE_SPECIFIER="))
        request.project.allowProvisioningUpdates = false
        XCTAssertThrowsError(try BuildService.command(for: request))
    }

    func testBuildServiceRefreshesBeforeXcodeAndRestoresBeforeReturning() async throws {
        let f = try RefreshFixture(); let phone = try f.write(f.project.signatures[0].profile!, name: "phone")
        let original = try Data(contentsOf: phone), request = f.request
        let app = BuildService.taskDirectory(request).appendingPathComponent("DerivedData/Build/Products/Debug-iphoneos/Test.app")
        let runner = RecordingRunner { command in
            XCTAssertEqual(command.executable, "/usr/bin/xcodebuild")
            XCTAssertFalse(FileManager.default.fileExists(atPath: phone.path))
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.app"], format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        }
        let product = try await BuildService(runner: runner, profileRefresher: f.service()).build(request, output: { _ in })
        XCTAssertEqual(product.app.resolvingSymlinksInPath().path, app.resolvingSymlinksInPath().path)
        XCTAssertEqual(try Data(contentsOf: phone), original)
        let commands = await runner.commands; XCTAssertEqual(commands.count, 1)
    }

    func testMissingRefreshServiceStopsRenewalBeforeXcode() async throws {
        let f = try RefreshFixture(), runner = RecordingRunner()
        do {
            _ = try await BuildService(runner: runner).build(f.request, output: { _ in })
            XCTFail("Expected missing service")
        } catch { XCTAssertEqual((error as? FlowError)?.category, .signing) }
        let commands = await runner.commands; XCTAssertTrue(commands.isEmpty)
    }

    func testRegistryKeepsProfileBackupsAsRetainedUserData() async throws {
        let f = try RefreshFixture(), runner = RecordingRunner()
        let registry = ArtifactRegistry(runner: runner, executable: "/usr/bin/true")
        try await registry.recordProfileBackup(at: f.root.appendingPathComponent("Backup"), root: f.backups, source: "Test signing backup")
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 1)
        let arguments = commands[0].arguments
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--type")! + 1], "USER_DATA")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--project")! + 1], f.backups.path)
        XCTAssertFalse(arguments.contains("--regenerable"))
        XCTAssertFalse(arguments.contains("--safe-to-delete"))
    }
}
