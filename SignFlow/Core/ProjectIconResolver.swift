import AppKit
import Foundation

struct ProjectIconRequest: Equatable, Sendable {
    var projectPath: String
    var targetName: String?
    var otherTargetNames: [String] = []
    var platform: ApplePlatform? = nil
    var artifactPath: String?
    var customIconPath: String?
    var prefersDark: Bool
}

/// Resolves actual artwork rather than the Finder icon for an iOS app, which
/// can include a macOS compatibility badge. All project and app reads are read-only.
enum ProjectIconResolver {
    static func resolve(_ request: ProjectIconRequest) -> NSImage? {
        if let path = request.customIconPath, let image = image(at: URL(fileURLWithPath: path)) {
            return image
        }

        var iconName: String?
        if let path = request.artifactPath {
            let app = URL(fileURLWithPath: path, isDirectory: true)
            let infoURL = app.appendingPathComponent("Info.plist")
            if let data = try? Data(contentsOf: infoURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                let info = primaryIconInfo(plist)
                iconName = info.name
                for url in applicationIconFiles(in: app, named: info.files) {
                    if let image = image(at: url) { return image }
                }
                // Some asset catalogs are readable through AppKit. iOS-only
                // catalog renditions can be unavailable here, so keep fallbacks.
                if let name = info.name, let bundle = Bundle(url: app),
                   let image = bundle.image(forResource: NSImage.Name(name)), image.isValid {
                    return image
                }
            }
        }

        let root = URL(fileURLWithPath: request.projectPath).deletingLastPathComponent()
        let catalogs = sourceCatalogs(in: root)
        for catalog in preferredCatalogs(catalogs, root: root, targetName: request.targetName,
                                         otherTargetNames: request.otherTargetNames, iconName: iconName) {
            let manifest = catalog.appendingPathComponent("Contents.json")
            guard let data = try? Data(contentsOf: manifest),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for filename in sourceImageNames(object, prefersDark: request.prefersDark, platform: request.platform) {
                if let image = image(at: catalog.appendingPathComponent(filename)) { return image }
            }
        }
        return nil
    }

    static func image(at url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.isValid,
              image.size.width > 0, image.size.height > 0,
              image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else { return nil }
        return image
    }

    struct PrimaryIconInfo {
        var name: String?
        var files: [String]
    }

