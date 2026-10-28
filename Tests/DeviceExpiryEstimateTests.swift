import XCTest
@testable import SignFlowCore

final class DeviceExpiryEstimateTests: XCTestCase {
    private let installedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() -> (ManagedProject, FlowTask) {
        var project = ManagedProject(name: "Test", path: "/test/Test.xcodeproj", kind: .project, scheme: "Test")
        project.phoneID = "phone"; project.watchID = "watch"
        project.targets = [
            TargetInfo(name: "Phone", bundleID: "test.app", platform: .iOS, kind: .application, productType: "application", teamID: "TEAM123456", automaticSigning: true, deploymentTarget: "17", productPath: nil),
            TargetInfo(name: "Watch", bundleID: "test.app.watch", platform: .watchOS, kind: .watchApplication, productType: "application", teamID: "TEAM123456", automaticSigning: true, deploymentTarget: "10", productPath: nil)
        ]
        var task = FlowTask(projectID: project.id, projectName: project.name, kind: .renew)
        task.newSignatures = [signedBundle(expires: installedAt.addingTimeInterval(7 * 86400)),
                              signedBundle(platform: .watchOS, expires: installedAt.addingTimeInterval(6 * 86400))]
        task.deployments = [evidence(platform: .iOS, at: installedAt, source: task.id),
                            evidence(platform: .watchOS, at: installedAt.addingTimeInterval(1), source: task.id)]
        task.transition(.completed, "Installed", now: installedAt.addingTimeInterval(1))
        project.deployments = task.deployments
        return (project, task)
    }

    private func evidence(platform: ApplePlatform, at date: Date, source: UUID? = nil, state: InstallationState = .installed) -> DeploymentEvidence {
        DeploymentEvidence(deviceID: platform == .watchOS ? "watch" : "phone", deviceName: platform.rawValue,
                           bundleID: platform == .watchOS ? "test.app.watch" : "test.app", platform: platform,
                           state: state, installedVersion: "1.0", installedBuild: "2", verifiedAt: date,
                           sourceTaskID: source, message: "Test evidence")
    }

    private func estimate(_ project: ManagedProject, _ platform: ApplePlatform, _ tasks: [FlowTask], file: StaticString = #filePath, line: UInt = #line) throws -> InstalledProfileEstimate {
        guard case .available(let result) = InstalledProfileEstimateResolver.resolve(project: project, platform: platform, tasks: tasks) else {
            XCTFail("Expected an installation-based estimate", file: file, line: line)
            throw FlowError(.verification, "Missing estimate")
        }
        return result
    }

    func testEachDeviceUsesItsInstalledAppAndNestedExtensions() throws {
        var (project, install) = fixture()
        var phoneExtension = signedBundle(expires: installedAt.addingTimeInterval(5 * 86400))
        phoneExtension.bundleID = "test.app.extension"; phoneExtension.parentBundleID = "test.app"; phoneExtension.isExtension = true
        var watchExtension = signedBundle(platform: .watchOS, expires: installedAt.addingTimeInterval(4 * 86400))
        watchExtension.bundleID = "test.app.watch.extension"; watchExtension.parentBundleID = "test.app.watch"; watchExtension.isExtension = true
        install.newSignatures += [phoneExtension, watchExtension]
        // A newer local inspection does not change either installation's recorded signature.
        project.signatures = [signedBundle(expires: installedAt.addingTimeInterval(30 * 86400))]
        let phone = try estimate(project, .iOS, [install])
        let watch = try estimate(project, .watchOS, [install])
        XCTAssertEqual(phone.expirationDate, installedAt.addingTimeInterval(5 * 86400))
        XCTAssertEqual(watch.expirationDate, installedAt.addingTimeInterval(4 * 86400))
        XCTAssertEqual(phone.installationConfirmedAt, installedAt)
        XCTAssertEqual(watch.sourceTaskID, install.id)
    }

    func testLaterMatchingInspectionFindsOriginalInstallTask() throws {
        var (project, install) = fixture()
        let checked = installedAt.addingTimeInterval(60)
        let phone = evidence(platform: .iOS, at: checked)
        let watch = evidence(platform: .watchOS, at: checked.addingTimeInterval(1))
        var query = FlowTask(projectID: project.id, projectName: project.name, kind: .verifyInstallation)
        query.deployments = [phone, watch]
        project.deployments = [phone, watch]
        let value = try estimate(project, .iOS, [query, install])
        XCTAssertEqual(value.sourceTaskID, install.id)
        XCTAssertEqual(value.installationConfirmedAt, installedAt)
        XCTAssertEqual(value.installationCheckedAt, checked)
    }

