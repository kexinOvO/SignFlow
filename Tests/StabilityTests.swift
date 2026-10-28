import XCTest
@testable import SignFlowCore

final class TaskResultTests: XCTestCase {
    func testStateRemainsBackgroundReadableWithPrivatePermissions() throws {
        let s = try Scenario()
        let repo = StateRepository(directory: s.root.appendingPathComponent("BackgroundState"))
        let state = PersistedState()
        try repo.save(state)
        XCTAssertEqual(try repo.load(), state)
        let attributes = try FileManager.default.attributesOfItem(atPath: repo.stateURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        if let protection = attributes[.protectionKey] {
            let value = (protection as? FileProtectionType)?.rawValue ?? (protection as? String)
            XCTAssertEqual(value, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        }
        let directory = try FileManager.default.attributesOfItem(atPath: repo.directory.path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testTaskAndProjectAreSavedTogether() throws {
        let s = try Scenario()
        let repo = StateRepository(directory: s.root.appendingPathComponent("State"))
        var task = s.task
        task.newSignatures = [signedBundle()]; task.artifactPath = s.app.path; task.assessment = .advanced
        task.deployments = [DeploymentEvidence(deviceID: "phone", deviceName: "Test", bundleID: "test.app", platform: .iOS, state: .installed, verifiedAt: Date(), sourceTaskID: task.id, message: "Test")]
        task.transition(.completed, "Completed")
        var state = PersistedState(); state.projects = [s.project]; state.tasks = [task]
        TaskResultCommitter.record(task, in: &state)
        try repo.save(state)
        let loaded = try repo.load()
        XCTAssertNotNil(loaded.tasks[0].projectResultCommittedAt)
        XCTAssertEqual(loaded.projects[0].signatures[0].profile?.uuid, task.newSignatures[0].profile?.uuid)
        XCTAssertEqual(loaded.projects[0].artifactPath, s.app.path)
        XCTAssertEqual(loaded.projects[0].deployments[0].sourceTaskID, task.id)
        XCTAssertNotNil(loaded.projects[0].lastRenewal)
    }

    func testLegacyCompletionIsReconciledWithoutRepeatingOperations() throws {
        let s = try Scenario()
        var task = s.task
        task.newSignatures = [signedBundle()]; task.artifactPath = s.app.path; task.assessment = .advanced
        task.transition(.completed, "Completed before project commit")
        var state = PersistedState(); state.projects = [s.project]; state.tasks = [task]
        // Optional new fields are absent in legacy JSON.
        var restored = try JSONDecoder.signFlow.decode(PersistedState.self, from: JSONEncoder.signFlow.encode(state))
        TaskResultCommitter.reconcile(&restored)
        XCTAssertEqual(restored.tasks[0].phase, .completed)
        XCTAssertEqual(restored.projects[0].artifactPath, s.app.path)
        XCTAssertEqual(restored.projects[0].signatures[0].profile?.uuid, task.newSignatures[0].profile?.uuid)
        restored.projects[0].artifactPath = "/new/user-selected.app"
        TaskResultCommitter.reconcile(&restored)
        XCTAssertEqual(restored.projects[0].artifactPath, "/new/user-selected.app")
    }

    func testLegacyReconciliationPreservesNewerSnapshotsAndEvidence() throws {
        let s = try Scenario()
        let now = Date()
        var task = s.task; task.newSignatures = [signedBundle()]; task.artifactPath = "/old.app"
        task.deployments = [DeploymentEvidence(deviceID: "phone", deviceName: "Test", bundleID: "test.app", platform: .iOS, state: .installed, verifiedAt: now, message: "Old")]
        task.transition(.partialSuccess, "Old", now: now)
        var project = s.project
        project.lastCheck = now.addingTimeInterval(10); project.artifactPath = "/new.app"
        project.deployments = [DeploymentEvidence(deviceID: "phone", deviceName: "Test", bundleID: "test.app", platform: .iOS, state: .notInstalled, verifiedAt: now.addingTimeInterval(10), message: "New")]
        var state = PersistedState(); state.projects = [project]; state.tasks = [task]
        TaskResultCommitter.reconcile(&state)
        XCTAssertEqual(state.projects[0].signatures, project.signatures)
        XCTAssertEqual(state.projects[0].artifactPath, "/new.app")
        XCTAssertEqual(state.projects[0].deployments[0].state, .notInstalled)
    }

    func testNewTransitionAllowsAResumedResultToBeCommitted() throws {
        let s = try Scenario()
        var task = s.task; task.newSignatures = [signedBundle()]; task.transition(.waitingDevice, "Offline")
        var state = PersistedState(); state.projects = [s.project]; state.tasks = [task]
        TaskResultCommitter.record(task, in: &state)
        task = state.tasks[0]
        task.transition(.checking, "Resume")
        XCTAssertNil(task.projectResultCommittedAt)
        task.transition(.completed, "Installed"); task.assessment = .advanced
        TaskResultCommitter.record(task, in: &state)
        XCTAssertNotNil(state.projects[0].lastRenewal)
    }

    func testLegacyResultsSharingASecondReplayOlderHistoryFirst() throws {
        let s = try Scenario()
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var older = s.task; older.newSignatures = [signedBundle()]; older.artifactPath = "/older.app"
        older.transition(.completed, "Older", now: date)
        var newer = s.task; newer.newSignatures = [signedBundle()]; newer.artifactPath = "/newer.app"
        newer.transition(.completed, "Newer", now: date)
        var state = PersistedState(); state.projects = [s.project]; state.tasks = [newer, older]
        TaskResultCommitter.reconcile(&state)
        XCTAssertEqual(state.projects[0].artifactPath, "/newer.app")
        XCTAssertEqual(state.projects[0].signatures, newer.newSignatures)
    }
}

private actor SlowQueryDevices: DeviceManaging {
    var entered: Set<ApplePlatform> = []
    let slowPlatform: ApplePlatform
    init(slowPlatform: ApplePlatform) { self.slowPlatform = slowPlatform }
    func discover() async throws -> [ManagedDevice] { [device(), device(platform: .watchOS)] }
    func installation(bundleID: String, device: ManagedDevice) async throws -> DeploymentEvidence {
        entered.insert(device.platform)
        if device.platform == slowPlatform { try await Task.sleep(for: .seconds(5)) }
        return DeploymentEvidence(deviceID: device.id, deviceName: device.name, bundleID: bundleID, platform: device.platform, state: .installed, installedVersion: "1.0", installedBuild: "2", verifiedAt: Date(), message: "Test")
    }
    func install(app: URL, device: ManagedDevice, output: @escaping @Sendable (String) -> Void) async throws { XCTFail("Unexpected installation") }
    func launch(bundleID: String, device: ManagedDevice) async throws { XCTFail("Unexpected launch") }
}

final class WorkflowBoundaryTests: XCTestCase {
    func testInstallationQueryRetryReplacesOfflineEvidence() async throws {
        let s = try Scenario()
        var task = s.task; task.kind = .verifyInstallation
        let engine = RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: []), devices: MockDevices(initiallyInstalled: true))
        var offline = s.context; offline.devices = []
        let first = await engine.execute(task: task, context: offline, update: { _ in }, output: { _ in })
        XCTAssertEqual(first.phase, .partialSuccess)
        let second = await engine.execute(task: first, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(second.phase, .completed)
        XCTAssertEqual(second.deployments.count, 1)
        XCTAssertEqual(second.deployments[0].state, .installed)
        XCTAssertTrue(second.events.contains { $0.phase == .partialSuccess })
    }

    func testCancellingSingleDeviceQueryIsCancelled() async throws { try await checkQueryCancellation(watch: false) }
    func testCancellingLastOfSeveralDeviceQueriesIsCancelled() async throws { try await checkQueryCancellation(watch: true) }
    private func checkQueryCancellation(watch: Bool) async throws {
        let s = try Scenario(watch: watch)
        let queries = SlowQueryDevices(slowPlatform: watch ? .watchOS : .iOS)
        let engine = RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: []), devices: queries)
        var task = s.task; task.kind = .verifyInstallation
        let running = Task { await engine.execute(task: task, context: s.context, update: { _ in }, output: { _ in }) }
        for _ in 0..<100 {
            if await queries.entered.contains(watch ? .watchOS : .iOS) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        running.cancel()
        let result = await running.value
        XCTAssertEqual(result.phase, .cancelled)
        XCTAssertEqual(result.error?.category, .cancelled)
        XCTAssertEqual(result.deployments.count, watch ? 1 : 0)
    }

    func testMissingArtifactGetsNewBuildAttemptWithoutSpendingRetryBudget() async throws {
        let s = try Scenario()
        let builder = MockBuilder(app: s.app)
        let engine = RenewalEngine(builder: builder, signer: MockSigner(bundles: [signedBundle()]), devices: MockDevices())
        var offline = s.context; offline.devices = []
        let first = await engine.execute(task: s.task, context: offline, update: { _ in }, output: { _ in })
        XCTAssertEqual(first.buildAttempt, 0)
        var missing = first; missing.artifactPath = s.root.appendingPathComponent("Missing.app").path
        let resumed = await engine.execute(task: missing, context: offline, update: { _ in }, output: { _ in })
        let requests = await builder.requests
        XCTAssertEqual(requests.map(\.attempt), [0, 1])
        XCTAssertEqual(resumed.buildAttempt, 1)
        XCTAssertEqual(resumed.retryCount, 0)
    }

    func testLegacyRecoverySkipsOccupiedAttemptDirectories() async throws {
        let s = try Scenario()
        var task = s.task; task.retryCount = 2; task.artifactPath = "/missing.app"
        let occupied = s.context.outputRoot.appendingPathComponent(task.id.uuidString).appendingPathComponent("Attempt-2/Build.xcresult")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let builder = MockBuilder(app: s.app)
        var offline = s.context; offline.devices = []
        let result = await RenewalEngine(builder: builder, signer: MockSigner(bundles: [signedBundle()]), devices: MockDevices()).execute(task: task, context: offline, update: { _ in }, output: { _ in })
        let requests = await builder.requests
        XCTAssertEqual(requests.first?.attempt, 3)
        XCTAssertEqual(result.retryCount, 2)
    }

    func testInterruptedBuildRetainsAttemptAndRetryBudget() throws {
        let s = try Scenario()
        var task = s.task; task.buildAttempt = 4; task.retryCount = 1; task.transition(.building, "Interrupted")
        let result = RecoveryPolicy.recover([task])[0]
        XCTAssertEqual(result.phase, .queued)
        XCTAssertEqual(result.buildAttempt, 4)
        XCTAssertEqual(result.retryCount, 1)
    }
}

final class ProcessBoundaryTests: XCTestCase {
    func testTimeoutAfterParentExitStopsDescendant() async throws {
        let s = try Scenario()
        let sentinel = s.root.appendingPathComponent("orphan-output")
        let start = Date()
        do {
            _ = try await ProcessCommandRunner().run(ToolCommand(executable: "/bin/sh", arguments: ["-c", "(/bin/sleep 1; /usr/bin/touch \"$1\") & exit 0", "test", sentinel.path], timeout: 0.05))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual((error as? FlowError)?.category, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testCancellationAfterParentExitReturnsPromptly() async throws {
        let start = Date()
        let running = Task { try await ProcessCommandRunner().run(ToolCommand(executable: "/bin/sh", arguments: ["-c", "/bin/sleep 8 & exit 0"], timeout: 10)) }
        try await Task.sleep(for: .milliseconds(100)); running.cancel()
        do { _ = try await running.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testIgnoringTerminationDoesNotHoldOutputOpenIndefinitely() async throws {
        let start = Date()
        do {
            _ = try await ProcessCommandRunner().run(ToolCommand(executable: "/bin/sh", arguments: ["-c", "(trap '' TERM; /bin/sleep 8) & exit 0"], timeout: 0.1))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual((error as? FlowError)?.category, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    func testLateDescendantOutputIsDrainedBeforeSuccess() async throws {
        let result = try await ProcessCommandRunner().run(ToolCommand(executable: "/bin/sh", arguments: ["-c", "(/bin/sleep 0.05; /usr/bin/printf late; /usr/bin/printf error >&2) & exit 0"], timeout: 3))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "late"); XCTAssertEqual(result.stderr, "error")
    }

    func testContinuousOutputCannotStarveTimeout() async throws {
        let start = Date()
        do { _ = try await ProcessCommandRunner().run(ToolCommand(executable: "/usr/bin/yes", timeout: 0.05)); XCTFail("Expected timeout") }
        catch {
            XCTAssertEqual((error as? FlowError)?.category, .timeout)
            XCTAssertLessThanOrEqual((error as? FlowError)?.technical.utf8.count ?? Int.max, 24_001)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testMissingExecutableDoesNotHangOrBreakSubsequentRuns() async throws {
        let runner = ProcessCommandRunner()
        do { _ = try await runner.run(ToolCommand(executable: "/missing/SignFlow-test-tool")); XCTFail("Expected failure") }
        catch { XCTAssertEqual((error as? FlowError)?.category, .environment) }
        let result = try await runner.run(ToolCommand(executable: "/usr/bin/printf", arguments: ["ok"]))
        XCTAssertEqual(result.stdout, "ok")
    }

    func testArgumentsEnvironmentWorkingDirectoryAndExitStatusArePreserved() async throws {
        let s = try Scenario()
        let value = "中文 value ; $(literal)"
        let command = ToolCommand(executable: "/bin/sh", arguments: ["-c", "/usr/bin/printf '%s' \"$SIGNFLOW_TEST_VALUE\"; /usr/bin/touch marker; exit 7"], environment: ["SIGNFLOW_TEST_VALUE": value], workingDirectory: s.root.path)
        let result = try await ProcessCommandRunner().run(command)
        XCTAssertEqual(result.stdout, value)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("marker").path))
    }
}
