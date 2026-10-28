import Foundation

struct WorkflowContext: Sendable {
    var project: ManagedProject
    var environment: XcodeEnvironment
    var devices: [ManagedDevice]
    var outputRoot: URL
    var installAutomatically: Bool
    var trustExistingInstallation: Bool = false
}

protocol WorkflowRunning: Sendable {
    func execute(task: FlowTask, context: WorkflowContext, update: @escaping @Sendable (FlowTask) async -> Void, output: @escaping @Sendable (String) -> Void) async -> FlowTask
}

struct RenewalEngine: WorkflowRunning {
    let builder: any AppBuilding
    let signer: any SignatureInspecting
    let devices: any DeviceManaging

    func execute(task original: FlowTask, context: WorkflowContext, update: @escaping @Sendable (FlowTask) async -> Void, output: @escaping @Sendable (String) -> Void) async -> FlowTask {
        var task = original
        // A resumed attempt reports its current failure; previous failures remain in events.
        task.error = nil
        let project = context.project
        func publish(_ phase: TaskPhase, _ message: String) async {
            task.transition(phase, message); await update(task)
        }
        do {
            try Task.checkCancellation()
            await publish(.checking, "检查项目、工具链和已保存的签名证据")
            guard context.environment.ready else { throw FlowError(.environment, "Xcode 环境不可用", technical: context.environment.errors.joined(separator: "\n"), suggestion: "打开签名与账户页面检查工具链。", requiresUser: true) }
            guard FileManager.default.isReadableFile(atPath: project.path) else { throw FlowError(.project, "项目路径已变更或无权访问", technical: project.path, suggestion: "在项目详情中重新定位工程。", requiresUser: true) }
            if task.oldSignatures.isEmpty { task.oldSignatures = project.signatures }
            if task.kind == .verifyInstallation {
                task.deployments = []
                var subjects = project.signatures.filter { !$0.isExtension }.map { ($0.bundleID, $0.platform) }
                for target in project.targets where [.application, .watchApplication].contains(target.kind) && !target.bundleID.isEmpty {
                    if !subjects.contains(where: { $0.0 == target.bundleID }) { subjects.append((target.bundleID, target.platform)) }
                }
                if subjects.isEmpty { throw FlowError(.verification, "没有已识别的 App Bundle ID，请先刷新项目元数据。") }
                for (bundleID, platform) in subjects {
                    try Task.checkCancellation()
                    let deviceID = platform == .watchOS ? project.watchID : project.phoneID
                    guard let device = context.devices.first(where: { $0.id == deviceID }) else {
                        task.deployments.append(DeploymentEvidence(deviceID: deviceID ?? "unselected-\(platform.rawValue)", deviceName: "未选择或未发现设备", bundleID: bundleID, platform: platform, state: .offline, verifiedAt: Date(), message: "设备安装尚未确认。")); continue
                    }
                    do { task.deployments.append(try await devices.installation(bundleID: bundleID, device: device)) }
                    catch {
                        if error is CancellationError { throw error }
                        let error = FlowError.wrap(error)
                        task.deployments.append(DeploymentEvidence(deviceID: device.id, deviceName: device.name, bundleID: bundleID, platform: platform, state: error.category == .deviceOffline ? .offline : .unknown, verifiedAt: Date(), message: error.message + "\n" + error.suggestion))
                    }
                }
                try Task.checkCancellation()
                let allInstalled = !task.deployments.isEmpty && task.deployments.allSatisfy { $0.state == .installed }
                await publish(allInstalled ? .completed : .partialSuccess, allInstalled ? "已确认所选设备的应用安装记录；设备端签名期限无法读取。" : "部分设备的应用尚未确认安装。")
                return task
            }
            if task.kind == .inspect {
                guard let path = project.artifactPath else { throw FlowError(.signing, "没有 SignFlow 构建产物", suggestion: "先执行构建并安装，或在项目详情选择一个现有 .app 进行检查。", requiresUser: true) }
                task.newSignatures = try await signer.inspect(app: URL(fileURLWithPath: path))
                try Self.validateExpectedBundles(project: project, bundles: task.newSignatures)
                guard task.newSignatures.allSatisfy(\.codeSignatureValid) else { throw FlowError(.signing, "一个或多个 Bundle 的签名无效", technical: task.newSignatures.map(\.validationMessage).joined(separator: "\n")) }
                await publish(.completed, "本地产物签名检查完成；尚未据此验证设备端签名。")
                return task
            }
            if task.kind == .renew { await publish(.needsRenewal, "将比较构建前后的全部嵌套 Profile 有效期") }
            await publish(.preparing, "检查签名身份，准备独立构建目录")
            let identities = try await signer.identities()
            guard identities.contains(where: { $0.name.contains("Development") || $0.name.contains("Developer") }) else {
                throw FlowError(.signing, "本机没有可用的开发签名身份", suggestion: "在 Xcode → 设置 → 账户 → Manage Certificates 中创建 Apple Development 证书。", requiresUser: true)
            }
            // Resume only an artifact that this exact persisted task already produced.
            if let path = task.artifactPath, FileManager.default.fileExists(atPath: path) {
                await publish(.verifyingSignature, "重新检查中断任务的已有产物")
                task.newSignatures = try await signer.inspect(app: URL(fileURLWithPath: path))
            } else {
                let primaryID = project.primaryTarget?.platform == .watchOS ? project.watchID : project.phoneID
                let device = context.devices.first { $0.id == primaryID && $0.canAttemptConnection }
                task.buildAttempt = try BuildService.nextAttempt(taskID: task.id, outputRoot: context.outputRoot, after: task.buildAttempt, legacyAttempt: task.retryCount)
                task.artifactPath = nil; task.newSignatures = []; task.deployments = []; task.assessment = nil
                await publish(.building, task.kind == .renew ? "备份并刷新当前项目的 Profile，由 Xcode 构建续签产物" : "Xcode 正在构建并请求可用的自动签名资源")
                try Task.checkCancellation()
                let request = BuildRequest(project: project, taskID: task.id, outputRoot: context.outputRoot, developerDirectory: context.environment.developerDirectory, destinationUDID: device?.udid, supportsProvisioningUpdates: context.environment.supportsProvisioningUpdates, supportsDeviceRegistration: context.environment.supportsDeviceRegistration, attempt: task.buildAttempt!, renewalBaseline: task.kind == .renew ? task.oldSignatures : nil)
                let product = try await builder.build(request, output: output)
                task.artifactPath = product.app.path
                await publish(.verifyingSignature, "构建完成，验证签名、证书、Profile 及嵌套 App")
                task.newSignatures = try await signer.inspect(app: product.app)
            }
            try Task.checkCancellation()
            try Self.validateExpectedBundles(project: project, bundles: task.newSignatures)
            task.assessment = RenewalVerifier.assess(old: task.oldSignatures, new: task.newSignatures)
            guard task.assessment != .invalid else {
                throw FlowError(.signing, "构建产物没有通过完整签名验证", technical: task.newSignatures.map { "\($0.bundleID): \($0.validationMessage)" }.joined(separator: "\n"), suggestion: "旧安装未卸载。请查看每个 Bundle 的 Profile 和签名错误。", requiresUser: true)
            }
            if task.kind == .renew && task.assessment == .unchanged {
                let details = task.newSignatures.map { bundle in
                    "\(bundle.bundleID): \(bundle.profile?.uuid ?? "unknown")，到期 \(bundle.profile?.expirationDate.ISO8601Format() ?? "unknown")"
                }.joined(separator: "\n")
                throw FlowError(.profileUnchanged, "Profile 有效期没有延长，未认定为续签成功", technical: details, suggestion: "已请求 Xcode 刷新专属 Profile，但返回的有效期仍未延长。请在 Xcode 检查账户状态与签名资源限制；共享通配 Profile 需要在 Xcode 中处理。", requiresUser: true)
            }
            if !context.installAutomatically {
                await publish(.partialSuccess, "\(task.assessment!.title)；自动安装已关闭，尚未部署。")
                return task
            }
            var waiting = false
            var failure: FlowError?
            // iPhone and Watch are handled independently. A phone install never proves Watch installation.
            for bundle in task.newSignatures where !bundle.isExtension {
                try Task.checkCancellation()
                let deviceID = bundle.platform == .watchOS ? project.watchID : project.phoneID
                guard let device = context.devices.first(where: { $0.id == deviceID && $0.platform == bundle.platform }), device.canAttemptConnection else {
                    upsert(missingEvidence(bundle, deviceID: deviceID), into: &task.deployments); waiting = true; continue
                }
                guard let profile = bundle.profile, profile.supports(deviceUDID: device.udid) else {
                    let error = FlowError(.signing, "\(bundle.displayName) 的 Profile 不包含 \(device.name)", suggestion: "在 Xcode 选中此设备后刷新自动签名，或启用项目的自动设备注册。", requiresUser: true)
                    upsert(errorEvidence(bundle, device: device, error: error), into: &task.deployments); failure = error; continue
                }
                do {
                    output("正在连接 \(device.name)，读取当前安装能力。\n")
                    let device = try await devices.prepareForInstallation(device)
                    let before = try await devices.installation(bundleID: bundle.bundleID, device: device)
                    if let previous = task.deployments.first(where: { $0.id == before.id }), previous.sourceTaskID == task.id, previous.state == .installed, before.state == .installed,
                       Self.matchesVersion(before, bundle: bundle) {
                        continue // A confirmed installation from this exact task is idempotent.
                    }
                    // A first-time adoption of an existing app requires an in-app data-risk acknowledgment.
                    if before.state == .installed && !context.trustExistingInstallation && !project.deployments.contains(where: { $0.id == before.id && $0.sourceTaskID != nil }) {
                        throw FlowError(.install, "需要确认覆盖已有的 \(bundle.displayName)", suggestion: "设备已安装相同 Bundle ID，但无法读取其 Team 与 Keychain 权限。在项目设置确认接受覆盖安装风险后重试。SignFlow 只调用覆盖安装，不会自动卸载。", requiresUser: true)
                    }
                    if let old = task.oldSignatures.first(where: { $0.bundleID == bundle.bundleID }), let team = old.teamID, team != bundle.teamID {
                        throw FlowError(.install, "开发团队变更，已停止覆盖安装", suggestion: "团队变化可能影响应用数据或 Keychain。请在 Xcode 中审查后手动处理。", requiresUser: true)
                    }
                    if bundle.platform == .watchOS && !device.canInstall {
                        var evidence = before
                        if before.state != .installed { evidence.state = .awaitingWatchSync }
                        evidence.message = "此 Watch 当前未公开直接安装能力。iPhone 安装不代表 Watch 已更新；请在 Watch App 中同步后再次检查。"
                        // An old Watch install cannot prove this task deployed its new signed build.
                        if before.state == .installed { evidence.state = .awaitingWatchSync }
                        upsert(evidence, into: &task.deployments); waiting = true; continue
                    }
                    await publish(.installing, "正在覆盖安装 \(bundle.displayName) → \(device.name)")
                    try await devices.install(app: URL(fileURLWithPath: bundle.path), device: device, output: output)
                    await publish(.verifyingInstallation, "安装命令已返回，查询 \(device.name) 上的 Bundle ID 与版本")
                    var evidence = try await devices.installation(bundleID: bundle.bundleID, device: device)
                    guard evidence.state == .installed, Self.matchesVersion(evidence, bundle: bundle) else {
                        throw FlowError(.verification, "安装命令已完成，但未确认目标版本", technical: "\(bundle.bundleID) expected \(bundle.version) (\(bundle.buildVersion))", suggestion: "保留此任务并在设备页面再次检查。", retryable: true)
                    }
                    evidence.sourceTaskID = task.id
                    evidence.message = "已确认安装命令成功，且设备查询到对应 Bundle ID 与版本。签名期限仅来自本次已验证的本地产物；未直接读取设备端 Profile。"
                    upsert(evidence, into: &task.deployments)
                } catch {
                    if error is CancellationError { throw error }
                    let flow = FlowError.wrap(error); failure = flow
                    upsert(errorEvidence(bundle, device: device, error: flow), into: &task.deployments)
                }
                await update(task)
            }
            if let failure {
                task.error = failure
                if failure.requiresUser { await publish(.waitingUser, "\(task.assessment!.title)；部署需要用户操作。\(failure.message)") }
                else if failure.retryable { await publish(.retryableFailure, "\(task.assessment!.title)；部署失败，等待重试。\(failure.message)") }
                else { await publish(.partialSuccess, "\(task.assessment!.title)；部署失败。\(failure.message)") }
            } else if waiting {
                await publish(.waitingDevice, "\(task.assessment!.title)；等待所选设备或 Watch 安装验证。")
            } else {
                let summary = task.kind == .renew && task.assessment == .advanced ? "签名有效期已延长，所选设备安装已确认。" : "构建与所选设备安装已确认。\(task.assessment!.title)。"
                await publish(.completed, summary)
            }
        } catch {
            let error = FlowError.wrap(error); task.error = error
            if error.category == .cancelled { await publish(.cancelled, "任务已取消；已有安装未卸载。") }
            else if error.requiresUser { await publish(.waitingUser, error.message) }
            else if error.retryable { await publish(.retryableFailure, error.message) }
            else { await publish(task.assessment == .advanced ? .partialSuccess : .failed, error.message) }
        }
        return task
    }

