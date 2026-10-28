import Foundation
import Security
import CryptoKit

protocol SignatureInspecting: Sendable {
    func inspect(app: URL) async throws -> [SignedBundle]
    func identities() async throws -> [SigningIdentity]
}

struct SigningService: SignatureInspecting {
    let runner: any CommandExecuting

    func decodeProfile(at url: URL) async throws -> ProvisioningProfile {
        let result = try await runner.run(ToolCommand(executable: "/usr/bin/security", arguments: ["cms", "-D", "-i", url.path], timeout: 30)).requireSuccess(category: .signing)
        return try Self.parseProfile(Data(result.stdout.utf8))
    }
    static func parseProfile(_ data: Data) throws -> ProvisioningProfile {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let uuid = plist["UUID"] as? String, let name = plist["Name"] as? String,
              let creation = plist["CreationDate"] as? Date, let expiration = plist["ExpirationDate"] as? Date,
              let teams = plist["TeamIdentifier"] as? [String], !teams.isEmpty,
              let entitlements = plist["Entitlements"] as? [String: Any],
              let appID = (entitlements["application-identifier"] ?? entitlements["com.apple.application-identifier"]) as? String else {
            throw FlowError(.signing, "Provisioning Profile 格式无效或缺少必需字段")
        }
        let certificates = (plist["DeveloperCertificates"] as? [Data] ?? []).compactMap { data -> ProfileCertificate? in
            guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else { return nil }
            return certificateInfo(certificate)
        }
        let values = entitlements.mapValues { value -> String in
            if let string = value as? String { return string }
            if let bool = value as? Bool { return bool ? "true" : "false" }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), let string = String(data: data, encoding: .utf8) { return string }
            return String(describing: value)
        }
        return ProvisioningProfile(uuid: uuid, name: name, teamIDs: teams, applicationIdentifier: appID, creationDate: creation, expirationDate: expiration, provisionedDevices: plist["ProvisionedDevices"] as? [String] ?? [], entitlements: values, certificates: certificates, provisionsAllDevices: plist["ProvisionsAllDevices"] as? Bool ?? false, isDevelopment: entitlements["get-task-allow"] as? Bool ?? false)
    }

    static func certificateInfo(_ certificate: SecCertificate) -> ProfileCertificate {
        let data = SecCertificateCopyData(certificate) as Data
        let fingerprint = Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
        let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter, kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any]
        let rawExpiration = (values?[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any])?[kSecPropertyKeyValue as String]
        let expiration = certificateExpiration(rawExpiration)
        let subject = (values?[kSecOIDX509V1SubjectName as String] as? [String: Any])?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        return ProfileCertificate(name: SecCertificateCopySubjectSummary(certificate) as String? ?? "未知证书", fingerprint: fingerprint, expiresAt: expiration, teamID: certificateTeamID(subject))
    }
    static func certificateExpiration(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        // SecCertificateCopyValues exposes this property as CFAbsoluteTime on macOS.
        if let seconds = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: seconds.doubleValue) }
        return nil
    }
    static func certificateTeamID(_ subject: [[String: Any]]) -> String? {
        // Team identifiers are the subject OU, not the UID printed in an identity's CN.
        guard let value = subject.first(where: { $0[kSecPropertyKeyLabel as String] as? String == kSecOIDOrganizationalUnitName as String })?[kSecPropertyKeyValue as String] as? String,
              value.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    func identities() async throws -> [SigningIdentity] {
        let result = try await runner.run(ToolCommand(executable: "/usr/bin/security", arguments: ["find-identity", "-v", "-p", "codesigning"], timeout: 30)).requireSuccess(category: .signing)
        let regex = try NSRegularExpression(pattern: #"\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)""#)
        var certificateQuery: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassCertificate, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll] as CFDictionary, &certificateQuery)
        let certificates = status == errSecSuccess ? (certificateQuery as? [SecCertificate] ?? []).map(Self.certificateInfo) : []
        return regex.matches(in: result.stdout, range: NSRange(result.stdout.startIndex..., in: result.stdout)).compactMap { match in
            guard let hashRange = Range(match.range(at: 1), in: result.stdout), let nameRange = Range(match.range(at: 2), in: result.stdout) else { return nil }
            let hash = String(result.stdout[hashRange]).uppercased(), name = String(result.stdout[nameRange])
            let certificate = certificates.first { $0.fingerprint == hash }
            return SigningIdentity(id: hash, name: LogRedactor.redact(name), teamID: certificate?.teamID, expiresAt: certificate?.expiresAt)
        }
    }

    func inspect(app: URL) async throws -> [SignedBundle] {
        let urls = try Self.bundleURLs(in: app)
        var result: [SignedBundle] = []
        for url in urls {
            try Task.checkCancellation()
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")) as? [String: Any], let bundleID = info["CFBundleIdentifier"] as? String else {
                throw FlowError(.signing, "App Bundle 缺少可读取的 Info.plist", technical: url.path)
            }
            let platformName = (info["CFBundleSupportedPlatforms"] as? [String])?.first ?? ""
            let platform: ApplePlatform = platformName.lowercased().contains("watch") || info["WKWatchKitApp"] as? Bool == true ? .watchOS : platformName.lowercased().contains("iphone") ? .iOS : .unknown
            let check = try await runner.run(ToolCommand(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", "--verbose=2", url.path], timeout: 120))
            let metadata = Self.signingMetadata(url)
            var valid = check.exitCode == 0
            var messages = [LogRedactor.redact(check.combined.trimmingCharacters(in: .whitespacesAndNewlines))]
            let profileURL = url.appendingPathComponent("embedded.mobileprovision")
            var profile: ProvisioningProfile?
            if FileManager.default.fileExists(atPath: profileURL.path) {
                do {
                    let decoded = try await decodeProfile(at: profileURL); profile = decoded
                    if !decoded.matches(bundleID: bundleID, teamID: metadata.teamID) { valid = false; messages.append("Profile 的 Team ID 或 Application Identifier 与签名不匹配。") }
                    if decoded.expirationDate <= Date() { valid = false; messages.append("Profile 已到期。") }
                    if let certificate = metadata.certificate {
                        if !decoded.certificates.contains(where: { $0.fingerprint == certificate.fingerprint }) { valid = false; messages.append("签名证书不在 Profile 的 DeveloperCertificates 中。") }
                        if let expiration = certificate.expiresAt, expiration <= Date() { valid = false; messages.append("签名证书已到期。") }
                    } else { valid = false; messages.append("无法读取签名证书。") }
                    let entitlementIssues = Self.entitlementValidationIssues(metadata.entitlements, profile: decoded)
                    if !entitlementIssues.isEmpty {
                        valid = false
                        messages.append("实际签名 Entitlements 与 Profile 授权不匹配。")
                        messages.append(contentsOf: entitlementIssues)
                    }
                } catch { valid = false; messages.append(FlowError.wrap(error).message) }
            } else { valid = false; messages.append("未找到 embedded.mobileprovision，不能用于开发设备部署。") }
            let parent = urls.filter { $0 != url && url.path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
            let parentID = parent.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String }
            result.append(SignedBundle(path: url.path, bundleID: bundleID, displayName: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent, version: info["CFBundleShortVersionString"] as? String ?? "", buildVersion: info["CFBundleVersion"] as? String ?? "", platform: platform, isExtension: url.pathExtension == "appex", parentBundleID: parentID, teamID: metadata.teamID, codeSignatureValid: valid, validationMessage: messages.joined(separator: "\n"), profile: profile, inspectedAt: Date()))
        }
        // A nested app must belong to the same development team as its container.
        for index in result.indices {
            if let parentID = result[index].parentBundleID, let parent = result.first(where: { $0.bundleID == parentID }), result[index].teamID != parent.teamID {
                result[index].codeSignatureValid = false; result[index].validationMessage += "\n嵌套 Bundle 与容器 Team ID 不一致。"
            }
        }
        return result
    }

    static func bundleURLs(in app: URL) throws -> [URL] {
        guard app.pathExtension == "app", FileManager.default.isReadableFile(atPath: app.path) else { throw FlowError(.signing, "App 产物不存在或不可读", technical: app.path) }
        var result = [app]
        if let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                if ["app", "appex"].contains(url.pathExtension.lowercased()) { result.append(url) }
            }
        }
        return result.sorted { $0.path.count < $1.path.count }
    }

    private static func signingMetadata(_ url: URL) -> (teamID: String?, certificate: ProfileCertificate?, entitlements: [String: Any]) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return (nil, nil, [:]) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess, let dictionary = info as? [String: Any] else { return (nil, nil, [:]) }
        let certificate = (dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first.map(certificateInfo)
        return (dictionary[kSecCodeInfoTeamIdentifier as String] as? String, certificate, dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:])
    }
    static func entitlementsAllowed(_ signed: [String: Any], profile: ProvisioningProfile) -> Bool {
        entitlementValidationIssues(signed, profile: profile).isEmpty
    }
    static func entitlementValidationIssues(_ signed: [String: Any], profile: ProvisioningProfile) -> [String] {
        var issues: [String] = []
        // Check the identity-bearing entitlements, including wildcard keychain groups.
        func matches(_ actual: String, _ pattern: String) -> Bool { pattern == actual || pattern.hasSuffix("*") && actual.hasPrefix(String(pattern.dropLast())) }
        func describe(_ value: Any) -> String {
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: value)
        }
        // Security on macOS may expose the macOS name for an iOS/watchOS App ID.
        // Both names must be checked against the decoded profile, never ignored.
        let appIDKeys = ["application-identifier", "com.apple.application-identifier"]
        let claimedIDs = appIDKeys.compactMap { signed[$0] as? String }
        if Set(claimedIDs).count > 1 { issues.append("application-identifier / com.apple.application-identifier：实际签名中的两个应用标识不一致。") }
        let allowedIDs = appIDKeys.compactMap { profile.entitlements[$0] }
        if Set(allowedIDs).count > 1 { issues.append("application-identifier / com.apple.application-identifier：Profile 中的两个应用标识不一致。") }
        for key in appIDKeys {
            guard let actual = signed[key] else { continue }
            guard let appID = actual as? String, matches(appID, profile.applicationIdentifier) else {
                issues.append("\(key)：实际值 \(describe(actual))；Profile 授权值 \(describe(profile.applicationIdentifier))。")
                continue
            }
        }
        if let team = signed["com.apple.developer.team-identifier"] as? String, !profile.teamIDs.contains(team) { issues.append("com.apple.developer.team-identifier：实际签名团队与 Profile 不匹配。") }
        if signed["get-task-allow"] as? Bool == true && !profile.isDevelopment { issues.append("get-task-allow：Profile 未授权调试。") }
        func permitted(_ actual: Any, allowed: Any) -> Bool {
            if let array = actual as? [Any], let options = allowed as? [Any] { return array.allSatisfy { item in options.contains { permitted(item, allowed: $0) } } }
            if let text = actual as? String, let pattern = allowed as? String { return matches(text, pattern) }
            if let boolean = actual as? Bool, let allowedBoolean = allowed as? Bool { return boolean == allowedBoolean || !boolean }
            return String(describing: actual) == String(describing: allowed)
        }
        for key in signed.keys.sorted() {
            if appIDKeys.contains(key) { continue } // Already validated, including conflicting aliases.
            let actual = signed[key]!
            guard let representation = profile.entitlements[key] else {
                if key == "com.apple.developer.team-identifier", let team = actual as? String, profile.teamIDs.contains(team) { continue }
                issues.append("\(key)：Profile 未授权此权限；实际值 \(describe(actual))。")
                continue
            }
            let allowed: Any
            if let decoded = try? JSONSerialization.jsonObject(with: Data(representation.utf8), options: [.fragmentsAllowed]) { allowed = decoded }
            else { allowed = representation }
            if !permitted(actual, allowed: allowed) { issues.append("\(key)：实际值 \(describe(actual))；Profile 授权值 \(describe(allowed))。") }
        }
        return issues
    }
}

