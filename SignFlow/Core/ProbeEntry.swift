import Foundation

public enum SignFlowProbe {
    public static func run(arguments: [String]) async {
        let runner = ProcessCommandRunner()
        if arguments.first == "--inspect-app" {
            guard arguments.count == 2 else { print("Usage: SignFlowProbe --inspect-app /path/to/App.app"); return }
            do {
                let bundles = try await SigningService(runner: runner).inspect(app: URL(fileURLWithPath: arguments[1]))
                for bundle in bundles {
                    print("BUNDLE \(bundle.bundleID) valid=\(bundle.codeSignatureValid)")
                    if let profile = bundle.profile {
                        print("PROFILE expires=\(profile.expirationDate.formatted(.iso8601)) development=\(profile.isDevelopment)")
                        for key in profile.entitlements.keys.sorted() { print("ALLOWED \(key)=\(profile.entitlements[key]!)") }
                    }
                    print(bundle.validationMessage)
                }
            } catch { print("SIGNATURE ERROR \(FlowError.wrap(error))") }
            return
        }
        let environment = await XcodeService(runner: runner).inspect()
        print("Xcode: \(environment.version); ready=\(environment.ready)")
        print("Swift: \(environment.swiftVersion)")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Probe")
        let service = ProjectService(runner: runner, metadataRoot: root)
        for path in arguments where !path.hasPrefix("--") {
            do {
                let url = URL(fileURLWithPath: path)
                let schemes = try await service.schemes(at: url)
                print("PROJECT \(path)\nSCHEMES \(schemes.joined(separator: ", "))")
                for scheme in schemes where !scheme.lowercased().contains("mac") && (scheme.contains("IOS") || scheme == "Reminder" || scheme.lowercased().contains("watch")) {
                    let project = try await service.inspect(url: url, scheme: scheme)
                    for target in project.targets { print("TARGET \(target.name) | \(target.platform.rawValue) | \(target.kind.rawValue) | \(target.bundleID) | automatic=\(target.automaticSigning) | team=\(target.teamID)") }
                }
            } catch { print("ERROR \(FlowError.wrap(error))") }
        }
        if arguments.contains("--devices") {
            do {
                let devices = try await DeviceService(runner: runner, temporaryRoot: root.appendingPathComponent("DeviceQuery")).discover()
                for device in devices { print("DEVICE \(device.platform.rawValue) | \(device.name) | \(device.connection.title) | developerMode=\(device.developerMode.title) | canInstall=\(device.canInstall)") }
            } catch { print("DEVICE ERROR \(FlowError.wrap(error))") }
        }
        if arguments.contains("--signing") {
            let signer = SigningService(runner: runner)
            do {
                let identities = try await signer.identities()
                for identity in identities { print("IDENTITY team=\(identity.teamID ?? "unknown") expires=\(identity.expiresAt?.formatted(.iso8601) ?? "unknown")") }
                let locations = ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"]
                var count = 0
                for location in locations {
                    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(location)
                    let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                    for file in files where file.pathExtension == "mobileprovision" {
                        let profile = try await signer.decodeProfile(at: file)
                        count += 1
                        print("PROFILE decoded=true team=\(profile.teamIDs.joined(separator: ",")) creation=\(profile.creationDate.formatted(.iso8601)) expires=\(profile.expirationDate.formatted(.iso8601)) certificates=\(profile.certificates.count)")
                    }
                }
                print("PROFILE COUNT \(count)")
            } catch { print("SIGNING ERROR \(FlowError.wrap(error))") }
        }
    }
}
