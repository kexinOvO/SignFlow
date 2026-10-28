import XCTest
@testable import SignFlowCore

final class InfrastructureTests: XCTestCase {
    func testDeviceParsingFiltersSimulatorsAndUsesReliableFields() throws {
        let root: [String: Any] = ["devices": [
            ["identifier": "phone", "hardwareProperties": ["reality": "physical", "platform": "iOS", "udid": "UDID"], "deviceProperties": ["name": "中文 iPhone", "developerModeStatus": "enabled", "bootState": "booted"], "connectionProperties": ["pairingState": "paired", "tunnelState": "connected"]],
            ["identifier": "sim", "hardwareProperties": ["reality": "simulated"]]
        ]]
        let devices = try DeviceService.parseDevices(root)
        XCTAssertEqual(devices.count, 1); XCTAssertEqual(devices[0].name, "中文 iPhone"); XCTAssertEqual(devices[0].connection, .connected); XCTAssertEqual(devices[0].developerMode, .enabled)
        XCTAssertThrowsError(try DeviceService.parseDevices([:]))
    }
    func testInstalledMetadataDoesNotImplyVerifiedDeviceProfile() throws {
        let value = try DeviceService.parseInstallation(["apps": [["bundleIdentifier": "test.app", "version": "1.0", "bundleVersion": "2"]]], bundleID: "test.app", device: device())
        XCTAssertEqual(value.state, .installed); XCTAssertFalse(value.deviceSignatureVerified)
        XCTAssertEqual(value.installedBuild, "2")
        XCTAssertThrowsError(try DeviceService.parseInstallation([:], bundleID: "test.app", device: device()))
    }
    func testErrorClassificationAvoidsGuessingCoreDeviceCause() {
        let value = ErrorClassifier.classify("Error Domain=com.apple.dt.CoreDeviceError Code=4000")
        XCTAssertEqual(value.category, .deviceConnection); XCTAssertTrue(value.retryable); XCTAssertFalse(value.requiresUser)
        XCTAssertEqual(ErrorClassifier.classify("RemotePairingError Code=1001").category, .watchConnection)
        XCTAssertEqual(ErrorClassifier.classify("Developer Mode is disabled").category, .developerMode)
        XCTAssertTrue(ErrorClassifier.classify("Authentication failed").requiresUser)
    }
    func testPersistenceRoundtripAndInterruptedTaskRecovery() throws {
        let s = try Scenario(); let repo = StateRepository(directory: s.root.appendingPathComponent("State"))
        var state = PersistedState(); state.projects = [s.project]; state.settings.advanceHours = 36
        var task = s.task; task.transition(.installing, "test"); state.tasks = [task]
        try repo.save(state); let restored = try repo.load()
        XCTAssertEqual(restored.projects[0].path, s.project.path); XCTAssertEqual(restored.settings.advanceHours, 36)
        let recovered = RecoveryPolicy.recover(restored.tasks)
        XCTAssertEqual(recovered[0].phase, .queued); XCTAssertTrue(recovered[0].recovered)
    }
    func testMigrationAndFutureVersionProtection() throws {
        let migrated = try JSONDecoder.signFlow.decode(PersistedState.self, from: Data(#"{"projects":[],"tasks":[]}"#.utf8))
        XCTAssertEqual(migrated.schemaVersion, 1); XCTAssertEqual(migrated.settings.advanceHours, 48)
        XCTAssertThrowsError(try JSONDecoder.signFlow.decode(PersistedState.self, from: Data(#"{"schemaVersion":999}"#.utf8)))
    }
    func testCorruptStateIsPreserved() throws {
        let s = try Scenario(); let repo = StateRepository(directory: s.root)
        let data = Data("corrupt user data".utf8); try data.write(to: repo.stateURL)
        XCTAssertThrowsError(try repo.load()); XCTAssertEqual(try Data(contentsOf: repo.stateURL), data)
    }
    func testInstanceLock() throws {
        let s = try Scenario(); let lease = try InstanceLease(directory: s.root)
        try withExtendedLifetime(lease) { XCTAssertThrowsError(try InstanceLease(directory: s.root)) }
    }
    func testBuildCommandUsesArgumentsAndSeparateOutput() throws {
        let s = try Scenario(); s.project.path = s.root.appendingPathComponent("Source/中文 Project $(evil).xcworkspace").path; s.project.kind = .workspace
        let request = BuildRequest(project: s.project, taskID: UUID(), outputRoot: s.root.appendingPathComponent("Output"), developerDirectory: "/Xcode", destinationUDID: "UDID", supportsProvisioningUpdates: true, supportsDeviceRegistration: true)
        let command = try BuildService.command(for: request)
        XCTAssertEqual(command.arguments[0], "-workspace"); XCTAssertEqual(command.arguments[1], s.project.path)
        XCTAssertTrue(command.arguments.contains("-allowProvisioningUpdates")); XCTAssertFalse(command.arguments.contains("-allowProvisioningDeviceRegistration"))
        XCTAssertFalse(command.arguments.contains("clean")); XCTAssertFalse(command.arguments.contains("uninstall"))
        var invalid = request; invalid.outputRoot = URL(fileURLWithPath: s.project.path).deletingLastPathComponent().appendingPathComponent("DerivedData")
        XCTAssertThrowsError(try BuildService.command(for: invalid))
    }
    func testProcessDoesNotInterpretShellCharacters() async throws {
        let string = "中文 ; $(echo WRONG) 'quoted'"
        let result = try await ProcessCommandRunner().run(ToolCommand(executable: "/usr/bin/printf", arguments: ["%s", string]))
        XCTAssertEqual(result.stdout, string); XCTAssertEqual(result.exitCode, 0)
    }
    func testProcessTimeout() async throws {
        do { _ = try await ProcessCommandRunner().run(ToolCommand(executable: "/bin/sleep", arguments: ["5"], timeout: 0.1)); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? FlowError)?.category, .timeout) }
    }
    func testProcessCancellation() async throws {
        let task = Task { try await ProcessCommandRunner().run(ToolCommand(executable: "/bin/sleep", arguments: ["5"])) }
        try await Task.sleep(for: .milliseconds(50)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testProcessDrainsLargeOutputBeforeCompleting() async throws {
        let result = try await ProcessCommandRunner().run(ToolCommand(executable: "/usr/bin/seq", arguments: ["1", "40000"]))
        XCTAssertEqual(result.exitCode, 0); XCTAssertTrue(result.stdout.hasSuffix("40000\n")); XCTAssertEqual(result.stdout.split(separator: "\n").count, 40000)
    }
    func testProcessConcurrentCompletionsDoNotLoseOutput() async throws {
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<12 { group.addTask { try await ProcessCommandRunner().run(ToolCommand(executable: "/usr/bin/printf", arguments: ["%s", "\(index)"])).stdout } }
            var results: [String] = []; for try await value in group { results.append(value) }; return results
        }
        XCTAssertEqual(Set(values), Set((0..<12).map(String.init)))
    }
    func testNewAttemptDoesNotReuseResultBundle() throws {
        let s = try Scenario()
        var request = BuildRequest(project: s.project, taskID: UUID(), outputRoot: s.root.appendingPathComponent("Output"), developerDirectory: "", destinationUDID: nil, supportsProvisioningUpdates: true, supportsDeviceRegistration: false)
        let first = BuildService.taskDirectory(request); request.attempt = 1
        XCTAssertNotEqual(first, BuildService.taskDirectory(request))
    }
    func testCancellationDrainsPipesOwnedByDescendant() async throws {
        let started = Date()
        // Constant test-only script creates a child inheriting both pipes.
        // Production commands always pass project paths in separate argv elements.
        let running = Task { try await ProcessCommandRunner().run(ToolCommand(executable: "/bin/sh", arguments: ["-c", "/bin/sleep 5 & wait"], timeout: 7)) }
        try await Task.sleep(for: .milliseconds(100)); running.cancel()
        do { _ = try await running.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
