import SwiftUI
import AppKit

/// Trailing icon-button trio acting on an instance's on-disk checkout (`system_path`):
/// reveal it in Finder, open it in iTerm, and open it in VS Code. Shared by every
/// surface that shows per-instance identity (landing card, session navigator header,
/// projects detail) so the behavior stays identical. All buttons disable when there's
/// no usable path. The iTerm launcher keys a per-instance dynamic profile off the
/// instance UUID + name.
struct InstancePathActions: View {
    let systemPath: String?
    let instanceUUID: UUID
    let instanceName: String

    private var url: URL? {
        guard let p = systemPath, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal the instance checkout in Finder")

            Button {
                if let url {
                    ITerm.open(dir: url, instanceUUID: instanceUUID, instanceName: instanceName)
                }
            } label: {
                Image(systemName: "terminal")
            }
            .help("Open the instance checkout in iTerm")

            Button {
                if let url { VSCode.open(url) }
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .help("Open the instance checkout in VS Code")
        }
        .buttonStyle(.borderless)
        .disabled(url == nil)
    }
}
