import XCTest
import AppKit
@testable import SignFlowCore

final class ProjectIconTests: XCTestCase {
    func testPrimaryIconMetadataAndFilenameSafety() {
        let plist: [String: Any] = ["CFBundleIcons": ["CFBundlePrimaryIcon": [
            "CFBundleIconName": "Artwork", "CFBundleIconFiles": ["Artwork60x60", "../Other.png"]
        ]]]
        let info = ProjectIconResolver.primaryIconInfo(plist)
        XCTAssertEqual(info.name, "Artwork")
        XCTAssertEqual(info.files.first, "Artwork60x60")
        XCTAssertFalse(info.files.contains("../Other"))
        XCTAssertTrue(info.files.contains("Artwork"))
    }

    func testCatalogSelectionPrefersMainTargetAndAvoidsWatch() {
        let root = URL(fileURLWithPath: "/tmp/Reminder")
        let phone = root.appendingPathComponent("Reminder/Assets.xcassets/AppIcon.appiconset")
        let watch = root.appendingPathComponent("Reminder Watch App/Assets.xcassets/AppIcon.appiconset")
        let nestedWatch = root.appendingPathComponent("Reminder/Reminder Watch App/Assets.xcassets/Reminder.appiconset")
        let chosen = ProjectIconResolver.preferredCatalogs([watch, phone, nestedWatch], root: root, targetName: "Reminder",
                                                             otherTargetNames: ["Reminder Watch App"], iconName: "Reminder")
        XCTAssertEqual(chosen, [phone])
        XCTAssertEqual(ProjectIconResolver.preferredCatalogs([watch], root: root, targetName: "Reminder",
                                                              otherTargetNames: ["Reminder Watch App"], iconName: "AppIcon"), [])
    }

    func testAmbiguousCatalogsDoNotGuess() {
        let root = URL(fileURLWithPath: "/tmp/Workspace")
        let first = root.appendingPathComponent("One/Assets.xcassets/AppIcon.appiconset")
        let second = root.appendingPathComponent("Two/Assets.xcassets/AppIcon.appiconset")
        XCTAssertEqual(ProjectIconResolver.preferredCatalogs([first, second], root: root, targetName: "Missing",
                                                              otherTargetNames: [], iconName: "AppIcon"), [])
    }

    func testAppearanceAndPlatformVariants() {
        let manifest: [String: Any] = ["images": [
            ["filename": "light.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
            ["filename": "dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024",
             "appearances": [["appearance": "luminosity", "value": "dark"]]],
            ["filename": "watch.png", "idiom": "watch", "platform": "watchos"],
            ["filename": "../escape.png", "idiom": "universal"],
            ["filename": "tinted.png", "idiom": "universal", "appearances": [["appearance": "luminosity", "value": "tinted"]]]
        ]]
        XCTAssertEqual(ProjectIconResolver.sourceImageNames(manifest, prefersDark: false, platform: .iOS), ["light.png", "dark.png"])
        XCTAssertEqual(ProjectIconResolver.sourceImageNames(manifest, prefersDark: true, platform: .iOS), ["dark.png", "light.png"])
        XCTAssertEqual(ProjectIconResolver.sourceImageNames(manifest, prefersDark: false, platform: .watchOS), ["watch.png"])
    }

    func testApplicationIconIsPreferredAndInvalidOverrideFallsBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SignFlowIconTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Phone.app")
        let catalog = root.appendingPathComponent("Phone/Assets.xcassets/AppIcon.appiconset")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon", "CFBundleIconFiles": ["AppIcon60x60"]]]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let appIcon = app.appendingPathComponent("AppIcon60x60@2x.png")
        let sourceIcon = catalog.appendingPathComponent("source.png")
        let customIcon = root.appendingPathComponent("custom.png")
        try png(red: 255, green: 0, blue: 0).write(to: appIcon)
        try png(red: 0, green: 255, blue: 0).write(to: sourceIcon)
        try Data(#"{"images":[{"filename":"source.png","idiom":"universal"}]}"#.utf8).write(to: catalog.appendingPathComponent("Contents.json"))
        var request = ProjectIconRequest(projectPath: root.appendingPathComponent("Phone.xcodeproj").path, targetName: "Phone",
                                         platform: .iOS, artifactPath: app.path, customIconPath: root.appendingPathComponent("missing.png").path, prefersDark: false)
        let expectedApp = try XCTUnwrap(NSImage(contentsOf: appIcon)?.tiffRepresentation)
        let expectedSource = try XCTUnwrap(NSImage(contentsOf: sourceIcon)?.tiffRepresentation)
        XCTAssertEqual(ProjectIconResolver.resolve(request)?.tiffRepresentation, expectedApp)
        try Data("invalid image".utf8).write(to: appIcon)
        XCTAssertEqual(ProjectIconResolver.resolve(request)?.tiffRepresentation, expectedSource)
        request.artifactPath = nil
        XCTAssertEqual(ProjectIconResolver.resolve(request)?.tiffRepresentation, expectedSource)
        try png(red: 0, green: 0, blue: 255).write(to: customIcon)
        request.customIconPath = customIcon.path
        XCTAssertEqual(ProjectIconResolver.resolve(request)?.tiffRepresentation, try XCTUnwrap(NSImage(contentsOf: customIcon)?.tiffRepresentation))
        request.customIconPath = nil
        request.projectPath = root.appendingPathComponent("Missing/Phone.xcodeproj").path
        XCTAssertNil(ProjectIconResolver.resolve(request))
    }

    private func png(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<4 { for x in 0..<4 {
            let offset = y * bitmap.bytesPerRow + x * 4
            bytes[offset] = red; bytes[offset + 1] = green; bytes[offset + 2] = blue; bytes[offset + 3] = 255
        } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
