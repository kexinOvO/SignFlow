import Foundation
@testable import SignFlowCore

func profile(expires: Date = Date().addingTimeInterval(7 * 86400), creation: Date = Date(), uuid: String = UUID().uuidString) -> ProvisioningProfile {
    ProvisioningProfile(uuid: uuid, name: "Test Development", teamIDs: ["TEAM123456"], applicationIdentifier: "TEAM123456.test.app", creationDate: creation, expirationDate: expires, provisionedDevices: ["phoneUDID", "watchUDID"], entitlements: ["application-identifier": "TEAM123456.test.app", "get-task-allow": "true"], certificates: [], provisionsAllDevices: false, isDevelopment: true)
}
func signedBundle(platform: ApplePlatform = .iOS, expires: Date = Date().addingTimeInterval(7 * 86400), creation: Date = Date(), valid: Bool = true) -> SignedBundle {
    let id = platform == .watchOS ? "test.app.watch" : "test.app"
    var p = profile(expires: expires, creation: creation); p.applicationIdentifier = "TEAM123456." + id
    return SignedBundle(path: "/test/\(id).app", bundleID: id, displayName: platform.rawValue, version: "1.0", buildVersion: "2", platform: platform, isExtension: false, parentBundleID: platform == .watchOS ? "test.app" : nil, teamID: "TEAM123456", codeSignatureValid: valid, validationMessage: valid ? "valid" : "invalid", profile: p, inspectedAt: Date())
}
func device(platform: ApplePlatform = .iOS, connection: ConnectionState = .connected, installCapable: Bool = true) -> ManagedDevice {
    ManagedDevice(id: platform == .watchOS ? "watch" : "phone", udid: platform == .watchOS ? "watchUDID" : "phoneUDID", name: platform.rawValue, platform: platform, model: "Test", osVersion: "27", connection: connection, developerMode: .enabled, pairingState: "paired", transport: "usb", capabilities: installCapable ? ["com.apple.coredevice.feature.installapp"] : [])
}
actor MockBuilder: AppBuilding {
    var calls = 0
    var requests: [BuildRequest] = []
    var error: FlowError?
    let app: URL
    init(app: URL, error: FlowError? = nil) { self.app = app; self.error = error }
    func build(_ request: BuildRequest, output: @escaping @Sendable (String) -> Void) async throws -> BuildProduct {
        calls += 1
        requests.append(request)
        if let error { throw error }
        return BuildProduct(app: app, derivedData: request.outputRoot, command: ToolCommand(executable: "mock"))
    }
}
struct MockSigner: SignatureInspecting {
    var bundles: [SignedBundle]
    var availableIdentity = true
    func inspect(app: URL) async throws -> [SignedBundle] { bundles }
    func identities() async throws -> [SigningIdentity] { availableIdentity ? [SigningIdentity(id: "test", name: "Apple Development: Test", teamID: "TEAM123456", expiresAt: nil)] : [] }
}
actor MockDevices: DeviceManaging {
    var values: [ManagedDevice]
    var installCalls: [String] = []
    var installed: Set<String> = []
    var failIDs: Set<String>
    var unknownVersion = false
    var absentAfterInstall = false
    var initiallyInstalled: Bool
    var preparedDevices: [String: ManagedDevice]
    init(values: [ManagedDevice] = [device()], failIDs: Set<String> = [], initiallyInstalled: Bool = false, preparedDevices: [String: ManagedDevice] = [:]) { self.values = values; self.failIDs = failIDs; self.initiallyInstalled = initiallyInstalled; self.preparedDevices = preparedDevices }
    func setUnknownVersion() { unknownVersion = true }
    func setAbsentAfterInstall() { absentAfterInstall = true }
    func discover() async throws -> [ManagedDevice] { values }
    func prepareForInstallation(_ device: ManagedDevice) async throws -> ManagedDevice { preparedDevices[device.id] ?? device }
    func installation(bundleID: String, device: ManagedDevice) async throws -> DeploymentEvidence {
        let exists = initiallyInstalled || installed.contains(device.id + bundleID) && !absentAfterInstall
        return DeploymentEvidence(deviceID: device.id, deviceName: device.name, bundleID: bundleID, platform: device.platform, state: exists ? .installed : .notInstalled, installedVersion: unknownVersion ? nil : "1.0", installedBuild: unknownVersion ? nil : "2", verifiedAt: Date(), message: "Mock installation query")
    }
    func install(app: URL, device: ManagedDevice, output: @escaping @Sendable (String) -> Void) async throws {
        installCalls.append(device.id)
        if failIDs.contains(device.id) { throw FlowError(.install, "Mock install failure") }
        installed.insert(device.id + (device.platform == .watchOS ? "test.app.watch" : "test.app"))
    }
    func launch(bundleID: String, device: ManagedDevice) async throws { }
}

final class Scenario {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SignFlowTests-\(UUID())")
    let app: URL
    var project: ManagedProject
    var environment: XcodeEnvironment
    init(watch: Bool = false) throws {
        app = root.appendingPathComponent("Built.app")
        let source = root.appendingPathComponent("Source/Test.xcodeproj")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        project = ManagedProject(name: "Test", path: source.path, kind: .project, scheme: "Test")
        project.phoneID = "phone"; project.watchID = watch ? "watch" : nil
        project.targets = [TargetInfo(name: "Test", bundleID: "test.app", platform: .iOS, kind: .application, productType: "application", teamID: "TEAM123456", automaticSigning: true, deploymentTarget: "17", productPath: nil)]
        project.signatures = [signedBundle(expires: Date().addingTimeInterval(24 * 3600), creation: Date().addingTimeInterval(-6 * 86400))]
        if watch { project.signatures.append(signedBundle(platform: .watchOS, expires: Date().addingTimeInterval(24 * 3600), creation: Date().addingTimeInterval(-6 * 86400))) }
        environment = XcodeEnvironment(developerDirectory: "/Xcode/Developer", version: "Xcode 27", swiftVersion: "Swift 6", sdks: "", devicectlPath: "/devicectl", supportsProvisioningUpdates: true)
    }
    var context: WorkflowContext { WorkflowContext(project: project, environment: environment, devices: project.watchID == nil ? [device()] : [device(), device(platform: .watchOS)], outputRoot: root.appendingPathComponent("Output"), installAutomatically: true) }
    var task: FlowTask { FlowTask(projectID: project.id, projectName: project.name, kind: .renew) }
    deinit { try? FileManager.default.removeItem(at: root) }
}