    private static func matchesVersion(_ evidence: DeploymentEvidence, bundle: SignedBundle) -> Bool {
        // At least one version field must be available; unknown is never successful verification.
        let shortMatches = evidence.installedVersion.map { $0 == bundle.version } ?? true
        let buildMatches = evidence.installedBuild.map { $0 == bundle.buildVersion } ?? true
        return (evidence.installedVersion != nil || evidence.installedBuild != nil) && shortMatches && buildMatches
    }
    static func validateExpectedBundles(project: ManagedProject, bundles: [SignedBundle]) throws {
        let expected = project.targets.filter { [.application, .watchApplication, .appExtension].contains($0.kind) && [.iOS, .watchOS].contains($0.platform) }
        let missing = expected.filter { target in !target.bundleID.isEmpty && !bundles.contains { $0.bundleID == target.bundleID } }
        guard missing.isEmpty else { throw FlowError(.signing, "构建产物缺少已识别的 App 或 Extension", technical: missing.map { $0.name + " (" + $0.bundleID + ")" }.joined(separator: "\n"), suggestion: "请检查 Scheme 的构建项与 Embed 配置。", requiresUser: true) }
    }
    private func upsert(_ evidence: DeploymentEvidence, into values: inout [DeploymentEvidence]) {
        values.removeAll { $0.id == evidence.id }; values.append(evidence)
    }
    private func missingEvidence(_ bundle: SignedBundle, deviceID: String?) -> DeploymentEvidence {
        DeploymentEvidence(deviceID: deviceID ?? "unselected-\(bundle.platform.rawValue)", deviceName: "未选择或未发现设备", bundleID: bundle.bundleID, platform: bundle.platform, state: .offline, verifiedAt: Date(), message: "本地产物已检查，设备安装尚未确认。")
    }
    private func errorEvidence(_ bundle: SignedBundle, device: ManagedDevice, error: Error) -> DeploymentEvidence {
        let flow = FlowError.wrap(error)
        return DeploymentEvidence(deviceID: device.id, deviceName: device.name, bundleID: bundle.bundleID, platform: bundle.platform, state: flow.category == .deviceOffline ? .offline : flow.category == .verification ? .unknown : .failed, verifiedAt: Date(), message: flow.message + "\n" + flow.suggestion)
    }
}
