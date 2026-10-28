import XCTest
@testable import SignFlowCore

private struct ModelQueryRunner: CommandExecuting {
    func run(_ command: ToolCommand, output: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        if let index = command.arguments.firstIndex(of: "--json-output") {
            let value: [String: Any] = ["info": ["outcome": "success"], "result": ["devices": []]]
            try JSONSerialization.data(withJSONObject: value).write(to: URL(fileURLWithPath: command.arguments[index + 1]))
        } else { XCTFail("Unexpected tool: \(command.executable)") }
        return CommandResult(exitCode: 0, stdout: "", stderr: "", duration: 0)
    }
}

private actor ModelTestWorkflow: WorkflowRunning {
    enum Mode: Sendable { case complete, hold, publishCompletion, retryable }
    let mode: Mode
    var executions: [UUID] = []
    var cleanupFinished = false
    var completionPublished = false
    init(_ mode: Mode) { self.mode = mode }
    func execute(task original: FlowTask, context: WorkflowContext, update: @escaping @Sendable (FlowTask) async -> Void, output: @escaping @Sendable (String) -> Void) async -> FlowTask {
        executions.append(original.id)
        var task = original
        task.transition(.checking, "Test workflow entered"); await update(task)
        if mode == .hold {
            do { try await Task.sleep(for: .seconds(20)) }
            catch {
                await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
                cleanupFinished = true
                task.error = FlowError(.cancelled, "Test cancellation")
                task.transition(.cancelled, "Test cleanup finished"); await update(task)
                return task
            }
        }
        if mode == .retryable {
            task.error = FlowError(.timeout, "Test temporary failure", retryable: true)
            task.transition(.retryableFailure, "Test retryable failure"); await update(task)
            return task
        }
        task.newSignatures = [signedBundle()]
        task.artifactPath = context.outputRoot.appendingPathComponent("Test.app").path
        task.assessment = .advanced
        task.transition(.completed, "Test completion"); await update(task)
        completionPublished = true
        if mode == .publishCompletion { try? await Task.sleep(for: .seconds(5)) }
        return task
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel(_ scenario: Scenario, projects: [ManagedProject], tasks: [FlowTask], workflow: ModelTestWorkflow) throws -> AppModel {
        let repo = StateRepository(directory: scenario.root.appendingPathComponent("State-\(UUID())"))
        var state = PersistedState(); state.projects = projects; state.tasks = tasks; state.devices = [device()]
        state.settings.automationEnabled = true
        state.settings.notifyExpiry = false; state.settings.notifyInstall = false; state.settings.notifyRenewal = false
        state.settings.notifyFailure = false; state.settings.notifyUserAction = false; state.settings.notifyDevice = false
        for index in state.tasks.indices { state.tasks[index].logPath = repo.directory.appendingPathComponent("Logs/\(state.tasks[index].id).log").path }
        try repo.save(state)
        let model = AppModel(runner: ModelQueryRunner(), repository: repo, workflow: workflow)
        if let error = model.alertError { throw error }
        model.environment = scenario.environment
        return model
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    func testShutdownWaitsForCleanupAndDoesNotStartQueuedWork() async throws {
        let s = try Scenario()
        var other = s.project; other.id = UUID(); other.path = s.root.appendingPathComponent("Other.xcodeproj").path
        let first = FlowTask(projectID: s.project.id, projectName: "First", kind: .inspect)
        let second = FlowTask(projectID: other.id, projectName: "Second", kind: .inspect)
        let workflow = ModelTestWorkflow(.hold)
        let model = try makeModel(s, projects: [s.project, other], tasks: [first, second], workflow: workflow)
        model.updateSettings { $0.logRetentionDays = 31 }
        try await waitUntil { await workflow.executions.count == 1 }
        await model.shutdown()
        let executions = await workflow.executions
        let cleanupFinished = await workflow.cleanupFinished
        XCTAssertEqual(executions, [first.id])
        XCTAssertTrue(cleanupFinished)
        XCTAssertTrue(model.isStopping)
        let disk = try model.repository.load()
        XCTAssertTrue(disk.tasks.allSatisfy { $0.phase == .queued })
        XCTAssertEqual(disk.tasks[0].retryCount, 0)
        await model.shutdown() // Repeated termination requests are safe.
    }

    func testStopRejectsEnqueueRetryAndSchedulerWork() async throws {
        let s = try Scenario()
        var project = s.project; project.renewal.enabled = true
        let task = FlowTask(projectID: project.id, projectName: "Test", kind: .inspect)
        let workflow = ModelTestWorkflow(.complete)
        let model = try makeModel(s, projects: [project], tasks: [task], workflow: workflow)
        model.stop()
        model.enqueue(project.id, kind: .verifyInstallation)
        model.retry(task.id)
        await model.tick()
        await model.shutdown()
        let executions = await workflow.executions
        XCTAssertTrue(executions.isEmpty)
        XCTAssertEqual(model.state.tasks.count, 1)
        XCTAssertEqual(model.state.tasks[0].phase, .queued)
    }

    func testDisabledProjectKeepsQueuedWaitingAndRetryTasksSuspended() async throws {
        let s = try Scenario()
        var tasks: [FlowTask] = []
        for phase in [TaskPhase.queued, .waitingDevice, .retryableFailure] {
            var task = FlowTask(projectID: s.project.id, projectName: "Test", kind: .inspect, automatic: true)
            task.transition(phase, "Existing automatic task"); task.nextRetryAt = .distantPast
            tasks.append(task)
        }
        let workflow = ModelTestWorkflow(.complete)
        let model = try makeModel(s, projects: [s.project], tasks: tasks, workflow: workflow)
        model.updateSettings { $0.logRetentionDays = 31 }
        await model.tick()
        model.enqueue(s.project.id, kind: .renew, automatic: true)
        let executions = await workflow.executions
        XCTAssertTrue(executions.isEmpty)
        XCTAssertEqual(model.state.tasks.map(\.phase), [.queued, .waitingDevice, .retryableFailure])
        await model.shutdown()
    }

    func testDisablingActiveProjectWaitsAndResumesOnlyAfterReenabling() async throws {
        let s = try Scenario()
        var project = s.project; project.renewal.enabled = true
        let workflow = ModelTestWorkflow(.hold)
        let model = try makeModel(s, projects: [project], tasks: [], workflow: workflow)
        model.enqueue(project.id, kind: .inspect, automatic: true)
        try await waitUntil { await workflow.executions.count == 1 }
        project.renewal.enabled = false; model.updateProject(project)
        try await waitUntil { model.state.tasks[0].phase == .queued }
        let countWhileDisabled = await workflow.executions.count
        XCTAssertEqual(countWhileDisabled, 1)
        XCTAssertEqual(model.state.tasks[0].retryCount, 0)
        project.renewal.enabled = true; model.updateProject(project)
        try await waitUntil { await workflow.executions.count == 2 }
        await model.shutdown()
    }

    func testGlobalPauseSuspendsActiveAutomaticTaskWithoutSpendingRetryBudget() async throws {
        let s = try Scenario()
        var project = s.project; project.renewal.enabled = true
        let workflow = ModelTestWorkflow(.hold)
        let model = try makeModel(s, projects: [project], tasks: [], workflow: workflow)
        model.enqueue(project.id, kind: .inspect, automatic: true)
        try await waitUntil { await workflow.executions.count == 1 }
        model.updateSettings { $0.automationPaused = true }
        try await waitUntil { model.state.tasks[0].phase == .queued }
        XCTAssertEqual(model.state.tasks[0].retryCount, 0)
        XCTAssertNil(model.state.tasks[0].error)
        await model.shutdown()
    }

    func testManualTaskRunsWithProjectAutomationDisabled() async throws {
        let s = try Scenario()
        let workflow = ModelTestWorkflow(.complete)
        let model = try makeModel(s, projects: [s.project], tasks: [], workflow: workflow)
        model.updateSettings { $0.automationEnabled = false }
        model.enqueue(s.project.id, kind: .inspect)
        try await waitUntil { model.state.tasks.first?.phase == .completed }
        let executions = await workflow.executions
        XCTAssertEqual(executions.count, 1)
        await model.shutdown()
    }

    func testExplicitRetryCanContinueASuspendedAutomaticTask() async throws {
        let s = try Scenario()
        let task = FlowTask(projectID: s.project.id, projectName: "Test", kind: .inspect, automatic: true)
        let workflow = ModelTestWorkflow(.complete)
        let model = try makeModel(s, projects: [s.project], tasks: [task], workflow: workflow)
        model.updateSettings { $0.automationEnabled = false }
        model.retry(task.id)
        try await waitUntil { model.state.tasks[0].phase == .completed }
        XCTAssertTrue(model.state.tasks[0].automatic)
        XCTAssertNil(model.state.tasks[0].manualRetryRequested)
        await model.shutdown()
    }

    func testExplicitRetryDoesNotEnableLaterAutomaticRetries() async throws {
        let s = try Scenario()
        let task = FlowTask(projectID: s.project.id, projectName: "Test", kind: .inspect, automatic: true)
        let workflow = ModelTestWorkflow(.retryable)
        let model = try makeModel(s, projects: [s.project], tasks: [task], workflow: workflow)
        model.retry(task.id)
        try await waitUntil { model.state.tasks[0].phase == .retryableFailure }
        XCTAssertNil(model.state.tasks[0].manualRetryRequested)
        model.state.tasks[0].nextRetryAt = .distantPast
        await model.tick()
        let executions = await workflow.executions
        XCTAssertEqual(executions.count, 1)
        XCTAssertEqual(model.state.tasks[0].phase, .retryableFailure)
        await model.shutdown()
    }

    func testFinalResultAndProjectCommitAfterWorkflowAndLogFinish() async throws {
        let s = try Scenario()
        let workflow = ModelTestWorkflow(.publishCompletion)
        let model = try makeModel(s, projects: [s.project], tasks: [], workflow: workflow)
        model.enqueue(s.project.id, kind: .renew)
        try await waitUntil { await workflow.completionPublished }
        let beforeReturn = try model.repository.load()
        XCTAssertEqual(beforeReturn.tasks[0].phase, .checking)
        XCTAssertNil(beforeReturn.projects[0].artifactPath)
        await model.shutdown()
        let disk = try model.repository.load()
        XCTAssertEqual(disk.tasks[0].phase, .completed)
        XCTAssertNotNil(disk.tasks[0].projectResultCommittedAt)
        XCTAssertEqual(disk.projects[0].artifactPath, disk.tasks[0].artifactPath)
        XCTAssertEqual(disk.projects[0].signatures, disk.tasks[0].newSignatures)
        XCTAssertNotNil(disk.projects[0].lastRenewal)
    }

    func testInitializationRepairsLegacyCompletedTaskProjection() async throws {
        let s = try Scenario()
        var task = s.task; task.newSignatures = [signedBundle()]; task.artifactPath = s.app.path; task.assessment = .advanced
        task.transition(.completed, "Legacy completion")
        let model = try makeModel(s, projects: [s.project], tasks: [task], workflow: ModelTestWorkflow(.complete))
        XCTAssertEqual(model.state.projects[0].artifactPath, s.app.path)
        XCTAssertNotNil(model.state.projects[0].lastRenewal)
        XCTAssertNotNil(model.state.tasks[0].projectResultCommittedAt)
        await model.shutdown()
    }
}
