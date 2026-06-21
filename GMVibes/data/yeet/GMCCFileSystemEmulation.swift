import Foundation
import Observation

// Single machine-wide read facade over the GMCC ckfs tree. Owns no timer of
// its own — pages drive refresh cadence via .task. State is published through
// @Observable so SwiftUI views re-render only when the slice they read changes.

@Observable
@MainActor
final class GMCCFileSystemEmulation {
    static let shared = GMCCFileSystemEmulation()
    private init() {}

    private(set) var projectIndex: GMCCProjectIndexFile?
    private(set) var projectData:  [UUID: GMCCProjectDataFile]  = [:]
    private(set) var instanceData: [UUID: GMCCInstanceDataFile] = [:]
    private(set) var sessionPrompts: [URL: [PromptFileStub]]    = [:]
    // Typed session_data files, keyed by the session_data.gmcc.yaml URL. Used by
    // the authoring surface to read the authoritative next-prompt id + kbite seed.
    private(set) var sessionData: [URL: GMCCSessionDataFile]    = [:]

    private(set) var lastError: [String: String] = [:]

    // MARK: - Refresh API (page-driven)

    func refreshProjectIndex(rootDirectory: URL) async {
        let key = "projectIndex"
        let url = rootDirectory.appendingPathComponent("project_index.gmcc.yaml")
        let result: Result<GMCCProjectIndexFile, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try GMCCRuntimeDecoder.decodeProjectIndex(at: url)) }
            catch { return .failure(error) }
        }.value
        switch result {
        case .success(let file):
            projectIndex = file
            lastError[key] = nil
        case .failure(let err):
            lastError[key] = err.localizedDescription
        }
    }

    func refreshProjectData(uuid: UUID, at url: URL) async {
        let key = "projectData:\(uuid)"
        let result: Result<GMCCProjectDataFile, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try GMCCRuntimeDecoder.decodeProjectData(at: url)) }
            catch { return .failure(error) }
        }.value
        switch result {
        case .success(let file):
            projectData[uuid] = file
            lastError[key] = nil
        case .failure(let err):
            lastError[key] = err.localizedDescription
        }
    }

    func refreshInstanceData(uuid: UUID, at url: URL) async {
        let key = "instanceData:\(uuid)"
        let result: Result<GMCCInstanceDataFile, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try GMCCRuntimeDecoder.decodeInstanceData(at: url)) }
            catch { return .failure(error) }
        }.value
        switch result {
        case .success(let file):
            instanceData[uuid] = file
            lastError[key] = nil
        case .failure(let err):
            lastError[key] = err.localizedDescription
        }
    }

    func refreshSessionData(at url: URL) async {
        let key = "sessionData:\(url.path)"
        let result: Result<GMCCSessionDataFile, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try GMCCRuntimeDecoder.decodeSessionData(at: url)) }
            catch { return .failure(error) }
        }.value
        switch result {
        case .success(let file):
            sessionData[url] = file
            lastError[key] = nil
        case .failure(let err):
            lastError[key] = err.localizedDescription
        }
    }

    func refreshSessionPrompts(at directoryURL: URL) async {
        let key = "sessionPrompts:\(directoryURL.path)"
        let stubs = await Task.detached(priority: .userInitiated) {
            GMCCFileSystemEmulation.readPromptStubs(in: directoryURL)
        }.value
        sessionPrompts[directoryURL] = stubs
        lastError[key] = nil
    }

    nonisolated private static func readPromptStubs(in directoryURL: URL) -> [PromptFileStub] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let stubs: [PromptFileStub] = contents.compactMap { url in
            guard url.pathExtension == "yaml" else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            let mtime = values?.contentModificationDate ?? .distantPast
            let display = url.deletingPathExtension().lastPathComponent
            return PromptFileStub(url: url, displayName: display, modifiedAt: mtime)
        }
        return stubs.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Raw file body (lazy reads)

    nonisolated static func readRawFile(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