    static func primaryIconInfo(_ plist: [String: Any]) -> PrimaryIconInfo {
        let icons = plist["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let name = (primary?["CFBundleIconName"] as? String) ?? (plist["CFBundleIconName"] as? String)
        var files = (primary?["CFBundleIconFiles"] as? [String]) ?? []
        files += (plist["CFBundleIconFiles"] as? [String]) ?? []
        if let file = plist["CFBundleIconFile"] as? String { files.append(file) }
        // Common legacy names are only fallbacks; avoid choosing arbitrary PNGs.
        if let name { files.append(name) }
        files += ["AppIcon60x60", "AppIcon", "Icon60", "Icon"]
        var seen = Set<String>()
        files = files.compactMap { value in
            let path = value as NSString
            guard path.lastPathComponent == value, !value.isEmpty else { return nil }
            let base = path.pathExtension.isEmpty ? value : path.deletingPathExtension
            return seen.insert(base.lowercased()).inserted ? base : nil
        }
        return PrimaryIconInfo(name: name, files: files)
    }

    static func applicationIconFiles(in app: URL, named names: [String]) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil) else { return [] }
        let extensions = Set(["png", "jpg", "jpeg", "tiff", "heic"])
        var result: [URL] = []
        for name in names {
            let prefix = name.lowercased()
            let matches = entries.filter { url in
                guard extensions.contains(url.pathExtension.lowercased()) else { return false }
                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                return stem == prefix || stem.hasPrefix(prefix + "@") || stem.hasPrefix(prefix + "~")
            }.sorted { left, right in
                func scale(_ url: URL) -> Int {
                    let filename = url.lastPathComponent.lowercased()
                    return filename.contains("@3x") ? 3 : filename.contains("@2x") ? 2 : 1
                }
                let leftScale = scale(left), rightScale = scale(right)
                return leftScale == rightScale ? left.lastPathComponent < right.lastPathComponent : leftScale > rightScale
            }
            for url in matches where !result.contains(url) { result.append(url) }
        }
        return result
    }

    static func sourceCatalogs(in root: URL) -> [URL] {
        let skip = Set(["build", "deriveddata", "node_modules", "pods", "carthage", ".build"])
        let packageExtensions = Set(["xcodeproj", "xcworkspace", "app", "appex", "framework", "icon"])
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 20_000 { break }
            if enumerator.level > 7 { enumerator.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "appiconset" { result.append(url); enumerator.skipDescendants() }
            else if skip.contains(url.lastPathComponent.lowercased()) || packageExtensions.contains(ext) { enumerator.skipDescendants() }
        }
        return result
    }

    static func preferredCatalogs(_ catalogs: [URL], root: URL, targetName: String?,
                                  otherTargetNames: [String], iconName: String?) -> [URL] {
        func belongs(_ url: URL, to name: String?) -> Bool {
            guard let name, !name.isEmpty else { return false }
            let relative = url.pathComponents.dropFirst(root.pathComponents.count)
            return relative.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        let eligible = catalogs.filter { url in !otherTargetNames.contains { belongs(url, to: $0) } }
        let targetCatalogs = eligible.filter { belongs($0, to: targetName) }
        func matches(_ url: URL, _ name: String?) -> Bool {
            guard let name, !name.isEmpty else { return false }
            return url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }
        // Only choose unambiguous candidates; a Watch or extension icon must
        // not be mistaken for the main application icon.
        var result: [URL] = []
        func appendIfUnique(_ values: [URL]) {
            if values.count == 1, let url = values.first, !result.contains(url) { result.append(url) }
        }
        appendIfUnique(targetCatalogs.filter { matches($0, iconName) })
        appendIfUnique(targetCatalogs.filter { matches($0, "AppIcon") })
        appendIfUnique(eligible.filter { matches($0, iconName) })
        if eligible.count == 1 { appendIfUnique(eligible.filter { matches($0, "AppIcon") }) }
        return result
    }

    static func sourceImageNames(_ manifest: [String: Any], prefersDark: Bool, platform: ApplePlatform?) -> [String] {
        guard let images = manifest["images"] as? [[String: Any]] else { return [] }
        let acceptedIdioms: Set<String> = platform == .watchOS ? ["universal", "watch"] : ["universal", "iphone", "ipad"]
        let preferredPlatform = platform == .watchOS ? "watchos" : "ios"
        let candidates: [(String, Int, Double)] = images.compactMap { entry in
            guard let filename = entry["filename"] as? String, !filename.isEmpty,
                  (filename as NSString).lastPathComponent == filename else { return nil }
            if let idiom = entry["idiom"] as? String, !acceptedIdioms.contains(idiom.lowercased()) { return nil }
            if let specified = entry["platform"] as? String, specified.lowercased() != preferredPlatform { return nil }
            let appearances = (entry["appearances"] as? [[String: String]]) ?? []
            guard appearances.allSatisfy({ $0["appearance"] == "luminosity" && $0["value"] == "dark" }) else { return nil }
            let dark = !appearances.isEmpty
            let appearanceScore = dark == prefersDark ? 2 : 1
            let size = (entry["size"] as? String)?.split(separator: "x").first.flatMap { Double($0) } ?? 0
            let scale = Double((entry["scale"] as? String)?.replacingOccurrences(of: "x", with: "") ?? "1") ?? 1
            return (filename, appearanceScore, size * scale)
        }
        var seen = Set<String>()
        return candidates.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return $0.0 < $1.0
        }.compactMap { seen.insert($0.0).inserted ? $0.0 : nil }
    }
}
