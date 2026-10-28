import XCTest
@testable import SignFlowCore

final class SigningTests: XCTestCase {
    func testValidExpiringExpiredProfile() {
        let now = Date()
        XCTAssertEqual(profile(expires: now.addingTimeInterval(6 * 86400)).health(at: now), .valid)
        XCTAssertEqual(profile(expires: now.addingTimeInterval(3600)).health(at: now), .expiring)
        XCTAssertEqual(profile(expires: now.addingTimeInterval(-1)).health(at: now), .expired)
    }
    func testSignatureExpiryUsesEarliestExpiringProfilesOwnLifetime() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let phone = signedBundle(expires: now.addingTimeInterval(6 * 86400), creation: now.addingTimeInterval(-20 * 86400))
        let watch = signedBundle(platform: .watchOS, expires: now.addingTimeInterval(2 * 86400), creation: now.addingTimeInterval(-6 * 86400))
        let summary = try XCTUnwrap(SignatureExpirySummary(signatures: [phone, watch], at: now))
        XCTAssertEqual(summary.expirationDate, watch.profile?.expirationDate)
        XCTAssertEqual(summary.remainingFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(summary.remainingDays, 2)
        XCTAssertEqual(summary.health, .expiring)
    }
    func testSignatureExpiryHandlesMissingExpiredFutureAndInvalidSignatures() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertNil(SignatureExpirySummary(signatures: [], at: now))
        var missingProfile = signedBundle(); missingProfile.profile = nil
        XCTAssertNil(SignatureExpirySummary(signatures: [missingProfile], at: now))

        let expired = try XCTUnwrap(SignatureExpirySummary(signatures: [signedBundle(expires: now.addingTimeInterval(-1), creation: now.addingTimeInterval(-86400))], at: now))
        XCTAssertEqual(expired.remainingFraction, 0)
        XCTAssertNil(expired.remainingDays)
        XCTAssertEqual(expired.health, .expired)

        let future = try XCTUnwrap(SignatureExpirySummary(signatures: [signedBundle(expires: now.addingTimeInterval(2 * 86400), creation: now.addingTimeInterval(86400))], at: now))
        XCTAssertEqual(future.remainingFraction, 1)
        XCTAssertEqual(future.remainingDays, 2)

