import XCTest
@testable import SignFlowCore

final class ProjectTests: XCTestCase {
    func testSchemeParsingAndInvalidSchema() throws {
        XCTAssertEqual(try ProjectService.parseSchemes(#"{"workspace":{"schemes":["Watch App","iOS","iOS"]}}"#), ["Watch App", "iOS"])
        XCTAssertThrowsError(try ProjectService.parseSchemes("{}"))
        XCTAssertThrowsError(try ProjectService.kind(for: URL(fileURLWithPath: "/tmp/no.swift")))
    }
    func testTargetClassification() throws {
        let json = #"[{"target":"Phone","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.application","PLATFORM_NAME":"iphoneos","PRODUCT_BUNDLE_IDENTIFIER":"test.phone","CODE_SIGN_STYLE":"Automatic"}},{"target":"Watch","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.application","PLATFORM_NAME":"watchos","PRODUCT_BUNDLE_IDENTIFIER":"test.phone.watch"}},{"target":"Widget","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.app-extension","PLATFORM_NAME":"iphoneos"}}]"#
        let targets = try ProjectService.parseBuildSettings(json)
        XCTAssertEqual(targets.map(\.kind), [.application, .watchApplication, .appExtension])
        XCTAssertEqual(targets.map(\.platform), [.iOS, .watchOS, .iOS])
        XCTAssertTrue(targets[0].automaticSigning)
    }
    func testPathWithUnicodeSpacesAndInvalidProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SignFlowTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("中文 App.xcodeproj"), withIntermediateDirectories: true)
        XCTAssertEqual(try ProjectService.candidates(at: root).first?.lastPathComponent, "中文 App.xcodeproj")
        XCTAssertThrowsError(try ProjectService.candidates(at: root.appendingPathComponent("missing")))
    }
    func testRedaction() {
        let result = LogRedactor.redact("Authorization: Bearer private123 password=secret user@example.com")
        XCTAssertFalse(result.contains("private123")); XCTAssertFalse(result.contains("secret")); XCTAssertFalse(result.contains("user@example.com"))
    }
    func testEmbedGraphRecognizesOnlyLinkedTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SignFlowTests-\(UUID()).xcodeproj")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plist: [String: Any] = ["objects": [
            "main": ["isa": "PBXNativeTarget", "name": "Phone", "productReference": "phoneProduct", "buildPhases": ["embed"]],
            "watch": ["isa": "PBXNativeTarget", "name": "Linked Watch", "productReference": "watchProduct", "productType": "com.apple.product-type.application", "buildPhases": []],
            "other": ["isa": "PBXNativeTarget", "name": "Unrelated Watch", "productReference": "otherProduct", "buildPhases": []],
            "embed": ["isa": "PBXCopyFilesBuildPhase", "files": ["file"]],
            "file": ["isa": "PBXBuildFile", "fileRef": "watchProduct"]
        ]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: root.appendingPathComponent("project.pbxproj"))
        let references = try XcodeProjectGraph.embeddedTargets(container: root, mainTargetName: "Phone")
        XCTAssertEqual(references.map(\.name), ["Linked Watch"])
    }
    func testWorkspaceRelativeGroups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SignFlowTests-\(UUID()).xcworkspace")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let xml = #"<Workspace><Group location="group:Apps"><FileRef location="group:Phone.xcodeproj"/></Group></Workspace>"#
        try Data(xml.utf8).write(to: root.appendingPathComponent("contents.xcworkspacedata"))
        XCTAssertEqual(try XcodeProjectGraph.workspaceProjects(root).first?.path, root.deletingLastPathComponent().appendingPathComponent("Apps/Phone.xcodeproj").path)
    }
    func testStructuredCredentialsAreRedacted() {
        let value = LogRedactor.redact(#"{"token":"very private value","password":"do not print"} https://account:credential@example.org/repo --token secretvalue"#)
        for secret in ["very private value", "do not print", "credential", "secretvalue"] { XCTAssertFalse(value.contains(secret)) }
    }
}