    func testVersionChangesOrMissingVersionDoNotProduceEstimate() {
        var (project, install) = fixture()
        project.deployments[0].installedBuild = "3"
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [install]), .unavailable(.changed))
        project.deployments[0].installedVersion = nil; project.deployments[0].installedBuild = nil
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [install]), .unavailable(.changed))
    }

    func testRemovalOrDifferentVersionBreaksHistoryEvenIfSameVersionReappears() {
        var (project, install) = fixture()
        var check = FlowTask(projectID: project.id, projectName: project.name, kind: .verifyInstallation)
        check.deployments = [evidence(platform: .iOS, at: installedAt.addingTimeInterval(10), state: .notInstalled)]
        project.deployments[0] = evidence(platform: .iOS, at: installedAt.addingTimeInterval(20))
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [install, check]), .unavailable(.changed))
        check.deployments[0].state = .installed; check.deployments[0].installedBuild = "different"
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [install, check]), .unavailable(.changed))
    }

    func testNewConfirmedInstallRestoresEstimateAfterRemoval() throws {
        var (project, install) = fixture()
        var removal = FlowTask(projectID: project.id, projectName: project.name, kind: .verifyInstallation)
        removal.deployments = [evidence(platform: .iOS, at: installedAt.addingTimeInterval(10), state: .notInstalled)]
        var next = FlowTask(projectID: project.id, projectName: project.name, kind: .buildInstall)
        next.newSignatures = [signedBundle(expires: installedAt.addingTimeInterval(14 * 86400))]
        next.deployments = [evidence(platform: .iOS, at: installedAt.addingTimeInterval(20), source: next.id)]
        project.deployments[0] = next.deployments[0]
        XCTAssertEqual(try estimate(project, .iOS, [install, removal, next]).sourceTaskID, next.id)
    }

    func testSelectedDeviceAndCurrentInstallStateMustMatch() {
        var (project, install) = fixture()
        project.phoneID = "another-phone"
        XCTAssertNil(project.selectedDeployment(for: .iOS))
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [install]), .unavailable(.noCurrentInstallation))
        project.phoneID = nil
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [install]), .unavailable(.noDevice))
        project.phoneID = "phone"; project.deployments[0].state = .offline
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [install]), .unavailable(.noCurrentInstallation))
    }

    func testMissingOrInvalidLatestSignatureDoesNotFallBackToOldInstall() {
        var (project, old) = fixture()
        var latest = FlowTask(projectID: project.id, projectName: project.name, kind: .buildInstall)
        latest.newSignatures = [signedBundle()]
        latest.newSignatures[0].profile = nil
        latest.deployments = [evidence(platform: .iOS, at: installedAt.addingTimeInterval(20), source: latest.id)]
        project.deployments[0] = latest.deployments[0]
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [old, latest]), .unavailable(.missingSignature))
        latest.newSignatures[0] = signedBundle(valid: false)
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [old, latest]), .unavailable(.missingSignature))
    }

    func testOnlyAnActualInstallTaskCanSupplyProvenance() {
        let (project, install) = fixture()
        var query = FlowTask(projectID: project.id, projectName: project.name, kind: .verifyInstallation)
        query.newSignatures = install.newSignatures
        query.deployments = [evidence(platform: .iOS, at: installedAt, source: query.id)]
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [query]), .unavailable(.noInstallRecord))
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: []), .unavailable(.noInstallRecord))
    }

    func testSameSecondInstallAmbiguityDoesNotPickArbitrarily() {
        let (project, install) = fixture()
        var other = FlowTask(projectID: project.id, projectName: project.name, kind: .buildInstall)
        other.newSignatures = install.newSignatures
        other.deployments = [evidence(platform: .iOS, at: installedAt, source: other.id)]
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [install, other]), .unavailable(.noInstallRecord))
    }

    func testPartialTaskCanStillProvePhoneInstallIndependently() throws {
        let (project, original) = fixture()
        var partial = original; partial.phase = .partialSuccess
        partial.deployments[1].state = .failed; partial.deployments[1].sourceTaskID = nil
        var current = project; current.deployments = partial.deployments
        XCTAssertEqual(try estimate(current, .iOS, [partial]).sourceTaskID, partial.id)
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: current, platform: .watchOS, tasks: [partial]), .unavailable(.noCurrentInstallation))
    }

    func testAttemptedReplacementMustFinishBeforeEarlierEstimateIsReused() {
        var (project, install) = fixture()
        var attempted = FlowTask(projectID: project.id, projectName: project.name, kind: .buildInstall)
        attempted.phase = .installing
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [install, attempted]), .unavailable(.noCurrentInstallation))
        attempted.phase = .retryableFailure
        attempted.deployments = [evidence(platform: .iOS, at: installedAt.addingTimeInterval(10), state: .unknown)]
        project.deployments[0] = evidence(platform: .iOS, at: installedAt.addingTimeInterval(20))
        XCTAssertEqual(InstalledProfileEstimateResolver.resolve(project: project, platform: .iOS, tasks: [install, attempted]), .unavailable(.changed))
    }
}
