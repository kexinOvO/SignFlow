import Foundation
import CryptoKit

// Reads OpenStep project files and workspace XML without rewriting either format.
struct XcodeProjectGraph: Sendable {
    struct Reference: Sendable, Hashable {
        var projectURL: URL
        var targetID: String
        var name: String
        var productType: String
    }
    private struct Container {
        var url: URL
        var objects: [String: [String: Any]]
    }
    static func embeddedTargets(container: URL, mainTargetName: String) throws -> [Reference] {
        let urls = container.pathExtension == "xcodeproj" ? [container] : try workspaceProjects(container)
        var containers: [Container] = []
        for url in urls {
            let data = try Data(contentsOf: url.appendingPathComponent("project.pbxproj"))
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let objects = plist["objects"] as? [String: [String: Any]] else { continue }
            containers.append(Container(url: url, objects: objects))
        }
        guard let main = containers.first(where: { $0.objects.values.contains { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == mainTargetName } }),
              let pair = main.objects.first(where: { $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["name"] as? String == mainTargetName }) else { return [] }
        var queue = [(main, pair.key)], seen: Set<String> = [], references: [Reference] = []
        while !queue.isEmpty {
            let (owner, targetID) = queue.removeFirst()
            guard seen.insert(owner.url.path + targetID).inserted, let target = owner.objects[targetID] else { continue }
            let phases = target["buildPhases"] as? [String] ?? []
            for phaseID in phases {
                guard let phase = owner.objects[phaseID], phase["isa"] as? String == "PBXCopyFilesBuildPhase" else { continue }
                for buildFileID in phase["files"] as? [String] ?? [] {
                    guard let buildFile = owner.objects[buildFileID], let fileID = buildFile["fileRef"] as? String else { continue }
                    var embedded: (Container, String)?
                    if let local = owner.objects.first(where: { $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["productReference"] as? String == fileID }) { embedded = (owner, local.key) }
                    else if let proxy = owner.objects[fileID], let remoteRef = proxy["remoteRef"] as? String, let remoteID = owner.objects[remoteRef]?["remoteGlobalIDString"] as? String {
                        if let remote = containers.first(where: { $0.objects[remoteID]?["isa"] as? String == "PBXNativeTarget" }) { embedded = (remote, remoteID) }
                        else if let portalID = owner.objects[remoteRef]?["containerPortal"] as? String, let relative = owner.objects[portalID]?["path"] as? String {
                            let projectURL = owner.url.deletingLastPathComponent().appendingPathComponent(relative).standardizedFileURL
                            if let data = try? Data(contentsOf: projectURL.appendingPathComponent("project.pbxproj")), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let objects = plist["objects"] as? [String: [String: Any]], objects[remoteID] != nil { embedded = (Container(url: projectURL, objects: objects), remoteID) }
                        }
                    }
                    if let (source, id) = embedded, let data = source.objects[id], let name = data["name"] as? String {
                        let reference = Reference(projectURL: source.url, targetID: id, name: name, productType: data["productType"] as? String ?? "")
                        if !references.contains(reference) { references.append(reference); queue.append((source, id)) }
                    }
                }
            }
        }
        return references
    }
    static func workspaceProjects(_ workspace: URL) throws -> [URL] {
        let parser = XMLParser(data: try Data(contentsOf: workspace.appendingPathComponent("contents.xcworkspacedata")))
        let delegate = WorkspaceReader(root: workspace.deletingLastPathComponent())
        parser.delegate = delegate
        guard parser.parse() else { throw FlowError(.project, "Workspace 文件格式无效", technical: parser.parserError?.localizedDescription ?? "") }
        return Array(Set(delegate.projects)).sorted { $0.path < $1.path }
    }
    static func cacheKey(_ url: URL) -> String { SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }
}

private final class WorkspaceReader: NSObject, XMLParserDelegate {
    let root: URL
    var groups: [URL] = []
    var projects: [URL] = []
    init(root: URL) { self.root = root }
    func resolved(_ location: String) -> URL {
        let parts = location.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let type = parts.count == 2 ? String(parts[0]) : "group"
        let path = parts.count == 2 ? String(parts[1]) : location
        if type == "absolute" { return URL(fileURLWithPath: path) }
        return (type == "container" ? root : groups.last ?? root).appendingPathComponent(path).standardizedFileURL
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "Group" { groups.append(resolved(attributeDict["location"] ?? "group:")) }
        if elementName == "FileRef", let location = attributeDict["location"] {
            let url = resolved(location)
            if url.pathExtension == "xcodeproj" { projects.append(url) }
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if elementName == "Group", !groups.isEmpty { groups.removeLast() } }
}
