import XCTest
@testable import SignFlowCore

final class WorkflowTests: XCTestCase {
    func testRenewalBuildReceivesNestedSigningBaseline() async throws {
        let s = try Scenario(watch: true)
        let builder = MockBuilder(app: s.app)
        let result = await RenewalEngine(builder: builder, signer: MockSigner(bundles: [signedBundle(), signedBundle(platform: .watchOS)]), devices: MockDevices(values: s.context.devices)).execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .completed)
        let requests = await builder.requests
        XCTAssertEqual(requests.first?.renewalBaseline, s.project.signatures)
    }
    func testOrdinaryBuildDoesNotRequestProfileRefresh() async throws {
        let s = try Scenario()
        let builder = MockBuilder(app: s.app)
        var task = s.task; task.kind = .buildInstall
        _ = await RenewalEngine(builder: builder, signer: MockSigner(bundles: [signedBundle()]), devices: MockDevices()).execute(task: task, context: s.context, update: { _ in }, output: { _ in })
        let requests = await builder.requests
        XCTAssertEqual(requests.count, 1); XCTAssertNil(requests[0].renewalBaseline)
    }
    func testSuccessfulRenewalAndInstallation() async throws {
        let s = try Scenario(); let devices = MockDevices()
        let engine = RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle()]), devices: devices)
        let result = await engine.execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .completed); XCTAssertEqual(result.assessment, .advanced)
        XCTAssertEqual(result.deployments.first?.state, .installed)
        XCTAssertFalse(result.deployments[0].deviceSignatureVerified)
        XCTAssertEqual(result.events.map(\.phase), [.checking, .needsRenewal, .preparing, .building, .verifyingSignature, .installing, .verifyingInstallation, .completed])
    }
    func testPhoneInstallFailureAfterSignatureUpdateIsPartial() async throws {
        let s = try Scenario(); let devices = MockDevices(failIDs: ["phone"])
        let engine = RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle()]), devices: devices)
        let result = await engine.execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .partialSuccess); XCTAssertEqual(result.assessment, .advanced)
        XCTAssertEqual(result.deployments[0].state, .failed)
    }
    func testWatchFailureDoesNotHidePhoneSuccess() async throws {
        let s = try Scenario(watch: true); let devices = MockDevices(values: s.context.devices, failIDs: ["watch"])
        let engine = RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle(), signedBundle(platform: .watchOS)]), devices: devices)
        let result = await engine.execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .partialSuccess)
        XCTAssertEqual(result.deployments.first(where: { $0.platform == .iOS })?.state, .installed)
        XCTAssertEqual(result.deployments.first(where: { $0.platform == .watchOS })?.state, .failed)
    }
    func testOfflineDeviceWaitsWithVerifiedLocalArtifact() async throws {
        let s = try Scenario(); var context = s.context; context.devices = [device(connection: .offline)]
        let engine = RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle()]), devices: MockDevices())
        let result = await engine.execute(task: s.task, context: context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .waitingDevice); XCTAssertEqual(result.assessment, .advanced); XCTAssertNotNil(result.artifactPath)
    }
    func testWatchWithoutDirectInstallCapabilityRemainsUnverified() async throws {
        let s = try Scenario(watch: true); var context = s.context; context.devices = [device(), device(platform: .watchOS, installCapable: false)]
        let devices = MockDevices(values: context.devices)
        let result = await RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle(), signedBundle(platform: .watchOS)]), devices: devices).execute(task: s.task, context: context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .waitingDevice)
        XCTAssertEqual(result.deployments.first(where: { $0.platform == .watchOS })?.state, .awaitingWatchSync)
        let calls = await devices.installCalls; XCTAssertEqual(calls, ["phone"])
    }
    func testWatchUsesCapabilitiesDiscoveredAfterConnecting() async throws {
        let s = try Scenario(watch: true); var context = s.context
        context.devices = [device(), device(platform: .watchOS, installCapable: false)]
        let devices = MockDevices(values: context.devices, preparedDevices: ["watch": device(platform: .watchOS)])
        let result = await RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle(), signedBundle(platform: .watchOS)]), devices: devices).execute(task: s.task, context: context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .completed)
        let calls = await devices.installCalls; XCTAssertEqual(calls, ["phone", "watch"])
        XCTAssertEqual(result.deployments.first(where: { $0.platform == .watchOS })?.sourceTaskID, result.id)
    }
    func testAccountInteractionStopsAutomaticRetry() async throws {
        let s = try Scenario(); let error = FlowError(.authentication, "Sign in", requiresUser: true)
        let result = await RenewalEngine(builder: MockBuilder(app: s.app, error: error), signer: MockSigner(bundles: []), devices: MockDevices()).execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .waitingUser); XCTAssertNil(result.nextRetryAt)
    }
    func testUnchangedProfileIsNotInstalledAsRenewed() async throws {
        let s = try Scenario(); let devices = MockDevices()
        let result = await RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: s.project.signatures), devices: devices).execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .waitingUser); XCTAssertEqual(result.error?.category, .profileUnchanged)
        let calls = await devices.installCalls; XCTAssertTrue(calls.isEmpty)
    }
    func testExistingInstallRequiresAcknowledgmentAndNeverUninstalls() async throws {
        let s = try Scenario(); let devices = MockDevices(initiallyInstalled: true)
        let result = await RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle()]), devices: devices).execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .waitingUser)
        let calls = await devices.installCalls; XCTAssertTrue(calls.isEmpty)
        let existing = await devices.initiallyInstalled; XCTAssertTrue(existing)
    }
    func testCannotVerifyInstallationDoesNotSucceed() async throws {
        let s = try Scenario(); let devices = MockDevices(); await devices.setUnknownVersion()
        let result = await RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle()]), devices: devices).execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .retryableFailure); XCTAssertEqual(result.error?.category, .verification)
    }
    func testAppAbsentAfterInstallDoesNotSucceed() async throws {
        let s = try Scenario(); let devices = MockDevices(); await devices.setAbsentAfterInstall()
        let result = await RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle()]), devices: devices).execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .retryableFailure)
    }
    func testAutomaticInstallDisabledKeepsLocalOnlyResult() async throws {
        let s = try Scenario(); var context = s.context; context.installAutomatically = false
        let devices = MockDevices()
        let result = await RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle()]), devices: devices).execute(task: s.task, context: context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .partialSuccess); XCTAssertEqual(result.assessment, .advanced)
        let calls = await devices.installCalls; XCTAssertTrue(calls.isEmpty)
    }
    func testResumeDoesNotRebuildOrReinstallConfirmedPhone() async throws {
        let s = try Scenario(); let builder = MockBuilder(app: s.app); let devices = MockDevices()
        let engine = RenewalEngine(builder: builder, signer: MockSigner(bundles: [signedBundle()]), devices: devices)
        let first = await engine.execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        let resumed = await engine.execute(task: first, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(resumed.phase, .completed)
        let builds = await builder.calls; let installs = await devices.installCalls
        XCTAssertEqual(builds, 1); XCTAssertEqual(installs, ["phone"])
    }
    func testRecoveredPhoneFailureDoesNotRemainWhileWatchAwaitsSync() async throws {
        let s = try Scenario(watch: true)
        var context = s.context
        context.devices = [device(), device(platform: .watchOS, installCapable: false)]
        let builder = MockBuilder(app: s.app)
        let signer = MockSigner(bundles: [signedBundle(), signedBundle(platform: .watchOS)])
        let failed = await RenewalEngine(builder: builder, signer: signer, devices: MockDevices(values: context.devices, failIDs: ["phone"]))
            .execute(task: s.task, context: context, update: { _ in }, output: { _ in })
        XCTAssertNotNil(failed.error)
        let recovered = await RenewalEngine(builder: builder, signer: signer, devices: MockDevices(values: context.devices))
            .execute(task: failed, context: context, update: { _ in }, output: { _ in })
        XCTAssertEqual(recovered.phase, .waitingDevice)
        XCTAssertNil(recovered.error)
        XCTAssertEqual(recovered.deployments.first(where: { $0.platform == .iOS })?.state, .installed)
        XCTAssertEqual(recovered.deployments.first(where: { $0.platform == .watchOS })?.state, .awaitingWatchSync)
        XCTAssertTrue(recovered.events.contains { $0.phase == .partialSuccess })
        let builds = await builder.calls; XCTAssertEqual(builds, 1)
    }
    func testTaskCancellation() async throws {
        let s = try Scenario()
        let engine = RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle()]), devices: MockDevices())
        let running = Task { await engine.execute(task: s.task, context: s.context, update: { _ in }, output: { _ in }) }
        running.cancel(); let result = await running.value
        XCTAssertEqual(result.phase, .cancelled)
    }
    func testMissingSigningIdentityNeedsUser() async throws {
        let s = try Scenario()
        let result = await RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [], availableIdentity: false), devices: MockDevices()).execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .waitingUser); XCTAssertEqual(result.error?.category, .signing)
    }
    func testMutexBlocksSameProjectAcrossSchemes() async throws {
        let s = try Scenario(); let mutex = ProjectMutex(); var other = s.project; other.scheme = "Another"
        let first = await mutex.acquire(s.project); let second = await mutex.acquire(other)
        XCTAssertTrue(first); XCTAssertFalse(second)
        await mutex.release(s.project); let third = await mutex.acquire(other); XCTAssertTrue(third)
    }
    func testRetryLimitsAndExponentialBackoff() {
        let now = Date()
        XCTAssertEqual(RecoveryPolicy.nextRetry(count: 0, maxRetries: 3, base: 60, now: now), now.addingTimeInterval(60))
        XCTAssertEqual(RecoveryPolicy.nextRetry(count: 2, maxRetries: 3, base: 60, now: now), now.addingTimeInterval(240))
        XCTAssertNil(RecoveryPolicy.nextRetry(count: 3, maxRetries: 3, base: 60, now: now))
    }
    func testMissingExpectedWatchBundleCannotComplete() async throws {
        let s = try Scenario(watch: true)
        s.project.targets.append(TargetInfo(name: "Watch", bundleID: "test.app.watch", platform: .watchOS, kind: .watchApplication, productType: "application", teamID: "TEAM123456", automaticSigning: true, deploymentTarget: "10", productPath: nil))
        let result = await RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: [signedBundle()]), devices: MockDevices()).execute(task: s.task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .waitingUser); XCTAssertEqual(result.error?.category, .signing)
    }
    func testInstallationQueryWorksBeforeFirstBuild() async throws {
        let s = try Scenario(); s.project.signatures = []
        var task = s.task; task.kind = .verifyInstallation
        let result = await RenewalEngine(builder: MockBuilder(app: s.app), signer: MockSigner(bundles: []), devices: MockDevices(initiallyInstalled: true)).execute(task: task, context: s.context, update: { _ in }, output: { _ in })
        XCTAssertEqual(result.phase, .completed); XCTAssertEqual(result.deployments.count, 1); XCTAssertTrue(result.newSignatures.isEmpty)
    }
    func testAutomaticRetryBudgetCannotRestartAfterInspection() throws {
        let s = try Scenario(); var task = s.task; task.automatic = true; task.oldSignatures = s.project.signatures
        task.transition(.failed, "Retry budget exhausted")
        // Reinspection changes timestamps and paths, not the actual signing baseline.
        s.project.signatures[0].inspectedAt = Date().addingTimeInterval(200)
        s.project.signatures[0].path = "/another/Artifact.app"
        XCTAssertFalse(SchedulingPolicy.canCreateAutomaticRenewal(project: s.project, tasks: [task]))
        s.project.signatures[0].profile?.uuid = UUID().uuidString
        XCTAssertTrue(SchedulingPolicy.canCreateAutomaticRenewal(project: s.project, tasks: [task]))
    }
    func testPendingTaskPreventsDuplicateAutomaticRenewal() throws {
        let s = try Scenario(); XCTAssertFalse(SchedulingPolicy.canCreateAutomaticRenewal(project: s.project, tasks: [s.task]))
    }
}