        let invalid = try XCTUnwrap(SignatureExpirySummary(signatures: [signedBundle(expires: now.addingTimeInterval(1), creation: now.addingTimeInterval(-86400), valid: false)], at: now))
        XCTAssertEqual(invalid.remainingDays, 1)
        XCTAssertEqual(invalid.health, .invalid)
    }
    func testProfileParsing() throws {
        let now = Date()
        let dictionary: [String: Any] = ["UUID": "UUID", "Name": "Test", "TeamIdentifier": ["TEAM123456"], "CreationDate": now, "ExpirationDate": now.addingTimeInterval(7 * 86400), "ProvisionedDevices": ["UDID"], "Entitlements": ["application-identifier": "TEAM123456.test.app", "get-task-allow": true, "keychain-access-groups": ["TEAM123456.*"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        let value = try SigningService.parseProfile(data)
        XCTAssertEqual(value.uuid, "UUID"); XCTAssertTrue(value.isDevelopment); XCTAssertEqual(value.provisionedDevices, ["UDID"])
        XCTAssertTrue(value.entitlements["keychain-access-groups"]!.contains("TEAM123456.*"))
    }
    func testInvalidProfile() { XCTAssertThrowsError(try SigningService.parseProfile(Data("bad".utf8))); XCTAssertThrowsError(try SigningService.parseProfile(Data("<?xml version=\"1.0\"?><plist><dict/></plist>".utf8))) }
    func testProfileTeamBundleAndDeviceMatching() {
        var p = profile()
        XCTAssertTrue(p.matches(bundleID: "test.app", teamID: "TEAM123456"))
        XCTAssertFalse(p.matches(bundleID: "test.other", teamID: "TEAM123456"))
        XCTAssertFalse(p.matches(bundleID: "test.app", teamID: "WRONG"))
        p.applicationIdentifier = "TEAM123456.test.*"
        XCTAssertTrue(p.matches(bundleID: "test.app.watch", teamID: "TEAM123456"))
        XCTAssertFalse(p.matches(bundleID: "testing.app", teamID: nil))
        XCTAssertTrue(p.supports(deviceUDID: "phoneUDID")); XCTAssertFalse(p.supports(deviceUDID: "unknown"))
    }
    func testBuildSuccessWithoutUpdatedProfileIsNotRenewal() {
        let bundle = signedBundle()
        XCTAssertEqual(RenewalVerifier.assess(old: [bundle], new: [bundle]), .unchanged)
    }
    func testNestedExpiryDoesNotHideWatchFailure() {
        let old = [signedBundle(expires: Date().addingTimeInterval(3600)), signedBundle(platform: .watchOS, expires: Date().addingTimeInterval(3600))]
        let new = [signedBundle(), old[1]]
        XCTAssertEqual(RenewalVerifier.assess(old: old, new: new), .unchanged)
        XCTAssertEqual(RenewalVerifier.assess(old: old, new: [signedBundle()]), .invalid)
    }
    func testInitialBaselineIsNotRenewal() { XCTAssertEqual(RenewalVerifier.assess(old: [], new: [signedBundle()]), .initialSignature) }
    func testInvalidSignatureNeverRenewed() { XCTAssertEqual(RenewalVerifier.assess(old: [], new: [signedBundle(valid: false)]), .invalid) }
    func testActualEntitlementsIdentity() {
        XCTAssertFalse(SigningService.entitlementsAllowed(["application-identifier": "OTHER.test.app"], profile: profile()))
        XCTAssertFalse(SigningService.entitlementsAllowed(["com.apple.developer.team-identifier": "OTHER"], profile: profile()))
    }
    func testSecurityApplicationIdentifierAliasMatchesIOSAndWatchProfiles() throws {
        for bundleID in ["test.app", "test.app.watchkitapp"] {
            let appID = "TEAM123456." + bundleID
            let dictionary: [String: Any] = [
                "UUID": "UUID", "Name": "Development", "TeamIdentifier": ["TEAM123456"],
                "CreationDate": Date(), "ExpirationDate": Date().addingTimeInterval(86400),
                "Entitlements": ["application-identifier": appID, "com.apple.developer.team-identifier": "TEAM123456", "get-task-allow": true, "keychain-access-groups": ["TEAM123456.*"]]
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            let value = try SigningService.parseProfile(data)
            // macOS Security reports this spelling when inspecting these iOS/watchOS signatures.
            let signed: [String: Any] = ["com.apple.application-identifier": appID, "com.apple.developer.team-identifier": "TEAM123456", "get-task-allow": true]
            XCTAssertTrue(SigningService.entitlementsAllowed(signed, profile: value), bundleID)
            XCTAssertTrue(SigningService.entitlementValidationIssues(signed, profile: value).isEmpty)
        }
    }
    func testBothApplicationIdentifierNamesMustAgree() {
        XCTAssertTrue(SigningService.entitlementsAllowed(["application-identifier": "TEAM123456.test.app", "com.apple.application-identifier": "TEAM123456.test.app"], profile: profile()))
        var wildcard = profile(); wildcard.applicationIdentifier = "TEAM123456.test.*"; wildcard.entitlements["application-identifier"] = wildcard.applicationIdentifier
        XCTAssertFalse(SigningService.entitlementsAllowed(["application-identifier": "TEAM123456.test.app", "com.apple.application-identifier": "TEAM123456.test.other"], profile: wildcard))
        XCTAssertFalse(SigningService.entitlementsAllowed(["com.apple.application-identifier": "OTHER.test.app"], profile: wildcard))
        XCTAssertFalse(SigningService.entitlementsAllowed(["com.apple.application-identifier": true], profile: wildcard))
        XCTAssertTrue(SigningService.entitlementsAllowed(["com.apple.application-identifier": "TEAM123456.test.app"], profile: wildcard))
        var conflicting = profile(); conflicting.entitlements["com.apple.application-identifier"] = "TEAM123456.test.other"
        XCTAssertFalse(SigningService.entitlementsAllowed(["application-identifier": "TEAM123456.test.app"], profile: conflicting))
    }
    func testApplicationIdentifierAliasWorksWithMacProfile() throws {
        let dictionary: [String: Any] = [
            "UUID": "UUID", "Name": "Development", "TeamIdentifier": ["TEAM123456"],
            "CreationDate": Date(), "ExpirationDate": Date().addingTimeInterval(86400),
            "Entitlements": ["com.apple.application-identifier": "TEAM123456.test.app", "get-task-allow": true]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        let value = try SigningService.parseProfile(data)
        XCTAssertTrue(SigningService.entitlementsAllowed(["application-identifier": "TEAM123456.test.app"], profile: value))
        XCTAssertFalse(SigningService.entitlementsAllowed(["application-identifier": "TEAM123456.test.other"], profile: value))
    }
    func testApplicationIdentifierAliasKeepsCapabilityAndTeamChecks() {
        let appID = ["com.apple.application-identifier": "TEAM123456.test.app"]
        XCTAssertFalse(SigningService.entitlementsAllowed(appID.merging(["aps-environment": "production"]) { $1 }, profile: profile()))
        XCTAssertFalse(SigningService.entitlementsAllowed(appID.merging(["com.apple.developer.team-identifier": "OTHER"]) { $1 }, profile: profile()))
    }
    func testEntitlementDiagnosticsIncludeSpecificKeysAndValues() {
        var value = profile(); value.entitlements["aps-environment"] = "development"
        let issues = SigningService.entitlementValidationIssues(["aps-environment": "production", "com.apple.developer.healthkit": true], profile: value)
        XCTAssertEqual(issues.count, 2)
        XCTAssertTrue(issues[0].contains("aps-environment")); XCTAssertTrue(issues[0].contains("production")); XCTAssertTrue(issues[0].contains("development"))
        XCTAssertTrue(issues[1].contains("com.apple.developer.healthkit")); XCTAssertTrue(issues[1].contains("Profile 未授权"))
    }
    func testKeychainAndCapabilityEntitlementsMustBeAuthorized() {
        var value = profile(); value.entitlements["keychain-access-groups"] = #"["TEAM123456.*"]"#
        XCTAssertTrue(SigningService.entitlementsAllowed(["keychain-access-groups": ["TEAM123456.test.app"]], profile: value))
        XCTAssertFalse(SigningService.entitlementsAllowed(["keychain-access-groups": ["OTHER.test.app"]], profile: value))
        XCTAssertFalse(SigningService.entitlementsAllowed(["aps-environment": "production"], profile: value))
    }
    func testAnyUnextendedComponentPreventsRenewalClaim() {
        let phone = signedBundle(expires: Date().addingTimeInterval(6 * 86400))
        let watch = signedBundle(platform: .watchOS, expires: Date().addingTimeInterval(5 * 86400))
        XCTAssertEqual(RenewalVerifier.assess(old: [phone, watch], new: [signedBundle(), watch]), .unchanged)
    }
    func testCertificateExpirationUsesCoreFoundationReferenceDate() {
        XCTAssertEqual(SigningService.certificateExpiration(NSNumber(value: 86400)), Date(timeIntervalSinceReferenceDate: 86400))
        let date = Date(); XCTAssertEqual(SigningService.certificateExpiration(date), date)
        XCTAssertNil(SigningService.certificateExpiration("unrecognized"))
    }
    func testTeamComesFromSubjectOUInsteadOfCertificateUID() {
        let subject: [[String: Any]] = [["label": "0.9.2342.19200300.100.1.1", "value": "PERSON1234"], ["label": "2.5.4.11", "value": "TEAM123456"]]
        XCTAssertEqual(SigningService.certificateTeamID(subject), "TEAM123456")
        XCTAssertNil(SigningService.certificateTeamID([["label": "2.5.4.3", "value": "Apple Development: User (PERSON1234)"]]))
    }
    func testNestedBundlesLocatedWithoutFixedWatchPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SignFlowTests-\(UUID()).app")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Nested/Watch.app/PlugIns/Extension.appex"), withIntermediateDirectories: true)
        XCTAssertEqual(try SigningService.bundleURLs(in: root).count, 3)
    }
}
