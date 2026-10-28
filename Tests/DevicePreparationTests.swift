import XCTest
@testable import SignFlowCore

private actor DeviceDetailsRunner: CommandExecuting {
    let supportsShow: Bool
    let identifier: String
    var commands: [ToolCommand] = []
    init(supportsShow: Bool = true, identifier: String = "watch") { self.supportsShow = supportsShow; self.identifier = identifier }
    func run(_ command: ToolCommand, output: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        commands.append(command)
        if command.arguments.contains("--help") {
            return CommandResult(exitCode: 0, stdout: supportsShow ? "--show <show>" : "--device <identifier>", stderr: "", duration: 0)
        }
        let row: [String: Any] = ["identifier": identifier, "hardwareProperties": ["reality": "physical", "platform": "watchOS", "udid": "watchUDID"], "deviceProperties": ["name": "Watch", "bootState": "booted", "developerModeStatus": "enabled"], "connectionProperties": ["tunnelState": "connected", "pairingState": "paired"], "capabilities": [["featureIdentifier": "com.apple.coredevice.feature.installapp"]]]
        let response: [String: Any] = ["info": ["outcome": "success"], "result": row]
        let index = command.arguments.firstIndex(of: "--json-output")!
        try JSONSerialization.data(withJSONObject: response).write(to: URL(fileURLWithPath: command.arguments[index + 1]))
        return CommandResult(exitCode: 0, stdout: "", stderr: "", duration: 0)
    }
}

final class DevicePreparationTests: XCTestCase {
    func testResolvesLiveWatchCapabilitiesInsteadOfPairedSnapshot() async throws {
        let s = try Scenario(), runner = DeviceDetailsRunner()
        let service = DeviceService(runner: runner, temporaryRoot: s.root.appendingPathComponent("Queries"))
        let resolved = try await service.prepareForInstallation(device(platform: .watchOS, connection: .available, installCapable: false))
        XCTAssertEqual(resolved.connection, .connected); XCTAssertTrue(resolved.canInstall)
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[1].arguments.contains("--show"))
        XCTAssertTrue(commands[1].arguments.contains("detailed"))
    }
    func testOlderDeviceToolsDoNotReceiveUnsupportedShowOption() async throws {
        let s = try Scenario(), runner = DeviceDetailsRunner(supportsShow: false)
        let service = DeviceService(runner: runner, temporaryRoot: s.root.appendingPathComponent("Queries"))
        let resolved = try await service.prepareForInstallation(device(platform: .watchOS, connection: .available, installCapable: false))
        XCTAssertTrue(resolved.canInstall)
        let commands = await runner.commands; XCTAssertFalse(commands[1].arguments.contains("--show"))
    }
    func testResolvedDeviceMustMatchSelectedDevice() async throws {
        let s = try Scenario(), runner = DeviceDetailsRunner(identifier: "another-watch")
        let service = DeviceService(runner: runner, temporaryRoot: s.root.appendingPathComponent("Queries"))
        do { _ = try await service.prepareForInstallation(device(platform: .watchOS)); XCTFail("Expected device mismatch") }
        catch { XCTAssertEqual((error as? FlowError)?.category, .verification) }
    }
}
