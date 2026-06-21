import Foundation
import Observation
import AppKit

@Observable
@MainActor
final class YeetViewerStore {
    static let recentsKey = "gmvibes.yeet.recents.v1"
    static let recentsLimit = 10

    private(set) var rescanToken: Int = 0
    var recents: [URL] {
        didSet { persistRecents() }
    }

    init() {
        self.recents = Self.loadRecents()
    }

    func refresh() {
        rescanToken &+= 1
    }

    // MARK: Quick Load

    func quickLoad(gmcc: GMCCEnvironment) -> [URL] {
        _ = rescanToken
        guard let root = gmcc[runtime: .pluginRoot], !root.isEmpty else { return [] }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)

        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if Self.isYeetYAML(url) { found.append(url) }
        }
        return found.sorted { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }

    func pluginRootRelative(_ url: URL, gmcc: GMCCEnvironment) -> String {
        guard let root = gmcc[runtime: .pluginRoot] else { return url.path }
        if url.path.hasPrefix(root) {
            return String(url.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.path
    }

    // MARK: Recents

    func markOpened(_ url: URL) {
        var next = recents.filter { $0 != url }
        next.insert(url, at: 0)
        if next.count > Self.recentsLimit {
            next = Array(next.prefix(Self.recentsLimit))
        }
        recents = next
    }

    func clearRecents() {
        recents = []
    }

    // MARK: File picker

    func pickFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Open a .yeet.yaml file"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: Helpers

    static func isYeetYAML(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".yeet.yaml") || name.hasSuffix(".yeet.yml")
    }

    private func persistRecents() {
        let paths = recents.map { $0.path }
        if let data = try? JSONEncoder().encode(paths) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    private static func loadRecents() -> [URL] {
        guard let data = UserDefaults.standard.data(forKey: recentsKey) else { return [] }
        guard let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        let fm = FileManager.default
        return paths
            .filter { fm.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