enum RenewalVerifier {
    static func baselineKey(_ signatures: [SignedBundle]) -> String {
        signatures.map { "\($0.bundleID)|\($0.teamID ?? "")|\($0.profile?.uuid ?? "")|\($0.profile?.expirationDate.timeIntervalSince1970 ?? 0)" }.sorted().joined(separator: "\n")
    }
    static func assess(old: [SignedBundle], new: [SignedBundle]) -> RenewalAssessment {
        guard !new.isEmpty, new.allSatisfy({ $0.codeSignatureValid && $0.profile != nil && $0.profile!.expirationDate > Date() }) else { return .invalid }
        if old.isEmpty { return .initialSignature }
        // Every old signed component must still exist. No disappearing Watch/extension.
        guard old.allSatisfy({ previous in new.contains { $0.bundleID == previous.bundleID } }) else { return .invalid }
        for bundle in new {
            guard let previous = old.first(where: { $0.bundleID == bundle.bundleID }), let before = previous.profile, let after = bundle.profile else { return .initialSignature }
            guard previous.teamID == bundle.teamID, after.creationDate >= before.creationDate else { return .invalid }
            // An unchanged component inside the renewal window blocks an overall renewal.
            guard after.expirationDate > before.expirationDate else { return .unchanged }
        }
        return .advanced
    }
}

enum SchedulingPolicy {
    static func canCreateAutomaticRenewal(project: ManagedProject, tasks: [FlowTask]) -> Bool {
        if tasks.contains(where: { $0.projectID == project.id && !$0.phase.isTerminal }) { return false }
        guard let previous = tasks.first(where: { $0.projectID == project.id && $0.automatic && $0.kind == .renew && $0.phase.isTerminal && $0.phase != .completed }) else { return true }
        let known = previous.newSignatures.isEmpty ? previous.oldSignatures : previous.newSignatures
        return RenewalVerifier.baselineKey(known) != RenewalVerifier.baselineKey(project.signatures)
    }
}
