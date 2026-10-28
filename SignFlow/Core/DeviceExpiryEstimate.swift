import Foundation

// A deployment record is evidence of a past install, not a device-side profile read.
struct InstalledProfileEstimate: Equatable {
    let expirationDate: Date
    let installationConfirmedAt: Date
    let installationCheckedAt: Date
    let sourceTaskID: UUID
}

enum InstalledProfileEstimateStatus: Equatable {
    enum Unavailable: Equatable {
        case noDevice, noApp, noCurrentInstallation, noInstallRecord, changed, missingSignature

        var description: String {
            switch self {
            case .noDevice: return "未选择设备"
            case .noApp: return "未识别应用"
            case .noCurrentInstallation: return "安装状态未确认"
            case .noInstallRecord: return "没有可用的安装记录"
            case .changed: return "安装状态或版本已变化"
            case .missingSignature: return "安装产物的签名记录不完整"
            }
        }
    }

    case available(InstalledProfileEstimate)
    case unavailable(Unavailable)
}

extension ManagedProject {
    func selectedDeviceID(for platform: ApplePlatform) -> String? {
        switch platform {
        case .iOS: return phoneID
        case .watchOS: return watchID
        default: return nil
        }
    }

    func installedAppID(for platform: ApplePlatform) -> String? {
        let kind: TargetKind = platform == .watchOS ? .watchApplication : .application
        let target = targets.first { $0.platform == platform && $0.kind == kind && !$0.bundleID.isEmpty }
        return target?.bundleID ?? signatures.first { $0.platform == platform && !$0.isExtension && !$0.bundleID.isEmpty }?.bundleID
    }

    func selectedDeployment(for platform: ApplePlatform) -> DeploymentEvidence? {
        guard let deviceID = selectedDeviceID(for: platform), let appID = installedAppID(for: platform) else { return nil }
        return deployments.filter { $0.deviceID == deviceID && $0.platform == platform && $0.bundleID == appID }
            .max { $0.verifiedAt < $1.verifiedAt }
    }
}

enum InstalledProfileEstimateResolver {
    static func resolve(project: ManagedProject, platform: ApplePlatform, tasks: [FlowTask]) -> InstalledProfileEstimateStatus {
        guard let deviceID = project.selectedDeviceID(for: platform) else { return .unavailable(.noDevice) }
        guard let appID = project.installedAppID(for: platform) else { return .unavailable(.noApp) }
        guard let current = project.selectedDeployment(for: platform), current.state == .installed else {
            return .unavailable(.noCurrentInstallation)
        }

        let projectTasks = tasks.filter { $0.projectID == project.id }
        if projectTasks.contains(where: { [.buildInstall, .renew].contains($0.kind) && [.installing, .verifyingInstallation].contains($0.phase) }) {
            return .unavailable(.noCurrentInstallation)
        }
        let installs = projectTasks.filter { [.buildInstall, .renew].contains($0.kind) }.flatMap { task in
            task.deployments.filter {
                $0.deviceID == deviceID && $0.platform == platform && $0.bundleID == appID &&
                $0.state == .installed && $0.sourceTaskID == task.id
            }.map { (task: task, evidence: $0) }
        }
        guard let latestDate = installs.map(\.evidence.verifiedAt).max() else { return .unavailable(.noInstallRecord) }
        let latest = installs.filter { $0.evidence.verifiedAt == latestDate }
        // Persisted dates have second precision; do not choose arbitrarily between tied installs.
        guard latest.count == 1, let install = latest.first else { return .unavailable(.noInstallRecord) }
        guard current.verifiedAt >= install.evidence.verifiedAt else { return .unavailable(.noCurrentInstallation) }

        let roots = install.task.newSignatures.filter { $0.bundleID == appID && $0.platform == platform && !$0.isExtension }
        guard roots.count == 1, let root = roots.first else { return .unavailable(.missingSignature) }
        guard matchesVersion(install.evidence, root), matchesVersion(current, root) else { return .unavailable(.changed) }

        // A later observed removal, different version, or uncertain replacement breaks the chain,
        // even if a later query happens to find the same version again.
        for task in projectTasks where task.id != install.task.id {
            for observation in task.deployments where observation.deviceID == deviceID && observation.platform == platform && observation.bundleID == appID && observation.verifiedAt >= latestDate {
                switch observation.state {
                case .notInstalled, .failed, .awaitingWatchSync:
                    return .unavailable(.changed)
                case .installed:
                    if hasVersionConflict(observation, root) { return .unavailable(.changed) }
                case .offline, .unknown:
                    // A failed install attempt can have changed the device before the error.
                    if [.buildInstall, .renew].contains(task.kind) { return .unavailable(.changed) }
                }
            }
        }

        // Include this app's nested extensions but never the separate Watch app on the phone.
        var bundleIDs: Set<String> = [root.bundleID]
        var components = [root]
        var added = true
        while added {
            added = false
            for bundle in install.task.newSignatures where bundle.isExtension && !bundleIDs.contains(bundle.bundleID) {
                if let parent = bundle.parentBundleID, bundleIDs.contains(parent) {
                    bundleIDs.insert(bundle.bundleID); components.append(bundle); added = true
                }
            }
        }
        guard components.allSatisfy({ $0.codeSignatureValid && $0.profile != nil }),
              let expiration = components.compactMap({ $0.profile?.expirationDate }).min() else {
            return .unavailable(.missingSignature)
        }
        return .available(InstalledProfileEstimate(expirationDate: expiration,
                                                    installationConfirmedAt: latestDate,
                                                    installationCheckedAt: current.verifiedAt,
                                                    sourceTaskID: install.task.id))
    }

    private static func hasVersionConflict(_ evidence: DeploymentEvidence, _ bundle: SignedBundle) -> Bool {
        if let version = evidence.installedVersion, !version.isEmpty, !bundle.version.isEmpty, version != bundle.version { return true }
        if let build = evidence.installedBuild, !build.isEmpty, !bundle.buildVersion.isEmpty, build != bundle.buildVersion { return true }
        return false
    }

    private static func matchesVersion(_ evidence: DeploymentEvidence, _ bundle: SignedBundle) -> Bool {
        guard !hasVersionConflict(evidence, bundle) else { return false }
        return (evidence.installedVersion.map { !$0.isEmpty && !bundle.version.isEmpty } ?? false) ||
               (evidence.installedBuild.map { !$0.isEmpty && !bundle.buildVersion.isEmpty } ?? false)
    }
}
